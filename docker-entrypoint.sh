#!/bin/sh
# Generates /etc/caddy/Caddyfile from APPS_DOMAIN and APPS at container start,
# then runs the given command (caddy run by default).
#
#   APPS_DOMAIN  apps are served at *.APPS_DOMAIN, e.g. apps.example.com
#   APPS         comma-separated [name](upstream) pairs, e.g.
#                [ns1](https://ns1.internal.example.com:443),[web](http://10.0.0.5:3000)
#                name becomes name.APPS_DOMAIN; https upstreams are proxied
#                without certificate verification (for self-signed/internal
#                certs), http upstreams are proxied as-is.
set -eu

: "${APPS_DOMAIN:?APPS_DOMAIN is required, e.g. apps.example.com}"
: "${APPS:?APPS is required, e.g. [ns1](https://ns1.internal.example.com:443)}"

CADDYFILE="/etc/caddy/Caddyfile"

{
	printf '{\n'
	printf '\t# Force Let'\''s Encrypt rather than allowing issuer fallback.\n'
	printf '\tacme_ca https://acme-v02.api.letsencrypt.org/directory\n'
	printf '\n'
	printf '\t# Cloudflare DNS-01 globally, required for the wildcard certificate.\n'
	printf '\tacme_dns cloudflare {env.CF_API_TOKEN}\n'
	printf '}\n'
	printf '\n'
	printf '*.%s {\n' "$APPS_DOMAIN"

	printf '%s\n' "$APPS" | tr ',' '\n' | while IFS= read -r entry; do
		entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -z "$entry" ] && continue

		name=$(printf '%s' "$entry" | sed -n 's/^\[\([^]]*\)\](\([^)]*\))$/\1/p')
		url=$(printf '%s' "$entry" | sed -n 's/^\[\([^]]*\)\](\([^)]*\))$/\2/p')

		case "$name" in
			'' | *[!A-Za-z0-9-]*)
				echo "invalid APPS entry '$entry': name must be [A-Za-z0-9-]" >&2
				exit 1
				;;
		esac
		case "$url" in
			http://?* | https://?*) ;;
			*)
				echo "invalid APPS entry '$entry': expected [name](http(s)://host[:port])" >&2
				exit 1
				;;
		esac

		# Upstreams that redirect to their own hostname/IP (common for
		# appliance UIs) would bounce visitors off the public domain, so
		# absolute Location headers pointing at the upstream host are
		# rewritten back to the app's public hostname. Request headers
		# (Host, Referer, Origin) are deliberately passed through untouched:
		# apps like FreePBX require Referer host == Host header, which the
		# browser's own headers already satisfy.
		upstream_host=$(printf '%s' "$url" | sed 's~^[a-z]*://~~; s~[/:].*~~')
		upstream_host_re=$(printf '%s' "$upstream_host" | sed 's/\./\\./g')

		printf '\t@%s host %s.%s\n' "$name" "$name" "$APPS_DOMAIN"
		printf '\thandle @%s {\n' "$name"
		printf '\t\treverse_proxy %s {\n' "$url"
		printf '\t\t\theader_down Location ^https?://%s(:[0-9]+)?(/.*)?$ https://%s.%s$2\n' \
			"$upstream_host_re" "$name" "$APPS_DOMAIN"
		case "$url" in
			https://*)
				printf '\t\t\ttransport http {\n'
				printf '\t\t\t\ttls_insecure_skip_verify\n'
				printf '\t\t\t}\n'
				;;
		esac
		printf '\t\t}\n'
		printf '\t}\n'
		printf '\n'
	done

	printf '\t# Unmatched hostnames under the wildcard get a 404.\n'
	printf '\thandle {\n'
	printf '\t\trespond "Application not configured" 404\n'
	printf '\t}\n'
	printf '}\n'
} > "$CADDYFILE"

exec "$@"
