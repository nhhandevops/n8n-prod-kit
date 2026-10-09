#!/usr/bin/env bash
# compose/scripts/upgrade-lib.sh — the steps `make upgrade` (upgrade.sh) and `make rollback` (rollback.sh) share.
# Sourced after lib.sh; not a command of its own.
#
# The state of an upgrade lives in compose/.upgrade/state.env (gitignored) so that an interruption, a reboot or a later
# `make rollback` knows exactly where things stand:
#   PHASE            preparing → stopping → backing-up → migrating → starting → verifying → done
#                    failed (FAILED_STEP=migrate|start|verify|interrupted) · aborted (put back before the version switch)
#                    rollback: rolling-back → restored (versions.env is back on FROM) → rolled-back
#   FROM_VERSION / FROM_N8N_DIGEST / FROM_RUNNERS_DIGEST   what ran before (from the containers, not versions.env)
#   TO_VERSION / TO_N8N_DIGEST / TO_RUNNERS_DIGEST         the target
#   TARGET_SOURCE    argument (make upgrade N8N_VERSION=x) | versions.env (a git pull brought the new pin)
#   BACKUP_NAME / BACKUP_FROM / BACKUP_AT                  the pre-upgrade bundle, the remote rollback fetches it from
#   MIGRATIONS_BEFORE / MIGRATIONS_AFTER                   db_migration_mark before the switch / after a failure: equal
#                    means the database was never changed (n8n runs all pending migrations in ONE transaction)
#   ROLLBACK_MODE    images (no migration ran: switch back only) | restore (restore BACKUP_NAME, then switch back)
#   SILENCE_ID       the Grafana silence covering the planned downtime (monitoring profile)
# Finished states (done stays until the next upgrade, because make rollback needs it) are moved to .upgrade/history/.
# shellcheck disable=SC2310,SC2311,SC2312,SC2016,SC2154  # SC2016: $VALKEY_PASSWORD expands in the container; SC2154: KIT_DIR, UPGRADE_* come from lib.sh

