#!/usr/bin/env bash
# compose/scripts/restore.sh — `make restore BACKUP=latest|<name> [FROM=<remote>] [AGE_KEY=file] [ADOPT_KEY=1] [YES=1]`
# (TC-012). AGE_KEY decrypts with another identity (the recovery key on a new host); ADOPT_KEY takes over the backup's
# N8N_ENCRYPTION_KEY into .env.
#
# Replaces the live n8n database with a backup, in the order n8n's own docs require (stop -> key -> database -> start):
#   1. lock (one restore at a time), fetch + decrypt + verify the bundle into the backup_work volume
#   2. key check: a bundle made with another N8N_ENCRYPTION_KEY stops here (exit 3) unless ADOPT_KEY=1, which shows
#      both key hints and asks to compare the bundle's with the password manager
#   3. confirm (YES=1 / CI=1 skip the prompt)
#   4. stop every n8n process and its runners — BEFORE the safety backup, so the undo copy has every last write
#   5. safety net: a "pre-restore" backup of the current database (SKIP_SAFETY_BACKUP=1 skips it)
#   6. restore into a staging database, verify it, swap it in atomically (the replaced one is kept as n8n_prev);
#      any failure up to here leaves the live database untouched and n8n is started again
#   7. ADOPT_KEY: the bundle's key into .env (old file kept as .env.bak.<ts>); n8n's settings file (which caches the key
#      in the n8n_data volume and would refuse a different one) is reset so n8n re-creates it from .env
#   8. empty the Bull queue (jobs in it belong to the timeline that is being rolled back)
#   9. start everything, wait for health, drop n8n_prev, print the status table
# For make rollback: RESTORE_STAGE=fetch does step 1-2 only and keeps the verified bundle in the work volume (fetched
# while n8n still serves); RESTORE_STAGE=apply then does the rest without fetching again. RESTORE_NO_START=1 stops after
# step 8 — n8n stays stopped, n8n_prev stays; the caller switches the n8n version, starts the stack and runs
# `restore.sh finalize`. RESTORE_SAFETY_LABEL labels the safety backup; RESTORE_RUN_VERSION is the n8n version that will
# run on the restored database (default: versions.env's).
# Refuses while a make upgrade / make rollback is unfinished or .env overrides the n8n pins, and for a bundle made by a
# NEWER n8n than the version that will run on it (exit 5; FORCE_VERSION=1 overrides).
# The decrypted dump and the key in the work volume are removed on EVERY exit (also Ctrl-C and errors) — except after
# a successful RESTORE_STAGE=fetch, whose caller empties it (make restore-clean does too).
# shellcheck disable=SC2310,SC2311,SC2312,SC2016  # SC2016: $VALKEY_PASSWORD expands inside the container
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

want="${BACKUP:-${1:-latest}}"
from="${FROM:-}"
[[ -f .env ]] || die ".env not found — run make init first"

exec 8>"${KIT_DIR}/.restore.lock"
flock -n 8 || die "another make restore is running on this host"
version_guard "make restore" --restore
no_start="${RESTORE_NO_START:-}"
stage="${RESTORE_STAGE:-}"
[[ "${stage}" =~ ^(fetch|apply)?$ ]] || die "RESTORE_STAGE must be fetch or apply (got '${stage}')" 2
keep_work=0

restore_key="${KIT_DIR}/secrets/restore-key.txt"
stopped=0
swapped=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  rm -f "${restore_key}"
  if (( keep_work == 0 )); then
    compose run --rm -T backup /opt/backup/restore.sh clean >/dev/null 2>&1 || warn "could not empty the backup_work volume — run: make restore-clean"
  fi
  if (( rc != 0 && stopped == 1 && swapped == 0 )) && [[ "${no_start}" == "1" ]]; then
    warn "the database was NOT changed — n8n stays stopped (RESTORE_NO_START: the caller decides)"
  elif (( rc != 0 && stopped == 1 && swapped == 0 )); then
    warn "the database was NOT changed — starting n8n again"
    compose up -d --wait --wait-timeout 600 >/dev/null 2>&1 || warn "n8n did not come back healthy — make status"
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

"${KIT_DIR}/scripts/backup-perms.sh"
compose up -d --wait --no-recreate postgres valkey >/dev/null

