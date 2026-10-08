#!/usr/bin/env bash
# tests/ci/dr-drill.sh — disaster-recovery drill: docs/operations/backup-restore.md "Restore on a new host", end to end,
# against a running stack that has passed `make smoke` (CI smoke job; on a dev box use a SEPARATE checkout with its own
# COMPOSE_PROJECT_NAME and ports — the drill destroys the stack's volumes, .env and age keys).
#   1. data worth recovering (a workflow + a credential, kept by SMOKE_KEEP=1), then make backup-now NAME=dr — the
#      bundle lands in compose/backups, which survives step 3
#   2. keep the recovery key aside      what the operator has in the password manager
#   3. make clean YES=1, delete .env + both age keys   the old host is gone
#   4. make init FORCE=1 + make up      a NEW host: new N8N_ENCRYPTION_KEY, new age keys, an empty n8n
#   5. restore WITHOUT ADOPT_KEY        must stop with exit 3 and change nothing
#   6. make restore … AGE_KEY=<recovery key> ADOPT_KEY=1 YES=1
#   7. the old key is back in .env and the full smoke suite passes: the restored owner logs in, workflows execute,
#      and the restore test decrypts the credential created before the "disaster" with the adopted key
# Found by the 2026-10-08 review: before the fix n8n refused to start after step 6 (it caches the key in n8n_data).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
KIT_DIR="${REPO_DIR}/compose"
# shellcheck source=../../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

step() { printf '\n\033[1m== dr-drill: %s\033[0m\n' "${*}" >&2; }

counts() { compose exec -T postgres psql -U n8n -d n8n -Atc \
  "select (select count(*) from workflow_entity) || ' ' || (select count(*) from credentials_entity)"; }

step "1. backup of the old host (with a workflow and a credential in it)"
SMOKE_KEEP=1 make -s smoke ONLY=03,04,07 >/dev/null
before="$(counts)"
read -r wf cred <<<"${before}"
(( wf >= 1 && cred >= 1 )) || die "expected at least one workflow and one credential before the backup, got '${before}'"
out="$(make -s backup-now NAME=dr 2>&1)" || { printf '%s\n' "${out}" >&2; die "backup-now failed"; }
name="$(awk '$1 == "BACKUP" && $2 == "OK" { print $3 }' <<<"${out}")"
[[ -n "${name}" ]] || die "no BACKUP OK line"
ok "bundle ${name}"

step "2. the recovery key goes to the 'password manager'"
vault="$(mktemp -d)"
trap 'rm -rf "${vault}"' EXIT
install -m 600 secrets/age-recovery-key.txt "${vault}/recovery.txt"
old_key="$(env_get N8N_ENCRYPTION_KEY)"
domain="$(env_get DOMAIN)"
http_port="$(env_get HTTP_PORT)"
https_port="$(env_get HTTPS_PORT)"
# what the operator re-applies on the new host: the same backup targets — plus what a fresh init on THIS machine would
# not reproduce (CI image mirrors, a drill project name)
install -m 600 .env "${vault}/old.env"
mapfile -t keep < <(grep -oE '^([A-Z0-9_]+_IMAGE|COMPOSE_PROJECT_NAME|BACKUP_REMOTES|BACKUP_LOCAL_PATH)=' .env | tr -d = | sort -u)

step "3. the old host is gone"
make -s clean YES=1 >/dev/null
rm -f .env secrets/age-key.txt secrets/age-recovery-key.txt

step "4. a new host: make init + make up"
make -s init DOMAIN="${domain}" HTTP_PORT="${http_port:-80}" HTTPS_PORT="${https_port:-443}" CI=1 >/dev/null
for k in "${keep[@]}"; do
  env_set "${k}" "$(env_get "${k}" "${vault}/old.env")"
done
[[ "$(env_get N8N_ENCRYPTION_KEY)" != "${old_key}" ]] || die "init did not generate a new key"
make -s up >/dev/null
ok "new host is up with a new N8N_ENCRYPTION_KEY and new age keys"

step "5. restore without ADOPT_KEY must refuse and change nothing"
rc=0
BACKUP="${name}" AGE_KEY="${vault}/recovery.txt" YES=1 scripts/restore.sh || rc=$?
[[ "${rc}" == "3" ]] || die "expected exit 3 (key mismatch), got ${rc}"
scripts/status.sh >/dev/null || die "the stack is not healthy after the refused restore"
ok "refused with exit 3, stack still healthy"

step "6. restore with the recovery key and ADOPT_KEY=1"
make -s restore BACKUP="${name}" AGE_KEY="${vault}/recovery.txt" ADOPT_KEY=1 YES=1
[[ "$(env_get N8N_ENCRYPTION_KEY)" == "${old_key}" ]] || die "the old N8N_ENCRYPTION_KEY was not adopted into .env"
after="$(counts)"
[[ "${after}" == "${before}" ]] || die "restored '${after}' (workflows credentials), the old host had '${before}'"
ok "old key adopted; ${before% *} workflow(s) and ${before#* } credential(s) back"

step "7. the restored instance works"
make -s smoke
make -s doctor
ok "disaster-recovery drill passed (${name})"
