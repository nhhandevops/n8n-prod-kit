#!/usr/bin/env bash
# compose/backup/restore-test.sh [NAME] — prove the backups can actually be restored, without touching the live
# database (weekly from cron; `make restore-test`; smoke 08).
#
# Without NAME ("latest"):
#   1. every remote in BACKUP_REMOTES: its newest bundle is downloaded, decrypted and sha256-verified (a copy that rots
#      or is truncated on ONE remote is found), and must be younger than RESTORE_TEST_MAX_AGE_HOURS (default 26 —
#      a stale newest bundle means the nightly backup stopped working)
#   2. the newest bundle overall gets the full test below
# With NAME: only that bundle, full test, no age check.
# Full test: the manifest names the file -> 2 age recipients (host + recovery key) unless BACKUP_ALLOW_SINGLE_RECIPIENT
# -> the bundle's key equals the running N8N_ENCRYPTION_KEY (checked BEFORE anything of the bundle is executed: a
# planted bundle encrypted to the public key never reaches Postgres) -> scratch Postgres on the tmpfs (unix socket
# only, port 5499) -> pg_restore as an UNPRIVILEGED role (archive SQL cannot run COPY ... PROGRAM) -> workflow count
# vs the manifest -> decrypt one credential with the bundle's key using openssl (n8n's credential cipher is
# OpenSSL-compatible AES-256-CBC, "Salted__", MD5 key derivation — verified 2026-10-08) -> stop + wipe.
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
verified=0

finish() {
  trap - ERR
  local duration=$(( $(date +%s) - started )) now
  now="$(date +%s)"
  jq -n --arg name "${name}" --argjson ok "$([[ ${status} == 1 ]] && echo true || echo false)" --arg note "${note}" \
    --argjson workflows "${workflows}" --argjson credentials "${credentials}" --arg cred "${cred_check}" \
    --argjson key "${key_match}" --argjson duration "${duration}" --argjson size "${size}" --arg at "$(date -u +%FT%TZ)" \
    --argjson verified "${verified}" \
    '{tested_at: $at, backup: $name, ok: $ok, note: $note, workflow_count: $workflows, credential_count: $credentials,
      credential_decrypt: $cred, key_matches_running: $key, bundle_bytes: $size, remotes_verified: $verified,
      duration_seconds: $duration}' \
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
  local summary="${name}: ${workflows} workflows, ${credentials} credentials, credential decrypt ${cred_check}, ${size} bytes, ${verified} remote(s) verified, ${duration}s"
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

if ! validate_remotes; then
  note="BACKUP_REMOTES has an invalid entry"
  finish
fi
if ! take_lock 900; then
  note="a backup or restore is still running after 15 min"
  finish
fi

# fetch_verified REMOTE PATH DIR — download, decrypt, verify; the bundle file is removed again (tmpfs space)
fetch_verified() {
  rclone copyto "${1}/${2}" "${rt}/bundle.tar.age" || return 1
  size="$(stat -c %s "${rt}/bundle.tar.age")"
  rcpt_count="$(recipient_count "${rt}/bundle.tar.age")"
  unpack_bundle "${rt}/bundle.tar.age" "${3}" "${2##*/}" || return 1
  rm -f "${rt}/bundle.tar.age"
}

