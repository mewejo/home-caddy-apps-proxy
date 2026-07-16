# home-caddy-apps-proxy

Caddy reverse proxy for a wildcard apps domain (`*.<APPS_DOMAIN>`), built by
GitHub Actions and published to GHCR. The official Caddy image is rebuilt with
the [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) module so
the wildcard certificate can be issued via Cloudflare DNS-01, and the
[`Caddyfile`](Caddyfile) is baked into the image — no config file has to exist
on the Docker host.

All deployment-specific values (domain, upstreams, API token) are supplied as
environment variables; nothing personal lives in this repo.

Image: `ghcr.io/mewejo/home-caddy-apps-proxy:latest`

## Environment variables

| Variable       | Example                                  | Purpose                                    |
|----------------|------------------------------------------|--------------------------------------------|
| `CF_API_TOKEN` | *(Cloudflare API token)*                 | DNS-01 challenges. Zone:Read + DNS:Edit.   |
| `APPS_DOMAIN`  | `apps.example.com`                       | Apps are served at `*.APPS_DOMAIN`.        |
| `NS1_UPSTREAM` | `https://ns1.internal.example.com:443`   | Upstream for `ns1.<APPS_DOMAIN>`.          |

`{$VAR}` placeholders in the Caddyfile are substituted from the container
environment when the config is parsed at startup.

## Adding an app

1. Add a matcher + `handle` block to [`Caddyfile`](Caddyfile), referencing a
   new env var for its upstream:

   ```caddyfile
   @myapp host myapp.{$APPS_DOMAIN}

   handle @myapp {
       reverse_proxy {$MYAPP_UPSTREAM}
   }
   ```

2. Add the new env var and a routing assertion to
   [`tests/test.sh`](tests/test.sh), and add the env var to the stack
   environment in Portainer.
3. Commit and push to `main`. The workflow runs the test suite against the
   built image and only publishes `latest` if it passes.
4. In Portainer, update the stack with **Re-pull image and redeploy** enabled.

## Tests

`tests/run.sh` builds the image and runs [`tests/test.sh`](tests/test.sh)
against it (requires `docker` and `jq`). The suite validates the config
(provisioning every module), checks `caddy fmt` formatting, and asserts on the
adapted JSON: wildcard site address, per-app routing, upstream dial address,
`insecure_skip_verify` on the upstream transport, the 404 fallback, the
Let's Encrypt CA, and the Cloudflare DNS provider. CI runs the same script
before publishing. For TDD, add a failing assertion for the behavior you want,
then edit the Caddyfile until `tests/run.sh` passes.

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

## Notes

- The certificate served to clients is a real Let's Encrypt wildcard for
  `*.<APPS_DOMAIN>`. `tls_insecure_skip_verify` only applies to the connection
  between Caddy and an upstream, for upstreams with self-signed/internal
  certificates.
- The GHCR package is public (anonymous pulls work), so Portainer needs no
  registry credentials.
- Caddy and the Cloudflare module versions are pinned in the
  [`Dockerfile`](Dockerfile); bump them there to upgrade.