st() { env_get "${1}" "${UPGRADE_STATE}"; }
st_set() { env_set "${1}" "${2}" "${UPGRADE_STATE}"; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
set_phase() {
  st_set PHASE "${1}"
  st_set UPDATED_AT "$(now_utc)"
}

# archive_state   move a finished state file to .upgrade/history/<started>-<phase>.env
archive_state() {
  [[ -f "${UPGRADE_STATE}" ]] || return 0
  local started
  started="$(st STARTED_AT)"
  mkdir -p "${UPGRADE_DIR}/history"
  mv "${UPGRADE_STATE}" "${UPGRADE_DIR}/history/${started//:/}-$(st PHASE).env"
}

# compose_at FROM|TO args…   compose with that side's n8n + runners pins, whatever versions.env says right now (the
# shell beats both env files in Compose's interpolation). Everything before the version switch runs as FROM, so the
# pre-upgrade backup is labelled with the version that wrote the data even when a git pull already moved versions.env.
compose_at() {
  local side="${1}"
  shift
  N8N_VERSION="$(st "${side}_VERSION")" N8N_DIGEST="$(st "${side}_N8N_DIGEST")" \
    RUNNERS_DIGEST="$(st "${side}_RUNNERS_DIGEST")" compose "${@}"
}

# switch_versions FROM|TO   point versions.env's three n8n keys at that side. Only these three: a rollback must not
# take back a Grafana/Postgres/Caddy pin that a git pull moved meanwhile (their data volumes cannot go back).
switch_versions() {
  local side="${1}"
  env_set N8N_VERSION "$(st "${side}_VERSION")" "${KIT_DIR}/versions.env"
  env_set N8N_DIGEST "$(st "${side}_N8N_DIGEST")" "${KIT_DIR}/versions.env"
  env_set RUNNERS_DIGEST "$(st "${side}_RUNNERS_DIGEST")" "${KIT_DIR}/versions.env"
}

n8n_services() { compose config --services 2>/dev/null | grep -E '^n8n-' || true; }

# pull_side FROM|TO [SERVICE…]   pull with retries (registries throttle anonymous pulls; docker.n8n.io answers 429
# from a shared proxy IP) — before any downtime.
pull_side() {
  local side="${1}" n
  shift
  for n in 1 2 3; do
    if compose_at "${side}" pull --quiet --ignore-buildable "${@}"; then
      return 0
    fi
    if (( n < 3 )); then
      warn "image pull failed — retrying in $((n * 30)) s"
      sleep $((n * 30))
    fi
  done
  warn "image pull failed 3 times. Docker Hub / docker.n8n.io rate limits are the usual cause: 'docker login', or set"
  warn "N8N_IMAGE=ghcr.io/n8n-io/n8n and RUNNERS_IMAGE=ghcr.io/n8n-io/runners in .env (same images, same digests)"
  return 1
}

# backup_sidecar_quiet   let a scheduled backup / restore test in the sidecar finish (it holds /state/backup.lock),
# then stop the sidecar so cron cannot start a pg_dump during the migration (its locks would block it) or label a
# bundle with the wrong version. The upgrade's own backup is a one-off `compose run`. Up to 15 min (n8n still runs).
backup_sidecar_quiet() {
  local cid waited=0
  cid="$(kit_container backup)"
  [[ -n "${cid}" ]] || return 0
  if [[ "$(docker inspect --format '{{.State.Running}}' "${cid}" 2>/dev/null)" == "true" ]]; then
    while ! compose exec -T backup flock -n /state/backup.lock true >/dev/null 2>&1; do
      if (( waited >= 900 )); then
        return 1
      fi
      (( waited % 60 == 0 )) && info "a scheduled backup or restore test is running in the backup sidecar — waiting for it"
      sleep 10
      waited=$((waited + 10))
    done
  fi
  compose stop backup >/dev/null
}

# stop_n8n   stop every n8n process so the backup holds every last write and nothing races the migration:
# webhook processors and main first (no new work arrives), then wait until the workers have no active job left
# (UPGRADE_DRAIN_TIMEOUT, default 300 s; queued jobs stay in Valkey for the next workers), then the workers and their
# runners. Also stops n8n containers Compose no longer models (a parked worker-2, workers of an older scale file).
# Ends with a check that nobody holds a session on n8n's database.
stop_n8n() {
  local -a all=() front=() back=()
  local svc active waited=0 drain="${UPGRADE_DRAIN_TIMEOUT:-300}" project cid sessions
  mapfile -t all < <(n8n_services)
  for svc in "${all[@]}"; do
    case "${svc}" in
      n8n-main | n8n-webhook-*) front+=("${svc}") ;;
      *) back+=("${svc}") ;;
    esac
  done
  info "stopping ${front[*]} (no new executions start)"
  compose stop "${front[@]}" >/dev/null
  while :; do
    active="$(compose exec -T valkey sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli --no-auth-warning LLEN n8n:jobs:active' 2>/dev/null | tr -dc '0-9')"
    [[ "${active:-0}" == "0" ]] && break
    if (( waited >= drain )); then
      warn "${active} execution(s) still running after ${drain} s — stopping the workers anyway (n8n cancels them; they show as crashed)"
      break
    fi
    (( waited % 30 == 0 )) && info "waiting for ${active} running execution(s) to finish on the workers"
    sleep 5
    waited=$((waited + 5))
  done
  info "stopping the workers and their runners"
  # a worker that is still draining can exit 1 (n8n 2.42) — that is not a failure here
  compose stop "${back[@]}" >/dev/null 2>&1 || true
  project="$(_kit_project_name)"
  while read -r cid svc; do
    [[ -n "${cid}" && "${svc}" == n8n-* ]] || continue
    warn "stopping ${svc} (not in the current compose model — an orphan from an older scale file?)"
    docker stop "${cid}" >/dev/null || true
  done < <(docker ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{.ID}} {{.Label "com.docker.compose.service"}}')
  waited=0
  while :; do
    sessions="$(kit_psql "select count(*) from pg_stat_activity where datname = 'n8n' and pid <> pg_backend_pid()" || echo '?')"
    [[ "${sessions}" == "0" ]] && break
    if (( waited >= 60 )); then
      die "${sessions} session(s) are still connected to n8n's database after every n8n process stopped — find them: make logs; docker ps"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  ok "n8n stopped, no session on its database"
}

