#!/usr/bin/env bash
# 12-gchat-approval — the shipped gchat-approval template suspends on a human decision and resumes through
# the kit's /webhook-waiting/ route, for both answers (M1).
#
# What this proves that nothing else does: the Caddyfile has routed `/webhook-waiting/*` to the webhook pool
# since S2 and 04 asserts the route exists, but no test has ever driven an execution through it. A waiting
# execution is also the one place where n8n hands a URL to a human and then trusts what comes back, so the
# token on that URL is part of the mechanism — n8n 2.x answers 401 to a resume with the wrong one.
#
# What is under test is the file a user downloads — templates/gchat-approval/workflow.json — with three
# things substituted and nothing else: the workflow name, the webhook path, and the URL of the
# "Ask in Google Chat" node, pointed at a sink workflow so the card (and the two button URLs inside it) can
# be read back. Nothing else is touched: the Code node that builds those URLs, the Wait node and the IF are
# the shipped ones.
#
# Side effects on the stack: two executions that reach `waiting` and are then resumed, plus one deliberate
# 401 and one deliberate 409.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; sh -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"

TEMPLATE="${SMOKE_DIR}/../../templates/gchat-approval/workflow.json"
[[ -f "${TEMPLATE}" ]] || die "templates/gchat-approval/workflow.json is missing"

nonce="$(rand_hex 6)"
gate_path="kit-smoke-appr-${nonce}"
sink_path="kit-smoke-apprsink-${nonce}"

# --- the sink: it receives the Chat card, so the test can read the buttons a human would click -----------
api POST /api/v1/workflows "$(workflow_from_fixture wf-idem-sink.json "kit-smoke-apprsink-${nonce}" "${sink_path}")"
sink_id="$(req_body | jq -r '.id // empty')"
check "card sink created (HTTP ${REQ_STATUS})" test -n "${sink_id}"
api POST "/api/v1/workflows/${sink_id}/activate"
check "card sink published (HTTP ${REQ_STATUS})" status_is 200
[[ -n "${sink_id}" ]] || finish

# --- the gate: the shipped template, with three substitutions -------------------------------------------
gate_json="$(jq -c --arg n "kit-smoke-appr-${nonce}" --arg p "${gate_path}" --arg u "${BASE_URL}/webhook/${sink_path}" '
  .name = $n
  | .nodes = [
      .nodes[]
      | if .type == "n8n-nodes-base.webhook" then .parameters.path = $p else . end
      | if .name == "Ask in Google Chat" then .parameters.url = $u else . end
    ]' "${TEMPLATE}")"
# The logic has to be the shipped logic: if a future edit builds the button URLs with ? instead of &, the
# token is dropped and every approval 401s — so that exact string is asserted here, not just "a URL".
check "the card still appends the decision with & so the resume token survives" \
  grep -q 'approved=true' <<<"${gate_json}"
check "the gate still waits on a webhook (not a timer)" grep -q '"resume": *"webhook"' <<<"${gate_json}"

api POST /api/v1/workflows "${gate_json}"
gate_id="$(req_body | jq -r '.id // empty')"
check "gate workflow created from the shipped template (HTTP ${REQ_STATUS})" test -n "${gate_id}"
[[ -n "${gate_id}" ]] || finish
api POST "/api/v1/workflows/${gate_id}/activate"
check "gate published (HTTP ${REQ_STATUS})" status_is 200

# --- helpers ---------------------------------------------------------------------------------------------
trigger() {   # trigger REF -> POSTs one approval request
  req POST "/webhook/${gate_path}" -H 'Content-Type: application/json' \
    --data "{\"ref\":\"${1}\",\"requester\":\"smoke@example.com\",\"amountVnd\":2500000,\"reason\":\"kit smoke ${nonce}\"}"
}
gate_exec_with_status() {   # gate_exec_with_status STATUS -> newest execution id with that status, or empty
  api GET "/api/v1/executions?workflowId=${gate_id}&status=${1}&limit=5"
  req_body | jq -r '.data[0].id // empty' 2>/dev/null || true
}
waiting_exec=''
gate_is_waiting() {
  waiting_exec="$(gate_exec_with_status waiting)"
  [[ -n "${waiting_exec}" ]]
}
card_urls() {   # the openLink URLs the card carried, newest sink execution, one per line
  local ex body
  api GET "/api/v1/executions?workflowId=${sink_id}&limit=5"
  ex="$(req_body | jq -r '.data[0].id // empty')"
  [[ -n "${ex}" ]] || return 1
  api GET "/api/v1/executions/${ex}?includeData=true"
  body="$(req_body)"
  jq -r '[.. | objects | select(has("openLink")) | .openLink.url // empty] | .[]' <<<"${body}" 2>/dev/null || true
}
get_url() {   # get_url URL -> sets URL_CODE, body in "${STATE_DIR}/last.body"
  URL_CODE="$(curl -sS --max-time 30 "${CURL_TLS[@]}" -o "${STATE_DIR}/last.body" -w '%{http_code}' "${1}" 2>/dev/null || echo 000)"
}
exec_outcome() {   # exec_outcome ID -> the `outcome` the terminal Code node produced
  api GET "/api/v1/executions/${1}?includeData=true"
  req_body | jq -r '[.. | objects | select(has("outcome")) | .outcome] | first // empty' 2>/dev/null || true
}

