#!/usr/bin/env bash
# 15-form-order-intake — the shipped form-order-intake template serves a real form on the kit's `/form/*`
# route, accepts an order, normalises a Vietnamese phone number, and sends a bad order back to a page that
# says what to fix (M1).
#
# What this proves that nothing else does: the Caddyfile has routed `/form/*` and `/form-waiting/*` to the
# webhook pool since S2, and `04-webhook-routing` asserts the routes reach the pool — but **nothing has ever
# served or submitted a form through them**. This script does, end to end, and it is the one template in the
# kit that needs **no credential of any kind**, which it also asserts.
#
# Three things about n8n's form API that this test had to be built around, all read out of 2.46.7's source
# rather than guessed:
#   * a submission MUST be `multipart/form-data` — the node asserts the content type outright
#     (`nodes/Form/utils/utils.ts`);
#   * the body keys are POSITIONAL (`field-0`, `field-1`, ...), not the field names, so the order of the
#     fields in the template is the wire format. Reordering them is a breaking change for anything that
#     posts directly, which is why this script posts positionally and the template pins its field names;
#   * **the form's path is an OPTION from node version 2.2 onward.** `FormTriggerV2` declares the top-level
#     `path` property only for `@version <= 2.1`, and the webhook path expression is
#     `$parameter["path"] || $parameter["options"]?.path || $webhookId`. A stored key the node does not
#     declare is invisible to `$parameter`, so a top-level `path` at 2.6 is ignored and the form is served at
#     `/form/<webhookId>` instead. The symptom is a 404 at your own path plus
#     `The requested webhook ... is not registered` in a webhook process's log, while `webhook_entity` holds
#     rows under a UUID. This test's first assertion exists so that can never ship again.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; sh -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"

TEMPLATE="${SMOKE_DIR}/../../templates/form-order-intake/workflow.json"
[[ -f "${TEMPLATE}" ]] || die "templates/form-order-intake/workflow.json is missing"

nonce="$(rand_hex 6)"
form_path="kit-smoke-form-${nonce}"

# --- the shipped shape ------------------------------------------------------------------------------------
# At node version 2.2+ the path is an option. Set at the top level it is silently ignored and the form is
# served at /form/<webhookId> — which is how this template failed its first test run.
check "the form's path is set where the node declares it (options.path), not at the top level" \
  test "$(jq -r '[.nodes[] | select(.type == "n8n-nodes-base.formTrigger") | (.parameters.options.path // "MISSING"), (if .parameters | has("path") then "TOP-LEVEL-PATH-PRESENT" else "absent" end)] | join(",")' "${TEMPLATE}")" \
    = "__PATH__,absent"
check "the form's output keys are pinned, so renaming a label cannot break the workflow" \
  test "$(jq -r '[.nodes[] | select(.type == "n8n-nodes-base.formTrigger") | .parameters.formFields.values[].fieldName] | join(",")' "${TEMPLATE}")" \
    = "customer,phone,item,qty,note"
# A Vietnamese mobile starts with 0, and a number field eats the leading zero.
check "phone is a text field, not a number field" \
  test "$(jq -r '[.nodes[] | select(.type == "n8n-nodes-base.formTrigger") | .parameters.formFields.values[] | select(.fieldName == "phone") | .fieldType // "text"] | first' "${TEMPLATE}")" = "text"
check "the form responds when the workflow finishes, so the confirmation can carry the reference" \
  test "$(jq -r '.nodes[] | select(.type == "n8n-nodes-base.formTrigger") | .parameters.responseMode' "${TEMPLATE}")" = "lastNode"
check "there are two completion pages: one confirming, one explaining" \
  test "$(jq -r '[.nodes[] | select(.type == "n8n-nodes-base.form")] | length' "${TEMPLATE}")" = "2"
# The only template in the kit that asks nothing of the operator but a path.
check "it needs no credential at all" \
  test "$(jq -r '[.nodes[] | select(has("credentials"))] | length' "${TEMPLATE}")" = "0"

# --- publish it -------------------------------------------------------------------------------------------
form_json="$(jq -c --arg n "kit-smoke-form-${nonce}" --arg p "${form_path}" '
  .name = $n
  | .nodes = [ .nodes[] | if .type == "n8n-nodes-base.formTrigger" then .parameters.options.path = $p else . end ]' "${TEMPLATE}")"
