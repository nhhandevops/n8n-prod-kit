#!/usr/bin/env bash
# 10-error-workflow — a production execution that fails reaches the Error Workflow (TC-027).
#
# The Error Workflow is the only automatic hook left when an execution dies: n8n never retries one by itself, and
# node-level "Retry on Fail" dies with the process that runs it. This script proves the whole path on the running
# stack, using the shipped template as the handler:
#
#   1. a collector workflow stands in for the alert channel (a webhook whose execution keeps what was posted),
#   2. the handler is built from templates/error-handler/workflow.json with its "Send alert" node swapped from the
#      Telegram node to an HTTP Request into that collector — the Error Trigger and the "Build alert" Code node,
#      which hold all of the template's logic, are the shipped ones,
#   3. a workflow that throws on purpose gets settings.errorWorkflow pointing at the handler.
#
# Both halves of the documented behaviour are asserted: an error workflow that is saved but NOT published never
# runs (n8n loads the published version, so a forgotten Publish silently disables alerting), and once published it
# runs in mode 'error' on a worker with the failing workflow's name, node and message in the alert.
#
# Side effect: two deliberately failed executions per run (one per half). On a stack with the monitoring profile
# they count toward the ExecutionFailureRate panel.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"

TEMPLATE="${SMOKE_DIR}/../../templates/error-handler/workflow.json"
[[ -f "${TEMPLATE}" ]] || die "templates/error-handler/workflow.json is missing"

nonce="$(rand_hex 6)"
sink_path="kit-smoke-errsink-${nonce}"
fail_path="kit-smoke-errfail-${nonce}"

# --- the alert channel: a webhook whose execution record keeps whatever the handler posts ------------------------------
api POST /api/v1/workflows "$(workflow_from_fixture wf-error-collector.json "kit-smoke-errsink-${nonce}" "${sink_path}")"
sink_id="$(req_body | jq -r '.id // empty')"
check "collector workflow created (HTTP ${REQ_STATUS})" test -n "${sink_id}"
api POST "/api/v1/workflows/${sink_id}/activate"
check "collector published (HTTP ${REQ_STATUS})" status_is 200

# --- the handler: the shipped template, with the Telegram node replaced by an HTTP Request ----------------------------
# Replacing the node by NAME keeps the connections intact, so nothing else in the template has to be touched. The
# Telegram leg is the one part of the template this suite cannot exercise: it needs a bot token.
handler_json="$(jq -c --arg n "kit-smoke-errhandler-${nonce}" --arg u "${BASE_URL}/webhook/${sink_path}" '
  .name = $n
  | .nodes = [
      .nodes[]
      | if .name == "Send alert" then
          {
            parameters: {
              method: "POST",
              url: $u,
              sendBody: true,
              specifyBody: "json",
              jsonBody: "={{ JSON.stringify($json) }}",
              options: {}
            },
            name: "Send alert",
            type: "n8n-nodes-base.httpRequest",
            typeVersion: 4.2,
            position: .position
          }
        else . end
    ]' "${TEMPLATE}")"
api POST /api/v1/workflows "${handler_json}"
handler_id="$(req_body | jq -r '.id // empty')"
check "error handler created from the shipped template (HTTP ${REQ_STATUS})" test -n "${handler_id}"
[[ -n "${handler_id}" ]] || finish

# --- the workflow that fails, pointed at the handler ------------------------------------------------------------------
fail_json="$(workflow_from_fixture wf-fail-on-purpose.json "kit-smoke-errfail-${nonce}" "${fail_path}" \
  | jq -c --arg h "${handler_id}" '.settings.errorWorkflow = $h')"
api POST /api/v1/workflows "${fail_json}"
fail_id="$(req_body | jq -r '.id // empty')"
check "failing workflow created (HTTP ${REQ_STATUS})" test -n "${fail_id}"
[[ -n "${fail_id}" ]] || finish
api GET "/api/v1/workflows/${fail_id}"
stored_handler="$(req_body | jq -r '.settings.errorWorkflow // empty')"
check "settings.errorWorkflow stored as ${handler_id} (${stored_handler:-empty})" test "${stored_handler}" = "${handler_id}"
api POST "/api/v1/workflows/${fail_id}/activate"
check "failing workflow published (HTTP ${REQ_STATUS})" status_is 200

