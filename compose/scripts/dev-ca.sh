#!/usr/bin/env bash
# compose/scripts/dev-ca.sh — dev-TLS plumbing for TLS_MODE=internal (`make dev-ca`; called by `make up`).
#
# With `tls internal` Caddy mints its own CA under /data/caddy/pki/authorities/local/ in the caddy_data volume. This
# script starts caddy first, waits for the CA certificate and exports it to secrets/dev-root.crt, which compose.dev.yml
# mounts read-only into every n8n service (and Uptime Kuma) as /certs/dev-root.crt with NODE_EXTRA_CA_CERTS pointing at
# it — only the certificate, never the caddy_data volume with the CA's private key. Node reads that file ONCE at process
# start, so it must exist BEFORE those containers start; `make trust-ca` uses the same file.
# Idempotent; safe on a running stack.
# shellcheck disable=SC2310,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

need_cmd docker
if [[ ! -f .env ]]; then
  die ".env not found — run 'make init DOMAIN=<your-domain>' first"
fi
if [[ "$(env_get TLS_MODE)" != "internal" ]]; then
  info "TLS_MODE is not 'internal' — nothing to do (the dev CA only exists with tls internal)"
  exit 0
fi

cert_in_container=/data/caddy/pki/authorities/local/root.crt
cert_out="${KIT_DIR}/secrets/dev-root.crt"

info "starting caddy (and waiting for it to be healthy)"
compose up -d --wait --wait-timeout 90 caddy

info "waiting for the local CA (${cert_in_container})"
deadline=$((SECONDS + 60))
until compose exec -T caddy test -f "${cert_in_container}" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    die "caddy did not create its local CA within 60 s — check: make logs SERVICE=caddy"
  fi
  sleep 2
done

mkdir -p "${KIT_DIR}/secrets"
tmp="$(mktemp "${cert_out}.XXXXXX")"
compose cp "caddy:${cert_in_container}" "${tmp}" >/dev/null
chmod 644 "${tmp}"
if [[ -f "${cert_out}" ]] && cmp -s "${tmp}" "${cert_out}"; then
  rm -f "${tmp}"
  ok "dev CA unchanged: ${cert_out}"
else
  mv -f "${tmp}" "${cert_out}"
  ok "dev CA exported: ${cert_out} (run 'make trust-ca' to trust it on this host / your browser)"
fi
