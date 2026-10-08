#!/usr/bin/env bash
# compose/scripts/backup-perms.sh — let the backup container (uid 70, the postgres user) read the age key and write the
# local backup directories, without sudo and without locking the operator out:
#   secrets/age-key.txt                  -> owner 70, group = the operator's group, mode 0440
#   backups/ (+ BACKUP_LOCAL_PATH if set) -> owner 70, group = the operator's group, mode 2775 (setgid: new files keep
#                                           the group, so the operator can still list and delete backups)
# Runs as root inside a throw-away container of the backup image (the Docker daemon does the chown). Idempotent;
# called by `make up`, `make backup-now`, `make restore`, `make restore-test`.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

image="n8nkit/backup:local"
if ! docker image inspect "${image}" >/dev/null 2>&1; then
  compose build --quiet backup
fi
if [[ ! -f secrets/age-key.txt ]]; then
  die "secrets/age-key.txt is missing — run make init (it creates the age keys)"
fi
mkdir -p backups
gid="$(id -g)"
mounts=(-v "${KIT_DIR}/secrets:/k/secrets:z" -v "${KIT_DIR}/backups:/k/backups:z")
targets="/k/backups"
external="$(env_get BACKUP_LOCAL_PATH)"
if [[ -n "${external}" ]]; then
  if [[ ! -d "${external}" ]]; then
    die "BACKUP_LOCAL_PATH=${external} is not a directory — mount the disk first (preflight checks this too)"
  fi
  mounts+=(-v "${external}:/k/external:z")
  targets="${targets} /k/external"
fi
# The named volumes /state and /work: a NEW volume inherits uid 70 from the image's mount points; one created before
# that (or by an older image) is root-owned and is fixed here. Only volumes that already exist are mounted — `docker
# run -v name:` would otherwise create them without Compose's labels. (Plain docker run on purpose: the compose
# service drops ALL capabilities, and root without CAP_CHOWN cannot chown.)
project="$(_kit_project_name)"
volume_dirs=''
for v in backup_state backup_work; do
  if docker volume inspect "${project}_${v}" >/dev/null 2>&1; then
    mounts+=(-v "${project}_${v}:/k/vol/${v}")
    volume_dirs="${volume_dirs} /k/vol/${v}"
  fi
done
docker run --rm --user 0:0 --entrypoint sh "${mounts[@]}" "${image}" -c "
  set -e
  chown 70:${gid} /k/secrets/age-key.txt && chmod 0440 /k/secrets/age-key.txt
  for d in ${targets}; do chown 70:${gid} \"\$d\" && chmod 2775 \"\$d\"; done
  for d in ${volume_dirs}; do chown 70:70 \"\$d\"; done
" || die "could not fix backup permissions (is Docker running?)"
