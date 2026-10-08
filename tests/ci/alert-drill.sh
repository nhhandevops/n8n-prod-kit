#!/usr/bin/env bash
# tests/ci/alert-drill.sh — TC-018: stop both webhook processors -> Grafana fires WebhookPoolDown within 3 minutes and
# routes it to the Telegram contact point; start them again -> the alert resolves. Needs the monitoring profile and
# ALERT_TELEGRAM_* set (CI uses a dummy bot: the delivery itself is rejected by Telegram, the routing is what is checked).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
KIT_DIR="${REPO_DIR}/compose"
# shellcheck source=../../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

auth="$(env_get GRAFANA_ADMIN_USER):$(env_get GRAFANA_ADMIN_PASSWORD)"
base="$(env_get PUBLIC_URL)grafana"
tls=()
if [[ -f secrets/dev-root.crt ]]; then
  tls=(--cacert secrets/dev-root.crt)
fi
gf() { curl -fsS --max-time 20 "${tls[@]}" -u "${auth}" "${base}${1}" 2>/dev/null || true; }
alert_state() {   # Grafana state of WebhookPoolDown: Alerting | Pending | Normal (none = no instance yet)
  gf /api/prometheus/grafana/api/v1/alerts |
    jq -r '[.data.alerts[]? | select(.labels.alertname == "WebhookPoolDown") | .state] | first // "none"'
}
wait_state() {   # wait_state REGEX SECONDS
  local deadline=$((SECONDS + ${2})) s
  while :; do
    s="$(alert_state)"
    if [[ "${s}" =~ ${1} ]]; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      fail "WebhookPoolDown is '${s}' after ${2} s (wanted ${1})"
      return 1
    fi
    sleep 5
  done
}

[[ "$(alert_state)" =~ ^(none|Normal|normal|inactive)$ ]] || die "WebhookPoolDown is already '$(alert_state)' before the drill"
info "stopping both webhook processors"
compose stop n8n-webhook-1 n8n-webhook-2 >/dev/null
started=${SECONDS}
wait_state '^(Alerting|firing)$' 180 || { compose up -d --wait >/dev/null; die "TC-018 failed: no alert within 3 minutes"; }
ok "WebhookPoolDown firing $((SECONDS - started)) s after the pool went down (TC-018: < 180 s)"

receivers="$(gf /api/alertmanager/grafana/api/v2/alerts |
  jq -r '[.[]? | select(.labels.alertname == "WebhookPoolDown") | .receivers[].name] | unique | join(",")')"
[[ "${receivers}" == *telegram* ]] || { compose up -d --wait >/dev/null; die "the alert is not routed to the telegram receiver (receivers: '${receivers:-none}')"; }
ok "routed to the Telegram contact point (receivers: ${receivers})"

info "starting the webhook processors again"
compose up -d --wait --wait-timeout 240 >/dev/null
started=${SECONDS}
wait_state '^(Normal|normal|inactive|none)$' 180
ok "WebhookPoolDown resolved $((SECONDS - started)) s after the pool came back"
