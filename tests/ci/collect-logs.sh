#!/usr/bin/env bash
# tests/ci/collect-logs.sh [DIR] — gather everything needed to debug a failed CI run into DIR (default: artifacts/):
# status table, doctor report, per-service logs and the resolved compose model with secrets masked.
# Never fails (it runs after a failure); never copies .env, secrets/ or compose/.smoke/.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
out="${1:-${REPO_DIR}/artifacts}"
mkdir -p "${out}"
cd "${REPO_DIR}" || exit 0

make -C compose status >"${out}/status.txt" 2>&1
make -C compose doctor >"${out}/doctor.txt" 2>&1
KIT_DIR="${REPO_DIR}/compose"
export KIT_DIR
# shellcheck source=../../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"
compose ps -a >"${out}/ps.txt" 2>&1
# make upgrade / rollback state (versions, digests, backup names, phases — no secrets)
if [[ -d "${KIT_DIR}/.upgrade" ]]; then
  mkdir -p "${out}/upgrade"
  cp -r "${KIT_DIR}/.upgrade/." "${out}/upgrade/" 2>/dev/null
  rm -f "${out}/upgrade/lock"
fi
compose logs --no-color --timestamps >"${out}/stack.log" 2>&1
# the resolved model, with every value of a *PASSWORD* / *KEY* / *TOKEN* / *HASH* variable replaced
compose config 2>/dev/null |
  sed -E 's/^([[:space:]]*[A-Z0-9_]*(PASSWORD|KEY|TOKEN|HASH)[A-Z0-9_]*:).*/\1 <masked>/' >"${out}/compose-config.yml"
ls -la "${out}"
exit 0