# start_main_alone FROM|TO   start n8n-main by itself (it runs the migrations; webhooks and workers wait for it) and
# watch it: healthy → 0; exited / restarting / "error running database migrations" → 1; UPGRADE_TIMEOUT (default
# 1800 s) → 2. Migration progress is printed as it happens. Compose's own --wait cannot be used: it gives up the moment
# the healthcheck says unhealthy, which a long migration reaches after ~170 s while still working.
start_main_alone() {
  local side="${1}" cid restarts0 restarts status health since deadline printed=0 i
  local -a lines=()
  since="$(now_utc)"
  info "starting n8n-main $(st "${side}_VERSION") alone — database migrations run now (UPGRADE_TIMEOUT=${UPGRADE_TIMEOUT:-1800} s)"
  compose_at "${side}" up -d --no-deps n8n-main >/dev/null || return 1
  cid="$(kit_container n8n-main)"
  restarts0="$(docker inspect --format '{{.RestartCount}}' "${cid}")"
  deadline=$((SECONDS + ${UPGRADE_TIMEOUT:-1800}))
  while :; do
    mapfile -t lines < <(docker logs --since "${since}" "${cid}" 2>&1 |
      grep -E 'Migrations in progress|Starting migration|Finished migration|error running database migrations' || true)
    for (( i = printed; i < ${#lines[@]}; i++ )); do
      log "    ${lines[i]:0:200}"
    done
    printed=${#lines[@]}
    status="$(docker inspect --format '{{.State.Status}}' "${cid}")"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
    restarts="$(docker inspect --format '{{.RestartCount}}' "${cid}")"
    if [[ "${status}" == "running" && "${health}" == "healthy" ]]; then
      ok "n8n-main is healthy"
      return 0
    fi
    if [[ "${status}" =~ ^(exited|dead|restarting)$ ]] || (( restarts > restarts0 )) ||
      printf '%s\n' "${lines[@]}" | grep -q 'error running database migrations'; then
      fail "n8n-main failed to start (status ${status}, restarts ${restarts}) — its last log lines:"
      docker logs --tail 30 "${cid}" 2>&1 | sed 's/^/        /' >&2 || true
      return 1
    fi
    if (( SECONDS >= deadline )); then
      fail "n8n-main is still not healthy after ${UPGRADE_TIMEOUT:-1800} s (status ${status}, health ${health})"
      return 2
    fi
    sleep 5
  done
}

# start_rest FROM|TO   start everything else: the core services with --wait (webhooks and workers need main healthy,
# which it is), then the monitoring profile without failing on it (a slow Grafana must not turn a good upgrade into a
# rollback), then the same post-up steps as make up.
start_rest() {
  local side="${1}"
  local -a core=()
  mapfile -t core < <(n8n_services)
  core+=(caddy postgres valkey backup)
  info "starting the webhook processors, workers, runners and the rest of the stack"
  if ! compose_at "${side}" up -d --wait --wait-timeout "${UPGRADE_START_TIMEOUT:-600}" "${core[@]}"; then
    return 1
  fi
  compose_at "${side}" up -d >/dev/null 2>&1 || warn "some optional services did not start — make status"
  "${KIT_DIR}/scripts/kuma-setup.sh" || warn "kuma-setup failed — make kuma-setup"
  "${KIT_DIR}/scripts/grafana-reload.sh" || true
}

# verify_side FROM|TO   every n8n container runs that version (label) and digest, then the smoke subset that is safe
# on a production host: 01 health, 02 TLS/routing, 06 metrics, + 03/04/05 (a real webhook → queue → worker → runner
# round trip) when smoke credentials exist (compose/.smoke/owner.env or SMOKE_OWNER_*), + 09 with the monitoring
# profile. Never 07/08 (an extra bundle on every remote, a full restore test). SMOKE_FAIL=1 forces a failure after the
# real checks passed (drills of TC-015).
verify_side() {
  local side="${1}" want_v want_d want_r project cid svc v d bad=0 only="01,02,06" profiles
  want_v="$(st "${side}_VERSION")"
  want_d="$(st "${side}_N8N_DIGEST")"
  want_r="$(st "${side}_RUNNERS_DIGEST")"
  project="$(_kit_project_name)"
  while read -r cid svc; do
    [[ "${svc}" == n8n-* ]] || continue
    v="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${cid}")"
    d="$(docker inspect --format '{{.Config.Image}}' "${cid}")"
    d="${d##*@}"
    if [[ "${svc}" == *-runners ]]; then
      [[ "${d}" == "${want_r}" ]] || { fail "${svc} runs ${d:0:19}…, expected the runners digest ${want_r:0:19}…"; bad=$((bad + 1)); }
    elif [[ "${v}" != "${want_v}" || "${d}" != "${want_d}" ]]; then
      fail "${svc} runs n8n ${v:-?} (${d:0:19}…), expected ${want_v} (${want_d:0:19}…) — does .env or the shell override N8N_VERSION/N8N_DIGEST?"
      bad=$((bad + 1))
    fi
  done < <(docker ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{.ID}} {{.Label "com.docker.compose.service"}}')
  if (( bad > 0 )); then
    return 1
  fi
  ok "every n8n container runs ${want_v}"
  if [[ -s "${KIT_DIR}/.smoke/owner.env" || -n "${SMOKE_OWNER_EMAIL:-}" ]]; then
    only="01,02,03,04,05,06"
  else
    info "no smoke credentials (compose/.smoke/owner.env) — skipping the webhook → worker round trip (smoke 03-05)"
  fi
  profiles=",$(env_get COMPOSE_PROFILES | tr -d ' '),"
  [[ "${profiles}" == *",monitoring,"* ]] && only="${only},09"
  ONLY="${only}" SMOKE_FAIL="${SMOKE_FAIL:-}" "${KIT_DIR}/../tests/smoke/run.sh"
}

# silence_start MINUTES "comment"   mute every kit alert for the planned downtime (monitoring profile, Grafana healthy).
# The silence expires on its own, so a crashed script cannot mute alerts for long. Remembered as SILENCE_ID.
silence_start() {
  local minutes="${1}" comment="${2}" profiles start end body resp id
  profiles=",$(env_get COMPOSE_PROFILES | tr -d ' '),"
  [[ "${profiles}" == *",monitoring,"* && "$(service_health grafana)" == "healthy" ]] || return 0
  start="$(now_utc)"
  end="$(date -u -d "+${minutes} min" +%Y-%m-%dT%H:%M:%SZ)"
  body="$(jq -nc --arg s "${start}" --arg e "${end}" --arg c "${comment}" \
    '{matchers: [{name: "alertname", value: ".+", isRegex: true, isEqual: true}], startsAt: $s, endsAt: $e, createdBy: "n8n-prod-kit", comment: $c}')"
  resp="$(printf 'user = "%s:%s"\n' "$(env_get GRAFANA_ADMIN_USER)" "$(env_get GRAFANA_ADMIN_PASSWORD)" |
    compose exec -T grafana curl -sS -m 20 -K - -H 'Content-Type: application/json' -X POST --data "${body}" \
      http://127.0.0.1:3000/grafana/api/alertmanager/grafana/api/v2/silences 2>/dev/null || true)"
  id="$(jq -r '.silenceID // empty' <<<"${resp}" 2>/dev/null || true)"
  if [[ -n "${id}" ]]; then
    st_set SILENCE_ID "${id}"
    ok "alerts silenced until ${end} (Grafana silence ${id})"
  else
    warn "could not silence the alerts — expect Telegram messages about the planned downtime"
  fi
}

# silence_end   lift the silence (on success AND on failure: a failed upgrade must page).
silence_end() {
  local id
  id="$(st SILENCE_ID 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0
  printf 'user = "%s:%s"\n' "$(env_get GRAFANA_ADMIN_USER)" "$(env_get GRAFANA_ADMIN_PASSWORD)" |
    compose exec -T grafana curl -sS -m 20 -o /dev/null -K - -X DELETE \
      "http://127.0.0.1:3000/grafana/api/alertmanager/grafana/api/v2/silence/${id}" >/dev/null 2>&1 ||
    warn "could not lift Grafana silence ${id} — it expires on its own"
  st_set SILENCE_ID ""
}
