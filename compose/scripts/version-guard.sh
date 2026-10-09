#!/usr/bin/env bash
# compose/scripts/version-guard.sh "WHAT" — the version guard (lib.sh version_guard) as a command, for the Makefile:
# `make up` and `make restart` run it before they start n8n. Exit 1 with the reason and the way out when starting n8n
# now would apply a new n8n version without make upgrade, run an older n8n on a newer database, or cut into an
# unfinished make upgrade / make rollback. FORCE_VERSION=1 overrides the version comparison (not a pending upgrade).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

[[ -f .env ]] || exit 0   # nothing installed yet: make up's preflight explains what to do
version_guard "${1:-this command}"
