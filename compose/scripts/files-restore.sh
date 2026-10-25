#!/usr/bin/env bash
# compose/scripts/files-restore.sh — put the n8n_files tree back from a decrypted bundle (bundle format 2).
#
# Called by scripts/restore.sh while n8n is stopped and after the database swap. **Non-fatal by design:** the
# database is what a restore is for, and a problem with user files must never leave a restored instance unstarted.
# Everything here therefore warns and returns 0; the caller decides nothing on its exit code.
#
# Why a throw-away root container, exactly as files-perms.sh does it: the tree belongs to uid 1000 (the image's
# "node" user) while the backup container runs as uid 70, and the compose services drop ALL capabilities, so root
# without CAP_CHOWN cannot chown. Named volumes take no uid/gid mount options either.
#
# MERGE, not wipe. Files in the volume that the bundle does not contain are left alone; same-named files are
# overwritten by the bundle's copy. Deleting user data on the strength of an archive is not something this does on
# its own, so the result can be a tree older in some places than others — stated in
# docs/operations/backup-restore.md rather than left to be discovered.
#
# A format-1 bundle (or a format-2 bundle whose files member was skipped) is a no-op with one line of explanation.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

project="$(_kit_project_name)"
work_vol="${project}_backup_work"
files_vol="${project}_n8n_files"
image="n8nkit/backup:local"

for v in "${work_vol}" "${files_vol}"; do
  if ! docker volume inspect "${v}" >/dev/null 2>&1; then
    warn "n8n files: volume ${v} does not exist — nothing restored (the database restore is unaffected)"
    exit 0
  fi
done
if ! docker image inspect "${image}" >/dev/null 2>&1; then
  warn "n8n files: ${image} is not built — nothing restored; run make up and, if you need the files, restore again"
  exit 0
fi

# The decrypted bundle sits in backup_work/current, written by backup/restore.sh's fetch stage; it is mounted
# read-only here so this can only ever read from it.
result=""
if ! result="$(docker run --rm --user 0:0 --entrypoint sh \
  -v "${work_vol}:/work:ro" -v "${files_vol}:/files" "${image}" -c '
  set -eu
  m=/work/current/manifest.json
  a=/work/current/n8n-files.tar.gz
  if [ ! -s "$m" ]; then echo "SKIP no decrypted bundle to read"; exit 0; fi
  inc=$(jq -r ".n8n_files.included // false" "$m" 2>/dev/null || echo false)
  if [ "$inc" != "true" ]; then
    why=$(jq -r ".n8n_files.reason // empty" "$m" 2>/dev/null || true)
    if [ -z "$why" ]; then why="this bundle carries no files member (format 1)"; fi
    echo "SKIP $why"
    exit 0
  fi
  if [ ! -s "$a" ]; then echo "FAIL the manifest says files are included but n8n-files.tar.gz is not in the bundle"; exit 1; fi
  gzip -dc "$a" | tar -xf - -C /files
  chown -R 1000:1000 /files
  echo "OK $(find /files -type f | wc -l) file(s) in the tree now"
' 2>&1)"; then
  warn "n8n files: could not be restored — ${result:-no output}. The database restore stands; extract the tree by hand from the bundle if you need it"
  exit 0
fi

case "${result}" in
  OK*) ok "n8n files: restored, ${result#OK }" ;;
  SKIP*) info "n8n files: ${result#SKIP }" ;;
  *) warn "n8n files: unexpected result — ${result}" ;;
esac
exit 0
