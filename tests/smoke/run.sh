#!/usr/bin/env bash
# tests/smoke/run.sh — end-to-end smoke suite against the running stack (`make smoke [ONLY=04,05]`).
#
# Runs tests/smoke/NN-*.sh in order and stops at the first failing script (later scripts build on earlier ones:
# 04 creates the workflow that 05 inspects). ONLY=04,05 limits the run to those numbers. Prints a PASS/FAIL table,
# then removes the "kit-smoke-*" workflows it created (SMOKE_KEEP=1 keeps them for debugging).
# Exit 0 only when every selected script passed.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "${SMOKE_DIR}/lib.sh"

only="${ONLY:-}"
if [[ "${1:-}" == "--only" ]]; then
  only="${2:-}"
fi

cleanup() {
  if [[ "${SMOKE_KEEP:-}" != "1" && -s "${STATE_DIR}/api-key" ]]; then
    delete_smoke_workflows || true
    cred="$(state_get CRED_ID)"
    if [[ -n "${cred}" ]]; then
      api DELETE "/api/v1/credentials/${cred}" || true
      state_set CRED_ID ""
    fi
  fi
}
trap cleanup EXIT

info "smoke suite against ${BASE_URL} (TLS_MODE=${TLS_MODE})"
declare -a rows=()
failed=0
for script in "${SMOKE_DIR}"/[0-9][0-9]-*.sh; do
  name="$(basename "${script}" .sh)"
  number="${name%%-*}"
  if [[ -n "${only}" && ",${only}," != *",${number},"* ]]; then
    continue
  fi
  log ""
  log "── ${name}"
  start="${SECONDS}"
  if bash "${script}"; then
    rows+=("PASS  ${name}  ($((SECONDS - start))s)")
  else
    rows+=("FAIL  ${name}  ($((SECONDS - start))s)")
    failed=1
    break
  fi
done

log ""
log "── result"
if (( ${#rows[@]} == 0 )); then
  die "no smoke script matched ONLY=${only}"
fi
for row in "${rows[@]}"; do
  log "  ${row}"
done
if (( failed )); then
  die "smoke: FAILED — see the [FAIL] lines above (make logs SERVICE=<name> SINCE=10m)"
fi
ok "smoke: all selected scripts passed"
