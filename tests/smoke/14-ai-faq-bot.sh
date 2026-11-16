#!/usr/bin/env bash
# 14-ai-faq-bot — the shipped ai-faq-bot template refuses everything it should refuse BEFORE it spends money
# on a model, and hands over to a human when the FAQ has no answer (M1).
#
# This endpoint is different from every other template's: each answered request costs real money at a model
# provider. So the guardrails are the product, and two of the three are testable here without any API key:
#
#   1. the shared secret on the webhook (Header Auth, so the secret is in n8n's credential store);
#   2. the rate limit — and this one is exercised for real, because the counter lives in the kit's own
#      Valkey, not at a vendor. 20 per sender per minute, atomic via INCR.
#
# The model call itself is stubbed: the LLM Chain and its model sub-node are replaced by a Code node that
# returns either a canned answer or the KHONG_BIET sentinel, which lets BOTH post-model paths be asserted —
# the answer, and the hand-over-to-a-human. CI has no model credential, and a test that paid per run would
# be a bad test anyway.
#
# Side effects: a handful of deliberately refused requests, and ~23 executions in the burst.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; sh -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"

TEMPLATE="${SMOKE_DIR}/../../templates/ai-faq-bot/workflow.json"
[[ -f "${TEMPLATE}" ]] || die "templates/ai-faq-bot/workflow.json is missing"

LIMIT=20   # must match the template's own limit; asserted against the file below
nonce="$(rand_hex 6)"
gate_path="kit-smoke-faq-${nonce}"
secret="kit-smoke-$(rand_hex 16)"
sender_a="smoke-a-${nonce}"
sender_b="smoke-b-${nonce}"
header_cred=''
redis_cred=''
codes_file="${STATE_DIR}/faq-codes-${nonce}"
: >"${codes_file}"

cleanup() {
  local c
  for c in "${header_cred}" "${redis_cred}"; do
    [[ -n "${c}" ]] && api DELETE "/api/v1/credentials/${c}" >/dev/null 2>&1
  done
  rm -f "${codes_file}"
}
trap cleanup EXIT

# --- the shipped shape ------------------------------------------------------------------------------------
check "the template's rate limit is the ${LIMIT} this script tests" \
  grep -q "limit: ${LIMIT}," "${TEMPLATE}"
check "the webhook requires the shared secret (Header Auth)" \
  test "$(jq -r '.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.authentication' "${TEMPLATE}")" = "headerAuth"
check "it answers through a Respond node, so a refusal can be a 429 rather than a 500" \
  test "$(jq -r '.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.responseMode' "${TEMPLATE}")" = "responseNode"
check "the refusal really is a 429" \
  test "$(jq -r '.nodes[] | select(.name == "Refuse: too many questions") | .parameters.options.responseCode' "${TEMPLATE}")" = "429"
# The counter key must carry the minute. Without that, n8n's Redis node refreshes the TTL on every INCR and a
# sender under continuous traffic never gets a fresh window — it stays blocked until it pauses.
check "the rate-limit key is bucketed per minute, not one key per sender" \
  grep -q 'faq:rl:\${sender}:\${minute}' "${TEMPLATE}"
check "the prompt tells the model to say KHONG_BIET rather than invent an answer" \
  grep -q 'reply with exactly KHONG_BIET' "${TEMPLATE}"
check "output tokens are capped (the bill is made of those)" \
  test "$(jq -r '.nodes[] | select(.type | endswith("lmChatGoogleGemini")) | .parameters.options.maxOutputTokens' "${TEMPLATE}")" = "200"

# --- credentials: the shared secret, and the kit's own Valkey --------------------------------------------
api POST /api/v1/credentials "$(jq -nc --arg n "kit-smoke-faqsecret-${nonce}" --arg v "${secret}" \
  '{name: $n, type: "httpHeaderAuth", data: {name: "X-Kit-FAQ-Secret", value: $v}}')"
header_cred="$(req_body | jq -r '.id // empty')"
check "header-auth credential created (HTTP ${REQ_STATUS})" test -n "${header_cred}"

valkey_password="$(env_get VALKEY_PASSWORD)"
check "VALKEY_PASSWORD is readable from .env" test -n "${valkey_password}"
api POST /api/v1/credentials "$(jq -nc --arg n "kit-smoke-faqvalkey-${nonce}" --arg p "${valkey_password}" \
  '{name: $n, type: "redis", data: {host: "valkey", port: 6379, database: 0, password: $p, ssl: false}}')"
redis_cred="$(req_body | jq -r '.id // empty')"
check "Valkey credential created from the kit's own .env (HTTP ${REQ_STATUS})" test -n "${redis_cred}"
[[ -n "${header_cred}" && -n "${redis_cred}" ]] || finish