api POST /api/v1/workflows "${form_json}"
form_id="$(req_body | jq -r '.id // empty')"
check "form workflow created from the shipped template (HTTP ${REQ_STATUS})" test -n "${form_id}"
[[ -n "${form_id}" ]] || finish
api POST "/api/v1/workflows/${form_id}/activate"
check "form published (HTTP ${REQ_STATUS})" status_is 200

# --- the form is served, from the pool --------------------------------------------------------------------
form_served() {
  req GET "/form/${form_path}"
  status_is 200
}
check "GET /form/${form_path} serves the form (HTTP 200, <= 180 s)" \
  wait_for 180 "the form to be registered on the pool" form_served
check "...from a webhook pool member, never main ($(header_of X-Kit-Upstream))" \
  bash -c '[[ "$1" =~ ^n8n-webhook-[0-9]+:5678$ ]]' _ "$(header_of X-Kit-Upstream)"
check "...and the page carries the form's own title" \
  grep -qF 'Dat hang' "${STATE_DIR}/last.body"

# --- a good order -----------------------------------------------------------------------------------------
# Positional keys and multipart, as the node requires. The phone is deliberately written the way a customer
# would who has the number saved for international use.
# A submission is two requests, which is the part that is not obvious from the outside. The POST does not
# return the page a customer reads: it returns {"formWaitingUrl": "<PUBLIC_URL>/form-waiting/<execution
# id>?signature=<token>"}, and the form's own client then FOLLOWS that URL to render whatever the workflow
# ended on. So `/form/*` and `/form-waiting/*` are both on the path of a single submission, and a test that
# stops at the POST proves only half of it.
PAGE="${STATE_DIR}/form-page.html"
submit() {   # submit NAME PHONE ITEM QTY NOTE -> sets REQ_STATUS, WAIT_URL, PAGE_CODE, and renders into $PAGE
  : >"${PAGE}"
  WAIT_URL=''
  PAGE_CODE='000'
  req POST "/form/${form_path}" \
    -F "field-0=${1}" -F "field-1=${2}" -F "field-2=${3}" -F "field-3=${4}" -F "field-4=${5}"
  WAIT_URL="$(req_body | jq -r '.formWaitingUrl // empty' 2>/dev/null || true)"
  [[ -n "${WAIT_URL}" ]] || return 0
  # Polled, the way the form's own client does it: the page is only served once the execution has PARKED at
  # the Form node, and a fetch before that blocks rather than erroring. Fetching once, immediately, is how
  # this test first "failed" against a template that was working.
  local try
  for try in 1 2 3 4 5 6 7 8; do
    PAGE_CODE="$(curl -sS --max-time 10 "${CURL_TLS[@]}" -o "${PAGE}" -w '%{http_code}' "${WAIT_URL}" 2>/dev/null || echo 000)"
    [[ "${PAGE_CODE}" == "200" ]] && return 0
    sleep 2
  done
}
submit 'Nguyen Thi Mai' '+84 901 234 567' 'Ca phe sua da' '2' 'giao truoc 9h'
check "a good order is accepted (HTTP ${REQ_STATUS})" status_is 200
# The second half of the flow, over the kit's other form route.
check "...answering with a form-waiting URL for this execution" \
  grep -qE '/form-waiting/[0-9]+\?signature=' <<<"${WAIT_URL}"
check "...which renders the confirmation page (HTTP ${PAGE_CODE})" test "${PAGE_CODE}" = "200"
check "...showing the customer their order was received" grep -qF 'Da nhan don' "${PAGE}"
check "...carrying a reference they can quote (DH-YYYYMMDD-XXXX)" \
  grep -qE 'DH-[0-9]{8}-[A-Z0-9]{4}' "${PAGE}"