collector_runs() {   # how many times the collector ran
  api GET "/api/v1/executions?workflowId=${sink_id}&limit=20"
  req_body | jq -r '.data | length' 2>/dev/null || printf '0'
}
trigger_failure() {
  req POST "/webhook/${fail_path}" -H 'Content-Type: application/json' --data '{"ping":"boom"}'
  [[ "${REQ_STATUS}" == "500" ]]
}

# --- half 1: a handler that was never published must not run ----------------------------------------------------------
# n8n loads the error workflow's PUBLISHED version (dist/workflows/workflow-execution.service.js,
# loadErrorWorkflowData), so a handler that is only saved is a handler that alerts nobody.
check "POST /webhook/${fail_path} fails as designed (HTTP 500, <= 180 s)" \
  wait_for 180 "the failing webhook to be registered on the pool" trigger_failure
sleep 12   # the dispatch happens in the same hook that finalises the execution, so this is slack, not a race
runs_unpublished="$(collector_runs)"
check "an unpublished error handler never ran (${runs_unpublished} collector execution(s))" \
  test "${runs_unpublished}" = "0"
worker_logs() {
  local svc
  for svc in $(compose config --services | grep -E '^n8n-worker-[0-9]+$'); do
    compose logs --no-color --since 15m "${svc}" 2>/dev/null || true
  done
}
logs="$(worker_logs)"
not_active_lines="$(grep -cF 'is not active and cannot be executed' <<<"${logs}" || true)"
check "a worker said why (${not_active_lines} x 'is not active and cannot be executed')" \
  test "${not_active_lines}" -ge 1

# --- half 2: publish it, fail again, and read the alert back -----------------------------------------------------------
api POST "/api/v1/workflows/${handler_id}/activate"
check "error handler published (HTTP ${REQ_STATUS})" status_is 200

check "POST /webhook/${fail_path} fails again (HTTP 500)" wait_for 60 "the second deliberate failure" trigger_failure
alert_arrived() {
  [[ "$(collector_runs)" != "0" ]]
}
check "the Error Workflow ran and the alert reached the collector (<= 90 s)" \
  wait_for 90 "an alert in the collector" alert_arrived

api GET "/api/v1/executions?workflowId=${sink_id}&limit=20"
sink_exec="$(req_body | jq -r '.data[0].id // empty')"
api GET "/api/v1/executions/${sink_exec}?includeData=true"
body="$(req_body)"
# The alert is read wherever it sits in the execution data: the public API's shape for `data` has changed before,
# and this assertion only cares that the fields the template builds came through.
alert="$(jq -r '[.. | objects | select(has("collected")) | .collected] | first | tostring' <<<"${body}" 2>/dev/null || true)"
if [[ -z "${alert}" || "${alert}" == "null" ]]; then
  alert="${body}"
  info "  (the collected alert was read from the raw execution body, not from a 'collected' key)"
fi
check "the alert names the workflow that failed (kit-smoke-errfail-${nonce})" \
  grep -qF "kit-smoke-errfail-${nonce}" <<<"${alert}"
check "the alert names the node that failed (Boom)" grep -qF 'Boom' <<<"${alert}"
check "the alert carries the error message" grep -qF 'kit-smoke deliberate failure' <<<"${alert}"
check "the template's one-line summary is there (n8n FAILED: ...)" grep -qF 'n8n FAILED:' <<<"${alert}"

# --- the handler's own execution: mode 'error', on a worker -----------------------------------------------------------
api GET "/api/v1/executions?workflowId=${handler_id}&limit=5"
handler_exec="$(req_body | jq -r '.data[0].id // empty')"
handler_mode="$(req_body | jq -r '.data[0].mode // empty')"
handler_status="$(req_body | jq -r '.data[0].status // empty')"
check "the handler ran in mode 'error' (${handler_mode:-none})" test "${handler_mode}" = "error"
check "the handler execution succeeded (${handler_status:-none})" test "${handler_status}" = "success"
logs="$(worker_logs)"
ran_on_worker="$(grep -cF "Worker finished execution ${handler_exec} (" <<<"${logs}" || true)"
check "a worker executed the handler (execution ${handler_exec:-?})" test "${ran_on_worker}" -ge 1
finish