# --- the gate: the shipped template with the model stubbed ----------------------------------------------
# The chain and its model sub-node are replaced by ONE Code node returning { text: ... }, which is the shape
# the chain produces. Everything else — the secret, the counter, the limit branch, the formatter, both
# Respond nodes — is shipped code.
gate_json="$(jq -c --arg n "kit-smoke-faq-${nonce}" --arg p "${gate_path}" \
  --arg hc "${header_cred}" --arg hn "kit-smoke-faqsecret-${nonce}" \
  --arg rc "${redis_cred}" --arg rn "kit-smoke-faqvalkey-${nonce}" '
  .name = $n
  | .nodes = [
      .nodes[]
      | if .type == "n8n-nodes-base.webhook" then
          .parameters.path = $p | .credentials = {httpHeaderAuth: {id: $hc, name: $hn}}
        else . end
      | if .type == "n8n-nodes-base.redis" then .credentials = {redis: {id: $rc, name: $rn}} else . end
      | if .name == "Answer from the FAQ" then
          {
            parameters: {
              jsCode: "// Stands in for the model. A question containing \"unknown\" exercises the KHONG_BIET\n// path; anything else gets a canned answer.\nconst q = String($json.question ?? \"\").toLowerCase();\nreturn [{ json: { text: q.includes(\"unknown\") ? \"KHONG_BIET\" : \"Gio mo cua: 07:00-21:00 moi ngay.\" } }];"
            },
            name: "Answer from the FAQ",
            type: "n8n-nodes-base.code",
            typeVersion: 2,
            position: .position
          }
        else . end
    ]
  # the model sub-node goes away with the chain, and so must its ai_languageModel connection
  | .nodes = [ .nodes[] | select(.type | endswith("lmChatGoogleGemini") | not) ]
  | .connections = (.connections | del(."Gemini (swap for your provider)"))' "${TEMPLATE}")"
check "the stubbed copy still carries both Respond nodes and the counter" \
  test "$(jq -r '[.nodes[] | select(.type == "n8n-nodes-base.respondToWebhook" or .type == "n8n-nodes-base.redis")] | length' <<<"${gate_json}")" = "3"

api POST /api/v1/workflows "${gate_json}"
gate_id="$(req_body | jq -r '.id // empty')"
check "gate workflow created from the shipped template (HTTP ${REQ_STATUS})" test -n "${gate_id}"
[[ -n "${gate_id}" ]] || finish
api POST "/api/v1/workflows/${gate_id}/activate"
check "gate published (HTTP ${REQ_STATUS})" status_is 200

ask() {   # ask SENDER QUESTION [SECRET] -> sets REQ_STATUS, body in req_body
  local s="${3-${secret}}"
  req POST "/webhook/${gate_path}" -H 'Content-Type: application/json' -H "X-Kit-FAQ-Secret: ${s}" \
    --data "$(jq -nc --arg q "${2}" --arg sender "${1}" '{question: $q, sender: $sender}')"
}
no_secret() {
  req POST "/webhook/${gate_path}" -H 'Content-Type: application/json' \
    --data '{"question":"gio mo cua?","sender":"nobody"}'
}

# --- the secret ------------------------------------------------------------------------------------------
# A metered endpoint with no authentication is a budget anyone can spend. n8n's webhook default is no auth,
# so this template departs from it deliberately — which is only worth anything if it actually refuses.
first_ask() { ask "${sender_a}" 'gio mo cua?'; status_is 200; }
check "an authenticated question is answered (HTTP 200, <= 180 s)" \
  wait_for 180 "the gate to answer on the pool" first_ask
check "...with an answer and answered=true" \
  test "$(req_body | jq -r '[.answered, (.answer | length > 0)] | all')" = "true"

no_secret
check "a request with NO secret is refused (HTTP ${REQ_STATUS}, expected 401 or 403)" \
  bash -c '[[ "$1" == 401 || "$1" == 403 ]]' _ "${REQ_STATUS}"
ask "${sender_a}" 'gio mo cua?' 'the-wrong-secret'
check "a request with the WRONG secret is refused (HTTP ${REQ_STATUS}, expected 401 or 403)" \
  bash -c '[[ "$1" == 401 || "$1" == 403 ]]' _ "${REQ_STATUS}"

# --- the FAQ has no answer: hand over, do not invent ----------------------------------------------------
ask "${sender_a}" 'do you deliver to an unknown planet?'
check "a question the FAQ cannot answer still returns 200" status_is 200
check "...but answered=false and needsHuman=true" \
  test "$(req_body | jq -r '[(.answered == false), (.needsHuman == true)] | all')" = "true"
