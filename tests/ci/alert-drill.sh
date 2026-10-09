#!/usr/bin/env bash
# tests/ci/alert-drill.sh — TC-018 and its worker twin, end to end through Grafana:
#   1. stop both webhook processors -> WebhookPoolDown fires within 3 minutes, routed to the Telegram contact point;
#      start them again -> it resolves
#   2. stop both workers -> WorkerPoolDown (critical: nothing executes) fires within 4 minutes, routed the same way;
#      start them again -> it resolves
# Needs the monitoring profile and ALERT_TELEGRAM_* set (CI uses a dummy bot: Telegram rejects the delivery, the routing
# is what is checked). On a real install every step sends a real Telegram message.
# Usage: tests/ci/alert-drill.sh [webhook|worker|all]   (default all)
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
KIT_DIR="${REPO_DIR}/compose"
# shellcheck source=../../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

which="${1:-all}"
auth="$(env_get GRAFANA_ADMIN_USER):$(env_get GRAFANA_ADMIN_PASSWORD)"
base="$(env_get PUBLIC_URL)grafana"
tls=()
if [[ -f secrets/dev-root.crt ]]; then
  tls=(--cacert secrets/dev-root.crt)
fi
gf() { curl -fsS --max-time 20 "${tls[@]}" -u "${auth}" "${base}${1}" 2>/dev/null || true; }
alert_state() {   # alert_state NAME — Grafana state: Alerting | Pending | Normal (none = no instance yet)
  gf /api/prometheus/grafana/api/v1/alerts |
    jq -r --arg n "${1}" '[.data.alerts[]? | select(.labels.alertname == $n) | .state] | first // "none"'
}
wait_state() {   # wait_state NAME REGEX SECONDS
  local deadline=$((SECONDS + ${3})) s
  while :; do
    s="$(alert_state "${1}")"
    if [[ "${s}" =~ ${2} ]]; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      fail "${1} is '${s}' after ${3} s (wanted ${2})"
      return 1
    fi
    sleep 5
  done
}

drill() {   # drill ALERT LIMIT_SECONDS SERVICE...
  local alert="${1}" limit="${2}" started receivers
  shift 2
  [[ "$(alert_state "${alert}")" =~ ^(none|Normal|normal|inactive)$ ]] ||
    die "${alert} is already '$(alert_state "${alert}")' before the drill"
  info "${alert}: stopping ${*}"
  compose stop "${@}" >/dev/null
  started=${SECONDS}
  wait_state "${alert}" '^(Alerting|firing)$' "${limit}" ||
    { compose up -d --wait >/dev/null; die "${alert} did not fire within ${limit} s"; }
  ok "${alert} firing $((SECONDS - started)) s after ${*} went down (limit ${limit} s)"
  receivers="$(gf /api/alertmanager/grafana/api/v2/alerts |
    jq -r --arg n "${alert}" '[.[]? | select(.labels.alertname == $n) | .receivers[].name] | unique | join(",")')"
  [[ "${receivers}" == *telegram* ]] ||
    { compose up -d --wait >/dev/null; die "${alert} is not routed to the telegram receiver (receivers: '${receivers:-none}')"; }
  ok "routed to the Telegram contact point (receivers: ${receivers})"
  info "starting ${*} again"
  compose up -d --wait --wait-timeout 480 >/dev/null
  started=${SECONDS}
  wait_state "${alert}" '^(Normal|normal|inactive|none)$' 180
  ok "${alert} resolved $((SECONDS - started)) s after ${*} came back"
}

if [[ "${which}" == "webhook" || "${which}" == "all" ]]; then
  # TC-018: scrape 15 s + evaluation 30 s + for 1 m (+ group wait 30 s before the message)
  drill WebhookPoolDown 180 n8n-webhook-1 n8n-webhook-2
fi
if [[ "${which}" == "worker" || "${which}" == "all" ]]; then
  mapfile -t workers < <(compose config --services | grep -E '^n8n-worker-[0-9]+$')
  drill WorkerPoolDown 240 "${workers[@]}"
fi
