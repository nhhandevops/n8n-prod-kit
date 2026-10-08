#!/usr/bin/env bash
# compose/scripts/detach-recovery-key.sh — `make detach-recovery-key`: move the offline recovery key off this host.
#
# Every backup is encrypted to two age recipients: the host key (secrets/age-key.txt, used by the automatic restore
# test) and the recovery key. The recovery PRIVATE key exists so that backups can be restored when this host is gone —
# which only works if it does NOT live on this host. This prints it once, asks for confirmation that it is stored in a
# password manager, then shreds the file. The public half stays in .env, so new backups remain recoverable with it.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

file=secrets/age-recovery-key.txt
if [[ ! -f "${file}" ]]; then
  ok "no ${file} on this host — the recovery key is already detached"
  exit 0
fi
banner_red "RECOVERY KEY — copy everything between the lines into your password manager (entry n8nkit/age-recovery-key)" "" \
  "$(cat "${file}")" "" "Without it, backups cannot be restored on another host once this one is lost."
confirm "Stored it in the password manager? The file on this host will be shredded" || die "kept ${file} — nothing changed" 0
if command -v shred >/dev/null 2>&1; then
  shred -u "${file}"
else
  rm -f "${file}"
fi
ok "recovery key removed from this host (public key stays in .env: BACKUP_AGE_RECOVERY_PUBLIC_KEY)"
