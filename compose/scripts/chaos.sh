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
# Set by a scenario when an assertion fails: the drill's workflow, executions and files are then left in place so
# the failure can be inspected instead of being deleted by the cleanup trap.
KEEP_DRILL="${KEEP_DRILL:-}"

case "${SCENARIO}" in
  worker|redis|main) ;;
  *) die "usage: make chaos SCENARIO=worker|redis|main [N=${N}] [OUTAGE=${OUTAGE}] [YES=1]" ;;
esac
if [[ ! "${N}" =~ ^[0-9]+$ ]] || (( N < 10 || N > 5000 )); then
  die "N must be 10..5000 (got '${N}')"
fi
# P reaches `xargs -P` directly: in GNU xargs P=0 means "as many processes as possible", which would point the
# whole of N at the edge at once, and a typo like "4o" makes xargs exit before anything is measured.
if [[ ! "${P}" =~ ^[0-9]+$ ]] || (( P < 1 || P > 200 )); then
  die "P must be 1..200 (got '${P}')"
fi
if [[ ! "${OUTAGE}" =~ ^[0-9]+$ ]] || (( OUTAGE < 1 || OUTAGE > 3600 )); then
  die "OUTAGE must be 1..3600 seconds (got '${OUTAGE}')"
fi

# --- preconditions ----------------------------------------------------------------------------------------------
# `compose ps` without --all hides stopped and missing containers, and its {{.State}} is the container state, never
# the health status — so the obvious "ps | awk $2 != running" check can only ever see a healthy stack. Health comes
# from service_health (missing/none/starting/healthy/unhealthy) and the run state from docker inspect.
unhealthy_services() {   # one service name per line; empty output means the whole project is running and healthy
  local svc cid status health
  while read -r svc; do
    [[ -n "${svc}" ]] || continue
    cid="$(compose ps -aq "${svc}" 2>/dev/null | head -1)"
    status=''
    [[ -n "${cid}" ]] && status="$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || true)"
    health="$(service_health "${svc}" 2>/dev/null || true)"
    if [[ "${status}" != "running" ]] || { [[ "${health}" != "healthy" && "${health}" != "none" ]]; }; then
      printf '%s\n' "${svc}"
    fi
  done < <(compose ps -a --format '{{.Service}}' 2>/dev/null | sort -u)
}
stack_healthy() {
  [[ -z "$(unhealthy_services)" ]]
}

# An unfinished upgrade or a pin that differs from what runs must not be discovered halfway through a drill: the
# drill's own `compose up -d` would otherwise apply it while the stack is deliberately broken.
version_guard "make chaos"

[[ -n "$(compose ps -aq n8n-main 2>/dev/null)" ]] || die "this project has no containers — a chaos drill needs a running stack: make up && make status"
not_running="$(unhealthy_services)"
[[ -z "${not_running}" ]] || die "not every service is running and healthy (${not_running//$'\n'/ }) — a chaos drill needs a healthy stack: make up && make status"

workers=()
while read -r svc; do
  [[ -n "${svc}" ]] && workers+=("${svc}")
