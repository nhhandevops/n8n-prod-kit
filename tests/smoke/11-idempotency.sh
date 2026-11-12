#!/usr/bin/env bash
# 11-idempotency — the shipped idempotent-webhook template does the work ONCE, however often the same key is
# delivered, and says something useful in the three cases where it refuses to (D-15).
#
# Why this cannot be a unit test: the invariant is about deliveries racing on different workers, so it needs
# the real pool, the real queue and the real database. The burst below sends one idempotency key N times at
# once (N=20, = WORKER_CONCURRENCY x 2 workers on a default stack) and asserts that exactly one execution
# reached the side effect.
#
# What is under test is the file a user downloads — templates/idempotent-webhook/workflow.json — with four
# things substituted and nothing else: the workflow name, the webhook path, the Postgres credential, and the
# URL of the "Do the work" node (pointed at a sink workflow, so the side effect can be counted). The ledger is
# created by the shipped templates/idempotent-webhook/schema.sql, with the table and role renamed so this test
# can never write to a real ledger or reset a real role's password.
#
# Side effects on the stack: the losers of the race are supposed to fail, so a run leaves roughly N failed
# executions behind, plus three more from the no-key, in-flight and stale refusals. On a stack with the
# monitoring profile they count toward the ExecutionFailureRate panel, as 10-error-workflow's failures do.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; sh -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"

TEMPLATE_DIR="${SMOKE_DIR}/../../templates/idempotent-webhook"
[[ -f "${TEMPLATE_DIR}/workflow.json" ]] || die "templates/idempotent-webhook/workflow.json is missing"
[[ -f "${TEMPLATE_DIR}/schema.sql" ]] || die "templates/idempotent-webhook/schema.sql is missing"

N="${IDEM_N:-20}"
nonce="$(rand_hex 6)"
table="kit_smoke_idem_${nonce}"
role="kit_smoke_idem_${nonce}"
ledger_password="$(rand_hex 16)"
gate_path="kit-smoke-idem-${nonce}"
sink_path="kit-smoke-idemsink-${nonce}"
burst_key="order-${nonce}"
second_key="order-${nonce}-b"
cred_id=''
codes_file="${STATE_DIR}/idem-codes-${nonce}"
: >"${codes_file}"

# The nonce keeps a leftover from a failed run harmless, but a left-behind role is untidy and a left-behind
# credential would accumulate one per run — so clean up on every exit path.
cleanup() {
  if [[ -n "${cred_id}" ]]; then
    api DELETE "/api/v1/credentials/${cred_id}" || true
  fi
  # DROP OWNED BY revokes the grants the schema made; without it DROP ROLE refuses ("privileges for table ...").
  kit_psql "drop table if exists ${table}" >/dev/null 2>&1 || true
  kit_psql "drop owned by ${role}" >/dev/null 2>&1 || true
  kit_psql "drop role if exists ${role}" >/dev/null 2>&1 || true
  rm -f "${codes_file}"
}
trap cleanup EXIT

# --- the ledger, from the shipped schema.sql ---------------------------------------------------------------
# Renamed, not rewritten: every statement that runs here is one the documented command runs, so a mistake in
# the shipped file fails this test instead of waiting for a user to find it.
# Plain substrings, not \b word boundaries: the index is called idempotency_keys_claimed_at_idx, and \b does
# not match between a letter and an underscore — so the index would keep the real ledger's name and land in
# the same namespace as one.
schema_sql="$(sed -e "s/idempotency_keys/${table}/g" -e "s/n8n_idem/${role}/g" "${TEMPLATE_DIR}/schema.sql")"
check "the shipped schema.sql was renamed for this test (no 'idempotency_keys' left)" \
  bash -c '! grep -q "idempotency_keys" <<<"$1"' _ "${schema_sql}"
check "the renamed schema creates ${table}" grep -q "CREATE TABLE IF NOT EXISTS ${table}" <<<"${schema_sql}"

