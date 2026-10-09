#!/usr/bin/env bash
# 01-health — every expected service is running and healthy within 180 s; the worker count matches WORKER_REPLICAS
# and every worker has its runner sidecar (TC-003).
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

mapfile -t services < <(compose config --services)
# SMOKE_CORE_ONLY=1 (make upgrade / make rollback): judge n8n and what it needs, not the monitoring profile — a slow
# Grafana must not fail an n8n upgrade (smoke 09 checks monitoring on its own)
if [[ "${SMOKE_CORE_ONLY:-}" == "1" ]]; then
  mapfile -t services < <(printf '%s\n' "${services[@]}" | grep -E '^(n8n-.*|caddy|postgres|valkey|backup)$')
fi

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

# What runs is what versions.env pins: the image's version label and digest of every n8n process (the tag in
# Config.Image would follow a stray N8N_VERSION in the environment; make upgrade relies on this check).
pinned="$(env_get N8N_VERSION "${KIT_DIR}/versions.env")"
version_lock_ok() {
  local cid svc v d project
  project="$(_kit_project_name)"
  while read -r cid svc; do
    [[ "${svc}" == n8n-* ]] || continue
    d="$(docker inspect --format '{{.Config.Image}}' "${cid}")"
    d="${d##*@}"
    if [[ "${svc}" == *-runners ]]; then
      [[ "${d}" == "$(env_get RUNNERS_DIGEST "${KIT_DIR}/versions.env")" ]] || { fail "  ${svc}: runners digest ${d:0:19}…"; return 1; }
    else
      v="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${cid}")"
      [[ "${v}" == "${pinned}" && "${d}" == "$(env_get N8N_DIGEST "${KIT_DIR}/versions.env")" ]] ||
        { fail "  ${svc}: n8n ${v:-?} ${d:0:19}…"; return 1; }
    fi
  done < <(docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.ID}} {{.Label "com.docker.compose.service"}}')
}
check "every n8n process runs the pinned n8n ${pinned} (version label + digest)" version_lock_ok
finish
