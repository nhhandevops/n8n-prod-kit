#!/usr/bin/env bash
# compose/scripts/loadtest.sh — `make loadtest [N=200] [P=20] [KEEP=1]`: push N webhook calls through the pool and
# watch the queue drain. It is the measurement half of S8 (the chaos drills reuse it) and the "200 test webhooks"
# step of the demo script.
#
# What it does: publishes its own `kit-smoke-load-<nonce>` workflow (the fixture the smoke suite uses, and the same
# name prefix, so a later `make smoke` cleans up anything this leaves behind), waits for the pool to register it,
# fires N POSTs with P in flight, samples the queue depth while they run, then waits for N successful executions.
#
# What it reports: a histogram of HTTP codes, wall clock for the send and drain phases, requests/s, executions/min,
# the peak queue depth and the per-worker split — the numbers behind the sizing table. A slow run on a small host
# is a measurement, not a failure; only a queue that never drains is.
#
# It talks to the stack the way a user does (through Caddy on PUBLIC_URL) and reuses the smoke suite's owner and API
# key from compose/.smoke/, creating them on first use. It deletes nothing: its own workflow goes away on exit
# unless KEEP=1, and the executions age out through the normal pruning settings.
#
# Exit codes: 0 every sent request produced a successful execution · 1 setup failed · 2 the queue did not drain.
# shellcheck disable=SC2310,SC2311,SC2312  # helpers are called in conditions on purpose (see tests/smoke/lib.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../../tests/smoke/lib.sh
source "${SCRIPT_DIR}/../../tests/smoke/lib.sh"

N="${N:-200}"
P="${P:-20}"
KEEP="${KEEP:-}"
# Sampling costs a `docker exec` per tick, which is itself load on a small host — 3 s is often enough to catch the
# peak without distorting what it measures.
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-3}"
# The drain budget scales with the backlog: 2 workers x concurrency 10 on a 2 vCPU host run a few executions/s.
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-$(( 120 + N * 3 ))}"

[[ "${N}" =~ ^[0-9]+$ ]] && (( N >= 1 && N <= 100000 )) || die "N must be 1..100000 (got '${N}')"
[[ "${P}" =~ ^[0-9]+$ ]] && (( P >= 1 && P <= 200 )) || die "P must be 1..200 (got '${P}')"
[[ "${DRAIN_TIMEOUT}" =~ ^[0-9]+$ ]] || die "DRAIN_TIMEOUT must be a number of seconds (got '${DRAIN_TIMEOUT}')"

# --- the stack has to be up before anything here means something -----------------------------------------------------
not_running="$(compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$2 != "running" { print $1 }' || true)"
[[ -z "${not_running}" ]] || die "not every service is running (${not_running//$'\n'/ }) — run make up && make status first"

workers=()
while read -r svc; do
  [[ -n "${svc}" ]] && workers+=("${svc}")
