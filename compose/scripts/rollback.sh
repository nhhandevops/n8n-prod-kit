#!/usr/bin/env bash
# compose/scripts/rollback.sh — `make rollback [YES=1] [ROLLBACK_MODE=auto|images|restore] [ROLLBACK_CONFIRM=<backup>]`
# (test case TC-015). Undoes the last `make upgrade` (compose/.upgrade/state.env), finished or failed.
#
#   images    no migration ran — the database's migration mark still equals the one taken before the upgrade (n8n runs
#             all pending migrations in ONE transaction, so even a failed migration leaves it unchanged): stop n8n,
#             switch versions.env back, start the old version. No data is lost.
#   restore   a migration ran: stop n8n, restore the pre-upgrade backup through scripts/restore.sh (fetch + decrypt,
#             safety backup of the current database, staging restore, atomic swap), switch versions.env back, start the
#             old version, verify, then drop the replaced database. Everything written after the backup is lost: the
#             confirm shows how much, and when data was written after a finished upgrade it also wants
#             ROLLBACK_CONFIRM=<backup name> (YES=1 alone is not enough).
# ROLLBACK_MODE=auto (default) chooses from the migration mark; images refuses when a migration ran; restore forces it.
# From the restore to the version switch Ctrl-C and a closed SSH session are ignored. Running make rollback again
# continues an interrupted rollback: the database itself tells whether the restore already happened. Only N8N_VERSION,
# N8N_DIGEST and RUNNERS_DIGEST go back — pins a git pull moved meanwhile (Grafana, Postgres…) stay.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
# shellcheck source=upgrade-lib.sh
source "${KIT_DIR}/scripts/upgrade-lib.sh"
cd "${KIT_DIR}"

# nothing from make's command line or an old shell export may change what restore.sh does here
unset N8N_VERSION N8N_DIGEST RUNNERS_DIGEST MAKEFLAGS MFLAGS MAKELEVEL SKIP_SAFETY_BACKUP ADOPT_KEY AGE_KEY FROM BACKUP
export KIT_UPGRADE_INTERNAL=1

[[ -f .env ]] || die ".env not found — run make init first"
mkdir -p "${UPGRADE_DIR}"
exec 7>"${UPGRADE_DIR}/lock"
flock -n 7 || die "another make upgrade / make rollback is running"
[[ -f "${UPGRADE_STATE}" ]] || die "nothing to roll back — no make upgrade on record (compose/.upgrade/state.env; finished ones are in .upgrade/history/)"

phase="$(upgrade_phase)"
from_v="$(st FROM_VERSION)"
to_v="$(st TO_VERSION)"
backup="$(st BACKUP_NAME)"

on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if (( rc != 0 )) && [[ "$(upgrade_phase)" =~ ^(rolling-back|restored)$ ]]; then
    silence_end
    fail "the rollback to n8n ${from_v} did not finish (PHASE=$(upgrade_phase)) — fix what the log above shows, then run make rollback again (it continues)"
  fi
  exit "${rc}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

case "${phase}" in
  preparing | aborted)
    [[ "${phase}" == "aborted" ]] || { set_phase aborted; archive_state; }
    die "the last upgrade stopped before anything changed — nothing to roll back" 0
    ;;
  stopping | backing-up)
    info "the upgrade to ${to_v} stopped before the version switch — starting n8n ${from_v} again"
    compose_at FROM up -d --wait --wait-timeout 300 >/dev/null || die "the stack did not come back healthy — make status"
    set_phase aborted
    archive_state
    ok "n8n ${from_v} runs again; nothing was changed"
    exit 0
    ;;
  migrating | starting | verifying | failed | done | rolling-back | restored) ;;
  rolled-back) die "already rolled back to n8n ${from_v}" 0 ;;
  *) die "unknown PHASE '${phase}' in ${UPGRADE_STATE}" ;;
esac

compose up -d --wait postgres valkey >/dev/null
before="$(st MIGRATIONS_BEFORE)"
mark="$(db_migration_mark)"
[[ -n "${mark}" ]] || die "cannot read n8n's migrations table — is postgres healthy? (make status)"