# The password goes in on stdin exactly as the README tells a user to do it — never on a command line, where
# every user on the host could read it out of /proc. The escaping is the README's too: psql's \set lexer eats
# a backslash and ends the value at a single quote, so a password containing either would be stored as
# something else. rand_hex can produce neither, so this line is here to keep the tested recipe identical to
# the documented one rather than to fix anything in this script.
esc_password="$(printf '%s' "${ledger_password}" | sed -e 's/\\/\\\\/g' -e "s/'/''/g")"
schema_log="${STATE_DIR}/idem-schema-${nonce}.log"
applied=0
{ printf "\\set idem_password '%s'\n" "${esc_password}"; printf '%s\n' "${schema_sql}"; } |
  compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U n8n -d n8n >"${schema_log}" 2>&1 && applied=1
check "schema.sql applied through psql on stdin (log: ${schema_log})" test "${applied}" = 1
if (( applied == 0 )); then
  tail -15 "${schema_log}" >&2
  finish
fi
check "the ledger table exists" test "$(kit_psql "select to_regclass('public.${table}') is not null")" = "t"
check "the ledger role exists" test "$(kit_psql "select count(*) from pg_roles where rolname = '${role}'")" = "1"

# The least privilege the template's README promises, asserted instead of only claimed: the role the workflow
# holds may claim and complete keys, and may not read n8n's own tables or delete ledger rows.
check "the ledger role may INSERT a claim and complete one (state, result, done_at)" \
  test "$(kit_psql "select has_table_privilege('${role}', '${table}', 'insert')
    and has_column_privilege('${role}', '${table}', 'state', 'update')
    and has_column_privilege('${role}', '${table}', 'result', 'update')
    and has_column_privilege('${role}', '${table}', 'done_at', 'update')")" = "t"
# UPDATE is granted per column, so the credential cannot rename a key or take over somebody else's lease.
# This is also why the claim query's no-op assignment targets `state` and not `key`.
check "the ledger role may NOT rewrite a key or an owner" \
  test "$(kit_psql "select has_column_privilege('${role}', '${table}', 'key', 'update')
    or has_column_privilege('${role}', '${table}', 'owner', 'update')")" = "f"
check "the ledger role may NOT DELETE ledger rows (retention is the owner's job)" \
  test "$(kit_psql "select has_table_privilege('${role}', '${table}', 'delete')")" = "f"
check "the ledger role may NOT read n8n's stored credentials" \
  test "$(kit_psql "select has_table_privilege('${role}', 'credentials_entity', 'select')")" = "f"
check "the ledger role is not a superuser" \
  test "$(kit_psql "select rolsuper from pg_roles where rolname = '${role}'")" = "f"
# The reason the template ships a second role at all. If this ever flips, templates/idempotent-webhook/
# README.md and schema.sql are making a claim about the image that is no longer true.
check "...unlike the 'n8n' role, which is the database's bootstrap superuser" \
  test "$(kit_psql "select rolsuper from pg_roles where rolname = 'n8n'")" = "t"

# --- the credential the two Postgres nodes use ------------------------------------------------------------
api POST /api/v1/credentials "$(jq -nc --arg n "kit-smoke-idemcred-${nonce}" --arg u "${role}" --arg p "${ledger_password}" \
  '{name: $n, type: "postgres", data: {host: "postgres", port: 5432, database: "n8n", user: $u, password: $p, ssl: "disable", allowUnauthorizedCerts: false}}')"
cred_id="$(req_body | jq -r '.id // empty')"
check "Postgres credential for ${role} created (HTTP ${REQ_STATUS})" test -n "${cred_id}"
[[ -n "${cred_id}" ]] || finish