done < <(compose config --services | grep -E '^n8n-worker-[0-9]+$' | sort)
(( ${#workers[@]} > 0 )) || die "no n8n-worker-* services found"

ensure_owner || die "could not get an owner account (see above)"
ensure_api_key || die "could not get an API key (see above)"

# --- state that the exit trap has to be able to clean up -------------------------------------------------------------
wf_id=''
sampler_pid=''
codes_file="$(mktemp "${STATE_DIR}/.loadtest-codes.XXXXXX")"
peak_file="$(mktemp "${STATE_DIR}/.loadtest-peak.XXXXXX")"
printf '0\n' >"${peak_file}"

stop_sampler() {
  [[ -n "${sampler_pid}" ]] || return 0
  kill "${sampler_pid}" 2>/dev/null || true
  wait "${sampler_pid}" 2>/dev/null || true
  sampler_pid=''
}
cleanup() {
  local rc=$?
  stop_sampler
  if [[ -n "${wf_id}" ]]; then
    if [[ -n "${KEEP}" ]]; then
      info "KEEP=1: workflow ${wf_id} left published on /webhook/${path}"
    else
      api POST "/api/v1/workflows/${wf_id}/deactivate" || true
      api DELETE "/api/v1/workflows/${wf_id}" || true
    fi
  fi
  rm -f "${codes_file}" "${peak_file}" 2>/dev/null || true
  exit "${rc}"
}
trap cleanup EXIT

# --- publish the workflow under test -----------------------------------------------------------------------------------
nonce="$(rand_hex 6)"
path="kit-smoke-load-${nonce}"
api POST /api/v1/workflows "$(workflow_from_fixture wf-webhook-echo.json "kit-smoke-load-${nonce}" "${path}")"
wf_id="$(req_body | jq -r '.id // empty')"
[[ -n "${wf_id}" ]] || die "could not create the load-test workflow (HTTP ${REQ_STATUS}): $(req_body | head -c 200)"
api POST "/api/v1/workflows/${wf_id}/activate"
status_is 200 || die "could not publish the workflow (HTTP ${REQ_STATUS})"

# Activation reaches the webhook processes asynchronously, and the first execution after a (re)start waits for the
# runner sidecar to launch its JS process — the smoke suite allows 180 s for the same reason (HANDOFF §5).
warm() {
  local code
  code="$(curl -sS --max-time 30 "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' \
    -X POST "${BASE_URL}/webhook/${path}" -H 'Content-Type: application/json' \
    --data "{\"ping\":\"${nonce}-warmup\"}" 2>/dev/null || true)"
  [[ "${code}" == "200" ]]
}
wait_for 180 "the pool to register /webhook/${path}" warm || die "the webhook never answered 200 — is the stack healthy? (make status)"

metric_int() {   # metric_int NAME -> integer value of a main metric, 0 when absent
  local v
  v="$(main_metric "${1}")"
  v="${v%%.*}"
  [[ "${v}" =~ ^[0-9]+$ ]] || v=0
  printf '%s\n' "${v}"
}
baseline_completed="$(metric_int n8n_scaling_mode_queue_jobs_completed)"
info "load test: N=${N} P=${P} -> ${BASE_URL}/webhook/${path} (${#workers[@]} workers, drain budget ${DRAIN_TIMEOUT}s)"

# --- sample the queue depth while the send phase runs -----------------------------------------------------------------
sample_queue() {
  local depth peak=0
  while :; do
    depth="$(metric_int n8n_scaling_mode_queue_jobs_waiting)"
    if (( depth > peak )); then
      peak="${depth}"
      printf '%s\n' "${peak}" >"${peak_file}"
    fi
    sleep "${SAMPLE_INTERVAL}"
  done
}
sample_queue &
sampler_pid=$!

# --- send phase ----------------------------------------------------------------------------------------------------
# One curl per request through `xargs -P`: no extra dependency, and each child prints only its HTTP code. A non-2xx
# (or a connection dropped by a chaos drill) must not kill the run — the histogram IS the result, hence `|| echo 000`
# per child and `|| true` on the pipeline. The child takes url/nonce/index as $1..$3 and shifts, so "$@" is exactly
# the TLS options; `-I{}` is safe next to curl's `%{http_code}` because that contains no literal `{}` pair.
send_start="${SECONDS}"
seq 1 "${N}" | xargs -P "${P}" -I{} sh -c '
  url=$1; nonce=$2; i=$3; shift 3
  curl -sS --max-time 60 "$@" -o /dev/null -w "%{http_code}\n" \
    -X POST "$url" -H "Content-Type: application/json" --data "{\"ping\":\"$nonce-$i\"}" 2>/dev/null || echo 000
' sh "${BASE_URL}/webhook/${path}" "${nonce}" {} "${CURL_TLS[@]}" >>"${codes_file}" || true
send_elapsed=$(( SECONDS - send_start ))

sent="$(wc -l <"${codes_file}" | tr -dc '0-9')"
sent="${sent:-0}"
ok_count="$(grep -c '^200$' "${codes_file}" || true)"
ok_count="${ok_count:-0}"
info "sent ${sent}/${N} in ${send_elapsed}s ($(( sent / (send_elapsed > 0 ? send_elapsed : 1) ))/s) — HTTP codes:"
sort "${codes_file}" | uniq -c | sort -rn | while read -r count code; do
  printf '         %6s x HTTP %s\n' "${count}" "${code}" >&2
done

# --- drain phase -----------------------------------------------------------------------------------------------------
count_executions() {   # count_executions STATUS -> how many executions of this workflow have it (paged)
  local status="${1}" cursor='' n=0 page
  while :; do
    api GET "/api/v1/executions?workflowId=${wf_id}&status=${status}&limit=250${cursor:+&cursor=${cursor}}"
    status_is 200 || break
    page="$(req_body)"
    n=$(( n + $(jq -r '.data | length' <<<"${page}" 2>/dev/null || echo 0) ))
    cursor="$(jq -r '.nextCursor // empty' <<<"${page}" 2>/dev/null || true)"
    [[ -n "${cursor}" ]] || break
  done
  printf '%s\n' "${n}"
}
drained() {
  (( $(count_executions success) >= ok_count ))
}
drain_start="${SECONDS}"
drain_rc=0
wait_for "${DRAIN_TIMEOUT}" "${ok_count} successful executions" drained || drain_rc=2
drain_elapsed=$(( SECONDS - drain_start ))
stop_sampler

success_n="$(count_executions success)"
error_n="$(count_executions error)"
peak="$(tr -dc '0-9' <"${peak_file}" 2>/dev/null || true)"
peak="${peak:-0}"
completed_now="$(metric_int n8n_scaling_mode_queue_jobs_completed)"

# Per-worker split: each worker logs the jobs it picked up, which is also how a chaos drill shows a takeover.
printf '\n' >&2
log "per-worker jobs (container logs for the window this run covers)"
window=$(( send_elapsed + drain_elapsed + 240 ))
for w in "${workers[@]}"; do
  n="$(compose logs --no-color --since "${window}s" "${w}" 2>/dev/null | grep -ciE 'start(ed)? (job|execution)' || true)"
  printf '         %-24s %s\n' "${w}" "${n:-0}" >&2
done

printf '\n' >&2
log "result"
printf '         sent               %s (HTTP 200: %s)\n' "${sent}" "${ok_count}" >&2
printf '         send phase         %ss\n' "${send_elapsed}" >&2
printf '         drain phase        %ss\n' "${drain_elapsed}" >&2
printf '         executions         %s success, %s error\n' "${success_n}" "${error_n}" >&2
printf '         throughput         %s executions/min over the drain\n' \
  "$(( drain_elapsed > 0 ? success_n * 60 / drain_elapsed : success_n ))" >&2
printf '         peak queue depth   %s waiting (sampled every %ss)\n' "${peak}" "${SAMPLE_INTERVAL}" >&2
printf '         queue completed    %s -> %s (+%s)\n' \
  "${baseline_completed}" "${completed_now}" "$(( completed_now - baseline_completed ))" >&2

if (( drain_rc != 0 )); then
  fail "the queue did not drain within ${DRAIN_TIMEOUT}s — ${success_n}/${ok_count} succeeded. Raise DRAIN_TIMEOUT, add workers (make scale-workers N=4), or look at make logs SERVICE=${workers[0]}"
  exit 2
fi
(( error_n == 0 )) || warn "${error_n} execution(s) ended in error — open them in the UI or run make logs SERVICE=${workers[0]}"
(( ok_count == N )) || warn "$(( N - ok_count )) request(s) did not answer HTTP 200 — see the histogram above"
ok "load test done: ${success_n} executions succeeded, peak queue depth ${peak}"