# AGE_KEY=/path/to/key.txt: decrypt with another age identity — the RECOVERY key from the password manager when
# restoring onto a new host. It is copied into secrets/ only for the fetch (owner = the backup container's uid,
# mode 0440) and removed right after it (and by the EXIT trap).
key_args=()
if [[ "${stage}" != "apply" && -n "${AGE_KEY:-}" ]]; then
  [[ -r "${AGE_KEY}" ]] || die "AGE_KEY=${AGE_KEY} is not a readable file"
  install -m 0600 "${AGE_KEY}" "${restore_key}"
  docker run --rm --user 0:0 --entrypoint sh -v "${KIT_DIR}/secrets:/k:z" n8nkit/backup:local \
    -c "chown 70:$(id -g) /k/restore-key.txt && chmod 0440 /k/restore-key.txt" || die "could not prepare AGE_KEY for the container"
  key_args=(-v "${restore_key}:/run/secrets/restore-key.txt:ro,z" -e AGE_KEY_FILE=/run/secrets/restore-key.txt)
  info "decrypting with AGE_KEY=${AGE_KEY}"
fi

if [[ "${stage}" != "apply" ]]; then
  info "fetching backup '${want}'${from:+ from ${from}}"
  fetch_args=(fetch "${want}")
  if [[ -n "${from}" ]]; then
    fetch_args+=(--from "${from}")
  fi
  compose run --rm -T "${key_args[@]}" backup /opt/backup/restore.sh "${fetch_args[@]}" || die "fetch failed — nothing was changed"
  rm -f "${restore_key}"
fi

bundle_name="$(compose run --rm -T backup jq -r '.name // empty' /work/current/manifest.json 2>/dev/null || true)"
bundle_version="$(compose run --rm -T backup jq -r '.n8n_version // empty' /work/current/manifest.json 2>/dev/null || true)"
run_version="${RESTORE_RUN_VERSION:-$(env_get N8N_VERSION versions.env)}"
if [[ -n "${bundle_version}" && "${bundle_version}" != "${run_version}" ]]; then
  if version_ge "${run_version}" "${bundle_version}"; then
    info "the backup was made by n8n ${bundle_version}; n8n ${run_version} migrates it forward when it starts"
  elif [[ "${FORCE_VERSION:-}" == "1" ]]; then
    warn "FORCE_VERSION=1: restoring a backup of n8n ${bundle_version} under the older n8n ${run_version}"
  else
    die "the backup ${bundle_name:-${want}} was made by n8n ${bundle_version}, NEWER than the ${run_version} that would run on it — n8n cannot run on a newer database. Move to ${bundle_version} first (make upgrade N8N_VERSION=${bundle_version}), then: make restore BACKUP=${bundle_name:-${want}} (not 'latest': the upgrade's own backup would be newer). FORCE_VERSION=1 overrides" 5
  fi
fi

key_rc=0
hints="$(compose run --rm -T backup /opt/backup/restore.sh keycheck)" || key_rc=$?
if (( key_rc == 3 )); then
  printf '%s\n' "${hints}" >&2
  if [[ "${ADOPT_KEY:-}" != "1" ]]; then
    warn "the backup was made with a different N8N_ENCRYPTION_KEY — restoring it as is would leave every credential unreadable."
    warn "If this host should take over the backup's key (restore onto a new host, or the key was rotated), re-run with"
    warn "ADOPT_KEY=1 and compare the 'bundle key' hint with the key in your password manager."
    die "restore aborted before anything was changed (encryption key mismatch)" 3
  fi
  # age proves confidentiality, not origin: the human comparison is what ties the bundle to this instance
  confirm "ADOPT_KEY=1: does the 'bundle key' hint above match the N8N_ENCRYPTION_KEY in your password manager?" ||
    die "aborted — nothing was changed" 0
elif (( key_rc != 0 )); then
  die "key check failed — nothing was changed"
fi

if [[ "${stage}" == "fetch" ]]; then
  keep_work=1
  ok "fetched and verified ${bundle_name:-${want}} — RESTORE_STAGE=apply restores it"
  exit 0
fi

mapfile -t n8n_services < <(compose config --services | grep -E '^n8n-')
confirm "Replace the CURRENT n8n database (workflows, credentials, executions) with this backup?" || die "aborted — nothing was changed" 0

