#!/usr/bin/env bash
# Assertion suite for the built image. Requires docker and jq.
# Usage: IMAGE=<image tag> tests/test.sh
set -uo pipefail

IMAGE="${IMAGE:?Set IMAGE to the image tag under test}"

# Deployment-shaped test fixtures — the entrypoint generates the Caddyfile
# from these at container start. One https upstream (proxied with
# tls_insecure_skip_verify) and one plain http upstream.
APPS_DOMAIN="apps.example.test"
APPS="[ns1](https://ns1.internal.example.test:8443),[web](http://10.0.0.5:3000)"
# The Cloudflare module format-checks the token (40 chars of [A-Za-z0-9_-])
# at provision time, so validation needs a format-valid dummy value.
CF_API_TOKEN="CIDummyToken0000000000000000000000000000"

run_caddy() {
  docker run --rm \
    -e CF_API_TOKEN="$CF_API_TOKEN" \
    -e APPS_DOMAIN="$APPS_DOMAIN" \
    -e APPS="$APPS" \
    "$IMAGE" caddy "$@"
}

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# --- validation: provisions every module, including the DNS provider --------

validate_output="$(run_caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"
if [ $? -eq 0 ]; then
  pass "caddy validate succeeds"
else
  fail "caddy validate succeeds"
  echo "$validate_output" | tail -5 | sed 's/^/       /'
fi

# --- generator: rejects malformed APPS entries -------------------------------

if docker run --rm -e CF_API_TOKEN="$CF_API_TOKEN" -e APPS_DOMAIN="$APPS_DOMAIN" \
    -e APPS="not-a-valid-entry" "$IMAGE" \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  fail "malformed APPS entry is rejected"
else
  pass "malformed APPS entry is rejected"
fi

# --- formatting: generated Caddyfile must be canonical (caddy fmt clean) -----

if run_caddy fmt --diff /etc/caddy/Caddyfile >/dev/null 2>&1; then
  pass "generated Caddyfile is canonically formatted"
else
  fail "generated Caddyfile is canonically formatted"
fi

# --- behavior: assertions against the adapted JSON config --------------------

json="$(run_caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null)"
if [ -z "$json" ]; then
  fail "caddy adapt produces JSON"
  echo "cannot run config assertions without adapted JSON"
  exit 1
fi
pass "caddy adapt produces JSON"

assert_jq() {
  local name="$1" expr="$2"
  if jq -e "$expr" >/dev/null 2>&1 <<<"$json"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_jq "serves the wildcard apps domain" \
  '[.apps.http.servers[].routes[].match[]?.host[]?] | index("*.apps.example.test")'

assert_jq "routes ns1.<APPS_DOMAIN>" \
  '[.. | objects | .host? | select(type == "array") | .[]] | index("ns1.apps.example.test")'

assert_jq "routes web.<APPS_DOMAIN>" \
  '[.. | objects | .host? | select(type == "array") | .[]] | index("web.apps.example.test")'

assert_jq "https upstream proxies to the right host and port" \
  '[.. | objects | select(.handler? == "reverse_proxy" and .upstreams[0].dial == "ns1.internal.example.test:8443")] | length == 1'

assert_jq "https upstream uses TLS without certificate verification" \
  '[.. | objects | select(.handler? == "reverse_proxy" and .upstreams[0].dial == "ns1.internal.example.test:8443")][0].transport.tls.insecure_skip_verify == true'

assert_jq "http upstream proxies to the right host and port" \
  '[.. | objects | select(.handler? == "reverse_proxy" and .upstreams[0].dial == "10.0.0.5:3000")] | length == 1'

assert_jq "http upstream is proxied without TLS" \
  '[.. | objects | select(.handler? == "reverse_proxy" and .upstreams[0].dial == "10.0.0.5:3000")][0] | (.transport.tls? // null) == null'

assert_jq "upstream-host Location redirects are rewritten to the public hostname" \
  '[.. | objects | select(.handler? == "reverse_proxy" and .upstreams[0].dial == "ns1.internal.example.test:8443")][0].headers.response.replace.Location[0]
   | (.search_regexp == "^https?://ns1\\.internal\\.example\\.test(:[0-9]+)?(/.*)?$") and (.replace == "https://ns1.apps.example.test$2")'

assert_jq "request headers pass through untouched (no header_up rewrites)" \
  '[.. | objects | select(.handler? == "reverse_proxy")] | all(.headers.request == null)'

assert_jq "http upstream also gets the Location rewrite" \
  '[.. | objects | select(.handler? == "reverse_proxy" and .upstreams[0].dial == "10.0.0.5:3000")][0].headers.response.replace.Location[0].replace == "https://web.apps.example.test$2"'

assert_jq "unmatched hostnames fall through to a 404" \
  '[.. | objects | select(.handler? == "static_response")][0].status_code | tostring == "404"'

assert_jq "certificates come from Let's Encrypt production" \
  '[.. | objects | select(.module? == "acme")] | any(.ca == "https://acme-v02.api.letsencrypt.org/directory")'

assert_jq "ACME uses the Cloudflare DNS provider" \
  '[.. | objects | select(.name? == "cloudflare")] | length > 0'

assert_jq "API token stays a runtime env placeholder, not baked into config" \
  '[.. | objects | select(.name? == "cloudflare")][0].api_token == "{env.CF_API_TOKEN}"'

# --- summary ------------------------------------------------------------------

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
