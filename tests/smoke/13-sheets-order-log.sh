#!/usr/bin/env bash
# 13-sheets-order-log — the shipped sheets-order-log template turns one order into exactly one row, refuses
# the orders that would make a bad row, and does not lose any under a burst (M1).
#
# The Google Sheets node cannot run here: it needs a Google account, and CI has none. So this script tests
# the two halves that do not need one, and says plainly which part is left:
#
#   1. the kit-side path, with the Sheets node swapped for an HTTP Request into a collector — the row the
#      Sheets node WOULD have appended is then readable, which is the part a user most often gets wrong
#      (field names must match the sheet's header row, because the node maps automatically);
#   2. the shipped JSON's own shape, asserted statically, so a later edit cannot quietly break the resource
#      locators, the mapping mode or the retry that absorbs Google's 429s.
#
# What is NOT covered: the append itself. That leg is validated once, by hand, against a real spreadsheet —
# `docs/compat.md` records when, the same way `error-handler`'s Telegram leg is handled.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; sh -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"

TEMPLATE="${SMOKE_DIR}/../../templates/sheets-order-log/workflow.json"
[[ -f "${TEMPLATE}" ]] || die "templates/sheets-order-log/workflow.json is missing"

N="${ORDERS_N:-20}"
nonce="$(rand_hex 6)"
gate_path="kit-smoke-order-${nonce}"
sink_path="kit-smoke-ordersink-${nonce}"
codes_file="${STATE_DIR}/order-codes-${nonce}"
: >"${codes_file}"
cleanup() { rm -f "${codes_file}"; }
trap cleanup EXIT

# --- the shipped shape, asserted before anything runs ---------------------------------------------------
# These are the parameters a user never thinks about until they are wrong, and the ones a careless edit
# breaks. Each is read out of the file that ships, not out of the copy this test mutates below.
sheets_node="$(jq -c '.nodes[] | select(.type == "n8n-nodes-base.googleSheets")' "${TEMPLATE}")"
check "the Sheets node is pinned to typeVersion 4.7 (the resourceMapper era)" \
  test "$(jq -r '.typeVersion' <<<"${sheets_node}")" = "4.7"
check "it appends rather than updates" test "$(jq -r '.parameters.operation' <<<"${sheets_node}")" = "append"
check "documentId and sheetName are resource locators, not plain strings" \
  test "$(jq -r '[.parameters.documentId.__rl, .parameters.sheetName.__rl] | all' <<<"${sheets_node}")" = "true"
check "the sheet tab is named by name ('Orders'), so no stranger's sheet id is baked in" \
  test "$(jq -r '.parameters.sheetName.mode + ":" + .parameters.sheetName.value' <<<"${sheets_node}")" = "name:Orders"
# autoMapInputData is what ties the row object's keys to the header row; with a cached schema instead, the
# template would carry somebody else's columns and silently drop fields.
check "columns are mapped automatically from the input fields" \
  test "$(jq -r '.parameters.columns.mappingMode' <<<"${sheets_node}")" = "autoMapInputData"
check "'Minimise API Calls' is on (one API call per row, not two)" \
  test "$(jq -r '.parameters.options.useAppend' <<<"${sheets_node}")" = "true"
check "the append retries, so a Google 429 does not drop the order" \
  test "$(jq -r '[.retryOnFail, (.maxTries >= 3)] | all' <<<"${sheets_node}")" = "true"

# --- the sink stands in for the spreadsheet --------------------------------------------------------------
api POST /api/v1/workflows "$(workflow_from_fixture wf-idem-sink.json "kit-smoke-ordersink-${nonce}" "${sink_path}")"
sink_id="$(req_body | jq -r '.id // empty')"
check "row sink created (HTTP ${REQ_STATUS})" test -n "${sink_id}"
api POST "/api/v1/workflows/${sink_id}/activate"
check "row sink published (HTTP ${REQ_STATUS})" status_is 200
[[ -n "${sink_id}" ]] || finish

