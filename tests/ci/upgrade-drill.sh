#!/usr/bin/env bash
# tests/ci/upgrade-drill.sh — make upgrade (TC-014) and make rollback (TC-015) end to end, against a stack that runs an
# OLDER n8n than the repository pins: CI pins the previous minor (PIN_ONLY="N8N RUNNERS" make pin N8N_VERSION=…) before
# tests/ci/up.sh. On a dev box use a SEPARATE checkout with its own COMPOSE_PROJECT_NAME and ports — the drill restores
# the stack's database.
#   1. data worth keeping (owner, API key, workflows) — their ids are remembered
#   2. versions.env back to the repository's pin (the "git pull brought a new pin" path): make up must refuse
#   3. make upgrade SMOKE_FAIL=1 — upgrades for real (backup, migrations, new images), its verification creates a
#      workflow under the new version, then fails on purpose: PHASE=failed, the pre-upgrade bundle exists, make up
#      refuses, doctor reports it
#   4. make rollback — a migration ran, so it restores the pre-upgrade backup: the old version runs again, every
#      workflow from step 1 is there and the one written under the new version is gone, versions.env pins the old
#      version again, smoke passes
#   5. make upgrade N8N_VERSION=<pin> (the explicit path) — succeeds with the data intact; a second make upgrade has
#      nothing to do and keeps the rollback point; ROLLBACK_MODE=images must refuse (a migration ran); smoke + doctor
# SMOKE_KEEP=1 everywhere: the smoke suite's cleanup would otherwise delete the very workflows the drill follows.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
KIT_DIR="${REPO_DIR}/compose"
# shellcheck source=../../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"
export SMOKE_KEEP=1

step() { printf '\n\033[1m== upgrade-drill: %s\033[0m\n' "${*}" >&2; }
workflow_ids() { kit_psql 'select id from workflow_entity order by id'; }
state() { env_get "${1}" "${UPGRADE_STATE}"; }
# all_present "ids" — every id of the list still exists; none_present "ids" — none does
all_present() {
  local id now
  local -a ids=()
  read -r -a ids <<<"${1}"
  now="$(workflow_ids)"
  for id in "${ids[@]}"; do
    grep -qxF "${id}" <<<"${now}" || return 1
  done
}
none_present() {
  local id now
  local -a ids=()
  read -r -a ids <<<"${1}"
  now="$(workflow_ids)"
  for id in "${ids[@]}"; do
    if grep -qxF "${id}" <<<"${now}"; then
      return 1
    fi
  done
}

from_v="$(image_version_of n8n-main)"
[[ -n "${from_v}" ]] || die "no running n8n-main — bring the stack up at the older version first"

step "1. data worth keeping (n8n ${from_v})"
make -s smoke ONLY=01,03,04,05 >/dev/null
kept="$(workflow_ids | tr '\n' ' ')"
[[ -n "${kept// /}" ]] || die "expected at least one workflow before the upgrade"
ok "n8n ${from_v} with workflows: ${kept}"

step "2. the repository's pin is newer: make up must refuse to apply it"
git -C "${REPO_DIR}" checkout -- compose/versions.env
to_v="$(env_get N8N_VERSION versions.env)"
if [[ "${to_v}" == "${from_v}" ]] || ! version_ge "${to_v}" "${from_v}"; then
  die "the repository pins ${to_v}, not newer than the running ${from_v}"
fi
out="$(make -s up 2>&1)" && die "make up applied n8n ${to_v} without make upgrade"
grep -q "make upgrade" <<<"${out}" || { printf '%s\n' "${out}" >&2; die "make up failed, but not with the version guard"; }
[[ "$(image_version_of n8n-main)" == "${from_v}" ]] || die "make up changed the running version"
ok "make up refused (${from_v} runs, ${to_v} pinned)"

