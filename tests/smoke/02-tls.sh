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
# A 000 is curl refusing to connect or to trust what it was handed, and its reason only ever reached .smoke/last.err,
# which nothing reads: on 2026-11-09 "certificate has expired" sat in that file while this check printed a bare 000 and
# every container was healthy (warning_bug_and_solutions.md). Say why, and show the dates of the certificate the edge
# really serves, before the check fails — this is also what `make upgrade`'s verify step prints, through verify_side.
req GET /
if [[ "${REQ_STATUS}" == "000" ]]; then
  curl_err="$(tr -d '\r' <"${STATE_DIR}/last.err" | tail -2 | tr '\n' ' ' || true)"
  warn "curl could not complete the request: ${curl_err:-no output}"
  https_port="$(env_get HTTPS_PORT)"
  served="$(echo | openssl s_client -connect "${DOMAIN}:${https_port:-443}" -servername "${DOMAIN}" 2>/dev/null |
    openssl x509 -noout -dates 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "${served}" ]]; then
    warn "the certificate the edge serves for ${DOMAIN}: ${served}— if notAfter is in the past: make -C compose restart SERVICE=caddy (make doctor reports it too)"
  fi
fi
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
