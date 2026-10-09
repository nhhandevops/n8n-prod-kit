#!/usr/bin/env bash
# compose/scripts/upgrade.sh — `make upgrade [N8N_VERSION=x] [YES=1] [RESUME=1]` (test case TC-014).
#
# Moves the running n8n (+ its runners) to a new version the way n8n's data needs it:
#   target   N8N_VERSION=x, or — without it — the N8N_VERSION now in versions.env (a `git pull` of the kit moved the
#            pin; `make up` refuses to apply that by itself). Only a plain release x.y.z newer than what RUNS; a major
#            jump needs ALLOW_MAJOR=1, a GitHub pre-release ALLOW_PRERELEASE=1.
#   0. checks with nothing changed: preflight, the running version (container label, cross-checked with the
#      database), the target digests resolved into .upgrade/target.env (a wrong version stops here), confirm
#   1. pull the new images (only what is missing) and check their version labels; build the backup image — n8n serves
#   2. let a scheduled backup finish, silence the alerts, stop n8n: webhooks + main, drain the workers, workers
#   3. pre-upgrade backup (kind pre-upgrade, label <from>-to-<to>) to every BACKUP_REMOTES target — taken after the
#      stop so it holds every last write. Fails → the old version is started again, nothing changed.
#   4. switch versions.env (N8N_VERSION, N8N_DIGEST, RUNNERS_DIGEST only); start n8n-main ALONE: it migrates
#   5. start everything else, verify (versions + smoke subset on the core services), lift the silence
# A failure from step 4 on leaves PHASE=failed and the stack stopped or unverified, and prints the two ways out:
# `make upgrade RESUME=1` (try again) and `make rollback` (back to the old version — with the pre-upgrade backup when a
# migration ran, without touching the data when none did). An attempt that stops before step 4 changes nothing and
# gives the previous upgrade's rollback point back. A closed SSH session does not stop the run (SIGHUP is ignored; the
# output also goes to compose/.upgrade/<time>-upgrade.log). State: compose/.upgrade/state.env (see upgrade-lib.sh).
#
# Knobs (seconds): UPGRADE_TIMEOUT (migrations, 1800) · UPGRADE_DRAIN_TIMEOUT (running executions, 300) ·
#        UPGRADE_START_TIMEOUT (rest of the stack, 600) · SMOKE_FAIL=1 (force a verification failure, for drills)
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
# shellcheck source=upgrade-lib.sh
source "${KIT_DIR}/scripts/upgrade-lib.sh"
cd "${KIT_DIR}"

# A version given on the make command line is in our environment, and Compose would use it for EVERY call (tag and
# digest out of step). Keep it as the target and remove it, and make's copy of it, from everything this script runs.
want="${N8N_VERSION:-}"
unset N8N_VERSION N8N_DIGEST RUNNERS_DIGEST MAKEFLAGS MFLAGS MAKELEVEL
export KIT_UPGRADE_INTERNAL=1   # the scripts called below must not run the version guard against this upgrade
validate_knobs

[[ -f .env ]] || die ".env not found — run make init first"
for key in N8N_VERSION N8N_DIGEST RUNNERS_DIGEST; do
  if grep -qE "^(export[[:space:]]+)?${key}=" .env; then
    die ".env sets ${key} — it overrides versions.env for Compose, so an upgrade could never take effect. Remove it from .env."
  fi
done
mkdir -p "${UPGRADE_DIR}"
exec 7>"${UPGRADE_DIR}/lock"
flock -n 7 || die "another make upgrade / make rollback is running"
exec 8>"${KIT_DIR}/.restore.lock"
flock -n 8 || die "a make restore is running — wait for it to finish"
log_run upgrade

own=0   # 1 once this run owns state.env (it created it, or resumes it): only then does the exit handler act on it