rows_logged() {
  api GET "/api/v1/executions?workflowId=${sink_id}&limit=250"
  status_is 200 || { printf '%s\n' -1; return 0; }
  req_body | jq -r '.data | length' 2>/dev/null || printf '%s\n' -1
}
newest_row() {   # the row object the Sheets node would have appended
  local ex
  api GET "/api/v1/executions?workflowId=${sink_id}&limit=1"
  ex="$(req_body | jq -r '.data[0].id // empty')"
  [[ -n "${ex}" ]] || return 1
  api GET "/api/v1/executions/${ex}?includeData=true"
  req_body | jq -c '[.. | objects | select(has("did")) | .did] | first // empty' 2>/dev/null || true
}

# --- the gate: the shipped template with the Sheets node swapped for the sink ----------------------------
# Swapped by NAME, so the connections and every other node stay exactly as shipped. The Code nodes that
# validate the order and build the row — the whole point of the template — are untouched.
gate_json="$(jq -c --arg n "kit-smoke-order-${nonce}" --arg p "${gate_path}" --arg u "${BASE_URL}/webhook/${sink_path}" '
  .name = $n
  | .nodes = [
      .nodes[]
      | if .type == "n8n-nodes-base.webhook" then .parameters.path = $p else . end
      | if .name == "Append the row" then
          {
            parameters: {
              method: "POST", url: $u, sendBody: true, specifyBody: "json",
              jsonBody: "={{ JSON.stringify($json) }}", options: {}
            },
            name: "Append the row",
            type: "n8n-nodes-base.httpRequest",
            typeVersion: 4.2,
            position: .position
          }
        else . end
    ]' "${TEMPLATE}")"
api POST /api/v1/workflows "${gate_json}"
gate_id="$(req_body | jq -r '.id // empty')"
check "gate workflow created from the shipped template (HTTP ${REQ_STATUS})" test -n "${gate_id}"
[[ -n "${gate_id}" ]] || finish
api POST "/api/v1/workflows/${gate_id}/activate"
check "gate published (HTTP ${REQ_STATUS})" status_is 200

post_order() {   # post_order JSON_BODY
  req POST "/webhook/${gate_path}" -H 'Content-Type: application/json' --data "${1}"
}
good_order() {   # good_order ORDER_ID [EXTRA_JSON]
  jq -nc --arg id "${1}" '{orderId: $id, customer: "Nguyen Thi Mai  ", phone: "0901234567",
    item: "Ca phe sua da x2", qty: 3, amountVnd: 125000, note: "giao truoc 9h"}'
}
gate_error_message() {
  local ex body
  api GET "/api/v1/executions?workflowId=${gate_id}&status=error&limit=1"
  ex="$(req_body | jq -r '.data[0].id // empty')"
  [[ -n "${ex}" ]] || { printf '\n'; return 0; }
  api GET "/api/v1/executions/${ex}?includeData=true"
  body="$(req_body)"
  jq -r '[.. | objects | select(has("message")) | .message | tostring] | join(" | ")' <<<"${body}" 2>/dev/null || printf '\n'
}
gate_error_says() { grep -q "${1}" <<<"$(gate_error_message)"; }

# --- one order, one row ----------------------------------------------------------------------------------
first_order() { post_order "$(good_order "DH-${nonce}-1")"; status_is 200; }
check "POST /webhook/${gate_path} accepted (HTTP 200, <= 180 s)" \
  wait_for 180 "the gate to answer on the pool" first_order
body="$(req_body)"
check "the caller gets a receipt (logged=true)" test "$(jq -r '.logged // empty' <<<"${body}")" = "true"
check "...naming the order it logged" test "$(jq -r '.orderId // empty' <<<"${body}")" = "DH-${nonce}-1"
check "...and the execution that wrote it, for tracing a wrong row back" \
  bash -c '[[ "$1" =~ ^[0-9]+$ ]]' _ "$(jq -r '.executionId // empty' <<<"${body}")"
one_row() { (( $(rows_logged) >= 1 )); }
check "exactly one row reached the spreadsheet (<= 60 s)" wait_for 60 "the row" one_row
sleep 4
check "...one, not two ($(rows_logged))" test "$(rows_logged)" = "1"

