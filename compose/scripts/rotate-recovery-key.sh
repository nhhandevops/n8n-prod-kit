#!/usr/bin/env bash
# compose/scripts/rotate-recovery-key.sh — `make rotate-recovery-key`: replace the offline age recovery key.
#
# Every backup is encrypted to two age recipients: this host's key (secrets/age-key.txt, used by the automatic
# restore test) and the offline recovery key, whose private half belongs in a password manager. Replacing that
# recovery key used to be impossible through the kit: `make init FORCE=1` deliberately KEEPS a detached recovery
# key's public half, because dropping it would leave every existing bundle openable only with this host's key.
# So a key that had to be replaced — exposed in a screenshot, lost, or simply old — could only be changed by
# editing .env by hand (HANDOFF §5). This is that procedure, with the checks it needs.
#
# What it can and cannot do. Rotation changes which key FUTURE bundles are encrypted to. It cannot re-encrypt a
# bundle that already exists: those stay readable with the OLD recovery key (and with this host's key), and this
# script says how many there are so that the old password-manager entry is kept as long as they matter.
#
# KEEP_OLD=1 also keeps the old public key as an extra recipient on new bundles
# (BACKUP_AGE_RECOVERY_PUBLIC_KEY_PREVIOUS). That is for rotating a key you LOST, where the old key is no threat
# and one more recipient is one more way back in. It is OFF by default, because the usual reason to rotate is the
# opposite one — the old key leaked — and then encrypting new bundles to it hands the next backup to whoever has it.
#
# Always interactive: YES=1 / CI=1 are ignored, because it prints a secret and asks for it back.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

file=secrets/age-recovery-key.txt
keep_old="${KEEP_OLD:-0}"

[[ -f .env ]] || die "no .env — run make init first" 2
if ! (exec 3</dev/tty) 2>/dev/null; then
  die "make rotate-recovery-key needs a terminal (it asks you to paste the new key back) — run it in an interactive shell"
fi

# age-keygen on the host, else the kit's backup image (which carries it) — the same fallback
# detach-recovery-key.sh uses. Two single-purpose helpers: the container cannot write to the host path, so
# generation goes through stdout and the caller owns the redirect.
keygen_new() {   # keygen_new FILE — write a fresh identity to FILE
  if command -v age-keygen >/dev/null 2>&1; then
    age-keygen -o "${1}" >/dev/null 2>&1
  else
    docker run --rm --network none --user "$(id -u):$(id -g)" --entrypoint age-keygen \
      n8nkit/backup:local >"${1}" 2>/dev/null
  fi
}
keygen_pub() {   # keygen_pub FILE — the age public key of an identity file
  if command -v age-keygen >/dev/null 2>&1; then
    age-keygen -y "${1}" 2>/dev/null
  else
    docker run --rm --network none --user "$(id -u):$(id -g)" --entrypoint age-keygen \
      -v "${1}:/k.txt:ro,z" n8nkit/backup:local -y /k.txt 2>/dev/null
  fi
}

old_pub="$(env_get BACKUP_AGE_RECOVERY_PUBLIC_KEY)"
if [[ -z "${old_pub}" ]]; then
  die "BACKUP_AGE_RECOVERY_PUBLIC_KEY is empty in .env — there is no recovery key to rotate. make init FORCE=1 generates one (it keeps your other secrets)" 2
fi

# --- what the bundles that already exist will mean afterwards --------------------------------------------------------
# Counted on the local target only: it is the one this script can read without the stack, credentials or network.
# Remote targets hold the same bundles, so this is a lower bound and the conclusion is the same for every target.
old_bundles=0
oldest=""
if [[ -d "${KIT_DIR}/backups" ]]; then
  while IFS= read -r b; do
    old_bundles=$((old_bundles + 1))
    [[ -z "${oldest}" ]] && oldest="$(basename "${b}")"
  done < <(find "${KIT_DIR}/backups" -type f -name 'n8n-*.tar.age' 2>/dev/null | sort)
fi
if (( old_bundles > 0 )); then
  bundle_note="On /backups/local there are ${old_bundles} such bundle(s), oldest ${oldest}."
else
  bundle_note="No bundles found on /backups/local — remote targets may still hold some."
fi
if [[ "${keep_old}" == "1" ]]; then
  mode_note="KEEP_OLD=1: the old public key stays an extra recipient on NEW bundles. Only do this for a key you LOST."
else
  mode_note="The old key will NOT receive new bundles. If you are rotating because it leaked, that is what you want."
fi

banner_red "ROTATING THE OFFLINE RECOVERY KEY" "" \
  "After this, new backups are encrypted to the NEW key. Bundles that already exist are NOT re-encrypted:" \
  "they stay openable with the OLD recovery key, and with this host's key (secrets/age-key.txt)." \
  "${bundle_note}" "" "${mode_note}"
