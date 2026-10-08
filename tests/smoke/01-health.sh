#!/usr/bin/env bash
# 01-health — every expected service is running and healthy within 180 s; the worker count matches WORKER_REPLICAS
# and every worker has its runner sidecar (TC-003).
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

mapfile -t services < <(compose config --services)

all_healthy() {
  local svc h
  for svc in "${services[@]}"; do
    h="$(service_health "${svc}")"
    if [[ "${h}" != "healthy" && "${h}" != "none" ]]; then
      return 1
    fi
  done
}
check "all ${#services[@]} services running and healthy (<= 180 s)" wait_for 180 "all services healthy" all_healthy
for svc in "${services[@]}"; do
  h="$(service_health "${svc}")"
  if [[ "${h}" != "healthy" && "${h}" != "none" ]]; then
    fail "  ${svc}: ${h}"
  fi
done

expected="$(env_get WORKER_REPLICAS)"
expected="${expected:-2}"
workers="$(printf '%s\n' "${services[@]}" | grep -cE '^n8n-worker-[0-9]+$' || true)"
runners="$(printf '%s\n' "${services[@]}" | grep -cE '^n8n-worker-[0-9]+-runners$' || true)"
check "worker count ${workers} = WORKER_REPLICAS ${expected}" test "${workers}" -eq "${expected}"
check "every worker has a runner sidecar (${runners} sidecars)" test "${runners}" -eq "${workers}"
finish
