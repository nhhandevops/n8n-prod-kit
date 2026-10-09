#!/usr/bin/env bash
# compose/scripts/rollback.sh — `make rollback [YES=1] [ROLLBACK_CONFIRM=<backup>] [ROLLBACK_MODE=auto|images|restore]
# [FROM=<remote>] [ABORT=1]` (test case TC-015). Undoes the last `make upgrade` (compose/.upgrade/state.env), finished
# or failed.
#
#   images    no migration ran — the database's migration mark still equals the one taken before the upgrade (n8n runs
#             all pending migrations in ONE transaction, so even a failed migration leaves it unchanged): stop n8n,
#             switch versions.env back, start the old version. No data is lost.
#   restore   a migration ran: the pre-upgrade backup is fetched, decrypted and verified FIRST, while n8n still serves
#             (from the local target recorded by the upgrade, else from every BACKUP_REMOTES target; FROM= picks one).
#             Then stop n8n, restore it through scripts/restore.sh (safety backup of the current database, labelled
#             with the version that wrote it; staging restore; atomic swap), empty the job queue, switch versions.env
#             back, start the old version, verify, drop the replaced database. Everything written after the backup is
#             lost: the confirm shows how much, and whenever that is not nothing, ROLLBACK_CONFIRM=<backup name> is
#             required (YES=1 alone is not enough).
# ROLLBACK_MODE=auto (default) chooses from the migration mark; images refuses when a migration ran; restore forces it.
# The decision is recorded only together with PHASE=rolling-back (when n8n is about to stop); a run that stops before
# that changes nothing and leaves nothing behind. From then on a re-run continues where it stopped — the database's oid
# tells whether the restore already swapped it in — and `make rollback ABORT=1` gives up a rollback that has not
# restored anything yet (n8n <to> starts again). A closed SSH session does not stop the run (SIGHUP is ignored; the
# output also goes to compose/.upgrade/<time>-rollback.log). Only N8N_VERSION, N8N_DIGEST and RUNNERS_DIGEST go back —
# pins a git pull moved meanwhile (Grafana, Postgres…) stay.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
# shellcheck source=upgrade-lib.sh
source "${KIT_DIR}/scripts/upgrade-lib.sh"
cd "${KIT_DIR}"

# nothing from make's command line or an old shell export may change what restore.sh does here — except FROM, which
# the operator may give on purpose (where to fetch the pre-upgrade backup from)
from_override="${FROM:-}"
unset N8N_VERSION N8N_DIGEST RUNNERS_DIGEST MAKEFLAGS MFLAGS MAKELEVEL SKIP_SAFETY_BACKUP ADOPT_KEY AGE_KEY FROM BACKUP
export KIT_UPGRADE_INTERNAL=1
validate_knobs

[[ -f .env ]] || die ".env not found — run make init first"
mkdir -p "${UPGRADE_DIR}"
exec 7>"${UPGRADE_DIR}/lock"
flock -n 7 || die "another make upgrade / make rollback is running"
[[ -f "${UPGRADE_STATE}" ]] || die "nothing to roll back — no make upgrade on record (compose/.upgrade/state.env; finished ones are in .upgrade/history/)"
log_run rollback

phase="$(upgrade_phase)"
from_v="$(st FROM_VERSION)"
to_v="$(st TO_VERSION)"
backup="$(st BACKUP_NAME)"
own=0       # 1 once this run committed (PHASE=rolling-back) or continues a committed rollback
fetched=0   # 1 while a verified bundle waits in the backup_work volume (RESTORE_STAGE=fetch)

