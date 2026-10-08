#!/usr/bin/env bash
# 05-execution-on-worker — the executions from 04 ran in queue mode: recorded as success in Postgres and the public
# API, executed by a WORKER (its log names the execution), counted by main's queue metrics, Bull keys live in
# Valkey; and a Code node can make HTTP calls through the worker (the runner sandbox has no network of its own)
# (TC-006).
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"
wf_id="$(state_get WF_ID)"
exec_id="$(state_get EXEC_ID)"
if [[ -z "${wf_id}" || ! "${exec_id}" =~ ^[0-9]+$ ]]; then
  die "no workflow/execution from 04 in compose/.smoke/state.env — run: make smoke ONLY=04,05"
fi

execution_succeeded() {
  api GET "/api/v1/executions?workflowId=${wf_id}&limit=50"
  [[ "$(req_body | jq -r --arg id "${exec_id}" '.data[] | select(.id == $id) | .status')" == "success" ]]
}
check "execution ${exec_id} has status success in the public API (<= 60 s)" wait_for 60 "execution ${exec_id} success" execution_succeeded

pg_status="$(compose exec -T postgres psql -U n8n -d n8n -Atc "select status from execution_entity where id = ${exec_id}" 2>/dev/null || true)"
check "execution ${exec_id} stored as success in Postgres (${pg_status:-none})" test "${pg_status}" = "success"

# The worker that ran it logs "Worker finished execution <id> (job <n>)" (n8n 2.42, JSON log line).
# Logs are captured before grepping: `compose logs | grep -q` under pipefail fails at random (grep exits on the first
# match, compose gets SIGPIPE, the pipeline reports failure even though the line was found).
runner_worker=''
for svc in $(compose config --services | grep -E '^n8n-worker-[0-9]+$'); do
  worker_logs="$(compose logs --no-color "${svc}" 2>/dev/null || true)"
  if grep -qF "Worker finished execution ${exec_id} (" <<<"${worker_logs}"; then
    runner_worker="${svc}"
    break
  fi
done
check "a worker executed it (${runner_worker:-no worker log mentions execution ${exec_id}})" test -n "${runner_worker}"
main_log_hit="$(compose logs --no-color n8n-main 2>/dev/null | grep -cF "Worker finished execution ${exec_id} (" || true)"
check "n8n-main did NOT execute it itself" test "${main_log_hit}" -eq 0

# main refreshes its queue gauges every N8N_METRICS_QUEUE_METRICS_INTERVAL (20 s in the kit), so a fast run can
# finish before the counter moves — wait for the next refresh.
before="$(state_get COMPLETED_BEFORE)"
after=''
completed_increased() {
  after="$(main_metric n8n_scaling_mode_queue_jobs_completed)"
  awk -v a="${after:-0}" -v b="${before:-0}" 'BEGIN { exit !(a > b) }'
}
check "queue metric n8n_scaling_mode_queue_jobs_completed increased (<= 45 s; metrics refresh every 20 s)" \
  wait_for 45 "queue metrics refresh" completed_increased
info "  n8n_scaling_mode_queue_jobs_completed: ${before:-0} -> ${after:-?}"

keys="$(compose exec -T valkey sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli --scan --pattern "n8n:*" | head -50' 2>/dev/null | grep -c . || true)"
check "Bull keys present in Valkey (${keys} n8n:* keys sampled)" test "${keys}" -gt 0

# HTTP from inside a Code node: this.helpers.httpRequest runs on the worker (RPC from the sandbox), which has egress
# and trusts the dev CA. Plain fetch() is not available in the sandbox by design.
nonce="$(rand_hex 6)"
path="kit-smoke-http-${nonce}"
api POST /api/v1/workflows "$(workflow_from_fixture wf-http-helper.json "kit-smoke-http-${nonce}" "${path}" "${BASE_URL}/healthz")"
http_wf="$(req_body | jq -r '.id // empty')"
api POST "/api/v1/workflows/${http_wf}/activate"
helper_ok() {
  req POST "/webhook/${path}" -H 'Content-Type: application/json' --data '{}'
  status_is 200 && [[ "$(req_body | jq -r '.helper.status // empty' 2>/dev/null)" == "ok" ]]
}
check "Code node this.helpers.httpRequest reaches ${BASE_URL}/healthz through the worker" wait_for 45 "helper workflow" helper_ok
finish
