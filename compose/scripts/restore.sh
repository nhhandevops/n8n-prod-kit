#!/usr/bin/env bash
# compose/scripts/restore.sh — `make restore BACKUP=latest|<name> [FROM=<remote>] [AGE_KEY=file] [ADOPT_KEY=1] [YES=1]`
# (TC-012). AGE_KEY decrypts with another identity (the recovery key on a new host); ADOPT_KEY takes over the backup's
# N8N_ENCRYPTION_KEY into .env.
#
# Replaces the live n8n database with a backup, in the order n8n's own docs require (stop -> key -> database -> start):
#   1. fetch + decrypt + verify the bundle (nothing is touched yet; a wrong name or key fails here)
#   2. confirm (YES=1 / CI=1 skip the prompt)
#   3. safety net: a "pre-restore" backup of the CURRENT database (SKIP_SAFETY_BACKUP=1 skips it)
#   4. stop every n8n process and its runners (webhooks must not accept work against a database being replaced)
#   5. drop + recreate + pg_restore in one transaction; a key mismatch aborts BEFORE the drop (ADOPT_KEY=1 instead
#      writes the bundle's key into .env, keeping a copy of the old .env — the "restore onto a new host" case)
#   6. empty the Bull queue (jobs in it belong to the timeline that is being rolled back)
#   7. start everything, wait for health, clean the work volume, print the status table
# shellcheck disable=SC2310,SC2311,SC2312,SC2016  # SC2016: $VALKEY_PASSWORD expands inside the container
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

want="${BACKUP:-${1:-latest}}"
from="${FROM:-}"
[[ -f .env ]] || die ".env not found — run make init first"

"${KIT_DIR}/scripts/backup-perms.sh"
compose up -d --wait postgres valkey >/dev/null

# AGE_KEY=/path/to/key.txt: decrypt with another age identity — the RECOVERY key from the password manager when
# restoring onto a new host. It is copied into secrets/ only for the fetch (owner = the backup container's uid,
# mode 0440) and removed afterwards.
key_args=()
restore_key="${KIT_DIR}/secrets/restore-key.txt"
if [[ -n "${AGE_KEY:-}" ]]; then
  [[ -r "${AGE_KEY}" ]] || die "AGE_KEY=${AGE_KEY} is not a readable file"
  install -m 0600 "${AGE_KEY}" "${restore_key}"
  trap 'rm -f "${restore_key}"' EXIT
  docker run --rm --user 0:0 --entrypoint sh -v "${KIT_DIR}/secrets:/k:z" n8nkit/backup:local \
    -c "chown 70:$(id -g) /k/restore-key.txt && chmod 0440 /k/restore-key.txt" || die "could not prepare AGE_KEY for the container"
  key_args=(-v "${restore_key}:/run/secrets/restore-key.txt:ro,z" -e AGE_KEY_FILE=/run/secrets/restore-key.txt)
  info "decrypting with AGE_KEY=${AGE_KEY}"
fi

info "fetching backup '${want}'${from:+ from ${from}}"
fetch_args=(fetch "${want}")
if [[ -n "${from}" ]]; then
  fetch_args+=(--from "${from}")
fi
compose run --rm -T "${key_args[@]}" backup /opt/backup/restore.sh "${fetch_args[@]}" || die "fetch failed — nothing was changed"
rm -f "${restore_key}"

mapfile -t n8n_services < <(compose config --services | grep -E '^n8n-')
confirm "Replace the CURRENT n8n database (workflows, credentials, executions) with this backup?" || die "aborted — nothing was changed" 0

if [[ "${SKIP_SAFETY_BACKUP:-}" != "1" ]]; then
  info "safety backup of the current database (kind pre-restore)"
  compose run --rm -T backup /opt/backup/backup.sh --kind pre-restore ||
    die "the safety backup failed — refusing to replace the database (SKIP_SAFETY_BACKUP=1 to override)"
fi

info "stopping n8n (${#n8n_services[@]} services)"
compose stop "${n8n_services[@]}" >/dev/null

apply_args=(apply)
if [[ "${ADOPT_KEY:-}" == "1" ]]; then
  apply_args+=(--adopt-key)
fi
rc=0
compose run --rm -T backup /opt/backup/restore.sh "${apply_args[@]}" || rc=$?
if (( rc == 3 )); then
  warn "key mismatch: the database was NOT touched. If this host should take over the backup's key (restore onto a"
  warn "new host, or the key was rotated), re-run with ADOPT_KEY=1 — .env is backed up first."
  compose up -d --wait >/dev/null
  die "restore aborted (encryption key mismatch)" 3
elif (( rc != 0 )); then
  fail "pg_restore failed; the transaction was rolled back, so the n8n database is EMPTY now."
  fail "Retry with another backup (make backups lists them), or restore the safety backup: make restore BACKUP=<pre-restore name>"
  die "restore failed" "${rc}"
fi

if [[ "${ADOPT_KEY:-}" == "1" ]]; then
  adopted="$(compose run --rm -T backup sh -c 'cat /work/adopt.key 2>/dev/null' || true)"
  if [[ -n "${adopted}" ]]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p .env ".env.bak.${stamp}"
    env_set N8N_ENCRYPTION_KEY "${adopted}"
    warn "N8N_ENCRYPTION_KEY in .env replaced by the backup's key (old file: .env.bak.${stamp}) — store the key in your password manager"
  fi
fi

info "emptying the job queue (Bull keys n8n:*)"
compose exec -T valkey sh -c 'VALKEYCLI_AUTH=$VALKEY_PASSWORD valkey-cli --no-auth-warning FLUSHDB' >/dev/null

info "starting the stack"
compose up -d --wait --wait-timeout 240 ||
  die "the restored database is in place, but the stack did not come back healthy — make status; make logs SERVICE=n8n-main SINCE=10m"
compose run --rm -T backup /opt/backup/restore.sh clean || true
ok "restore complete"
"${KIT_DIR}/scripts/status.sh"
