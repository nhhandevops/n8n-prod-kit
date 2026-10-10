#!/usr/bin/env bash
# compose/scripts/loadtest.sh — `make loadtest [N=200] [P=20] [KEEP=1]`: push N webhook calls through the pool and
# watch the queue drain. It is the measurement half of S8 (the chaos drills reuse it) and the "200 test webhooks"
# step of the demo script.
#
# What it does: publishes its own `kit-smoke-load-<nonce>` workflow (same name prefix as the smoke suite, so a later
# `make smoke` cleans up anything this leaves behind), waits for the pool to register it, fires N POSTs with P in
# flight, samples the queue depth while they run, then waits for N successful executions.
#
# MODE=async (default) uses a webhook that answers as soon as the job is queued — a real inbound burst, and the only
# shape that can build a backlog: the senders race ahead of the workers, the queue rises, then it drains. That is
# step 6 of the demo script. MODE=sync holds each response until its workflow has finished (responseMode lastNode),
# which measures end-to-end latency per request but can never queue more than P jobs — with P at or below
# WORKER_REPLICAS x WORKER_CONCURRENCY no job ever waits, so its peak depth is 0 by construction.
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
# shellcheck disable=SC2310,SC2311,SC2312,SC2016  # helpers are called in conditions on purpose (see tests/smoke/lib.sh);
#                                                  the sh -c snippets are literal on purpose — $VALKEY_PASSWORD must
#                                                  expand inside the container, $1.. inside the child shell
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../../tests/smoke/lib.sh
source "${SCRIPT_DIR}/../../tests/smoke/lib.sh"

N="${N:-200}"
P="${P:-20}"
MODE="${MODE:-async}"
KEEP="${KEEP:-}"
# Queue depth is read from Valkey, not from n8n's Prometheus gauge: that gauge only refreshes every
# N8N_METRICS_QUEUE_METRICS_INTERVAL seconds (20 by default), so sampling it faster just re-reads a stale number.
# One long-lived `exec` inside the container does the sampling, so a 1 s interval costs no docker exec per tick.
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
# The drain budget scales with the backlog: 2 workers x concurrency 10 on a 2 vCPU host run a few executions/s.
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-$(( 120 + N * 3 ))}"

if [[ ! "${N}" =~ ^[0-9]+$ ]] || (( N < 1 || N > 100000 )); then
  die "N must be 1..100000 (got '${N}')"
fi
if [[ ! "${P}" =~ ^[0-9]+$ ]] || (( P < 1 || P > 200 )); then
  die "P must be 1..200 (got '${P}')"
fi
if [[ ! "${DRAIN_TIMEOUT}" =~ ^[0-9]+$ ]] || (( DRAIN_TIMEOUT < 1 )); then
  die "DRAIN_TIMEOUT must be a positive number of seconds (got '${DRAIN_TIMEOUT}')"
fi
if [[ ! "${SAMPLE_INTERVAL}" =~ ^[0-9]+$ ]] || (( SAMPLE_INTERVAL < 1 )); then
  die "SAMPLE_INTERVAL must be a positive number of seconds (got '${SAMPLE_INTERVAL}')"
fi
case "${MODE}" in
  async) fixture=wf-webhook-async.json ;;
  sync)  fixture=wf-webhook-echo.json ;;
  *)     die "MODE must be async (answer when queued — builds a backlog) or sync (answer when finished), got '${MODE}'" ;;
esac

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
depth_file="$(mktemp "${STATE_DIR}/.loadtest-depth.XXXXXX")"
# BullMQ names its lists "<QUEUE_BULL_PREFIX>:jobs:<state>"; the kit's prefix is n8n (compose/docker-compose.yml).
queue_prefix="$(env_get QUEUE_BULL_PREFIX)"
wait_key="${queue_prefix:-n8n}:jobs:wait"

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
  rm -f "${codes_file}" "${depth_file}" 2>/dev/null || true
  exit "${rc}"
}
trap cleanup EXIT

# --- publish the workflow under test -----------------------------------------------------------------------------------
nonce="$(rand_hex 6)"
path="kit-smoke-load-${nonce}"
api POST /api/v1/workflows "$(workflow_from_fixture "${fixture}" "kit-smoke-load-${nonce}" "${path}")"
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

# --- baseline AFTER the warm-up, so the warm-up's own execution is not counted ---------------------------------------
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
# MODE=async answers before the workflow has run, so the warm-up's own execution is still in flight here. Wait for
# it to land before baselining, or it finishes during the run and is counted as one extra success.
warmup_landed() {
  (( $(count_executions success) + $(count_executions error) >= 1 ))
}
wait_for 120 "the warm-up execution to finish" warmup_landed \
  || warn "the warm-up execution has not finished — the totals below may be off by one"
