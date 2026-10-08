#!/usr/bin/env bash
# 06-metrics — every n8n process and Caddy expose Prometheus metrics INSIDE the stack (what S6 scrapes), main carries
# the Bull queue gauges, and /metrics is NOT reachable through the public edge (TC-017 part).
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

metrics_of() {
  compose exec -T "${1}" wget -qO- "${2}" 2>/dev/null || true
}

main_metrics="$(metrics_of n8n-main http://127.0.0.1:5678/metrics)"
for gauge in waiting active completed failed; do
  check "n8n-main exposes n8n_scaling_mode_queue_jobs_${gauge}" grep -q "^n8n_scaling_mode_queue_jobs_${gauge} " <<<"${main_metrics}"
done
for svc in $(compose config --services | grep -E '^n8n-(worker|webhook)-[0-9]+$'); do
  lines="$(metrics_of "${svc}" http://127.0.0.1:5678/metrics | grep -c '^n8n_' || true)"
  check "${svc} exposes n8n_* metrics (${lines} series)" test "${lines}" -gt 0
done
caddy_lines="$(metrics_of caddy http://127.0.0.1:2019/metrics | grep -c '^caddy_http_request_duration_seconds_count' || true)"
check "caddy exposes caddy_http_* metrics on its admin endpoint" test "${caddy_lines}" -gt 0

req GET /metrics
check "/metrics is NOT public through the edge (HTTP ${REQ_STATUS})" status_is 404
finish