info "stopping n8n (${#n8n_services[@]} services)"
stopped=1
compose stop "${n8n_services[@]}" >/dev/null

if [[ "${SKIP_SAFETY_BACKUP:-}" != "1" ]]; then
  info "safety backup of the current database (kind pre-restore)"
  safety_args=(--kind pre-restore)
  if [[ -n "${RESTORE_SAFETY_LABEL:-}" ]]; then
    safety_args+=(--name "${RESTORE_SAFETY_LABEL}")
  fi
  safety="$(compose run --rm -T backup /opt/backup/backup.sh "${safety_args[@]}")" ||
    die "the safety backup failed — the database was NOT changed (SKIP_SAFETY_BACKUP=1 to restore without one)"
  safety_name="$(awk '$1 == "BACKUP" && $2 == "OK" { print $3 }' <<<"${safety}")"
fi

apply_args=(apply)
if [[ "${ADOPT_KEY:-}" == "1" ]]; then
  apply_args+=(--adopt-key)
fi
rc=0
compose run --rm -T backup /opt/backup/restore.sh "${apply_args[@]}" || rc=$?
case "${rc}" in
  0) swapped=1 ;;
  3) die "restore aborted (encryption key mismatch) — the database was NOT changed" 3 ;;
  4) die "restore failed — the database was NOT changed (see the error above)" 4 ;;
  *) swapped=1   # unknown state: do not restart n8n automatically
     die "restore.sh apply failed unexpectedly (exit ${rc}) — check 'make status' and the databases n8n / n8n_restore / n8n_prev before starting n8n" "${rc}" ;;
esac

if [[ "${ADOPT_KEY:-}" == "1" ]]; then
  adopted="$(compose run --rm -T backup cat /work/adopt.key 2>/dev/null || true)"
  if [[ -n "${adopted}" ]]; then
    [[ "${adopted}" =~ ^[A-Za-z0-9+/=._~:@%-]{16,255}$ ]] || die "the adopted key has an unexpected format — set N8N_ENCRYPTION_KEY in .env by hand, then make up"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p .env ".env.bak.${stamp}"
    env_set N8N_ENCRYPTION_KEY "${adopted}"
    warn "N8N_ENCRYPTION_KEY in .env replaced by the backup's key (old file: .env.bak.${stamp}) — store the key in your password manager"
  fi
fi
# n8n caches its key in /home/node/.n8n/config (volume n8n_data) and refuses to start when N8N_ENCRYPTION_KEY differs
# ("Mismatching encryption keys"). The restored database belongs to the key now in .env: let n8n write a fresh file.
compose run --rm --no-deps -T --entrypoint sh n8n-main -c 'rm -f /home/node/.n8n/config' >/dev/null ||
  warn "could not reset n8n's settings file — if n8n-main reports 'Mismatching encryption keys', delete /home/node/.n8n/config in the n8n_data volume"

info "emptying the job queue (Bull keys n8n:*)"
# not optional: a job left from the replaced timeline names an execution id the restored database hands out again,
# so a worker would run a different, new execution a second time
compose exec -T valkey sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli --no-auth-warning FLUSHDB' >/dev/null ||
  die "the database is restored, but the job queue could not be emptied — n8n is NOT started. Empty it (docker compose exec valkey valkey-cli FLUSHDB, with VALKEYCLI_AUTH set), then make up${safety_name:+; the safety backup is ${safety_name}}"

if [[ "${no_start}" == "1" ]]; then
  ok "database restored; n8n NOT started (RESTORE_NO_START=1)${safety_name:+ — safety backup ${safety_name}}"
  exit 0
fi

info "starting the stack"
if ! compose up -d --wait --wait-timeout 600; then
  fail "the restored database is in place, but the stack did not come back healthy — make status; make logs SERVICE=n8n-main SINCE=10m"
  die "the replaced database is kept as n8n_prev${safety_name:+; the safety backup is ${safety_name}}"
fi
compose run --rm -T backup /opt/backup/restore.sh finalize >/dev/null || warn "could not drop the database n8n_prev"
ok "restore complete${safety_name:+ (undo: make restore BACKUP=${safety_name} SKIP_SAFETY_BACKUP=1)}"
"${KIT_DIR}/scripts/status.sh"
