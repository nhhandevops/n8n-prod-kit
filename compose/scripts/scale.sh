#!/usr/bin/env bash
# compose/scripts/scale.sh N — change the number of workers (`make scale-workers N=4`, test case TC-007).
#
# Workers come in pairs: n8n-worker-N + n8n-worker-N-runners (the Code-node sandbox is 1:1 with its worker), so the
# kit does not use `compose up --scale`; instead WORKER_REPLICAS is written to .env, render.sh regenerates
# compose.scale.yml (worker-3..N fully expanded; for N=1 it parks the static n8n-worker-2 pair behind a Compose profile),
# and `compose up --wait --remove-orphans` converges the stack. Finally every expected worker and sidecar is verified
# healthy and the Prometheus target list is refreshed. 1 <= N <= 16.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

n="${1:-${N:-}}"
if [[ ! "${n}" =~ ^[0-9]+$ ]] || (( n < 1 || n > 16 )); then
  die "usage: make scale-workers N=<1..16>   (got '${n:-}')" 2
fi
if [[ ! -f .env ]]; then
  die ".env not found — run 'make init DOMAIN=<your-domain>' first"
fi

current="$(env_get WORKER_REPLICAS)"
info "workers: ${current:-2} -> ${n}"
env_set WORKER_REPLICAS "${n}"
"${KIT_DIR}/scripts/render.sh"

if (( n == 1 )); then
  # n8n-worker-2 is static in docker-compose.yml; render.sh just parked it behind the "parked" profile, so Compose no
  # longer manages it — remove the pair explicitly (their containers would otherwise keep running as orphans).
  compose --profile parked rm -sf n8n-worker-2-runners n8n-worker-2 >/dev/null 2>&1 || true
fi

info "converging the stack"
compose up -d --wait --wait-timeout 240 --remove-orphans

bad=0
for (( i = 1; i <= n; i++ )); do
  for svc in "n8n-worker-${i}" "n8n-worker-${i}-runners"; do
    h="$(service_health "${svc}")"
    if [[ "${h}" == "healthy" ]]; then ok "${svc}: healthy"; else fail "${svc}: ${h}"; bad=$((bad + 1)); fi
  done
done
for (( i = n + 1; i <= 16; i++ )); do
  if [[ "$(service_health "n8n-worker-${i}")" != "missing" ]]; then
    fail "n8n-worker-${i} still exists although WORKER_REPLICAS=${n}"; bad=$((bad + 1))
  fi
done
if (( bad > 0 )); then
  die "scale-workers: ${bad} problem(s) — make status / make logs SERVICE=<name>"
fi
ok "scale-workers: ${n} worker(s) + ${n} runner sidecar(s) healthy (WORKER_REPLICAS=${n} saved in .env)"