if [[ "${want}" == "latest" ]]; then
  max_age_h="${RESTORE_TEST_MAX_AGE_HOURS:-26}"
  mapfile -t rs < <(remotes)
  if (( ${#rs[@]} == 0 )); then
    note="BACKUP_REMOTES is empty"
    finish
  fi
  for r in "${rs[@]}"; do
    rc=0
    hit="$(resolve_bundle latest "${r}")" || rc=$?
    if (( rc == 2 )); then
      note="cannot list ${r}"
      finish
    elif [[ -z "${hit}" ]]; then
      note="no backup on ${r}"
      finish
    fi
    path="${hit#*$'\t'}"
    ts="${path##*/}"
    age_h=$(( ( $(date +%s) - $(date -u -d "${ts:4:4}-${ts:8:2}-${ts:10:2} ${ts:13:2}:${ts:15:2}:${ts:17:2}" +%s) ) / 3600 ))
    if (( age_h >= max_age_h )); then
      note="the newest backup on ${r} is ${age_h} h old (limit ${max_age_h} h) — the nightly backup is not working"
      finish
    fi
    if ! fetch_verified "${r}" "${path}" "${rt}/v"; then
      note="newest bundle on ${r} (${path}) does not decrypt/verify — corrupt copy?"
      finish
    fi
    rm -rf "${rt}/v"
    verified=$((verified + 1))
  done
fi

rc=0
hit="$(resolve_bundle "${want}")" || rc=$?
if [[ -z "${hit}" ]]; then
  note="no backup '${want}' found on ${BACKUP_REMOTES:-<BACKUP_REMOTES empty>}"
  if (( rc == 2 )); then
    note="${note} (a remote could not be listed)"
  fi
  finish
fi
remote="${hit%%$'\t'*}"
path="${hit#*$'\t'}"
name="${path##*/}"
name="${name%.tar.age}"
info "restore test of ${remote}/${path}"
if ! fetch_verified "${remote}" "${path}" "${rt}/b"; then
  note="download/decrypt/verify failed (wrong key, corrupt or renamed bundle)"
  finish
fi
if [[ "${want}" != "latest" ]]; then
  verified=1
fi
if (( rcpt_count < 2 )) && [[ "${BACKUP_ALLOW_SINGLE_RECIPIENT:-false}" != "true" ]]; then
  note="the bundle is encrypted to ${rcpt_count} key(s) — the recovery key cannot open it (BACKUP_AGE_RECOVERY_PUBLIC_KEY empty when it was made?)"
  finish
fi

# The key check comes BEFORE the bundle's SQL is executed anywhere: age proves confidentiality, not origin — anyone
# who can write to a remote can encrypt to the public keys. The running key is the secret that ties a bundle to us.
key="$(bundle_key "${rt}/b")"
if [[ "${key}" != "${N8N_ENCRYPTION_KEY:-}" ]]; then
  note="the bundle's N8N_ENCRYPTION_KEY differs from the running one — not restored (a restore would leave every credential unreadable)"
  finish
fi
key_match=true

initdb -D "${pgdata}" -U postgres --auth=trust --no-instructions >/dev/null
pg_ctl -D "${pgdata}" -w -s -o "-p 5499 -k ${rt} -c listen_addresses=''" start >/dev/null
pg_up=1
psql -X -h "${rt}" -p 5499 -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
  -c "CREATE ROLE restore_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE" -c "CREATE DATABASE n8n OWNER restore_test"
scratch=(-X -h "${rt}" -p 5499 -U restore_test -d n8n)
if ! pg_restore -h "${rt}" -p 5499 -U restore_test -d n8n --no-owner --no-privileges --exit-on-error "${rt}/b/db.dump"; then
  note="pg_restore failed"
  finish
fi
workflows="$(psql "${scratch[@]}" -Atc 'select count(*) from workflow_entity')"
credentials="$(psql "${scratch[@]}" -Atc 'select count(*) from credentials_entity')"
expected="$(jq -r '.counts.workflows' "${rt}/b/manifest.json")"
if [[ "${workflows}" != "${expected}" ]]; then
  note="restored ${workflows} workflows, manifest says ${expected}"
  finish
fi

if (( credentials > 0 )); then
  cipher="$(psql "${scratch[@]}" -Atc 'select data from credentials_entity order by "createdAt" limit 1')"
  # the key goes through the environment (-pass env:), never the command line (readable by every host user in /proc)
  if printf '%s' "${cipher}" | RT_KEY="${key}" openssl enc -d -aes-256-cbc -md md5 -base64 -A -pass env:RT_KEY 2>/dev/null |
    jq -e 'type == "object"' >/dev/null; then
    cred_check=ok
  else
    cred_check=failed
    note="a credential could not be decrypted with the bundle's key"
    finish
  fi
fi
status=1
finish