mode="$(st ROLLBACK_MODE)"
if [[ -z "${mode}" ]]; then
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

  log ""
  if [[ "${mode}" == "images" ]]; then
    log "  n8n ${to_v} -> ${from_v}: no migration ran, so only the images go back — no data is lost"
  else
    since="$(st BACKUP_AT)"
    IFS='|' read -r lost_exec lost_wf lost_cred <<<"$(kit_psql "select
      (select count(*) from execution_entity where \"startedAt\" > '${since}'),
      (select count(*) from workflow_entity where \"updatedAt\" > '${since}'),
      (select count(*) from credentials_entity where \"updatedAt\" > '${since}')" || echo '?|?|?')"
    log "  n8n ${to_v} -> ${from_v}: restore the pre-upgrade backup ${backup}"
    log "  (taken ${since}, fetched from $(st BACKUP_FROM)); a safety backup of the current database comes first."
    log "  LOST with the rollback: ${lost_exec} execution(s), ${lost_wf} workflow change(s), ${lost_cred} credential change(s) made since"
    if [[ "${phase}" == "done" && "${lost_exec}${lost_wf}${lost_cred}" != "000" && "${ROLLBACK_CONFIRM:-}" != "${backup}" ]]; then
      die "the upgrade finished and n8n ${to_v} has been used since — to discard that, run: make rollback ROLLBACK_CONFIRM=${backup}"
    fi
  fi
  log ""
  confirm "Roll back n8n ${to_v} -> ${from_v}?" || die "aborted — nothing was changed" 0
  st_set ROLLBACK_MODE "${mode}"
  st_set ROLLBACK_MIGRATED "${migrated}"
  st_set ROLLBACK_STARTED_AT "$(now_utc)"
else
  info "continuing the rollback ${to_v} -> ${from_v} (mode ${mode}, PHASE=${phase})"
fi

if [[ "$(upgrade_phase)" != "restored" ]]; then
  mapfile -t services < <(n8n_services)
  pull_side FROM "${services[@]}" || die "could not pull n8n ${from_v} — nothing was changed"
  backup_sidecar_quiet || die "a scheduled backup is still running after 15 min — try again later; nothing was changed"
  silence_start 60 "make rollback ${to_v} -> ${from_v}"
  set_phase rolling-back
  stop_n8n
  # an interrupted upgrade can leave n8n-main migrating in the background until stop_n8n stopped it: look again
  mark="$(db_migration_mark)"
  if [[ "${mode}" == "images" && "${mark}" != "${before}" ]]; then
    warn "a migration finished while the rollback started (${before} -> ${mark}) — restoring the pre-upgrade backup instead"
    mode=restore
    st_set ROLLBACK_MODE restore
    st_set ROLLBACK_MIGRATED 1
  fi

  if [[ "${mode}" == "restore" && "$(st RESTORE_DONE)" != "1" ]]; then
    if [[ "$(st ROLLBACK_MIGRATED)" == "1" && "${mark}" == "${before}" ]]; then
      st_set RESTORE_DONE 1   # an interrupted earlier run already swapped the database in
    else
      # restore → version switch: nothing may interrupt this (a half-done pair would let the new image re-migrate the
      # restored database, or the old image run on the migrated one)
      trap '' INT HUP
      rc=0
      BACKUP="${backup}" FROM="$(st BACKUP_FROM)" YES=1 RESTORE_NO_START=1 RESTORE_SAFETY_LABEL="rollback-from-${to_v}" \
        "${KIT_DIR}/scripts/restore.sh" || rc=$?
      mark="$(db_migration_mark)"
      if (( rc == 0 )); then
        st_set RESTORE_DONE 1
      elif [[ "$(st ROLLBACK_MIGRATED)" == "1" && "${mark}" == "${before}" ]]; then
        warn "restore.sh reported an error after the swap — the pre-upgrade database IS in place; continuing"
        st_set RESTORE_DONE 1
      else
        die "the restore failed and the database was NOT changed (see above) — n8n stays stopped; fix the cause and run make rollback again"
      fi
    fi
  fi
  switch_versions FROM
  set_phase restored
  trap 'exit 130' INT
  trap 'exit 143' HUP
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
ok "rolled back to n8n ${from_v} (${mode})"
if [[ "${mode}" == "restore" ]]; then
  log "  the database is the pre-upgrade backup ${backup}; the replaced one is in the pre-restore safety backup above"
fi
log "  versions.env pins ${from_v} again. 'make upgrade N8N_VERSION=${to_v}' tries again once the cause is fixed."
"${KIT_DIR}/scripts/status.sh" || true