latest_execution() {   # the newest execution's data for this workflow
  local ex
  api GET "/api/v1/executions?workflowId=${form_id}&limit=1"
  ex="$(req_body | jq -r '.data[0].id // empty')"
  [[ -n "${ex}" ]] || return 1
  api GET "/api/v1/executions/${ex}?includeData=true"
  req_body | jq -c '[.. | objects | select(has("valid") and has("ref"))] | first // empty' 2>/dev/null || true
}
order() { latest_execution; }
got_order() { [[ -n "$(order)" ]]; }
check "the execution recorded the order (<= 30 s)" wait_for 30 "the execution data" got_order
row="$(order)"
check "it is marked usable" test "$(jq -r '.valid' <<<"${row}")" = "true"
# The point of the phone handling: three ways of writing one number must become one number.
check "the phone was normalised from '+84 901 234 567' to 0901234567 ($(jq -r '.phone' <<<"${row}"))" \
  test "$(jq -r '.phone' <<<"${row}")" = "0901234567"
check "quantity arrived as a number, not a string" test "$(jq -r '.qty | type' <<<"${row}")" = "number"
check "the pinned keys are what the workflow sees (customer, item, note)" \
  test "$(jq -r '[(.customer == "Nguyen Thi Mai"), (.item == "Ca phe sua da"), (.note == "giao truoc 9h")] | all' <<<"${row}")" = "true"

# --- the orders it sends back -----------------------------------------------------------------------------
# A form is read by a person, so an invalid order gets a page that says what to fix — not an error page.
reject() {   # reject DESCRIPTION EXPECTED_TEXT NAME PHONE ITEM QTY NOTE
  local desc="${1}" expect="${2}"
  shift 2
  submit "${@}"
  check "${desc} is sent back (HTTP ${REQ_STATUS})" status_is 200
  check "...on the 'what to fix' page, not an error page (HTTP ${PAGE_CODE})" grep -qF 'Chua gui duoc' "${PAGE}"
  check "...saying ${expect}" grep -qF "${expect}" "${PAGE}"
}
reject "a number that is not a Vietnamese mobile" 'So dien thoai khong hop le' \
  'Nguyen Thi Mai' '12345' 'Ca phe den' '1' ''
reject "a quantity of zero" 'So luong phai tu 1 den 99' \
  'Nguyen Thi Mai' '0901234567' 'Ca phe den' '0' ''
reject "a quantity above 99" 'So luong phai tu 1 den 99' \
  'Nguyen Thi Mai' '0901234567' 'Ca phe den' '100' ''
reject "an order with no name" 'Vui long nhap ten' \
  '' '0901234567' 'Ca phe den' '1' ''

# A rejected order must not look like an accepted one in the execution list: the data says so, which is what
# a later "how many orders did we get?" query will read.
row="$(order)"
check "the last rejected order is recorded as not usable" test "$(jq -r '.valid' <<<"${row}")" = "false"
check "...with the problem kept, so it can be counted" \
  bash -c '[[ -n "$1" && "$1" != "null" ]]' _ "$(jq -r '.problem // empty' <<<"${row}")"

# --- the cost of a completion page, pinned ---------------------------------------------------------------
# A Form Ending node parks its execution with n8n's wait-indefinitely sentinel (year 3000) and never resumes
# it, even after the page has been served. Pruning excludes `waiting` executions outright, so **every
# submission leaves a row nothing will ever delete** — and those rows still count when the count-based prune
# computes its cutoff, which is how a busy form shortens the retention window for every OTHER workflow on
# the instance. ~1.7 KB of execution_data each, measured on this stack.
#
# This is asserted rather than merely documented so that if a future n8n version stops parking — or starts
# resuming — the kit finds out from a failing test rather than from a full database.
parked="$(kit_psql "select count(*) from execution_entity where \"workflowId\" = '${form_id}' and status = 'waiting'")"
check "every submission left a parked execution (${parked:-?} of the $(( 1 + 4 )) submitted)" \
  bash -c '[[ -n "$1" ]] && (( $1 >= 5 ))' _ "${parked}"
check "...parked with the wait-indefinitely sentinel, so nothing will resume them" \
  test "$(kit_psql "select count(*) from execution_entity where \"workflowId\" = '${form_id}' and status = 'waiting' and \"waitTill\" > now() + interval '100 years'")" = "${parked}"
info "a form that parks one execution per submission needs a sweep — docs/operations/forms.md has the query"
finish
