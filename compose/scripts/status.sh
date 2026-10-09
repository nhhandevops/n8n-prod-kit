#!/usr/bin/env bash
# compose/scripts/status.sh — one-glance health of the stack (`make status`, test case TC-003).
#
# Prints a table (service | state | health | started | restarts) for every service of the resolved compose
# configuration, then the login URL. Exit 1 when any service is not "running" with health "healthy" (a service without
# a healthcheck counts as healthy while running). Read-only.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

need_cmd docker
if [[ ! -f .env ]]; then
  die ".env not found — run 'make init DOMAIN=<your-domain>' first"
fi

project="$(_kit_project_name)"
mapfile -t services < <(compose config --services 2>/dev/null || true)
if (( ${#services[@]} == 0 )); then
  die "could not list services (compose config failed) — run: make config"
fi

# age "2h13m" from an RFC3339 StartedAt
age_of() {
  local started="${1}" start_s now_s delta
  start_s="$(date -d "${started}" +%s 2>/dev/null || echo 0)"
  now_s="$(date +%s)"
  delta=$((now_s - start_s))
  if (( start_s == 0 || delta < 0 )); then
    printf -- '-\n'
  elif (( delta < 3600 )); then
    printf '%dm\n' $((delta / 60))
  elif (( delta < 86400 )); then
    printf '%dh%02dm\n' $((delta / 3600)) $(((delta % 3600) / 60))
  else
    printf '%dd%02dh\n' $((delta / 86400)) $(((delta % 86400) / 3600))
  fi
}

bad=0
log ""
printf '%-24s %-10s %-10s %-9s %s\n' SERVICE STATE HEALTH UP RESTARTS >&2
printf '%-24s %-10s %-10s %-9s %s\n' ------------------------ ---------- ---------- --------- -------- >&2
for svc in "${services[@]}"; do
  cid="$(docker ps -aq --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=${svc}" | head -1 || true)"
  if [[ -z "${cid}" ]]; then
    printf '%-24s %-10s %-10s %-9s %s\n' "${svc}" missing - - - >&2
    bad=$((bad + 1))
    continue
  fi
  state="$(docker inspect --format '{{.State.Status}}' "${cid}")"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
  started="$(docker inspect --format '{{.State.StartedAt}}' "${cid}")"
  restarts="$(docker inspect --format '{{.RestartCount}}' "${cid}")"
  up="$(age_of "${started}")"
  printf '%-24s %-10s %-10s %-9s %s\n' "${svc}" "${state}" "${health}" "${up}" "${restarts}" >&2
  if [[ "${state}" != "running" ]] || [[ "${health}" != "healthy" && "${health}" != "none" ]]; then
    bad=$((bad + 1))
  fi
done
log ""

public_url="$(env_get PUBLIC_URL)"
if (( bad > 0 )); then
  warn "${bad} service(s) not healthy — inspect with: make logs SERVICE=<name> SINCE=10m   (unhealthy ones: docker inspect --format '{{json .State.Health.Log}}' <container>)"
  die "status: ${bad} service(s) need attention"
fi
ok "all ${#services[@]} services running and healthy"
log "  n8n:  ${public_url}"
if [[ " ${services[*]} " == *" grafana "* ]]; then
  log "  grafana: ${public_url}grafana/   (user $(env_get GRAFANA_ADMIN_USER), password GRAFANA_ADMIN_PASSWORD in .env)"
fi
if [[ " ${services[*]} " == *" uptime-kuma "* ]]; then
  log "  uptime kuma: ${public_url/:\/\//://kuma.}   (user $(env_get KUMA_ADMIN_USER), password KUMA_ADMIN_PASSWORD in .env)"
fi
if [[ "$(env_get TLS_MODE)" == "internal" ]]; then
  log "  dev TLS: the certificate is signed by the kit's local CA — run 'make trust-ca' once so browsers and curl trust it"
fi