printf 'Type "rotate" to continue: ' >&2
answer=''
read -r answer </dev/tty || answer=''
[[ "${answer}" == "rotate" ]] || die "nothing changed" 0

# --- generate the new pair -------------------------------------------------------------------------------------------
# A recovery key file still on this host is the un-detached case: keep it under a dated name rather than destroying
# the only copy of a key the existing bundles need.
if [[ -f "${file}" ]]; then
  kept="secrets/age-recovery-key.replaced-$(date -u +%Y%m%dT%H%M%SZ).txt"
  mv "${file}" "${kept}"
  chmod 600 "${kept}"
  info "the previous key file was still on this host — kept as ${kept} (it opens the bundles above; put it in your password manager, then shred it)"
fi

umask 077
keygen_new "${file}" || die "age-keygen failed — install age, or make sure Docker is running (the backup image carries age-keygen)"
chmod 600 "${file}"
new_pub="$(keygen_pub "${KIT_DIR}/${file}" || true)"
if [[ ! "${new_pub}" =~ ^age1[0-9a-z]{20,}$ ]]; then
  rm -f "${file}"
  die "the generated key did not yield a usable public key — nothing in .env was changed"
fi
if [[ "${new_pub}" == "${old_pub}" ]]; then
  rm -f "${file}"
  die "age-keygen produced the key already in use — run this again; nothing was changed"
fi

# --- paste-back check, while the original still exists ---------------------------------------------------------------
banner_red "NEW RECOVERY KEY — it is in this file, at mode 600:" "" \
  "    ${KIT_DIR}/${file}" "" \
  "Open it, copy the AGE-SECRET-KEY-1… line into your password manager (entry n8nkit/age-recovery-key)," \
  "then come back here. Keep the OLD entry too until the bundles above leave retention — they need it." "" \
  "The key is deliberately NOT printed on this screen: a terminal keeps scrollback, and a screen like this" \
  "is how four separate secrets in this project's history ended up in a chat or a screenshot."
printf 'Now paste the NEW key back FROM the password manager (input hidden), then Enter: ' >&2
pasted=''
read -rs pasted </dev/tty || pasted=''
printf '\n' >&2
pasted="${pasted//[[:space:]]/}"
check="$(mktemp "${KIT_DIR}/secrets/.rotate-check.XXXXXX")"
trap 'rm -f "${check}"' EXIT
printf '%s\n' "${pasted}" >"${check}"
pasted_pub="$(keygen_pub "${check}" || true)"
rm -f "${check}"
unset pasted
if [[ "${pasted_pub}" != "${new_pub}" ]]; then
  die "the pasted key is not the new recovery key (truncated or mistyped copy?) — ${file} is still here and .env is UNCHANGED, so nothing is lost: fix the password-manager entry and run this again"
fi
ok "the copy in your password manager is the new recovery key"

# --- swap it in .env -------------------------------------------------------------------------------------------------
env_set BACKUP_AGE_RECOVERY_PUBLIC_KEY "${new_pub}"
env_set BACKUP_AGE_RECOVERY_ROTATED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "${keep_old}" == "1" ]]; then
  env_set BACKUP_AGE_RECOVERY_PUBLIC_KEY_PREVIOUS "${old_pub}"
  ok "new bundles go to: this host's key, the new recovery key, and the previous one (KEEP_OLD=1)"
else
  env_set BACKUP_AGE_RECOVERY_PUBLIC_KEY_PREVIOUS ""
  ok "new bundles go to: this host's key and the new recovery key only"
fi
ok "BACKUP_AGE_RECOVERY_PUBLIC_KEY is now ${new_pub}"

# --- what the operator must still do ---------------------------------------------------------------------------------
info "next, in this order:"
info "  1. make up                       the backup sidecar keeps the OLD recipient until it is recreated"
info "  2. make backup-now NAME=rotated  the first bundle encrypted to the new key"
info "  3. prove the new key opens it, BEFORE the private half leaves this host:"
info "       age -d -i ${file} <newest bundle under backups/manual/> | tar -tf -"
info "     it must list db.dump, key-bundle.env and manifest.json"
info "  4. make detach-recovery-key      shred the new private half once the password manager has it"
info "  5. make doctor                   confirms the rotation and that the sidecar runs the new key"
if (( old_bundles > 0 )); then
  info "until those ${old_bundles} older bundle(s) age out of retention (BACKUP_RETENTION_DAILY_DAYS / _MONTHLY_DAYS), keep the OLD recovery key in your password manager: nothing else opens them once this host is gone"
fi
if [[ "${keep_old}" != "1" ]]; then
  info "if the old key leaked, treat those older bundles as readable by whoever holds it — each carries a copy of N8N_ENCRYPTION_KEY, and rotating that is a separate job (docs/operations/backup-restore.md)"
fi
