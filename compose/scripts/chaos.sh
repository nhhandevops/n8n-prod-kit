#!/usr/bin/env bash
# compose/scripts/chaos.sh — `make chaos SCENARIO=worker|redis|main [N=] [YES=1]`: break one part of a running stack
# under load and prove the documented behaviour (PLAN §2.9, TC-008/009/010).
#
#   worker  kill a worker mid-execution        -> Bull re-queues its jobs, another worker finishes them, Docker
#                                                 restarts the container, and an idempotent workflow still leaves
#                                                 exactly one side effect per input (TC-008)
#   redis   stop Valkey for OUTAGE seconds     -> webhooks fail loudly while it is down, and every job that was
#                                                 already queued survives (AOF) and completes afterwards (TC-009)
#   main    restart n8n-main under load        -> production webhooks keep answering 200 because main is not in
#                                                 their path, and schedule triggers resume by themselves (TC-010)
#
# These drills stop and kill containers of THIS Compose project on purpose. They never touch volumes, the database
# or .env: the stack is left running and healthy, the drill's own workflow is deleted and its files removed. Expect
# a few minutes — recovery from a lost worker waits for Bull's lock to lapse (QUEUE_WORKER_LOCK_DURATION 60 s).
#
# Exit codes: 0 every assertion held · 1 an assertion failed or setup went wrong.
# shellcheck disable=SC2310,SC2311,SC2312,SC2016,SC2329  # helpers run in conditions; sh -c snippets are literal on
#   purpose; the assertion/recovery helpers are invoked indirectly, through check, wait_for and the EXIT trap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../../tests/smoke/lib.sh
source "${SCRIPT_DIR}/../../tests/smoke/lib.sh"

SCENARIO="${SCENARIO:-}"
N="${N:-120}"
P="${P:-40}"
OUTAGE="${OUTAGE:-60}"
YES="${YES:-}"
RECOVER_TIMEOUT="${RECOVER_TIMEOUT:-420}"

case "${SCENARIO}" in
  worker|redis|main) ;;
  *) die "usage: make chaos SCENARIO=worker|redis|main [N=${N}] [OUTAGE=${OUTAGE}] [YES=1]" ;;
esac
if [[ ! "${N}" =~ ^[0-9]+$ ]] || (( N < 10 || N > 5000 )); then
  die "N must be 10..5000 (got '${N}')"
fi

# --- preconditions ----------------------------------------------------------------------------------------------
not_running="$(compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$2 != "running" { print $1 }' || true)"
[[ -z "${not_running}" ]] || die "not every service is running (${not_running//$'\n'/ }) — a chaos drill needs a healthy stack: make up && make status"

workers=()
while read -r svc; do
  [[ -n "${svc}" ]] && workers+=("${svc}")
