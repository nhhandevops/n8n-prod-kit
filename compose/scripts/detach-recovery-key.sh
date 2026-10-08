#!/usr/bin/env bash
# compose/scripts/detach-recovery-key.sh — `make detach-recovery-key`: move the offline recovery key off this host.
#
# Every backup is encrypted to two age recipients: the host key (secrets/age-key.txt, used by the automatic restore
# test) and the recovery key. The recovery PRIVATE key exists so that backups can be restored when this host is gone —
# which only works if it does NOT live on this host. This prints it once, asks you to paste it back FROM the password
# manager (so a truncated or mistyped copy is caught while the original still exists), checks that it is the key
# .env encrypts to, and only then shreds the file. The public half stays in .env, so new backups remain recoverable.
# Always interactive: YES=1 / CI=1 are ignored here — shredding the only copy must never happen unattended.
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
if ! (exec 3</dev/tty) 2>/dev/null; then
  die "make detach-recovery-key needs a terminal (it asks you to paste the key back) — run it in an interactive shell"
fi

pub_of() {   # pub_of FILE — the age public key of an identity file (host age-keygen, else the backup image's)
  if command -v age-keygen >/dev/null 2>&1; then
    age-keygen -y "${1}" 2>/dev/null
  else
    docker run --rm --network none --user "$(id -u):$(id -g)" --entrypoint age-keygen -v "${1}:/k.txt:ro,z" \
      n8nkit/backup:local -y /k.txt 2>/dev/null
  fi
}
expected="$(env_get BACKUP_AGE_RECOVERY_PUBLIC_KEY)"
file_pub="$(pub_of "${KIT_DIR}/${file}" || true)"
if [[ -z "${file_pub}" ]]; then
  die "could not read the public key of ${file} (is it a valid age key? is Docker running?)"
fi
if [[ "${file_pub}" != "${expected}" ]]; then
  die "${file} does not belong to BACKUP_AGE_RECOVERY_PUBLIC_KEY in .env (${expected:-empty}) — fix .env first (make doctor shows the right value); nothing was shredded"
fi

banner_red "RECOVERY KEY — copy the AGE-SECRET-KEY-1… line into your password manager (entry n8nkit/age-recovery-key)" "" \
  "$(grep -E '^AGE-SECRET-KEY-' "${file}")" "" "Without it, backups cannot be restored on another host once this one is lost."
printf 'Now paste the key back FROM the password manager (input hidden), then Enter: ' >&2
pasted=''
read -rs pasted </dev/tty || pasted=''
printf '\n' >&2
pasted="${pasted//[[:space:]]/}"
check="$(mktemp "${KIT_DIR}/secrets/.recovery-check.XXXXXX")"
trap 'rm -f "${check}"' EXIT
printf '%s\n' "${pasted}" >"${check}"
pasted_pub="$(pub_of "${check}" || true)"
rm -f "${check}"
unset pasted
if [[ "${pasted_pub}" != "${expected}" ]]; then
  die "the pasted key is not the recovery key (truncated or mistyped copy?) — fix the password-manager entry and run this again; nothing was shredded"
fi
ok "the copy in your password manager is the recovery key"
printf 'Shred %s from this host now? Type "shred": ' "${file}" >&2
answer=''
read -r answer </dev/tty || answer=''
[[ "${answer}" == "shred" ]] || die "kept ${file} — nothing changed" 0
if command -v shred >/dev/null 2>&1; then
  shred -u "${file}"
else
  rm -f "${file}"
fi
ok "recovery key removed from this host (public key stays in .env: BACKUP_AGE_RECOVERY_PUBLIC_KEY)"