# --- the side effect, made countable ----------------------------------------------------------------------
# One execution of the sink = one side effect. The gate's "Do the work" node posts here instead of to a
# payment API, which is the one substitution that makes the invariant measurable.
api POST /api/v1/workflows "$(workflow_from_fixture wf-idem-sink.json "kit-smoke-idemsink-${nonce}" "${sink_path}")"
sink_id="$(req_body | jq -r '.id // empty')"
check "sink workflow created (HTTP ${REQ_STATUS})" test -n "${sink_id}"
api POST "/api/v1/workflows/${sink_id}/activate"
check "sink published (HTTP ${REQ_STATUS})" status_is 200
[[ -n "${sink_id}" ]] || finish

side_effects() {   # how many times the work has actually been done
  api GET "/api/v1/executions?workflowId=${sink_id}&limit=250"
  status_is 200 || { printf '%s\n' -1; return 0; }
  req_body | jq -r '.data | length' 2>/dev/null || printf '%s\n' -1
}
# The sink answers before its own execution runs (onReceived), so "exactly once" needs a window in which a
# second side effect would have shown up. Without it the assertion passes for the wrong reason: it would also
# pass while a second one is still on the queue.
settle() { sleep "${IDEM_SETTLE:-8}"; }

# --- the gate: the shipped template, with four substitutions ----------------------------------------------
gate_json="$(jq -c --arg n "kit-smoke-idem-${nonce}" --arg p "${gate_path}" --arg u "${BASE_URL}/webhook/${sink_path}" \
  --arg cid "${cred_id}" --arg cname "kit-smoke-idemcred-${nonce}" --arg tbl "${table}" '
  .name = $n
  | .nodes = [
      .nodes[]
      | if .type == "n8n-nodes-base.webhook" then .parameters.path = $p else . end
      | if .type == "n8n-nodes-base.postgres" then
            .credentials = {postgres: {id: $cid, name: $cname}}
          | .parameters.query |= gsub("idempotency_keys"; $tbl)
        else . end
      | if .name == "Do the work" then .parameters.url = $u else . end
    ]' "${TEMPLATE_DIR}/workflow.json")"
# The logic has to be the shipped logic: if a future edit drops the row lock or starts pasting the key into
# the SQL, this is where it shows.
check "the gate's claim query still takes the row lock (ON CONFLICT ... DO UPDATE)" \
  grep -q 'ON CONFLICT (key) DO UPDATE' <<<"${gate_json}"
check "the gate still binds the key as a query parameter instead of pasting it into the SQL" \
  grep -q 'queryReplacement' <<<"${gate_json}"
check "both Postgres nodes point at the test ledger (${table})" \
  test "$(grep -o "${table}" <<<"${gate_json}" | wc -l | tr -dc '0-9' || true)" -ge 2

api POST /api/v1/workflows "${gate_json}"
gate_id="$(req_body | jq -r '.id // empty')"
check "gate workflow created from the shipped template (HTTP ${REQ_STATUS})" test -n "${gate_id}"
[[ -n "${gate_id}" ]] || finish
api POST "/api/v1/workflows/${gate_id}/activate"
check "gate published (HTTP ${REQ_STATUS})" status_is 200

post_key() {   # post_key KEY [NOTE] -> sets REQ_STATUS, body in req_body
  req POST "/webhook/${gate_path}" -H 'Content-Type: application/json' \
    -H "Idempotency-Key: ${1}" --data "{\"orderId\":\"${1}\",\"note\":\"${2:-smoke}\"}"
}
gate_error_message() {   # the newest errored gate execution's error text
  local exec_id body
  api GET "/api/v1/executions?workflowId=${gate_id}&status=error&limit=1"
  exec_id="$(req_body | jq -r '.data[0].id // empty')"
  [[ -n "${exec_id}" ]] || { printf '\n'; return 0; }
  api GET "/api/v1/executions/${exec_id}?includeData=true"
  body="$(req_body)"
  jq -r '[.. | objects | select(has("message")) | .message | tostring] | join(" | ")' <<<"${body}" 2>/dev/null || printf '\n'
}
gate_error_says() {   # the execution record is written just after the HTTP answer, so this is polled
  grep -q "${1}" <<<"$(gate_error_message)"
}
gate_executions() {   # gate_executions STATUS -> how many
  api GET "/api/v1/executions?workflowId=${gate_id}&status=${1}&limit=250"
  req_body | jq -r '.data | length' 2>/dev/null || printf '0\n'
}

