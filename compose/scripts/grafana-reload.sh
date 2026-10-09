#!/usr/bin/env bash
# compose/scripts/grafana-reload.sh — re-read Grafana's provisioning files after `make up` (monitoring profile).
# Grafana loads alert rules, contact points and data sources only at start; `make up` recreates Grafana only when its
# compose config changes, so an update that touched rules.yml or notifications.yml alone would keep the OLD rules running
# (seen 2026-10-09: 17 of 19 rules after a pull). Dashboards reload by themselves (every 60 s) but are reloaded here too.
# Uses Grafana's admin API from inside the container; the credentials go to curl on stdin, never on a command line.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

profiles=",$(env_get COMPOSE_PROFILES | tr -d ' '),"
if [[ "${profiles}" != *",monitoring,"* ]]; then
  exit 0
fi
if [[ "$(service_health grafana)" != "healthy" ]]; then
  warn "grafana is $(service_health grafana) — provisioning not reloaded (make restart SERVICE=grafana once it is healthy)"
  exit 0
fi
failed=''
for what in datasources alerting dashboards; do
  if ! printf 'user = "%s:%s"\n' "$(env_get GRAFANA_ADMIN_USER)" "$(env_get GRAFANA_ADMIN_PASSWORD)" |
    compose exec -T grafana curl -fsS -m 60 -o /dev/null -K - -X POST \
      "http://127.0.0.1:3000/grafana/api/admin/provisioning/${what}/reload" 2>/dev/null; then
    failed="${failed} ${what}"
  fi
done
if [[ -n "${failed}" ]]; then
  warn "grafana: could not reload provisioning for${failed} (GRAFANA_ADMIN_PASSWORD changed after Grafana's first start?) — make restart SERVICE=grafana"
else
  ok "grafana: provisioning reloaded (data sources, alert rules + contact point, dashboards)"
fi
