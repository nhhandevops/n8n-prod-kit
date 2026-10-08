#!/usr/bin/env bash
# 08-restore-test — `make restore-test` (the weekly job, "latest" mode): every remote's newest bundle downloads,
# decrypts and verifies and is fresh; the newest overall — the bundle from 07 — restores into a scratch Postgres inside
# the backup container: workflow count matches the manifest, a credential decrypts with the bundle's key, the key
# matches the running one, and the restore-test report + metrics are written (TC-012/013). The live database is never
# touched.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

name="$(state_get BACKUP_NAME)"
if [[ -z "${name}" ]]; then
  die "no backup from 07 in compose/.smoke/state.env — run: make smoke ONLY=07,08"
fi

"${KIT_DIR}/scripts/backup-perms.sh"
out="$(compose run --rm -T backup /opt/backup/restore-test.sh 2>&1)" && rc=0 || rc=$?
check "make restore-test exits 0 (rc=${rc})" test "${rc}" -eq 0
if (( rc != 0 )); then
  printf '%s\n' "${out}" | tail -10 >&2
fi

report="$(compose run --rm -T backup cat /state/restore-test.json 2>/dev/null || true)"
check "report names the tested backup" test "$(jq -r '.backup // empty' <<<"${report}")" = "${name}"
check "report says ok" test "$(jq -r '.ok // empty' <<<"${report}")" = "true"
remote_count="$(wc -w <<<"$(env_get BACKUP_REMOTES)")"
check "every remote's newest bundle verified ($(jq -r '.remotes_verified // "?"' <<<"${report}") of ${remote_count})"   test "$(jq -r '.remotes_verified // 0' <<<"${report}")" -eq "${remote_count}"
check "restored workflows >= 1 ($(jq -r '.workflow_count // "?"' <<<"${report}"))" \
  bash -c '(( ${1:-0} >= 1 ))' _ "$(jq -r '.workflow_count // 0' <<<"${report}")"
check "a credential decrypted with the bundle key ($(jq -r '.credential_decrypt // "?"' <<<"${report}"))" \
  test "$(jq -r '.credential_decrypt // empty' <<<"${report}")" = "ok"
check "bundle key matches the running key" test "$(jq -r '.key_matches_running // empty' <<<"${report}")" = "true"

metrics="$(compose run --rm -T backup cat /state/metrics.prom 2>/dev/null || true)"
check "metric restore_test_last_status = 1" grep -qx 'restore_test_last_status 1' <<<"${metrics}"
finish
