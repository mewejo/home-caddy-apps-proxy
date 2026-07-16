# home-caddy-apps-proxy

Caddy reverse proxy for a wildcard apps domain (`*.<APPS_DOMAIN>`), built by
GitHub Actions and published to GHCR. The official Caddy image is rebuilt with
the [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) module so
the wildcard certificate can be issued via Cloudflare DNS-01.

The Caddyfile is **generated at container start** by
[`docker-entrypoint.sh`](docker-entrypoint.sh) from environment variables — no
config file on the Docker host, no image rebuild to add an app, and nothing
personal in this repo.

Image: `ghcr.io/mewejo/home-caddy-apps-proxy:latest`

## Environment variables

| Variable       | Example                                          | Purpose                                  |
|----------------|--------------------------------------------------|------------------------------------------|
| `CF_API_TOKEN` | *(Cloudflare API token)*                         | DNS-01 challenges. Zone:Read + DNS:Edit. |
| `APPS_DOMAIN`  | `apps.example.com`                               | Apps are served at `*.APPS_DOMAIN`.      |
| `APPS`         | `[ns1](https://ns1.internal.example.com:443),[web](http://10.0.0.5:3000)` | The app list (see below). |

`APPS` is a comma-separated list of `[name](upstream)` pairs:

- `name` (letters, digits, hyphens) is served at `name.<APPS_DOMAIN>`.
- `upstream` is a full URL. `https://` upstreams are proxied **without
  certificate verification** (for self-signed/internal certs); `http://`
  upstreams are proxied as-is.
- Hostnames under the wildcard with no matching app return a 404.
- Malformed entries make the container exit at startup with an error, so a
  typo can't silently drop an app.

## Adding an app

Edit the `APPS` stack environment variable in Portainer and redeploy the
stack. No commit, rebuild, or image pull needed.

## Deployment (Portainer stack)

Use [`portainer-stack.yml`](portainer-stack.yml). It assumes an existing
macvlan/ipvlan Docker network named `services-vlan` whose subnet includes the
static address given to Caddy — Caddy is directly addressable on that VLAN, so
no `ports:` mappings are needed. Set the environment variables above as stack
env vars in Portainer.

## DNS

In Cloudflare, create (DNS only — not proxied, if Caddy's address is private):

| Type | Name              | Content                |
|------|-------------------|------------------------|
| A    | `*.<APPS_DOMAIN>` | *(Caddy's IP address)* |

## Tests

`tests/run.sh` builds the image and runs [`tests/test.sh`](tests/test.sh)
against it (requires `docker` and `jq`). The suite exercises the Caddyfile
generator with fixture apps: config validation (provisioning every module),
`caddy fmt` canonical output, rejection of malformed `APPS` entries, and
assertions on the adapted JSON — wildcard site address, per-app routing,
upstream dial addresses, `insecure_skip_verify` for https upstreams (and its
absence for http upstreams), the 404 fallback, the Let's Encrypt CA, and the
Cloudflare DNS provider. CI runs the same script and only publishes if it
passes. For TDD, add a failing assertion for the behavior you want, then edit
the entrypoint until `tests/run.sh` passes.

## Notes

- The certificate served to clients is a real Let's Encrypt wildcard for
  `*.<APPS_DOMAIN>`. `tls_insecure_skip_verify` only applies to connections
  between Caddy and https upstreams.
- The GHCR package is public (anonymous pulls work), so Portainer needs no
  registry credentials.
- Caddy and the Cloudflare module versions are pinned in the
  [`Dockerfile`](Dockerfile); bump them there to upgrade.
