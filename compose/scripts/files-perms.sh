#!/usr/bin/env bash
# compose/scripts/files-perms.sh — make the n8n_files volume writable by n8n (uid 1000, the image's "node" user).
#
# /home/node/.n8n-files is the 2.x default N8N_RESTRICT_FILE_ACCESS_TO tree: the ONLY place the Read/Write Files node
# is allowed to write. Unlike /home/node/.n8n, that directory does not exist in the n8n image, so Docker has nothing
# to copy ownership from and creates the mount point as root:root 0755. n8n then runs as uid 1000 and every write
# fails with EACCES — the node is effectively broken until the directory is chowned. Named volumes accept no
# uid/gid mount options, so a throw-away root container fixes it once; new files inherit uid 1000 from n8n itself.
#
# Runs AFTER `compose up`, not before: on a first install the volume does not exist until Compose creates it, and
# `docker run -v <name>:` would create it without Compose's project labels. Chowning while the containers run is
# safe — it is the same directory on the host, so the new ownership applies immediately, with no restart.
# Plain `docker run` on purpose: the compose services drop ALL capabilities and root without CAP_CHOWN cannot chown
# (same reason as backup-perms.sh). Only the directory itself, never recursively.
# Idempotent and quiet when there is nothing to fix; called by `make up`.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

project="$(_kit_project_name)"
volume="${project}_n8n_files"

if ! docker volume inspect "${volume}" >/dev/null 2>&1; then
  # Nothing has been started yet; Compose creates the volume on `up`, and the next `make up` fixes it.
  exit 0
fi

# The backup image is local, already built by `make up`, and needs no registry access — it is used here only as a
# shell with chown, exactly as backup-perms.sh uses it for the backup volumes.
image="n8nkit/backup:local"
if ! docker image inspect "${image}" >/dev/null 2>&1; then
  compose build --quiet backup
fi

result="$(docker run --rm --user 0:0 --entrypoint sh -v "${volume}:/v" "${image}" -c '
  owner=$(stat -c %u /v 2>/dev/null || echo unknown)
  if [ "$owner" = "1000" ]; then
    echo already-ok
  else
    chown 1000:1000 /v && chmod 0755 /v && echo "fixed-from-${owner}"
  fi
' 2>/dev/null || true)"

case "${result}" in
  already-ok) ;;
  fixed-from-*)
    ok "n8n files volume ${volume}: owner ${result#fixed-from-} -> 1000 (the Read/Write Files node can write again)"
    ;;
  *)
    warn "could not check or fix the ownership of ${volume} — workflows writing to /home/node/.n8n-files may fail with EACCES (make doctor explains)"
    ;;
esac