# --- a delivery with no key is refused, which doubles as the warm-up --------------------------------------
# Two things at once: an unregistered path answers 404 while a registered one that throws answers 500, so
# waiting for 500 proves the webhook reached the pool AND that the "no key, no work" rule holds. It leaves no
# side effect, which keeps every count below a clean delta from zero.
no_key_refused() {
  req POST "/webhook/${gate_path}" -H 'Content-Type: application/json' --data '{"customer":"no-key-at-all"}'
  status_is 500
}
check "a delivery with no idempotency key is refused (HTTP 500, <= 180 s)" \
  wait_for 180 "the gate to answer on the pool" no_key_refused
check "...for the right reason (the key check, not a cold runner)" \
  wait_for 30 "the refusal to be recorded" gate_error_says 'no idempotency key'
check "refusing it did the work zero times ($(side_effects) sink execution(s))" test "$(side_effects)" = "0"
# Measured, not assumed to be 1: wait_for polls, so on a slow stack the first attempts can 404 (no execution)
# while a later one errors — and if activation lands between two polls, more than one 500 can be recorded.
# The accounting assertion after the burst needs the real number, or it fails on a correct stack.
warmup_errors="$(gate_executions error)"
info "the warm-up left ${warmup_errors} errored execution(s) behind"

# --- the race: one key, N deliveries, all at once ---------------------------------------------------------
info "firing the same idempotency key ${burst_key} ${N} times with ${N} in flight"
seq 1 "${N}" | xargs -P "${N}" -I{} sh -c '
  url=$1; key=$2; i=$3; shift 3
  code=$(curl -sS --max-time 60 "$@" -o /dev/null -w "%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" -H "Idempotency-Key: $key" \
    --data "{\"orderId\":\"$key\",\"try\":\"$i\"}" 2>/dev/null) || code=""
  case "$code" in ""|*[!0-9]*) code=000 ;; esac
  printf "%s\n" "$code"
' sh "${BASE_URL}/webhook/${gate_path}" "${burst_key}" {} "${CURL_TLS[@]}" >>"${codes_file}" || true

sent="$(wc -l <"${codes_file}" | tr -dc '0-9')"
ok_n="$(grep -c '^200$' "${codes_file}" || true)"
err_n="$(grep -c '^500$' "${codes_file}" || true)"
other_n="$(grep -cvE '^(200|500)$' "${codes_file}" || true)"
check "all ${N} deliveries were answered (${sent:-0} responses)" test "${sent:-0}" = "${N}"
check "every answer was a 200 or a 500 (${ok_n:-0} x 200, ${err_n:-0} x 500, ${other_n:-0} other)" \
  test "${other_n:-0}" = "0"
check "at least one delivery was accepted (${ok_n:-0} x 200)" test "${ok_n:-0}" -ge 1

work_done_once() { (( $(side_effects) >= 1 )); }
check "the work was done (<= 60 s)" wait_for 60 "the side effect to be recorded" work_done_once
settle

# THE invariant. Everything else in this file is scaffolding for this line.
effects="$(side_effects)"
check "the work happened EXACTLY ONCE for ${N} simultaneous deliveries of one key (${effects} sink execution(s))" \
  test "${effects}" = "1"
check "the ledger holds exactly one row for the key" \
  test "$(kit_psql "select count(*) from ${table} where key = '${burst_key}'")" = "1"
check "that row is 'done', with a result stored for the replays" \
  test "$(kit_psql "select state = 'done' and result is not null and done_at is not null from ${table} where key = '${burst_key}'")" = "t"
