#!/usr/bin/env bash
# compose/scripts/version-guard.sh "WHAT" [--pending-only SERVICE] — the version guard (lib.sh version_guard) as a
# command, for the Makefile. `make up` runs the full guard before it starts n8n: exit 1 with the reason and the way out
# when that would apply a new n8n version without make upgrade, run an older n8n on a newer database, or cut into an
# unfinished make upgrade / make rollback. `make restart SERVICE=x` runs only the last check, and only for n8n services
# (a restart never changes an image; restarting caddy or grafana during a failed upgrade is fine).
# FORCE_VERSION=1 overrides the version comparison (never a pending upgrade).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

[[ -f .env ]] || exit 0   # nothing installed yet: make up's preflight explains what to do
what="${1:-this command}"
mode="${2:-}"
if [[ "${mode}" == "--pending-only" && -n "${3:-}" && "${3}" != n8n-* ]]; then
  exit 0
fi
version_guard "${what}" "${mode}"