# --- what to do when the script stops (error, Ctrl-C, kill) --------------------------------------------------------
put_back_old() {   # before the version switch nothing is changed: start the old version again
  local why="${1}" from_v
  from_v="$(st FROM_VERSION)"
  silence_end
  if compose_at FROM up -d --wait --wait-timeout "${UPGRADE_START_TIMEOUT:-600}" >/dev/null 2>&1; then
    set_phase aborted
    restore_previous_state
    warn "${why} — n8n ${from_v} runs again; nothing was changed"
    return 0
  fi
  fail "${why} — and n8n ${from_v} did not come back healthy by itself (make status). 'make upgrade RESUME=1' starts it again"
  return 1
}
rollback_hint() {
  local before after
  before="$(st MIGRATIONS_BEFORE)"
  after="$(db_migration_mark)" || after=''
  if [[ -z "${after}" ]]; then
    printf 'look at the database first (it could not be read just now) and then switch back\n'
  elif [[ "${after}" == "${before}" ]]; then
    printf 'switch only the images back — no migration ran, no data is lost\n'
  else
    printf 'restore the pre-upgrade backup %s — anything written after %s is lost\n' "$(st BACKUP_NAME)" "$(st BACKUP_AT)"
  fi
}
on_exit() {
  local rc=$? phase
  set +e
  trap '' INT TERM PIPE
  trap - EXIT
  if (( own == 1 && rc != 0 )); then
    phase="$(upgrade_phase)"
    case "${phase}" in
      preparing)
        set_phase aborted
        restore_previous_state
        ;;
      stopping | backing-up) put_back_old "the upgrade stopped before the version switch" ;;
      migrating | starting | verifying)
        st_set FAILED_STEP interrupted
        set_phase failed
        ;;
      *) ;;
    esac
    if [[ "$(upgrade_phase)" == "failed" ]]; then
      silence_end
      fail "the upgrade to n8n $(st TO_VERSION) did not finish (failed step: $(st FAILED_STEP))"
      log "  make upgrade RESUME=1   try the failed step again (e.g. after fixing what the log above shows)"
      log "  make rollback           back to n8n $(st FROM_VERSION): it would $(rollback_hint)"
      log "  make doctor             the state of the stack"
    fi
  fi
  exit "${rc}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- an unfinished upgrade? -----------------------------------------------------------------------------------------
resume=0
if upgrade_pending; then
  phase="$(upgrade_phase)"
  [[ "${phase}" =~ ^(rolling-back|restored)$ ]] && die "a make rollback is unfinished (PHASE=${phase}) — run make rollback again"
  if [[ "${RESUME:-}" != "1" ]]; then
    die "an upgrade to n8n $(st TO_VERSION) is unfinished (PHASE=${phase}, step $(st FAILED_STEP)) — 'make upgrade RESUME=1' continues it, 'make rollback' goes back to $(st FROM_VERSION)"
  fi
  if [[ -n "${want}" && "${want}" != "$(st TO_VERSION)" ]]; then
    die "RESUME=1 continues the upgrade to $(st TO_VERSION), not ${want} — make rollback first to change the target"
  fi
  resume=1
  own=1
  # this run decides anew whatever a rollback attempt that never got going may have left behind
  for key in ROLLBACK_MODE ROLLBACK_MIGRATED ROLLBACK_PREV_PHASE ROLLBACK_DB_OID ROLLBACK_SRC ROLLBACK_STARTED_AT RESTORE_DONE; do
    st_set "${key}" ""
  done
elif [[ "${RESUME:-}" == "1" ]]; then
  die "nothing to resume — no unfinished upgrade (make doctor)"
fi

if (( resume == 1 )); then
  case "${phase}" in
    preparing)
      set_phase aborted
      restore_previous_state
      own=0
      die "the earlier attempt stopped before anything changed — the upgrade did not happen; run make upgrade again"
      ;;
    stopping | backing-up)
      own=0
      put_back_old "the earlier attempt stopped before the version switch" || exit 1
      die "the upgrade did not happen — run make upgrade again"
      ;;
    *) info "resuming the upgrade $(st FROM_VERSION) -> $(st TO_VERSION) (PHASE=${phase})" ;;
  esac