check "its owner is the n8n execution that claimed it (exec:...)" \
  bash -c '[[ "$1" =~ ^exec:[0-9]+$ ]]' _ "$(kit_psql "select owner from ${table} where key = '${burst_key}'")"
# How n8n recorded the burst. A 200 means an execution succeeded — either the one that did the work or a
# delivery that arrived after it finished and was answered from the ledger — so the two counts must agree, and
# together with the errors they must account for every delivery plus the no-key refusal. Nothing may be left
# running or waiting.
gate_success="$(gate_executions success)"
gate_error="$(gate_executions error)"
check "n8n recorded one execution per delivery (${gate_success} success + ${gate_error} error = ${N} + ${warmup_errors} from the warm-up)" \
  test "$(( gate_success + gate_error ))" = "$(( N + warmup_errors ))"
check "the 200s are exactly the executions that succeeded (${ok_n:-0} vs ${gate_success})" \
  test "${ok_n:-0}" = "${gate_success}"

# --- a replay gets the first answer back, not a second side effect ----------------------------------------
post_key "${burst_key}" replay
replay_outcome="$(req_body | jq -r '.outcome // empty' 2>/dev/null || true)"
replay_result="$(req_body | jq -c '.result // empty' 2>/dev/null || true)"
check "a later delivery of the same key answers 200 (HTTP ${REQ_STATUS})" status_is 200
check "...with outcome=duplicate (${replay_outcome:-none})" test "${replay_outcome}" = "duplicate"
check "...and the stored result of the first execution" \
  bash -c '[[ -n "$1" && "$1" != "null" ]]' _ "${replay_result}"
settle
check "the replay did NOT do the work again ($(side_effects) sink execution(s))" test "$(side_effects)" = "1"

# --- a different key must not be blocked ------------------------------------------------------------------
# The failure nobody notices until it costs an order: a gate that deduplicates everything.
post_key "${second_key}" second
second_outcome="$(req_body | jq -r '.outcome // empty' 2>/dev/null || true)"
check "a NEW key is accepted (HTTP ${REQ_STATUS}, outcome ${second_outcome:-none})" test "${second_outcome}" = "done"
work_done_twice() { (( $(side_effects) >= 2 )); }
check "the work happened for it (<= 60 s)" wait_for 60 "the second side effect" work_done_twice
settle
check "...once, not twice ($(side_effects) sink execution(s))" test "$(side_effects)" = "2"

# --- the two refusals: a lease still running, and a lease nobody completed ---------------------------------
# Planted rather than raced, so both are deterministic: a row owned by somebody else, young or old. What is
# asserted is the message the operator ends up reading — that is the whole value of these two branches.
kit_psql "insert into ${table} (key, owner, state, claimed_at) values ('inflight-${nonce}', 'exec:999999', 'in_progress', now())" >/dev/null ||
  die "could not plant the in-flight row"
post_key "inflight-${nonce}" inflight
check "a key somebody else is still working on is refused (HTTP ${REQ_STATUS})" status_is 500
check "...and the error says it is in flight" wait_for 30 "the in-flight refusal" gate_error_says 'is in flight'
check "...and the lease was left alone" \
  test "$(kit_psql "select owner = 'exec:999999' and state = 'in_progress' from ${table} where key = 'inflight-${nonce}'")" = "t"

kit_psql "insert into ${table} (key, owner, state, claimed_at) values ('stale-${nonce}', 'exec:999998', 'in_progress', now() - interval '1 hour')" >/dev/null ||
  die "could not plant the stale row"
post_key "stale-${nonce}" stale
check "a lease claimed an hour ago and never completed is refused (HTTP ${REQ_STATUS})" status_is 500
check "...and the error says it needs a human, not a retry" \
  wait_for 30 "the stale refusal" gate_error_says 'never completed'

settle
check "neither refusal did the work ($(side_effects) sink execution(s), still 2)" test "$(side_effects)" = "2"
finish
