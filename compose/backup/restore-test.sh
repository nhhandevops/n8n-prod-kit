#!/usr/bin/env bash
# compose/backup/restore-test.sh [NAME] — prove the newest backup (or NAME) can actually be restored, without touching
# the live database (weekly from cron; `make restore-test`; smoke 08).
#
# fetch -> decrypt with the host key -> verify sha256s -> start a scratch Postgres on the tmpfs (port 5499, unix socket
# only) -> pg_restore -> count workflows/credentials -> decrypt one credential with the bundle's key using openssl
# (n8n's credential cipher is OpenSSL-compatible AES-256-CBC, "Salted__", MD5 key derivation — verified 2026-10-08)
# -> compare the bundle key with the running key -> stop + wipe the scratch server.
# Writes /state/restore-test.json and restore_test_* metrics; alerts on failure (and on success if
# BACKUP_NOTIFY_SUCCESS=true). Exit 0 only when everything checked out.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329  # SC2329: cleanup/finish run from traps
set -euo pipefail
# shellcheck source=lib.sh
source /opt/backup/lib.sh

want="${1:-latest}"
started="$(date +%s)"
rt="$(mktemp -d /tmp/restore-test.XXXXXX)"
pgdata="${rt}/pg"
pg_up=0
cleanup() {
  if (( pg_up )); then
    pg_ctl -D "${pgdata}" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "${rt}"
}
trap cleanup EXIT

status=0
note=''
workflows=-1
credentials=-1
cred_check=none
key_match=false
name='?'
size=0

finish() {
  trap - ERR
  local duration=$(( $(date +%s) - started )) now
  now="$(date +%s)"
  jq -n --arg name "${name}" --argjson ok "$([[ ${status} == 1 ]] && echo true || echo false)" --arg note "${note}" \
    --argjson workflows "${workflows}" --argjson credentials "${credentials}" --arg cred "${cred_check}" \
    --argjson key "${key_match}" --argjson duration "${duration}" --argjson size "${size}" --arg at "$(date -u +%FT%TZ)" \
    '{tested_at: $at, backup: $name, ok: $ok, note: $note, workflow_count: $workflows, credential_count: $credentials,
      credential_decrypt: $cred, key_matches_running: $key, bundle_bytes: $size, duration_seconds: $duration}' \
    >"${STATE_DIR}/restore-test.json.tmp" && mv -f "${STATE_DIR}/restore-test.json.tmp" "${STATE_DIR}/restore-test.json"
  local prev_success
  prev_success="$(grep -E '^restore_test_last_success_timestamp_seconds ' "${STATE_DIR}/metrics.d/restore-test.prom" 2>/dev/null || true)"
  {
    printf 'restore_test_last_run_timestamp_seconds %s\n' "${now}"
    if (( status == 1 )); then
      printf 'restore_test_last_success_timestamp_seconds %s\n' "${now}"
    elif [[ -n "${prev_success}" ]]; then
      printf '%s\n' "${prev_success}"
    fi
    printf 'restore_test_last_status %s\nrestore_test_workflow_count %s\nrestore_test_duration_seconds %s\n' \
      "${status}" "${workflows}" "${duration}"
  } | write_metrics restore-test
  local summary="${name}: ${workflows} workflows, ${credentials} credentials, credential decrypt ${cred_check}, ${size} bytes, ${duration}s"
  if (( status == 1 )); then
    [[ "${BACKUP_NOTIFY_SUCCESS:-false}" == "true" ]] && /opt/backup/notify.sh ok "restore test OK — ${summary}"
    ok "RESTORE TEST OK — ${summary}"
    exit 0
  fi
  /opt/backup/notify.sh error "restore test FAILED (${note}) — ${summary}"
  fail "RESTORE TEST FAILED: ${note} — ${summary}"
  exit 1
}

# Any unexpected failure (initdb, a full tmpfs, ...) must still produce a report, metrics and an alert.
trap 'note="unexpected error at line ${LINENO}"; finish' ERR

hit="$(resolve_bundle "${want}" || true)"
if [[ -z "${hit}" ]]; then
  note="no backup '${want}' found on ${BACKUP_REMOTES:-<BACKUP_REMOTES empty>}"
  finish
fi
remote="${hit%%$'\t'*}"
path="${hit#*$'\t'}"
info "restore test of ${remote}/${path}"
if ! rclone copyto "${remote}/${path}" "${rt}/bundle.tar.age"; then
  note="download failed"
  finish
fi
size="$(stat -c %s "${rt}/bundle.tar.age")"
if ! unpack_bundle "${rt}/bundle.tar.age" "${rt}/b"; then
  note="decrypt/verify failed (wrong key or corrupt bundle)"
  finish
fi
rm -f "${rt}/bundle.tar.age"
name="$(jq -r .name "${rt}/b/manifest.json")"

initdb -D "${pgdata}" -U postgres --auth=trust --no-instructions >/dev/null
pg_ctl -D "${pgdata}" -w -s -o "-p 5499 -k ${rt} -c listen_addresses=''" start >/dev/null
pg_up=1
scratch=(-h "${rt}" -p 5499 -U postgres)
createdb "${scratch[@]}" n8n
if ! pg_restore "${scratch[@]}" --no-owner --no-privileges --exit-on-error -d n8n "${rt}/b/db.dump"; then
  note="pg_restore failed"
  finish
fi
workflows="$(psql "${scratch[@]}" -d n8n -Atc 'select count(*) from workflow_entity')"
credentials="$(psql "${scratch[@]}" -d n8n -Atc 'select count(*) from credentials_entity')"
expected="$(jq -r '.counts.workflows' "${rt}/b/manifest.json")"
if [[ "${workflows}" != "${expected}" ]]; then
  note="restored ${workflows} workflows, manifest says ${expected}"
  finish
fi

key="$(bundle_key "${rt}/b")"
[[ "${key}" == "${N8N_ENCRYPTION_KEY:-}" ]] && key_match=true
if (( credentials > 0 )); then
  cipher="$(psql "${scratch[@]}" -d n8n -Atc 'select data from credentials_entity order by "createdAt" limit 1')"
  if printf '%s' "${cipher}" | openssl enc -d -aes-256-cbc -md md5 -base64 -A -pass "pass:${key}" 2>/dev/null | jq -e 'type == "object"' >/dev/null; then
    cred_check=ok
  else
    cred_check=failed
    note="a credential could not be decrypted with the bundle's key"
    finish
  fi
fi
if [[ "${key_match}" != "true" ]]; then
  note="the bundle's N8N_ENCRYPTION_KEY differs from the running one — backups would not restore credentials on this stack"
  finish
fi
status=1
finish
