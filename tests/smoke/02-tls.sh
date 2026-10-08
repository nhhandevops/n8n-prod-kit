#!/usr/bin/env bash
# 02-tls — the edge: http -> https redirect (keeping a non-standard port), a certificate chain that validates,
# security headers, no Server banner, health routes to the right upstream (TC-004).
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

http_port="$(env_get HTTP_PORT)"
http_url="http://${DOMAIN}"
if [[ -n "${http_port}" && "${http_port}" != "80" ]]; then
  http_url="${http_url}:${http_port}"
fi
redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "${http_url}/" || true)"
check "http -> https redirect: ${redirect}" test "${redirect}" = "308 ${BASE_URL}/"

# req uses CURL_TLS (dev CA / system store): a successful request IS the chain validation.
req GET /
check "TLS chain validates and / answers 200 (got ${REQ_STATUS})" status_is 200
check "HSTS header" test -n "$(header_of Strict-Transport-Security)"
check "X-Content-Type-Options: nosniff" test "$(header_of X-Content-Type-Options)" = "nosniff"
check "X-Frame-Options: SAMEORIGIN" test "$(header_of X-Frame-Options)" = "SAMEORIGIN"
check "no Server banner" test -z "$(header_of Server)"

req GET /healthz
check "/healthz -> 200 from n8n-main ($(header_of X-Kit-Upstream))" \
  bash -c '[[ "$1" == 200 && "$2" == "n8n-main:5678" ]]' _ "${REQ_STATUS}" "$(header_of X-Kit-Upstream)"
req GET /healthz/webhook
check "/healthz/webhook -> 200 from the webhook pool ($(header_of X-Kit-Upstream))" \
  bash -c '[[ "$1" == 200 && "$2" =~ ^n8n-webhook-[0-9]+:5678$ ]]' _ "${REQ_STATUS}" "$(header_of X-Kit-Upstream)"
finish