check "...and the caller is told a person will follow up" \
  grep -qi 'will get back to you\|nhan vien' <<<"$(req_body | jq -r '.answer // empty')"

# --- the input cap ---------------------------------------------------------------------------------------
long_q="$(head -c 600 /dev/zero | tr '\0' 'a')"
gate_error_says() {   # polled: the execution record lands just after the HTTP answer
  local ex body
  api GET "/api/v1/executions?workflowId=${gate_id}&status=error&limit=1"
  ex="$(req_body | jq -r '.data[0].id // empty')"
  [[ -n "${ex}" ]] || return 1
  api GET "/api/v1/executions/${ex}?includeData=true"
  body="$(req_body)"
  grep -q "${1}" <<<"$(jq -r '[.. | objects | select(has("message")) | .message | tostring] | join(" ")' <<<"${body}" 2>/dev/null || true)"
}
ask "${sender_a}" "${long_q}"
check "a 600-character question is refused before the model runs (HTTP ${REQ_STATUS})" status_is 500
check "...and the error names the 500-character limit" \
  wait_for 20 "the refusal to be recorded" gate_error_says 'the limit is 500'

# --- the rate limit, against the kit's real Valkey -------------------------------------------------------
# The counter is a fixed window keyed on the minute, so the burst must not straddle a minute boundary or the
# count resets half way and the split below is meaningless. Wait for the start of a minute if we are late in
# one — cheap, and it makes the assertion exact rather than approximate.
second_now="$(date +%-S)"
if (( second_now > 40 )); then
  info "waiting $(( 61 - second_now ))s for a fresh minute so the fixed window does not roll over mid-burst"
  sleep $(( 61 - second_now ))
fi
burst=$(( LIMIT + 3 ))
sender_c="smoke-c-${nonce}"
info "asking ${burst} questions as one sender in one minute (limit ${LIMIT})"
seq 1 "${burst}" | xargs -P 8 -I{} sh -c '
  url=$1; secret=$2; sender=$3; shift 4
  code=$(curl -sS --max-time 60 "$@" -o /dev/null -w "%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" -H "X-Kit-FAQ-Secret: $secret" \
    --data "{\"question\":\"gio mo cua?\",\"sender\":\"$sender\"}" 2>/dev/null) || code=""
  case "$code" in ""|*[!0-9]*) code=000 ;; esac
  printf "%s\n" "$code"
' sh "${BASE_URL}/webhook/${gate_path}" "${secret}" "${sender_c}" {} "${CURL_TLS[@]}" >>"${codes_file}" || true
ok_n="$(grep -c '^200$' "${codes_file}" || true)"
rl_n="$(grep -c '^429$' "${codes_file}" || true)"
other_n="$(grep -cvE '^(200|429)$' "${codes_file}" || true)"
check "every answer was a 200 or a 429 (${ok_n:-0} x 200, ${rl_n:-0} x 429, ${other_n:-0} other)" \
  test "${other_n:-0}" = "0"
check "exactly ${LIMIT} questions were answered" test "${ok_n:-0}" = "${LIMIT}"
check "the other $(( burst - LIMIT )) were refused with 429, not charged to the model" \
  test "${rl_n:-0}" = "$(( burst - LIMIT ))"

ask "${sender_c}" 'gio mo cua?'
check "the rate-limited sender stays refused within the same minute (HTTP ${REQ_STATUS})" status_is 429
check "...and the 429 says how long to wait" \
  bash -c '[[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 60 ))' _ \
  "$(req_body | jq -r '.retryAfterSeconds // empty')"

# The counter is per sender: one noisy caller must not silence everybody else.
ask "${sender_b}" 'gio mo cua?'
check "a different sender is unaffected (HTTP ${REQ_STATUS})" status_is 200

# And the counter really is in the broker, under a key that expires.
keys="$(compose exec -T valkey sh -c "VALKEYCLI_AUTH=\$VALKEY_PASSWORD valkey-cli --scan --pattern 'faq:rl:${sender_c}:*'" 2>/dev/null || true)"
key_name="$(awk 'NR == 1 { print; exit }' <<<"${keys}")"
check "the counter is a key in the kit's Valkey (${key_name:-none})" test -n "${key_name}"
ttl="$(compose exec -T valkey sh -c "VALKEYCLI_AUTH=\$VALKEY_PASSWORD valkey-cli ttl '${key_name}'" 2>/dev/null | tr -dc '0-9' || true)"
check "...with a TTL set, so counters cannot pile up in a noeviction broker (${ttl:-none}s)" \
  bash -c '[[ -n "$1" ]] && (( $1 > 0 && $1 <= 120 ))' _ "${ttl}"
finish