on_exit() {
  local rc=$?
  set +e
  trap '' INT TERM PIPE
  trap - EXIT
  if (( fetched == 1 )); then
    compose run --rm -T backup /opt/backup/restore.sh clean >/dev/null 2>&1 || warn "could not empty the backup_work volume — make restore-clean"
  fi
  if (( own == 1 && rc != 0 )) && [[ "$(upgrade_phase)" =~ ^(rolling-back|restored)$ ]]; then
    silence_end
    fail "the rollback to n8n ${from_v} did not finish (PHASE=$(upgrade_phase))"
    if [[ "$(upgrade_phase)" == "rolling-back" && "$(st RESTORE_DONE)" != "1" ]]; then
      log "  make rollback           try again — it continues (fix what the log above shows first)"
      log "  make rollback ABORT=1   give up: n8n ${to_v} starts again on its unchanged database"
    else
      log "  make rollback           continue — the database already is the pre-upgrade one"
    fi
  fi
  exit "${rc}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# fetch_bundle REMOTE|''   download, decrypt and verify the pre-upgrade bundle into the work volume — n8n keeps serving
fetch_bundle() {
  RESTORE_STAGE=fetch BACKUP="${backup}" FROM="${1}" RESTORE_RUN_VERSION="${from_v}" YES=1 \
    N8N_VERSION="${to_v}" N8N_DIGEST="$(st TO_N8N_DIGEST)" RUNNERS_DIGEST="$(st TO_RUNNERS_DIGEST)" \
    "${KIT_DIR}/scripts/restore.sh"
}

# --- ABORT=1: give up a rollback that has not restored anything ------------------------------------------------------
if [[ "${ABORT:-}" == "1" ]]; then
  [[ "${phase}" == "rolling-back" ]] ||
    die "ABORT=1 gives up an unfinished make rollback that has not restored the database yet — PHASE is ${phase}"
  [[ "$(st RESTORE_DONE)" != "1" ]] || die "the database already is the restored pre-upgrade one — run make rollback to finish"
  compose up -d --wait --no-recreate postgres valkey >/dev/null || die "postgres / valkey did not come up — make status"
  oid="$(db_oid)" || die "cannot read the database (make logs SERVICE=postgres)"
  if [[ -n "$(st ROLLBACK_DB_OID)" && "${oid}" != "$(st ROLLBACK_DB_OID)" ]]; then
    die "the database was already swapped for the pre-upgrade one — run make rollback to finish"
  fi
  own=1
  info "giving up the rollback: n8n ${to_v} starts again on its unchanged database"
  switch_versions TO
  compose_at TO up -d --wait --wait-timeout "${UPGRADE_START_TIMEOUT:-600}" >/dev/null ||
    die "n8n ${to_v} did not come back healthy — make status; then make rollback ABORT=1 again (or make rollback)"
  prev="$(st ROLLBACK_PREV_PHASE)"
  for key in ROLLBACK_MODE ROLLBACK_MIGRATED ROLLBACK_PREV_PHASE ROLLBACK_DB_OID ROLLBACK_SRC ROLLBACK_STARTED_AT RESTORE_DONE; do
    st_set "${key}" ""
  done
  set_phase "${prev:-failed}"
  silence_end
  own=0
  ok "rollback given up — n8n ${to_v} runs again (PHASE=${prev:-failed}); make rollback starts over"
  exit 0
fi

case "${phase}" in
  preparing | aborted)
    if [[ "${phase}" == "preparing" ]]; then
      set_phase aborted
      restore_previous_state
    fi
    die "the last upgrade attempt stopped before anything changed — nothing to roll back from it" 0
    ;;
  stopping | backing-up)
    info "the upgrade to ${to_v} stopped before the version switch — starting n8n ${from_v} again"
    silence_end
    compose_at FROM up -d --wait --wait-timeout "${UPGRADE_START_TIMEOUT:-600}" >/dev/null || die "the stack did not come back healthy — make status"
    set_phase aborted
    restore_previous_state
    ok "n8n ${from_v} runs again; nothing was changed"
    exit 0
    ;;
  migrating | starting | verifying | failed | "done" | rolling-back | restored) ;;
  rolled-back) die "already rolled back to n8n ${from_v}" 0 ;;
  *) die "unknown PHASE '${phase}' in ${UPGRADE_STATE}" ;;
esac

compose up -d --wait --no-recreate postgres valkey >/dev/null || die "postgres / valkey did not come up — make status"
before="$(st MIGRATIONS_BEFORE)"
mark="$(db_migration_mark)" || die "cannot read n8n's migrations table — is postgres healthy? (make status)"
src="${from_override}"