# The row's KEYS are the sheet's header row, because the node maps automatically. Asserting them is
# asserting the contract between this template and the spreadsheet a user set up.
row="$(newest_row || true)"
check "the row carries exactly the documented columns" \
  test "$(jq -r 'keys_unsorted | sort | join(",")' <<<"${row}" 2>/dev/null || true)" \
    = "amountVnd,customer,executionId,item,note,orderId,phone,qty,receivedAt"
check "receivedAt is ISO 8601 in UTC, not a local-time string" \
  bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]' _ \
  "$(jq -r '.receivedAt // empty' <<<"${row}")"
check "whitespace is collapsed and trimmed (customer)" \
  test "$(jq -r '.customer // empty' <<<"${row}")" = "Nguyen Thi Mai"
check "numbers arrive as numbers, not strings (qty, amountVnd)" \
  test "$(jq -r '[(.qty | type), (.amountVnd | type)] | join(",")' <<<"${row}")" = "number,number"

# --- the orders it must refuse ---------------------------------------------------------------------------
# A refused order is a 4xx-shaped answer the caller can act on; a bad row in a spreadsheet is a person's
# afternoon. Each refusal names its field.
refuse() {   # refuse DESCRIPTION JSON_BODY EXPECTED_TEXT
  local desc="${1}" payload="${2}" expect="${3}" before
  before="$(rows_logged)"
  post_order "${payload}"
  check "${desc} is refused (HTTP ${REQ_STATUS})" status_is 500
  check "...and the error names the problem (${expect})" wait_for 20 "the refusal to be recorded" gate_error_says "${expect}"
  check "...and nothing was written (${before} rows, unchanged)" test "$(rows_logged)" = "${before}"
}
refuse "an order with no orderId" \
  '{"customer":"Mai","amountVnd":1000}' 'orderId is required'
refuse "a negative amount" \
  "$(jq -nc --arg id "DH-${nonce}-neg" '{orderId: $id, customer: "Mai", amountVnd: -5}')" 'amountVnd must be'
refuse "a fractional quantity" \
  "$(jq -nc --arg id "DH-${nonce}-frac" '{orderId: $id, customer: "Mai", amountVnd: 1000, qty: 1.5}')" 'qty must be'
refuse "an order identifying nobody" \
  "$(jq -nc --arg id "DH-${nonce}-anon" '{orderId: $id, amountVnd: 1000}')" 'need customer or phone'

# --- a burst must not lose orders ------------------------------------------------------------------------
# The kit can push far more executions per minute than any spreadsheet API will accept (docs/sizing.md), so
# the interesting question is not speed but loss: every accepted order must end up as a row.
before="$(rows_logged)"
info "firing ${N} distinct orders with ${N} in flight"
seq 1 "${N}" | xargs -P "${N}" -I{} sh -c '
  url=$1; nonce=$2; i=$3; shift 3
  code=$(curl -sS --max-time 60 "$@" -o /dev/null -w "%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" \
    --data "{\"orderId\":\"DH-$nonce-burst-$i\",\"customer\":\"Khach $i\",\"qty\":1,\"amountVnd\":50000}" 2>/dev/null) || code=""
  case "$code" in ""|*[!0-9]*) code=000 ;; esac
  printf "%s\n" "$code"
' sh "${BASE_URL}/webhook/${gate_path}" "${nonce}" {} "${CURL_TLS[@]}" >>"${codes_file}" || true
ok_n="$(grep -c '^200$' "${codes_file}" || true)"
check "every one of the ${N} orders was accepted (${ok_n:-0} x 200)" test "${ok_n:-0}" = "${N}"
all_rows() { (( $(rows_logged) >= before + N )); }
check "every accepted order became a row (<= 90 s)" wait_for 90 "all ${N} rows" all_rows
sleep 5
check "...exactly ${N} new rows, no duplicates ($(( $(rows_logged) - before )))" \
  test "$(( $(rows_logged) - before ))" = "${N}"
finish
