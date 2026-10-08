#!/usr/bin/env bash
# 09-monitoring — the monitoring profile works end to end (TC-017): every Prometheus target is up and the key series
# exist (n8n queue, Caddy, host, containers, the backup sidecar's textfile metrics), Grafana answers through the edge
# under /grafana/ with its provisioned data sources (healthy), the 3 dashboards and the alert rules (none in error),
# Loki holds n8n's JSON logs with a level label, and — with the kuma profile — kuma.DOMAIN answers.
# Skipped (passes) when COMPOSE_PROFILES does not list "monitoring".
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

profiles=",$(env_get COMPOSE_PROFILES | tr -d ' '),"
if [[ "${profiles}" != *",monitoring,"* ]]; then
  info "monitoring profile off (COMPOSE_PROFILES) — skipped"
  finish
fi
project="$(_kit_project_name)"
gf_auth="$(env_get GRAFANA_ADMIN_USER):$(env_get GRAFANA_ADMIN_PASSWORD)"

prom() {   # prom PATH — Prometheus HTTP API, read inside the stack
  compose exec -T prometheus wget -qO- "http://127.0.0.1:9090${1}" 2>/dev/null || true
}
targets_down() {
  local t
  t="$(prom '/api/v1/targets?state=active')"
  [[ -n "${t}" ]] && jq -e '[.data.activeTargets[] | select(.health != "up")] | length == 0' <<<"${t}" >/dev/null
}
series_exists() {   # series_exists 'PROMQL' — the instant query returns at least one sample
  local r
  r="$(compose exec -T prometheus wget -qO- "http://127.0.0.1:9090/api/v1/query?query=$(jq -rn --arg q "${1}" '$q|@uri')" 2>/dev/null || true)"
  [[ -n "${r}" ]] && jq -e '.data.result | length > 0' <<<"${r}" >/dev/null
}

# --- Prometheus ---------------------------------------------------------------------------------------------------
check "every Prometheus scrape target is up (<= 120 s)" wait_for 120 "all targets up" targets_down
if ! targets_down; then
  prom '/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.health != "up") | "  down: \(.labels.job) \(.labels.instance) \(.lastError)"' >&2 || true
fi
for q in 'n8n_scaling_mode_queue_jobs_waiting' 'up{job="n8n-worker"} == 1' 'caddy_http_request_duration_seconds_count' \
  'node_load1' "container_memory_working_set_bytes{container_label_com_docker_compose_project=\"${project}\"}" \
  'backup_last_success_timestamp_seconds'; do
  check "Prometheus has ${q}" wait_for 60 "${q}" series_exists "${q}"
done

# --- Grafana through the edge ---------------------------------------------------------------------------------------
req GET /grafana/api/health
check "GET /grafana/api/health through Caddy (HTTP ${REQ_STATUS})" status_is 200
check "Grafana database ok" bash -c '[[ "$(jq -r .database <<<"$1")" == "ok" ]]' _ "$(req_body)"
req GET /grafana
check "/grafana redirects to /grafana/ (HTTP ${REQ_STATUS})" status_is 308
req GET /grafana/metrics
check "Grafana's /metrics is NOT public (HTTP ${REQ_STATUS})" status_is 404

for uid in prometheus loki; do
  req GET "/grafana/api/datasources/uid/${uid}/health" -u "${gf_auth}"
  check "data source ${uid} is healthy (HTTP ${REQ_STATUS}: $(jq -r '.message // .status // empty' <<<"$(req_body)" | head -c 80))" \
    bash -c '[[ "$1" == 200 && "$(jq -r .status <<<"$2")" == "OK" ]]' _ "${REQ_STATUS}" "$(req_body)"
done
for uid in kit-n8n-overview kit-host kit-backups; do
  req GET "/grafana/api/dashboards/uid/${uid}" -u "${gf_auth}"
  check "dashboard ${uid} is provisioned (HTTP ${REQ_STATUS}, $(jq -r '.dashboard.panels | length' <<<"$(req_body)" 2>/dev/null) panels)" status_is 200
done
req GET /grafana/api/v1/provisioning/alert-rules -u "${gf_auth}"
rule_count="$(jq -r 'length' <<<"$(req_body)" 2>/dev/null || echo 0)"
check "alert rules provisioned (${rule_count})" test "${rule_count}" -ge 13
rules_ok() {
  req GET /grafana/api/prometheus/grafana/api/v1/rules -u "${gf_auth}"
  [[ "${REQ_STATUS}" == 200 ]] && jq -e '[.data.groups[].rules[]] | length >= 13 and all(.health != "error")' <<<"$(req_body)" >/dev/null
}
check "every alert rule evaluates without error (<= 90 s)" wait_for 90 "rule health" rules_ok
if ! rules_ok; then
  jq -r '.data.groups[].rules[] | select(.health == "error") | "  \(.name): \(.lastError)"' <<<"$(req_body)" >&2 || true
fi

# --- Loki (queried through Grafana's data source proxy) -------------------------------------------------------------
loki_has() {   # loki_has 'LOGQL'
  req GET /grafana/api/datasources/proxy/uid/loki/loki/api/v1/query_range -u "${gf_auth}" -G \
    --data-urlencode "query=${1}" --data-urlencode "limit=5" --data-urlencode "since=15m"
  [[ "${REQ_STATUS}" == 200 ]] && jq -e '.data.result | length > 0' <<<"$(req_body)" >/dev/null
}
check "Loki holds n8n-main's logs (<= 90 s)" wait_for 90 "n8n-main logs in Loki" loki_has '{service="n8n-main"}'
check "n8n's JSON log level became a label" wait_for 30 "level label" loki_has '{service="n8n-main", level=~".+"}'
check "Loki holds Caddy's access log" wait_for 30 "caddy logs" loki_has '{service="caddy"}'

# --- Uptime Kuma (profile kuma) -------------------------------------------------------------------------------------
if [[ "${profiles}" == *",kuma,"* ]]; then
  kuma_url="${BASE_URL/:\/\//://kuma.}"
  kuma_status="$(curl -sS --max-time 30 "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' "${kuma_url}/" 2>/dev/null || echo 000)"
  check "Uptime Kuma answers at ${kuma_url}/ (HTTP ${kuma_status})" bash -c '[[ "$1" =~ ^(200|302)$ ]]' _ "${kuma_status}"
fi
finish