done < <(compose config --services | grep -E '^n8n-worker-[0-9]+$' | sort)
(( ${#workers[@]} >= 2 )) || die "the ${SCENARIO} drill needs at least 2 workers (make scale-workers N=2)"

# Ask BEFORE ensure_owner: on an instance with no owner that call claims one, so asking afterwards would make
# "nothing was touched" untrue. confirm() handles YES=1/CI=1 and the no-tty case itself — wrapping it in a test
# for a non-empty YES meant YES=0, YES=no and YES=false all silently skipped the question.
confirm "Run the '${SCENARIO}' chaos drill against ${BASE_URL}? Containers will be killed or stopped, then recovered." \
  || die "cancelled — nothing was touched" 0

ensure_owner  || die "could not get an owner account (see above)"
ensure_api_key || die "could not get an API key (see above)"

# --- shared state and recovery ------------------------------------------------------------------------------------
run_id="$(rand_hex 4)"
# Log windows are anchored to when the drill STARTED: a fixed "--since 420s" looks at the wrong window once the
# recovery waits have burned more than that — which is exactly when the evidence matters.
drill_started_at="$(date -u +%Y-%m-%dT%H:%M:%S)"
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
deactivate_workflow() {   # deactivate_workflow ID LABEL — and SAY SO when it did not work
  local id="${1}" label="${2}"
  [[ -n "${id}" ]] || return 0
  api POST "/api/v1/workflows/${id}/deactivate"
  if status_is 200; then
    return 0
  fi
  warn "could NOT deactivate the ${label} workflow ${id} (HTTP ${REQ_STATUS}) — it is still published and reachable; deactivate or delete it in the UI"
  return 1
}
cleanup() {
  local rc=$?
  # The recovery must not be interruptible: a second Ctrl-C used to end bash mid-trap and leave valkey stopped
  # and the drill's workflow published.
  trap '' INT TERM HUP
  printf '\n' >&2
  info "restoring the stack (this is not interruptible — it is what puts the stack back)"
  # `--no-recreate` is deliberate: this starts what the drill stopped or killed, and must never recreate a service
  # onto a different image. Volumes, the database and .env are never touched by this script.
  if ! compose up -d --wait --wait-timeout 600 --no-recreate; then
    warn "the stack did NOT come back healthy — run 'make up' and 'make doctor'. Still not running/healthy: $(unhealthy_services | tr '\n' ' ')"
    (( rc == 0 )) && rc=1   # never report success on a stack we left broken; never mask an existing failure
  fi
  if [[ -n "${KEEP_DRILL}" ]]; then
    # Keep the evidence, but never leave a drill workflow PUBLISHED: it stays reachable on the public webhook URL
    # and a schedule workflow would keep firing. `api` cannot fail (req swallows every error), so the result is
    # checked explicitly rather than claimed.
    deactivate_workflow "${wf_id}" drill || rc=1
    deactivate_workflow "${sched_id}" schedule || rc=1
    info "KEEP_DRILL: kept ${wf_id:-none}${sched_id:+ and ${sched_id}} and the files under /home/node/.n8n-files/chaos-${run_id}/ for inspection"
    info "delete them when done: make smoke removes any kit-smoke-* workflow, or do it in the UI"
    rm -f "${codes_file}" 2>/dev/null || true
    exit "${rc}"
  fi
  delete_workflow "${wf_id}"
  delete_workflow "${sched_id}"
  compose exec -T n8n-main sh -c "rm -rf /home/node/.n8n-files/chaos-${run_id}" >/dev/null 2>&1 || true
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
# The n8n_files volume is shared by every n8n service, so the count is read from n8n-main — never from a worker the
# drill may have just killed. Reading it from the victim is how the first version of this drill reported 0 of 120.
side_effects() {   # how many distinct files this run produced (one per input id, overwritten by a retry)
  local n
  # [0-9]* deliberately: it counts the numbered inputs and never the warm-up call's own file.
  n="$(compose exec -T n8n-main sh -c "ls -1 /home/node/.n8n-files/chaos-${run_id}/[0-9]*.txt 2>/dev/null | wc -l" 2>/dev/null || true)"
  n="${n//[^0-9]/}"
  printf '%s\n' "${n:-0}"
}
# RestartCount is not a reliable signal here — it stayed 0 across a kill plus a policy restart on Docker 29 — so
# "did it come back" is answered by the container's start time having moved instead.
started_at() {   # started_at SERVICE — when this service's container last started, or "none" if it is not there
  local cid t
  cid="$(compose ps -q "${1}" 2>/dev/null | head -1)"
  [[ -n "${cid}" ]] || { printf 'none\n'; return 0; }
  t="$(docker inspect -f '{{.State.StartedAt}}' "${cid}" 2>/dev/null || true)"
  printf '%s\n' "${t:-none}"
}
came_back() {   # came_back SERVICE PREVIOUS_START — the container exists AND started later than it did before
  local now
  now="$(started_at "${1}")"
  [[ "${now}" != "none" && "${now}" != "${2}" ]]
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
  # The drill writes into its own directory so it never mixes with the operator's own Read/Write Files output.
  # The Write File node does not create parent directories, so it has to exist before the first execution.
  compose exec -T n8n-main sh -c "mkdir -p /home/node/.n8n-files/chaos-${run_id}" >/dev/null 2>&1     || die "could not create the drill's directory under /home/node/.n8n-files (run make up once, it fixes the volume ownership)"

  # The warm-up answers before its own execution has run, so let it settle and baseline every status: every number
  # reported below is then a delta covering the N inputs alone.
  settled_n() { printf '%s\n' "$(( $(count_status success) + $(count_status crashed) + $(count_status error) ))"; }
  warmup_settled() { (( $(settled_n) >= 1 )); }
  wait_for 120 "the warm-up execution to finish" warmup_settled \
    || warn "the warm-up has not settled — the counts below may be off by one"
  local base_success base_crashed base_error
  base_success="$(count_status success)"
  base_crashed="$(count_status crashed)"
  base_error="$(count_status error)"

  local before_started
  before_started="$(started_at "${victim}")"
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
  ok "SIGKILLed ${victim} — no graceful shutdown, so whatever it was executing is orphaned"

  # What actually happens (verified against n8n 2.42.4 and bull 4.16.4, see docs/operations/chaos-drills.md):
  # the SURVIVING worker runs Bull's stalled sweep, finds the victim's jobs still in `active` with expired locks
  # (QUEUE_WORKER_LOCK_DURATION 60 s, swept every QUEUE_WORKER_STALLED_INTERVAL 30 s), and because n8n hard-codes
  # maxStalledCount: 0 it moves them straight to `failed` — never back to `wait`. They surface as `crashed`
  # executions and are NOT retried. So the drill waits for every input to reach a TERMINAL state, not for every
  # input to succeed; ~90 s longer than a plain drain is normal.
  settled() { (( $(settled_n) - base_success - base_crashed - base_error >= N )); }
  local settled_ok=0
  wait_for "${RECOVER_TIMEOUT}" "all ${N} inputs to reach a terminal state" settled && settled_ok=1

  local effects success_n crashed_n error_n st
  effects="$(side_effects)"
  success_n=$(( $(count_status success) - base_success ))
  crashed_n=$(( $(count_status crashed) - base_crashed ))
  error_n=$(( $(count_status error) - base_error ))
  printf '\n' >&2
  log "what n8n recorded for the ${N} inputs"
  for st in success crashed error running waiting; do
    printf '         %-10s %s\n' "${st}" "$(count_status "${st}")" >&2
  done

  # Docker does NOT restart a container terminated with `docker kill`: kill and stop both cancel the restart
  # manager and set HasBeenManuallyStopped, so `restart: unless-stopped` deliberately stays out of it. Bringing
  # the worker back is the operator's job — here, this `compose up -d`.
  if [[ "$(started_at "${victim}")" == "none" ]]; then
    info "${victim} did not come back on its own — expected: Docker treats an explicit kill as an operator stop"
  fi
  compose up -d --wait --wait-timeout "${RECOVER_TIMEOUT}" --no-recreate >/dev/null 2>&1 || true

  printf '\n' >&2
  log "worker drill (TC-008)"
  check "every input reached a terminal state (${success_n} success + ${crashed_n} crashed + ${error_n} error = ${N}) — nothing vanished" \
    test "${settled_ok}" = 1
  check "queued work survived the kill — ${success_n} of ${N} completed on the remaining worker(s)" \
    test "${success_n}" -gt 0
  # A crashed execution may ALREADY have done its work: the kill can land after the write node finished but
  # before the execution was marked done. So the invariant is not equality — it is "every success wrote its
  # file" and "never more side effects than inputs", the latter being what the idempotent key buys us.
  check "every successful input left its side effect (${effects} files >= ${success_n} successes)" \
    test "${effects}" -ge "${success_n}"
  check "never more side effects than inputs (${effects} files for ${N} inputs) — the idempotent key prevents duplicates" \
    test "${effects}" -le "${N}"
  if (( effects > success_n )); then
    info "$(( effects - success_n )) crashed execution(s) had already written their side effect before the kill landed — a crashed execution is NOT proof that nothing happened, which is exactly why re-driving one needs an idempotent workflow"
  fi
  check "${survivor} took the load over ($(jobs_logged "${survivor}") jobs)" \
    test "$(jobs_logged "${survivor}")" -gt 0
  check "${victim} is back and healthy after make up" came_back "${victim}" "${before_started}"
  check "${victim} reports healthy" wait_for "${RECOVER_TIMEOUT}" "${victim} healthy" test_service_healthy "${victim}"
  if (( crashed_n == 0 )); then
    warn "no execution ended as crashed — the kill did not catch anything in flight, so this run did not exercise the failure path. Raise N or P."
  else
    info "${crashed_n} execution(s) ended as 'crashed': n8n 2.x removed Bull's stalled-job retry (maxStalledCount is hard-coded to 0), so work in flight on a killed worker is LOST, not retried. Drain with docker stop / N8N_GRACEFUL_SHUTDOWN_TIMEOUT instead, and give critical workflows an error workflow — docs/operations/chaos-drills.md"
  fi
  if (( SMOKE_FAILED > 0 )); then
    KEEP_DRILL=1
    warn "assertions failed — keeping workflow ${wf_id} and the files under /home/node/.n8n-files/chaos-${run_id}/ so you can inspect them"
  fi
}
test_service_healthy() {
  [[ "$(service_health "${1}" 2>/dev/null || true)" == "healthy" ]]
}
jobs_logged() {   # jobs_logged SERVICE — jobs of this drill's workflow that this worker started
  local n
  n="$(compose logs --no-color --since "${drill_started_at}" "${1}" 2>/dev/null \
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
  # Both numbers are taken as close to the stop as possible: the depth is what must survive the outage, and the
  # success count is the baseline it has to be measured against. Comparing the TOTAL success count against the
  # depth would pass vacuously — by then the workers have usually finished more jobs than were left waiting.
  local depth_at_stop success_at_stop
  depth_at_stop="$(queue_depth)"
  success_at_stop="$(count_status success)"
  compose stop valkey >/dev/null 2>&1 || die "could not stop valkey"
  ok "valkey stopped with ${depth_at_stop} job(s) waiting and ${success_at_stop} already done"
  if (( depth_at_stop == 0 )); then
    warn "nothing was waiting when valkey stopped — the workers drained the burst first. Raise N (make chaos SCENARIO=redis N=400) so the outage has something to protect."
  fi

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
  # A worker's readiness probe requires a LIVE Redis connection, so "every worker healthy again" is the signal that
  # they have reconnected. Measure the drain only after that, or a slow reconnect looks like a lost queue.
  local reconnected=0
  wait_for "${RECOVER_TIMEOUT}" "every service to be healthy again after the outage" stack_healthy && reconnected=1

  # Only jobs that complete AFTER the stop count — the baseline is what makes this assertion mean anything.
  drained() { (( $(count_status success) - success_at_stop >= depth_at_stop )); }
  local survived=0
  if (( depth_at_stop > 0 )); then
    wait_for "${RECOVER_TIMEOUT}" "the ${depth_at_stop} queued job(s) to finish after the outage" drained && survived=1
  else
    survived=1   # nothing was queued, so there is nothing for the outage to have lost
  fi
  local recovered_n=$(( $(count_status success) - success_at_stop ))

  printf '\n' >&2
  log "redis drill (TC-009)"
  check "webhooks failed loudly while valkey was down (${good_failures}/3 non-2xx) — no call was silently dropped" \
    test "${good_failures}" -eq 3
  check "every service reconnected and is healthy again" test "${reconnected}" = 1
  check "the ${depth_at_stop} job(s) queued before the outage completed afterwards (${recovered_n} finished since) — AOF kept the queue" \
    test "${survived}" = 1
  if (( SMOKE_FAILED > 0 )); then KEEP_DRILL=1; fi
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
  # post_one prints the code with NO trailing newline (it is written for command substitution), so the trickle has
  # to add one. Appending it raw concatenates all 40 codes into a single "200200200..." line, which then counts as
  # one sent request and zero 200s — the first run of this drill failed exactly that way.
  local i
  ( for i in $(seq 1 40); do printf '%s\n' "$(post_one "${path}" "trickle-${i}")" >>"${codes_file}"; sleep 1; done ) &
  local trickle_pid=$!
  sleep 5
  compose restart n8n-main >/dev/null 2>&1 || die "could not restart n8n-main"
  ok "n8n-main restarted"
  wait "${trickle_pid}" 2>/dev/null || true

  local sent ok_count
  sent="$(grep -c . "${codes_file}" || true)"
  ok_count="$(grep -c '^200$' "${codes_file}" || true)"

  # n8n-main's healthcheck allows a long start_period, and on a loaded host it genuinely uses it.
  local healthy_again=0
  wait_for "${RECOVER_TIMEOUT}" "n8n-main healthy again" test_service_healthy n8n-main && healthy_again=1
  # Re-baseline AFTER main is back: a tick counted from before the restart would let this assertion pass on a
  # tick that fired while main was still the old process, which proves nothing about resuming.
  local ticks_after_restart
  ticks_after_restart="$(ticks)"
  more_ticks() { (( $(ticks) > ticks_after_restart )); }
  local resumed=0
  wait_for 180 "a schedule tick fired by the restarted main" more_ticks && resumed=1

  printf '\n' >&2
  log "main drill (TC-010)"
  check "every webhook answered 200 across the restart (${ok_count}/${sent}) — the pool is independent of main" \
    test "${ok_count}" -eq "${sent}"
  check "n8n-main is healthy again" test "${healthy_again}" = 1
  check "the schedule trigger resumed on its own (${ticks_before} before, ${ticks_after_restart} at recovery, $(ticks) now)" \
    test "${resumed}" = 1
  if (( SMOKE_FAILED > 0 )); then KEEP_DRILL=1; fi
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