if [[ ! "${phase}" =~ ^(rolling-back|restored)$ ]]; then
  # --- a new decision: nothing is recorded or stopped until the confirm ------------------------------------------
  migrated=0
  [[ "${mark}" != "${before}" ]] && migrated=1
  case "${ROLLBACK_MODE:-auto}" in
    auto) if (( migrated )); then mode=restore; else mode=images; fi ;;
    images)
      (( migrated == 0 )) || die "n8n ${to_v} migrated the database (${before} -> ${mark}) — ${from_v} must not run on it; use the default ROLLBACK_MODE (restore)"
      mode=images
      ;;
    restore) mode=restore ;;
    *) die "ROLLBACK_MODE must be auto, images or restore" 2 ;;
  esac
  mapfile -t services < <(n8n_services)
  pull_side FROM "${services[@]}" || die "could not pull n8n ${from_v} — nothing was changed"

  log ""
  if [[ "${mode}" == "images" ]]; then
    log "  n8n ${to_v} -> ${from_v}: no migration ran, so only the images go back — no data is lost"
  else
    if [[ -z "${src}" ]]; then
      src="$(st BACKUP_FROM)"
    fi
    fetched=1
    if ! fetch_bundle "${src}"; then
      [[ -z "${from_override}" && -n "${src}" ]] || die "could not fetch ${backup}${src:+ from ${src}} — nothing was changed (FROM=<remote> picks another target)"
      warn "${backup} could not be fetched from ${src} — searching every BACKUP_REMOTES target"
      src=''
      fetch_bundle '' || die "could not fetch ${backup} from any target — nothing was changed (make backups lists them)"
    fi
    since="$(st BACKUP_AT)"
    IFS='|' read -r lost_exec lost_wf lost_cred now_wf now_cred <<<"$(kit_psql "select
      (select count(*) from execution_entity where \"createdAt\" > '${since}') || '|' ||
      (select count(*) from workflow_entity where \"updatedAt\" > '${since}') || '|' ||
      (select count(*) from credentials_entity where \"updatedAt\" > '${since}') || '|' ||
      (select count(*) from workflow_entity) || '|' || (select count(*) from credentials_entity)" || echo '?|?|?|?|?')"
    IFS='|' read -r bundle_wf bundle_cred <<<"$(compose run --rm -T backup jq -r \
      '"\(.counts.workflows)|\(.counts.credentials)"' /work/current/manifest.json 2>/dev/null || echo '?|?')"
    log "  n8n ${to_v} -> ${from_v}: restore the pre-upgrade backup ${backup}"
    log "  (taken ${since}, fetched${src:+ from ${src}}); a safety backup of the current database comes first."
    log "  LOST with the rollback: ${lost_exec} execution(s), ${lost_wf} workflow change(s), ${lost_cred} credential change(s)"
    log "  made since; workflows ${now_wf} now / ${bundle_wf} in the backup, credentials ${now_cred} now / ${bundle_cred} in the backup"
    changes="unknown"
    if [[ "${lost_exec}${lost_wf}${lost_cred}${now_wf}${now_cred}${bundle_wf}${bundle_cred}" =~ ^[0-9]+$ ]]; then
      changes=$(( lost_exec + lost_wf + lost_cred ))
      [[ "${now_wf}" == "${bundle_wf}" && "${now_cred}" == "${bundle_cred}" ]] || changes=$(( changes + 1 ))
    fi
    if [[ "${changes}" != "0" && "${ROLLBACK_CONFIRM:-}" != "${backup}" ]]; then
      die "this rollback discards data written under n8n ${to_v} (or cannot tell) — to go ahead, run: make rollback ROLLBACK_CONFIRM=${backup}"
    fi
  fi
  log ""
  confirm "Roll back n8n ${to_v} -> ${from_v}?" || die "aborted — nothing was changed" 0
  backup_sidecar_quiet || die "a scheduled backup is still running after 15 min — try again later; nothing was changed"
  silence_start 60 "make rollback ${to_v} -> ${from_v}"
  oid="$(db_oid)" || die "cannot read the database (make logs SERVICE=postgres) — nothing was changed"
  # the commitment: from here on a re-run continues this rollback
  set_phase rolling-back
  own=1
  st_set ROLLBACK_PREV_PHASE "${phase}"
  st_set ROLLBACK_MODE "${mode}"
  st_set ROLLBACK_MIGRATED "${migrated}"
  st_set ROLLBACK_DB_OID "${oid}"
  st_set ROLLBACK_SRC "${src}"
  st_set ROLLBACK_STARTED_AT "$(now_utc)"
  st_set RESTORE_DONE ""
else
  own=1
  mode="$(st ROLLBACK_MODE)"
  [[ -n "${src}" ]] || src="$(st ROLLBACK_SRC)"
  info "continuing the rollback ${to_v} -> ${from_v} (mode ${mode}, PHASE=${phase})"
fi

if [[ "$(upgrade_phase)" == "rolling-back" ]]; then
  stop_n8n
  # an interrupted upgrade can leave n8n-main migrating in the background until stop_n8n stopped it: look again
  mark="$(db_migration_mark)" || die "cannot read n8n's migrations table — run make rollback again (it continues)"
  if [[ "${mode}" == "images" && "${mark}" != "${before}" ]]; then
    st_set ROLLBACK_MODE restore
    st_set ROLLBACK_MIGRATED 1
    mode=restore
    [[ "${ROLLBACK_CONFIRM:-}" == "${backup}" ]] ||
      die "a migration finished after this rollback was decided (${before} -> ${mark}): it must now restore the pre-upgrade backup, which discards data written under ${to_v} — run make rollback ROLLBACK_CONFIRM=${backup} (or make rollback ABORT=1)"
  fi

  if [[ "${mode}" == "restore" && "$(st RESTORE_DONE)" != "1" ]]; then
    oid_before="$(st ROLLBACK_DB_OID)"
    oid_now="$(db_oid)" || die "cannot read the database — run make rollback again (it continues)"
    if [[ -n "${oid_before}" && "${oid_now}" != "${oid_before}" ]]; then
      st_set RESTORE_DONE 1   # an interrupted earlier run already swapped the pre-upgrade database in
    else
      # restore → version switch: Ctrl-C would leave a half-done pair (the new image re-migrating the restored database,
      # or the old image on the migrated one); a closed SSH session is already ignored for the whole run
      trap '' INT
      stage=''
      (( fetched == 1 )) && stage=apply
      rc=0
      RESTORE_STAGE="${stage}" BACKUP="${backup}" FROM="${src}" YES=1 RESTORE_NO_START=1 \
        RESTORE_SAFETY_LABEL="rollback-from-${to_v}" RESTORE_RUN_VERSION="${from_v}" \
        N8N_VERSION="${to_v}" N8N_DIGEST="$(st TO_N8N_DIGEST)" RUNNERS_DIGEST="$(st TO_RUNNERS_DIGEST)" \
        "${KIT_DIR}/scripts/restore.sh" || rc=$?
      fetched=0   # restore.sh empties the work volume itself
      oid_now="$(db_oid)" || oid_now=''
      if [[ -n "${oid_now}" && "${oid_now}" != "${oid_before}" ]]; then
        st_set RESTORE_DONE 1
        (( rc == 0 )) || warn "restore.sh reported an error after the swap — the pre-upgrade database IS in place; continuing"
      else
        die "the restore did not happen and the database was NOT changed (see above) — n8n stays stopped: fix the cause and run make rollback again, or make rollback ABORT=1 to start n8n ${to_v} again"
      fi
    fi
  fi
  if [[ "${mode}" == "restore" ]]; then
    flush_queue || die "could not empty the job queue (Valkey) — run make rollback again (it continues)"
  fi
  switch_versions FROM
  set_phase restored
  trap 'exit 130' INT
fi

rc=0
start_main_alone FROM || rc=$?
if (( rc != 0 )); then
  compose stop n8n-main >/dev/null 2>&1 || true
  die "n8n ${from_v} did not start (rollback mode ${mode}) — fix what its log shows, then make rollback again"
fi
start_rest FROM || die "the rest of the stack did not come back healthy — make status; then make rollback again"
verify_side FROM || die "n8n ${from_v} runs again but did not pass verification — fix it, then make rollback again (re-verifies)"
if [[ "${mode}" == "restore" ]]; then
  compose run --rm -T backup /opt/backup/restore.sh finalize >/dev/null 2>&1 || warn "could not drop the replaced database n8n_prev"
fi
set_phase rolled-back
st_set FINISHED_AT "$(now_utc)"
silence_end
archive_state
own=0
ok "rolled back to n8n ${from_v} (${mode})"
if [[ "${mode}" == "restore" ]]; then
  log "  the database is the pre-upgrade backup ${backup}; the replaced one is in the pre-restore safety backup above"
fi
log "  versions.env pins ${from_v} again. 'make upgrade N8N_VERSION=${to_v}' tries again once the cause is fixed."
"${KIT_DIR}/scripts/status.sh" || true