# --- cycle 1: approve ------------------------------------------------------------------------------------
# The first call can 404 while activation reaches the pool, and the first execution of a run waits for the
# runner sidecar, so this gets the same 180 s budget as 04.
first_trigger() { trigger "EXP-${nonce}-1"; status_is 200; }
check "POST /webhook/${gate_path} accepted (HTTP 200, <= 180 s)" \
  wait_for 180 "the gate to answer on the pool" first_trigger
check "the caller was answered immediately, not held until a human decides" \
  grep -q 'Workflow was started' "${STATE_DIR}/last.body"
check "the execution is parked in 'waiting' (<= 60 s)" wait_for 60 "the execution to suspend" gate_is_waiting

# The template's Limit Wait Time (2 days) is what stops a forgotten request waiting for ever, and the only
# place that deadline exists is the row n8n writes while the execution is parked — resuming clears it, so it
# has to be read now rather than at the end of this script.
wait_secs="$(kit_psql "select floor(extract(epoch from (\"waitTill\" - now())))::bigint from execution_entity where id = ${waiting_exec:-0}")"
check "...with a deadline about 2 days out (${wait_secs:-none} s), so nobody has to remember it" \
  bash -c '[[ -n "$1" ]] && (( $1 > 171000 && $1 <= 172800 ))' _ "${wait_secs}"

urls="$(card_urls || true)"
approve_url="$(awk '/approved=true/ { print; exit }' <<<"${urls}")"
reject_url="$(awk '/approved=false/ { print; exit }' <<<"${urls}")"
check "the card reached Google Chat's webhook with two decision links" \
  bash -c '[[ -n "$1" && -n "$2" ]]' _ "${approve_url}" "${reject_url}"
if [[ -z "${approve_url}" ]]; then
  warn "no openLink URLs in the sink execution; what it received was:"
  printf '%s\n' "${urls}" | head -5 >&2
  finish
fi
check "the links point at this execution's waiting webhook (/webhook-waiting/${waiting_exec})" \
  grep -qF "/webhook-waiting/${waiting_exec}" <<<"${approve_url}"
check "...and carry the execution's resume token" grep -q 'signature=' <<<"${approve_url}"
check "...and append the decision with & (a ? here would drop the token)" \
  grep -q '&approved=true' <<<"${approve_url}"

# The token is not decoration: n8n validates it, so a tampered link must not resume anything.
tampered="$(sed -E 's/signature=[^&]*/signature=deadbeefdeadbeefdeadbeefdeadbeef/' <<<"${approve_url}")"
get_url "${tampered}"
check "a link with the wrong token is refused (HTTP ${URL_CODE:-none}, expected 401)" test "${URL_CODE}" = "401"
check "...and the execution is still waiting" test "$(gate_exec_with_status waiting)" = "${waiting_exec}"

get_url "${approve_url}"
check "clicking Approve resumes the execution (HTTP ${URL_CODE:-none})" test "${URL_CODE}" = "200"
approved_done() { [[ "$(gate_exec_with_status success)" == "${waiting_exec}" ]]; }
check "the execution finished (<= 60 s)" wait_for 60 "the resumed execution to finish" approved_done
check "it took the approved branch (outcome: $(exec_outcome "${waiting_exec}"))" \
  test "$(exec_outcome "${waiting_exec}")" = "approved"

# A button link lives in a chat message for ever, and browsers prefetch. The second click must not re-run
# the action: n8n answers 409 because the execution has finished.
get_url "${approve_url}"
check "clicking Approve again changes nothing (HTTP ${URL_CODE:-none}, expected 409)" test "${URL_CODE}" = "409"

# --- cycle 2: reject -------------------------------------------------------------------------------------
check "a second request is accepted" trigger "EXP-${nonce}-2"
first_waiting="${waiting_exec}"
second_waiting() {
  waiting_exec="$(gate_exec_with_status waiting)"
  [[ -n "${waiting_exec}" && "${waiting_exec}" != "${first_waiting}" ]]
}
check "it parks in 'waiting' too (<= 60 s)" wait_for 60 "the second execution to suspend" second_waiting
urls="$(card_urls || true)"
reject_url="$(awk '/approved=false/ { print; exit }' <<<"${urls}")"
check "its card carries a Reject link for the new execution" \
  grep -qF "/webhook-waiting/${waiting_exec}" <<<"${reject_url}"
get_url "${reject_url}"
check "clicking Reject resumes it (HTTP ${URL_CODE:-none})" test "${URL_CODE}" = "200"
rejected_done() { [[ "$(gate_exec_with_status success)" == "${waiting_exec}" ]]; }
check "the execution finished (<= 60 s)" wait_for 60 "the rejected execution to finish" rejected_done
check "it took the rejected branch (outcome: $(exec_outcome "${waiting_exec}"))" \
  test "$(exec_outcome "${waiting_exec}")" = "rejected"

# --- nothing is left parked ------------------------------------------------------------------------------
# Both executions were answered, so the workflow must hold no waiting rows: a leaked one would sit there for
# two days and resume later into a stack that has moved on.
check "no execution of this workflow is left waiting" \
  test "$(kit_psql "select count(*) from execution_entity where \"workflowId\" = '${gate_id}' and status = 'waiting'")" = "0"

finish
