#!/usr/bin/env bash
# 07-backup — `make backup-now` produces an encrypted bundle on EVERY remote in BACKUP_REMOTES; the bundle decrypts with
# the host key, its sha256s verify, its key bundle carries the running N8N_ENCRYPTION_KEY, and the backup metrics are
# updated (TC-011). Creates a throw-away credential first so 08 can prove credentials survive a restore.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ensure_api_key || die "no API key (run 03-owner first)"
remotes="$(env_get BACKUP_REMOTES)"
check "BACKUP_REMOTES is configured (${remotes:-empty})" test -n "${remotes}"
finish_if_failed() { if (( SMOKE_FAILED > 0 )); then finish; fi; }
finish_if_failed

nonce="$(rand_hex 6)"
api POST /api/v1/credentials "$(jq -nc --arg n "kit-smoke-cred-${nonce}" \
  '{name: $n, type: "httpHeaderAuth", data: {name: "X-Kit-Smoke", value: "smoke-secret-value"}}')"
cred_id="$(req_body | jq -r '.id // empty')"
check "test credential created (HTTP ${REQ_STATUS})" test -n "${cred_id}"
state_set CRED_ID "${cred_id}"

"${KIT_DIR}/scripts/backup-perms.sh"
out="$(compose run --rm -T backup /opt/backup/backup.sh --kind manual --name smoke 2>&1)" || true
name="$(awk '$1 == "BACKUP" && $2 == "OK" { print $3 }' <<<"${out}")"
check "make backup-now succeeded (${name:-no BACKUP OK line})" test -n "${name}"
if [[ -z "${name}" ]]; then
  printf '%s\n' "${out}" | tail -15 >&2
  finish
fi
state_set BACKUP_NAME "${name}"

for remote in ${remotes}; do
  listing="$(compose run --rm -T backup rclone lsf "${remote%/}/manual/" 2>/dev/null || true)"
  check "bundle present on ${remote} (manual/${name}.tar.age)" grep -qxF "${name}.tar.age" <<<"${listing}"
done

fetched="$(compose run --rm -T backup /opt/backup/restore.sh fetch "${name}" 2>&1 || true)"
check "bundle decrypts with the host key and its sha256s verify" grep -q "^FETCHED ${name}" <<<"${fetched}"
check "key bundle carries the running N8N_ENCRYPTION_KEY" grep -q 'key: *matches the running' <<<"${fetched}"
compose run --rm -T backup /opt/backup/restore.sh clean >/dev/null 2>&1 || true

metrics="$(compose run --rm -T backup cat /state/metrics.prom 2>/dev/null || true)"
now="$(date +%s)"
for remote in ${remotes}; do
  ts="$(awk -v r="backup_last_success_timestamp_seconds{remote=\"${remote%/}\"}" '$1 == r { print $2 }' <<<"${metrics}")"
  check "metric backup_last_success_timestamp_seconds for ${remote} is fresh" \
    bash -c '[[ -n "$1" ]] && (( $2 - ${1%.*} < 600 ))' _ "${ts}" "${now}"
done
finish