step "3. make upgrade with a forced verification failure"
rc=0
make -s upgrade YES=1 SMOKE_FAIL=1 || rc=$?
(( rc != 0 )) || die "make upgrade SMOKE_FAIL=1 succeeded"
[[ "$(state PHASE)" == "failed" && "$(state FAILED_STEP)" == "verify" ]] ||
  die "expected PHASE=failed FAILED_STEP=verify, got $(state PHASE) / $(state FAILED_STEP)"
[[ "$(image_version_of n8n-main)" == "${to_v}" ]] || die "n8n-main does not run ${to_v} after the upgrade"
bundle="$(state BACKUP_NAME)"
[[ -f "backups/pre-upgrade/${bundle}.tar.age" ]] || die "pre-upgrade bundle ${bundle} not in compose/backups/pre-upgrade/"
[[ "$(state MIGRATIONS_BEFORE)" != "$(db_migration_mark)" ]] || die "no migration ran between ${from_v} and ${to_v} — this drill needs one"
written_after="$(comm -13 <(tr ' ' '\n' <<<"${kept}" | sed '/^$/d' | sort) <(workflow_ids | sort) | tr '\n' ' ')"
[[ -n "${written_after// /}" ]] || die "the verification under ${to_v} created no workflow (smoke 04 with SMOKE_KEEP=1 should)"
out="$(make -s up 2>&1)" && die "make up ran during a failed upgrade"
grep -q "unfinished" <<<"${out}" || { printf '%s\n' "${out}" >&2; die "make up failed, but not because of the pending upgrade"; }
out="$(make -s doctor 2>&1)" && die "doctor passed during a failed upgrade"
grep -q "FAILED at step verify" <<<"${out}" || { printf '%s\n' "${out}" >&2; die "doctor does not report the failed upgrade"; }
ok "upgraded to ${to_v}, verification failed on purpose; backup ${bundle}; written under ${to_v}: ${written_after}"

step "4. make rollback restores the pre-upgrade backup"
make -s rollback YES=1
[[ "$(image_version_of n8n-main)" == "${from_v}" ]] || die "n8n-main does not run ${from_v} after the rollback"
[[ "$(env_get N8N_VERSION versions.env)" == "${from_v}" ]] || die "versions.env does not pin ${from_v} after the rollback"
[[ ! -f "${UPGRADE_STATE}" ]] || die "the rollback left an active state file"
grep -q '^ROLLBACK_MODE=restore' "${UPGRADE_DIR}"/history/*-rolled-back.env || die "the rollback did not restore the backup"
all_present "${kept}" || die "a workflow from before the upgrade is missing after the rollback"
none_present "${written_after}" || die "a workflow written under ${to_v} survived the rollback"
make -s smoke ONLY=01,02,04,05,06
ok "n8n ${from_v} again with the pre-upgrade data; smoke passes"

step "5. make upgrade N8N_VERSION=${to_v}"
make -s upgrade YES=1 N8N_VERSION="${to_v}"
[[ "$(state PHASE)" == "done" ]] || die "PHASE=$(state PHASE) after a successful upgrade"
[[ "$(image_version_of n8n-main)" == "${to_v}" ]] || die "n8n-main does not run ${to_v}"
all_present "${kept}" || die "a workflow from before the upgrade is missing"
out="$(make -s upgrade YES=1 2>&1)"
grep -q "nothing to upgrade" <<<"${out}" || { printf '%s\n' "${out}" >&2; die "a second make upgrade did not say 'nothing to upgrade'"; }
[[ "$(state PHASE)" == "done" ]] || die "a no-op make upgrade threw away the rollback point"
out="$(ROLLBACK_MODE=images make -s rollback YES=1 2>&1)" && die "an image-only rollback over migrations was allowed"
grep -q "must not run on it" <<<"${out}" || { printf '%s\n' "${out}" >&2; die "image-only rollback refused for the wrong reason"; }
make -s smoke
make -s doctor
ok "upgrade drill passed: ${from_v} -> ${to_v} (failed on purpose) -> rollback -> ${to_v}; pre-upgrade bundle ${bundle}"
