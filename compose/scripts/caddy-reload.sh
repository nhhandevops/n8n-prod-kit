#!/usr/bin/env bash
# compose/scripts/caddy-reload.sh — load the current Caddyfile into the running Caddy (`make up`, `make upgrade`).
# The Caddyfile and its snippets are bind-mounted: a `git pull` that changes them does not recreate the container, so
# Caddy would keep serving the old configuration until its next restart (seen 2026-10-09: S7 moved the n8n health
# checks to /healthz/readiness). `caddy reload` is graceful — no dropped connections — and refuses an invalid file,
# leaving the running configuration in place. Does nothing when Caddy is not running (its next start reads the file).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

[[ "$(service_health caddy)" == "healthy" ]] || exit 0
if out="$(compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
  ok "caddy: configuration reloaded"
else
  warn "caddy: the Caddyfile was not reloaded — it keeps the previous configuration (make logs SERVICE=caddy): ${out##*$'\n'}"
fi