base_success="$(count_executions success)"
base_error="$(count_executions error)"
info "load test: N=${N} P=${P} MODE=${MODE} -> ${BASE_URL}/webhook/${path} (${#workers[@]} workers, drain budget ${DRAIN_TIMEOUT}s)"

# --- sample the real queue depth from Valkey while the run proceeds ----------------------------------------------
# A single bounded loop inside the container: killing a backgrounded `compose exec` does not reliably stop the
# process it started, so the loop counts itself out instead of relying on the signal.
max_ticks=$(( (DRAIN_TIMEOUT + 900) / SAMPLE_INTERVAL ))
compose exec -T valkey sh -c '
  key=$1; interval=$2; ticks=$3; i=0
  while [ "$i" -lt "$ticks" ]; do
    VALKEYCLI_AUTH="$VALKEY_PASSWORD" valkey-cli llen "$key" 2>/dev/null || echo 0
    i=$((i + 1))
    sleep "$interval"
  done
' sh "${wait_key}" "${SAMPLE_INTERVAL}" "${max_ticks}" >"${depth_file}" 2>/dev/null &
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
drained() {
  (( $(count_executions success) - base_success >= ok_count ))
}
drain_start="${SECONDS}"
drain_rc=0
wait_for "${DRAIN_TIMEOUT}" "${ok_count} successful executions" drained || drain_rc=2
drain_elapsed=$(( SECONDS - drain_start ))
total_elapsed=$(( SECONDS - send_start ))
stop_sampler

success_n=$(( $(count_executions success) - base_success ))
error_n=$(( $(count_executions error) - base_error ))
peak="$(awk '/^[0-9]+$/ && $1 > m { m = $1 } END { print m + 0 }' "${depth_file}" 2>/dev/null || echo 0)"
samples="$(grep -c '^[0-9]\+$' "${depth_file}" 2>/dev/null || true)"

# Per-worker split: each worker logs "Worker started execution N (job M)" once per job, with the workflow id in the
# JSON. Matching on this run's workflow id is what keeps an earlier run inside the same time window out of the count.
printf '\n' >&2
log "per-worker jobs (this run's workflow only)"
window=$(( send_elapsed + drain_elapsed + 240 ))
worker_total=0
for w in "${workers[@]}"; do
  n="$(compose logs --no-color --since "${window}s" "${w}" 2>/dev/null \
        | grep -F "\"workflowId\":\"${wf_id}\"" | grep -c 'started execution' || true)"
  n="${n:-0}"
  worker_total=$(( worker_total + n ))
  printf '         %-24s %s\n' "${w}" "${n}" >&2
done
printf '         %-24s %s\n' "total" "${worker_total}" >&2

printf '\n' >&2
log "result"
printf '         sent               %s (HTTP 200: %s)\n' "${sent}" "${ok_count}" >&2
printf '         send phase         %ss (%s req/s)\n' "${send_elapsed}" \
  "$(( sent / (send_elapsed > 0 ? send_elapsed : 1) ))" >&2
printf '         drain after send   %ss\n' "${drain_elapsed}" >&2
printf '         end to end         %ss (first request -> last execution)\n' "${total_elapsed}" >&2
printf '         executions         %s success, %s error (this run only)\n' "${success_n}" "${error_n}" >&2
printf '         throughput         %s executions/min end to end\n' \
  "$(( total_elapsed > 0 ? success_n * 60 / total_elapsed : success_n ))" >&2
printf '         peak queue depth   %s waiting (%s samples of %s, %ss apart)\n' \
  "${peak}" "${samples:-0}" "${wait_key}" "${SAMPLE_INTERVAL}" >&2
if (( peak == 0 )) && [[ "${MODE}" == "sync" ]]; then
  printf '         note               MODE=sync holds each response until its execution finishes, so at most P=%s jobs\n' "${P}" >&2
  printf '                            exist at once and none of them waits. Use MODE=async to build a backlog.\n' >&2
fi

if (( drain_rc != 0 )); then
  fail "the queue did not drain within ${DRAIN_TIMEOUT}s — ${success_n}/${ok_count} succeeded. Raise DRAIN_TIMEOUT, add workers (make scale-workers N=4), or look at make logs SERVICE=${workers[0]}"
  exit 2
fi
(( error_n == 0 )) || warn "${error_n} execution(s) ended in error — open them in the UI or run make logs SERVICE=${workers[0]}"
(( ok_count == N )) || warn "$(( N - ok_count )) request(s) did not answer HTTP 200 — see the histogram above"
ok "load test done: ${success_n} executions succeeded, peak queue depth ${peak}"