done < <(compose config --services | grep -E '^n8n-worker-[0-9]+$' | sort)
(( ${#workers[@]} >= 2 )) || die "the ${SCENARIO} drill needs at least 2 workers (make scale-workers N=2)"

ensure_owner  || die "could not get an owner account (see above)"
ensure_api_key || die "could not get an API key (see above)"

if [[ -z "${YES}" ]]; then
  confirm "Run the '${SCENARIO}' chaos drill against the running stack? Containers will be killed or stopped and then recovered." \
    || die "cancelled — nothing was touched" 0
fi

# --- shared state and recovery ------------------------------------------------------------------------------------
run_id="$(rand_hex 4)"
wf_id=''
sched_id=''
codes_file="$(mktemp "${STATE_DIR}/.chaos-codes.XXXXXX")"
queue_prefix="$(env_get QUEUE_BULL_PREFIX)"
wait_key="${queue_prefix:-n8n}:jobs:wait"

delete_workflow() {   # delete_workflow ID — deactivate, then delete (DELETE 409s for a moment after deactivation)
  local id="${1}" tries=0
  [[ -n "${id}" ]] || return 0
  api POST "/api/v1/workflows/${id}/deactivate" || true
  until api DELETE "/api/v1/workflows/${id}" && status_is 200; do
    tries=$((tries + 1))
    (( tries < 10 )) || { warn "could not delete the drill workflow ${id} (HTTP ${REQ_STATUS}) — remove it in the UI"; break; }
    sleep 2
  done
}
cleanup() {
  local rc=$?
  printf '\n' >&2
  info "restoring the stack"
  # Whatever happened, every service must be running again: `compose up -d` starts what the drill stopped and leaves
  # everything else alone. Volumes, the database and .env are never touched by this script.
  compose up -d --wait --wait-timeout 300 >/dev/null 2>&1 \
    || warn "the stack did not come back healthy by itself — check make status and make doctor"
  delete_workflow "${wf_id}"
  delete_workflow "${sched_id}"
  compose exec -T "${workers[0]}" sh -c "rm -f /home/node/.n8n-files/chaos-${run_id}-*.txt" >/dev/null 2>&1 || true
  rm -f "${codes_file}" 2>/dev/null || true
  exit "${rc}"
}
trap cleanup EXIT

queue_depth() {
  local d
  d="$(compose exec -T valkey sh -c 'VALKEYCLI_AUTH="$VALKEY_PASSWORD" valkey-cli llen "$1"' sh "${wait_key}" 2>/dev/null || true)"
  d="${d//[^0-9]/}"
  printf '%s\n' "${d:-0}"
}
publish() {   # publish FIXTURE PATH -> sets wf_id
  api POST /api/v1/workflows "$(workflow_from_fixture "${1}" "kit-smoke-chaos-${run_id}" "${2}")"
  wf_id="$(req_body | jq -r '.id // empty')"
  [[ -n "${wf_id}" ]] || die "could not create the drill workflow (HTTP ${REQ_STATUS}): $(req_body | head -c 200)"
  api POST "/api/v1/workflows/${wf_id}/activate"
  status_is 200 || die "could not publish the drill workflow (HTTP ${REQ_STATUS})"
}
post_one() {   # post_one PATH ID -> HTTP code on stdout
  curl -sS --max-time 30 "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' \
    -X POST "${BASE_URL}/webhook/${1}" -H 'Content-Type: application/json' \
    --data "{\"run\":\"${run_id}\",\"id\":\"${2}\"}" 2>/dev/null || echo 000
}
warm() {
  [[ "$(post_one "${1}" warmup)" == "200" ]]
}
fire() {   # fire PATH FROM TO — POST ids FROM..TO with P in flight, codes appended to codes_file
  seq "${2}" "${3}" | xargs -P "${P}" -I{} sh -c '
    url=$1; run=$2; i=$3; shift 3
    curl -sS --max-time 30 "$@" -o /dev/null -w "%{http_code}\n" \
      -X POST "$url" -H "Content-Type: application/json" --data "{\"run\":\"$run\",\"id\":\"$i\"}" 2>/dev/null || echo 000
  ' sh "${BASE_URL}/webhook/${1}" "${run_id}" {} "${CURL_TLS[@]}" >>"${codes_file}" || true
}
side_effects() {   # how many distinct files this run produced (one per input id, overwritten by a retry)
  local n
  n="$(compose exec -T "${workers[0]}" sh -c "ls -1 /home/node/.n8n-files/chaos-${run_id}-*.txt 2>/dev/null | wc -l" 2>/dev/null || true)"
  n="${n//[^0-9]/}"
  printf '%s\n' "${n:-0}"
}
restart_count() {   # restart_count SERVICE — Docker's restart counter for a compose service
  local cid n
  cid="$(compose ps -q "${1}" 2>/dev/null | head -1)"
  [[ -n "${cid}" ]] || { printf '0\n'; return 0; }
  n="$(docker inspect -f '{{.RestartCount}}' "${cid}" 2>/dev/null || true)"
  printf '%s\n' "${n:-0}"
}
count_status() {   # count_status STATUS -> executions of the drill workflow with that status (paged)
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

# ======================================================================================================================
# worker — kill a worker mid-execution (TC-008)
# ======================================================================================================================
scenario_worker() {
  local path="kit-chaos-${run_id}" victim="${workers[0]}" survivor="${workers[1]}"
  publish wf-chaos-idempotent.json "${path}"
  wait_for 180 "the pool to register /webhook/${path}" warm "${path}" \
    || die "the drill webhook never answered 200 — is the stack healthy?"
  compose exec -T "${victim}" sh -c "rm -f /home/node/.n8n-files/chaos-${run_id}-*.txt" >/dev/null 2>&1 || true

  local before_restarts
  before_restarts="$(restart_count "${victim}")"
  info "firing ${N} jobs, then killing ${victim} while the backlog drains"
  fire "${path}" 1 "${N}"

  # Kill while there is still a backlog AND work in flight — that is what makes it a mid-execution kill.
  local depth waited=0
  depth="$(queue_depth)"
  while (( depth == 0 )) && (( waited < 20 )); do
    sleep 1; waited=$((waited + 1)); depth="$(queue_depth)"
  done
  info "queue depth at kill time: ${depth}"
  docker kill "$(compose ps -q "${victim}" | head -1)" >/dev/null 2>&1 || warn "could not kill ${victim}"
  ok "SIGKILLed ${victim} (no graceful shutdown — its in-flight jobs are lost until Bull re-queues them)"

  # Bull only re-queues a job once its lock lapses (QUEUE_WORKER_LOCK_DURATION 60 s) and the stalled check runs
  # (QUEUE_WORKER_STALLED_INTERVAL 30 s), so recovery legitimately takes up to ~90 s longer than a normal drain.
  all_written() { (( $(side_effects) >= N )); }
  local recovered=0
  wait_for "${RECOVER_TIMEOUT}" "all ${N} inputs to have produced their file" all_written && recovered=1

  local effects successes
  effects="$(side_effects)"
  successes="$(count_status success)"
  printf '\n' >&2
  log "worker drill (TC-008)"
  check "every input produced its side effect (${effects}/${N}) — no job was lost" test "${recovered}" = 1
  check "exactly one side effect per input (${effects} files for ${N} inputs) — retries did not duplicate" \
    test "${effects}" -le "${N}"
  check "${victim} was restarted by Docker (restart count ${before_restarts} -> $(restart_count "${victim}"))" \
    test "$(restart_count "${victim}")" -gt "${before_restarts}"
  check "${victim} is healthy again" wait_for 180 "${victim} healthy" test_service_healthy "${victim}"
  check "${survivor} kept working through the kill" test "$(jobs_logged "${survivor}")" -gt 0
  info "executions recorded: ${successes} success for ${N} inputs — anything above ${N} is Bull re-running a stalled job, which is expected (PLAN §2.9: workflows must be idempotent)"
}
test_service_healthy() {
  [[ "$(service_health "${1}" 2>/dev/null || true)" == "healthy" ]]
}
jobs_logged() {   # jobs_logged SERVICE — jobs of this drill's workflow that this worker started
  local n
  n="$(compose logs --no-color --since "${RECOVER_TIMEOUT}s" "${1}" 2>/dev/null \
        | grep -F "\"workflowId\":\"${wf_id}\"" | grep -c 'started execution' || true)"
  printf '%s\n' "${n:-0}"
}

# ======================================================================================================================
# redis — stop Valkey for OUTAGE seconds (TC-009)
# ======================================================================================================================
scenario_redis() {
  local path="kit-chaos-${run_id}"
  publish wf-webhook-async.json "${path}"
  wait_for 180 "the pool to register /webhook/${path}" warm "${path}" \
    || die "the drill webhook never answered 200 — is the stack healthy?"

  info "firing ${N} jobs to build a backlog, then stopping valkey for ${OUTAGE}s"
  fire "${path}" 1 "${N}"
  local depth_at_stop
  depth_at_stop="$(queue_depth)"
  compose stop valkey >/dev/null 2>&1 || die "could not stop valkey"
  ok "valkey stopped with ${depth_at_stop} job(s) waiting in the queue"

  # During the outage the webhook processes cannot enqueue, so they must FAIL rather than silently drop the call.
  local outage_codes='' i code
  for i in 1 2 3; do
    code="$(post_one "${path}" "outage-${i}")"
    outage_codes="${outage_codes} ${code}"
    sleep 2
  done
  info "webhook replies during the outage:${outage_codes}"
  local good_failures=0
  for code in ${outage_codes}; do
    [[ "${code}" =~ ^2 ]] || good_failures=$((good_failures + 1))
  done

  sleep "${OUTAGE}"
  compose start valkey >/dev/null 2>&1 || die "could not start valkey again"
  ok "valkey started again after ${OUTAGE}s"
  compose up -d --wait --wait-timeout 300 >/dev/null 2>&1 || true

  drained() { (( $(count_status success) >= depth_at_stop )); }
  local survived=0
  wait_for "${RECOVER_TIMEOUT}" "the queued jobs to finish after the outage" drained && survived=1

  printf '\n' >&2
  log "redis drill (TC-009)"
  check "webhooks failed loudly while valkey was down (${good_failures}/3 non-2xx) — no call was silently dropped" \
    test "${good_failures}" -eq 3
  check "the ${depth_at_stop} job(s) queued before the outage completed afterwards ($(count_status success) success) — AOF kept the queue" \
    test "${survived}" = 1
  check "every service is healthy again" wait_for 300 "stack healthy" stack_healthy
}
stack_healthy() {
  local bad
  bad="$(compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$2 != "running" { print $1 }' || true)"
  [[ -z "${bad}" ]]
}

# ======================================================================================================================
# main — restart n8n-main under load (TC-010)
# ======================================================================================================================
scenario_main() {
  local path="kit-chaos-${run_id}"
  publish wf-webhook-async.json "${path}"
  wait_for 180 "the pool to register /webhook/${path}" warm "${path}" \
    || die "the drill webhook never answered 200 — is the stack healthy?"

  # A schedule trigger fires on main only: it is the thing that must come back by itself after the restart.
  api POST /api/v1/workflows "$(workflow_from_fixture wf-schedule-tick.json "kit-smoke-chaos-${run_id}-tick" tick-unused)"
  sched_id="$(req_body | jq -r '.id // empty')"
  [[ -n "${sched_id}" ]] || die "could not create the schedule workflow (HTTP ${REQ_STATUS})"
  api POST "/api/v1/workflows/${sched_id}/activate"
  status_is 200 || die "could not publish the schedule workflow (HTTP ${REQ_STATUS})"

  ticks() {
    api GET "/api/v1/executions?workflowId=${sched_id}&status=success&limit=250"
    req_body | jq -r '.data | length' 2>/dev/null || echo 0
  }
  first_tick() { (( $(ticks) >= 1 )); }
  wait_for 120 "the schedule trigger to fire once before the restart" first_tick \
    || die "the schedule trigger never fired — it cannot prove a resume"
  local ticks_before
  ticks_before="$(ticks)"
  ok "schedule trigger is firing (${ticks_before} tick(s) so far)"

  # A steady trickle through the webhook pool spans the restart: main is deliberately not in this path
  # (N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true), so every one of these must answer 200 the whole time.
  info "sending a webhook every second while n8n-main restarts"
  local i
  ( for i in $(seq 1 40); do post_one "${path}" "trickle-${i}" >>"${codes_file}"; sleep 1; done ) &
  local trickle_pid=$!
  sleep 5
  compose restart n8n-main >/dev/null 2>&1 || die "could not restart n8n-main"
  ok "n8n-main restarted"
  wait "${trickle_pid}" 2>/dev/null || true

  local sent ok_count
  sent="$(grep -c . "${codes_file}" || true)"
  ok_count="$(grep -c '^200$' "${codes_file}" || true)"

  more_ticks() { (( $(ticks) > ticks_before )); }
  local resumed=0
  wait_for 180 "a schedule tick after the restart" more_ticks && resumed=1

  printf '\n' >&2
  log "main drill (TC-010)"
  check "every webhook answered 200 across the restart (${ok_count}/${sent}) — the pool is independent of main" \
    test "${ok_count}" -eq "${sent}"
  check "the schedule trigger resumed on its own (${ticks_before} -> $(ticks) ticks)" test "${resumed}" = 1
  check "n8n-main is healthy again" wait_for 300 "n8n-main healthy" test_service_healthy n8n-main
}

# ======================================================================================================================
info "chaos drill '${SCENARIO}' on project $(_kit_project_name) — run id ${run_id}"
case "${SCENARIO}" in
  worker) scenario_worker ;;
  redis)  scenario_redis ;;
  main)   scenario_main ;;
  *)      die "unknown scenario '${SCENARIO}'" ;;   # unreachable: validated above, kept so the dispatch is total
esac
finish
