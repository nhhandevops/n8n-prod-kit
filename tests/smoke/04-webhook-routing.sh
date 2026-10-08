#!/usr/bin/env bash
# 04-webhook-routing — a published workflow answers on /webhook/<path> through the webhook POOL (never main), the
# pool load-balances across every webhook process, and test/production routes go to the right process (TC-005).
# Leaves the workflow id, path and an execution id in the shared state for 05.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"

# Baselines for 05 and for the Postgres "NaN" error seen once on 2026-10-07 (HANDOFF §5).
state_set COMPLETED_BEFORE "$(main_metric n8n_scaling_mode_queue_jobs_completed)"
nan_before="$(compose logs --no-color postgres 2>/dev/null | grep -c 'NaN' || true)"

nonce="$(rand_hex 6)"
path="kit-smoke-${nonce}"
api POST /api/v1/workflows "$(workflow_from_fixture wf-webhook-echo.json "kit-smoke-${nonce}" "${path}")"
wf_id="$(req_body | jq -r '.id // empty')"
check "workflow created via the public API (HTTP ${REQ_STATUS})" test -n "${wf_id}"
api POST "/api/v1/workflows/${wf_id}/activate"
check "workflow published/activated (HTTP ${REQ_STATUS})" status_is 200
state_set WF_ID "${wf_id}"
state_set WF_PATH "${path}"
state_set NONCE "${nonce}"

post_ping() {
  req POST "/webhook/${path}" -H 'Content-Type: application/json' --data "{\"ping\":\"${nonce}\"}"
  status_is 200 && [[ "$(req_body | jq -r '.pong // empty' 2>/dev/null)" == "${nonce}" ]]
}
# activation reaches the webhook processes asynchronously — the first calls may 404 for a moment
check "POST /webhook/${path} echoes the nonce (HTTP ${REQ_STATUS})" wait_for 45 "webhook registered on the pool" post_ping
state_set EXEC_ID "$(req_body | jq -r '.exec // empty')"
first_upstream="$(header_of X-Kit-Upstream)"
check "production webhook served by the pool (${first_upstream})" bash -c '[[ "$1" =~ ^n8n-webhook-[0-9]+:5678$ ]]' _ "${first_upstream}"

pool_size="$(compose config --services | grep -cE '^n8n-webhook-[0-9]+$' || true)"
declare -A seen=()
if [[ -n "${first_upstream}" ]]; then
  seen["${first_upstream}"]=1
fi
for _ in $(seq 1 $((pool_size * 3))); do
  if post_ping; then
    upstream="$(header_of X-Kit-Upstream)"
    if [[ -n "${upstream}" ]]; then
      seen["${upstream}"]=1
    fi
  fi
done
check "round robin reached all ${pool_size} webhook processes (${!seen[*]})" test "${#seen[@]}" -eq "${pool_size}"

req POST "/webhook-test/${path}" -H 'Content-Type: application/json' --data '{}'
check "/webhook-test/ goes to n8n-main and 404s without a test session ($(header_of X-Kit-Upstream), HTTP ${REQ_STATUS})" \
  bash -c '[[ "$1" == 404 && "$2" == "n8n-main:5678" ]]' _ "${REQ_STATUS}" "$(header_of X-Kit-Upstream)"
for p in /form/x /form-waiting/x /webhook-waiting/x /mcp/x; do
  req GET "${p}"
  check "${p} routed to the pool ($(header_of X-Kit-Upstream))" bash -c '[[ "$1" =~ ^n8n-webhook-[0-9]+:5678$ ]]' _ "$(header_of X-Kit-Upstream)"
done
for p in /form-test/x /mcp-test/x /rest/settings; do
  req GET "${p}"
  check "${p} routed to n8n-main ($(header_of X-Kit-Upstream))" test "$(header_of X-Kit-Upstream)" = "n8n-main:5678"
done

nan_after="$(compose logs --no-color postgres 2>/dev/null | grep -c 'NaN' || true)"
if (( nan_after > nan_before )); then
  warn "postgres logged $((nan_after - nan_before)) new 'invalid input syntax ... NaN' error(s) during this script — known upstream issue under investigation (HANDOFF §5)"
fi
finish