else
  # --- 0. checks; nothing changes until the confirm -------------------------------------------------------------
  "${KIT_DIR}/scripts/preflight.sh"
  # --no-recreate: a git pull may have moved the postgres/valkey pins — those are applied inside the downtime, not now
  compose up -d --wait --no-recreate postgres valkey >/dev/null || die "postgres / valkey did not come up — make status"
  from_v="$(image_version_of n8n-main)"
  db_v="$(db_n8n_version)" || die "cannot read which n8n version last used the database (make logs SERVICE=postgres)"
  [[ -n "${from_v}" ]] || from_v="${db_v}"
  [[ -n "${from_v}" ]] || die "cannot tell which n8n version this installation runs (no n8n-main container, no version record in the database) — a new installation needs make up, not make upgrade"
  if [[ -n "${db_v}" && "${db_v}" != "${from_v}" && "${FORCE_VERSION:-}" != "1" ]]; then
    die "n8n-main runs ${from_v} but the database was last used by n8n ${db_v} — find out why first (make doctor); FORCE_VERSION=1 to continue"
  fi
  pinned="$(env_get N8N_VERSION versions.env)"
  if [[ -n "${want}" ]]; then
    to_v="${want}"
    source_of_target=argument
  else
    to_v="${pinned}"
    source_of_target=versions.env
  fi
  is_release_version "${to_v}" || die "N8N_VERSION must be a release number like 2.42.6 (got '${to_v}')"
  if [[ "${to_v}" == "${from_v}" ]]; then
    ok "n8n ${from_v} already runs — nothing to upgrade (make upgrade N8N_VERSION=x picks a version)"
    exit 0
  fi
  if ! version_ge "${to_v}" "${from_v}"; then
    if [[ "${source_of_target}" == "versions.env" ]]; then
      die "versions.env pins n8n ${to_v}, OLDER than the running ${from_v} — nothing to upgrade. If versions.env came from git (checkout, pull), pin forward: PIN_ONLY='N8N RUNNERS' make pin N8N_VERSION=${from_v}. Going back to ${to_v} is make rollback (it discards what was written since the upgrade)"
    fi
    die "n8n ${to_v} is OLDER than the running ${from_v}, and n8n cannot migrate a database down. Undo the last make upgrade with make rollback; otherwise restore a backup made by ${to_v} (make backups)"
  fi
  if [[ "${to_v%%.*}" != "${from_v%%.*}" && "${ALLOW_MAJOR:-}" != "1" ]]; then
    die "${from_v} -> ${to_v} is a MAJOR upgrade — read n8n's breaking changes for ${to_v%%.*}.0 first (docs.n8n.io → release notes), test it on a copy, then ALLOW_MAJOR=1"
  fi
  pre="$(curl -fsS --max-time 15 "https://api.github.com/repos/n8n-io/n8n/releases/tags/n8n%40${to_v}" 2>/dev/null | jq -r '.prerelease' 2>/dev/null || true)"
  case "${pre}" in
    false) ok "n8n ${to_v} is a stable release" ;;
    true)
      [[ "${ALLOW_PRERELEASE:-}" == "1" ]] || die "n8n ${to_v} is a PRE-RELEASE (beta) on GitHub — wait for a stable one, or ALLOW_PRERELEASE=1"
      warn "n8n ${to_v} is a pre-release (ALLOW_PRERELEASE=1)"
      ;;
    *) warn "could not ask GitHub whether n8n ${to_v} is a stable release (offline or rate-limited) — check https://github.com/n8n-io/n8n/releases" ;;
  esac

  # state from here on: an interruption is recorded. The previous upgrade's state (done) is parked, not thrown away:
  # until this attempt passes the version switch, aborting it gives that rollback point back.
  stash_previous_state
  : >"${UPGRADE_STATE}"
  own=1
  st_set STARTED_AT "$(now_utc)"
  set_phase preparing
  st_set FROM_VERSION "${from_v}"
  st_set TO_VERSION "${to_v}"
  st_set TARGET_SOURCE "${source_of_target}"
  from_d="$(image_digest_of n8n-main)"
  from_r="$(image_digest_of n8n-worker-1-runners)"
  if [[ -z "${from_d}" || -z "${from_r}" ]]; then
    # no containers to read them from (after make down): resolve the running version's digests
    cp versions.env "${UPGRADE_DIR}/from.env"
    PIN_FILE="${UPGRADE_DIR}/from.env" PIN_ONLY="N8N RUNNERS" N8N_VERSION="${from_v}" "${KIT_DIR}/scripts/pin.sh" >/dev/null ||
      die "could not resolve the digests of the running n8n ${from_v}"
    from_d="$(env_get N8N_DIGEST "${UPGRADE_DIR}/from.env")"
    from_r="$(env_get RUNNERS_DIGEST "${UPGRADE_DIR}/from.env")"
  fi
  st_set FROM_N8N_DIGEST "${from_d}"
  st_set FROM_RUNNERS_DIGEST "${from_r}"
  cp versions.env "${UPGRADE_DIR}/target.env"
  if [[ "${source_of_target}" == "argument" ]]; then
    info "resolving n8n ${to_v}"
    PIN_FILE="${UPGRADE_DIR}/target.env" PIN_ONLY="N8N RUNNERS" N8N_VERSION="${to_v}" "${KIT_DIR}/scripts/pin.sh" ||
      die "could not resolve n8n ${to_v} (no such version? registry down?) — nothing was changed"
  else
    # the pin came reviewed through git: use its digests as they are, only check them
    PIN_FILE="${UPGRADE_DIR}/target.env" PIN_ONLY="N8N RUNNERS" "${KIT_DIR}/scripts/pin.sh" --check >/dev/null ||
      die "versions.env has no valid digests for n8n ${to_v} — make pin"
  fi
  st_set TO_N8N_DIGEST "$(env_get N8N_DIGEST "${UPGRADE_DIR}/target.env")"
  st_set TO_RUNNERS_DIGEST "$(env_get RUNNERS_DIGEST "${UPGRADE_DIR}/target.env")"

  log ""
  log "  n8n ${from_v} -> ${to_v}   (target from ${source_of_target}; release notes: https://github.com/n8n-io/n8n/releases/tag/n8n%40${to_v})"
  log "  1. pull the new images (n8n keeps serving)"
  log "  2. stop n8n — webhooks and the editor go offline; the workers finish running executions (and keep taking"
  log "     queued ones) for up to ${UPGRADE_DRAIN_TIMEOUT:-300} s"
  log "  3. backup to: $(env_get BACKUP_REMOTES)"
  log "  4. start n8n-main ${to_v} alone (database migrations), then everything else, then verify"
  log "  If anything fails: make rollback returns to ${from_v}."
  log ""
  if ! confirm "Upgrade n8n ${from_v} -> ${to_v} now?"; then
    set_phase aborted
    restore_previous_state
    own=0
    die "aborted — nothing was changed" 0
  fi

  # --- 1. pull while n8n still serves ---------------------------------------------------------------------------
  "${KIT_DIR}/scripts/render.sh"
  pull_side TO || die "could not pull the images for n8n ${to_v} — nothing was changed"
  check_pulled_versions TO
  compose_at TO build --quiet backup || die "could not build the backup image — nothing was changed"
  "${KIT_DIR}/scripts/backup-perms.sh"

  # --- 2. stop ----------------------------------------------------------------------------------------------------
  set_phase stopping
  backup_sidecar_quiet || die "a scheduled backup is still running after 15 min — try again later; nothing was changed"
  silence_start "$(( (${UPGRADE_DRAIN_TIMEOUT:-300} + ${UPGRADE_TIMEOUT:-1800} + ${UPGRADE_START_TIMEOUT:-600}) / 60 + 15 ))" \
    "make upgrade ${from_v} -> ${to_v}"
  stop_n8n

  # --- 3. backup --------------------------------------------------------------------------------------------------
  set_phase backing-up
  mark="$(db_migration_mark)" || die "cannot read n8n's migrations table (make logs SERVICE=postgres)"
  st_set MIGRATIONS_BEFORE "${mark}"
  info "pre-upgrade backup"
  out="$(compose_at FROM run --rm -T backup /opt/backup/backup.sh --kind pre-upgrade --name "${from_v}-to-${to_v}")" ||
    die "the pre-upgrade backup failed (see above)"
  name="$(awk '$1 == "BACKUP" && $2 == "OK" { print $3 }' <<<"${out}")"
  [[ -n "${name}" ]] || die "the backup reported no bundle name"
  st_set BACKUP_NAME "${name}"
  st_set BACKUP_AT "$(now_utc)"
  # rollback fetches it from a local target when there is one (fast, no egress), else searches every target
  read -r -a remotes <<<"$(env_get BACKUP_REMOTES)"
  remote=''
  for r in "${remotes[@]}"; do
    if [[ "${r}" == /* ]]; then
      remote="${r}"
      break
    fi
  done
  st_set BACKUP_FROM "${remote}"
  st_set BACKUP_REMOTES "${remotes[*]}"
  ok "pre-upgrade backup ${name}"

  # --- 4. switch: the point of no return ------------------------------------------------------------------------
  set_phase migrating
  drop_previous_state
  rm -f "${UPGRADE_DIR}/target.env" "${UPGRADE_DIR}/from.env"
fi

# --- 4. migrate (also the resume point) ---------------------------------------------------------------------------
to_v="$(st TO_VERSION)"
if [[ "$(upgrade_phase)" =~ ^(migrating|failed)$ ]]; then
  set_phase migrating
  st_set FAILED_STEP ""
  switch_versions TO   # idempotent: completes a switch that an interruption cut short
  rc=0
  start_main_alone TO || rc=$?
  if (( rc != 0 )); then
    compose stop n8n-main >/dev/null 2>&1 || true   # its restart policy would re-run the failing migration forever
    after="$(db_migration_mark)" || after=''
    st_set MIGRATIONS_AFTER "${after}"
    st_set FAILED_STEP migrate
    set_phase failed
    exit 1
  fi
fi

# --- 5. everything else, verify ---------------------------------------------------------------------------------
if [[ "$(upgrade_phase)" == "migrating" ]]; then
  set_phase starting
fi
if [[ "$(upgrade_phase)" == "starting" ]]; then
  if ! start_rest TO; then
    st_set FAILED_STEP start
    set_phase failed
    exit 1
  fi
  set_phase verifying
fi
if ! verify_side TO; then
  st_set FAILED_STEP verify
  set_phase failed
  exit 1
fi
set_phase "done"
st_set FINISHED_AT "$(now_utc)"
silence_end
ok "n8n $(st FROM_VERSION) -> ${to_v} done"
log "  pre-upgrade backup: $(st BACKUP_NAME)"
log "  make rollback stays available until the next upgrade — it would $(rollback_hint)"
if [[ "$(st TARGET_SOURCE)" == "argument" ]] && git -C "${KIT_DIR}" rev-parse --git-dir >/dev/null 2>&1 &&
  ! git -C "${KIT_DIR}" diff --quiet -- versions.env; then
  log "  versions.env now pins ${to_v} — a local change to a tracked file: commit it, or run"
  log "  'git checkout -- compose/versions.env' before the next git pull (make up then tells whether the pulled pin is newer or older)"
fi
"${KIT_DIR}/scripts/status.sh" || true
