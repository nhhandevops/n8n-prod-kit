#!/usr/bin/env bash
# compose/scripts/render.sh — derive the generated files from WORKER_REPLICAS. S2 contract §7 "render.sh".
#
#   compose.scale.yml                       WORKER_REPLICAS > 2: services n8n-worker-3..N + runners, fully expanded
#                                           WORKER_REPLICAS = 1: parks the static n8n-worker-2 pair behind a profile
#                                           WORKER_REPLICAS = 2: file DELETED (workers 1 and 2 are static)
#   monitoring/prometheus/targets/n8n.json  [{"targets":["n8n-worker-1:5678", ...]}] for Prometheus
#                                           file_sd (S6 scrapes the workers' /metrics on 5678)
#
# Usage: make render   |   bash scripts/render.sh   (init.sh and `make up` call it)
# WORKER_REPLICAS comes from the environment when set (one-off experiments), else from .env
# (the normal source of truth), else 2. Allowed range 1..16.
#
# WHY the worker bodies are duplicated here instead of using YAML anchors: a generated file cannot
# reference anchors defined in docker-compose.yml (anchors are per-document), so compose.scale.yml
# must carry FULLY EXPANDED service bodies. The two templates below are docker-compose.yml's
# x-n8n-base + x-n8n-env + the n8n-worker-1 stanza, and x-runners-base + x-runners-env + the
# n8n-worker-1-runners stanza (contract §10), and they MUST stay byte-for-byte equivalent (same env,
# healthcheck, volumes, limits, depends_on) to n8n-worker-1 / n8n-worker-1-runners. Change both
# places or neither. When TLS_MODE=internal the dev CA trust that compose.dev.yml merges into the
# static workers is written inline for worker-3..N, so the merged model matches in both modes.
#
# WORKER_REPLICAS=1: n8n-worker-2 is static in docker-compose.yml, so this script writes a compose.scale.yml that
# assigns the pair the "parked" profile (Compose then ignores it); `make scale-workers N=1` removes the containers.
set -euo pipefail
shopt -s inherit_errexit

__script_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
KIT_DIR="$(cd "${__script_dir}/.." && pwd)"
unset __script_dir
cd "${KIT_DIR}"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"

for arg in "${@}"; do
  case "${arg}" in
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" >&2
      exit 0
      ;;
    *)
      die "render.sh takes no arguments (set WORKER_REPLICAS in .env or the environment)"
      ;;
  esac
done

scale_file="${KIT_DIR}/compose.scale.yml"
targets_dir="${KIT_DIR}/monitoring/prometheus/targets"
targets_file="${targets_dir}/n8n.json"

# --- WORKER_REPLICAS: environment > .env > 2 ------------------------------------------------------------
replicas="${WORKER_REPLICAS:-}"
source_of_value="environment"
if [[ -z "${replicas}" ]]; then
  replicas="$(env_get WORKER_REPLICAS)"
  source_of_value=".env"
fi
if [[ -z "${replicas}" ]]; then
  replicas=2
  source_of_value="default"
fi
if [[ ! "${replicas}" =~ ^[0-9]+$ ]] || (( replicas < 1 || replicas > 16 )); then
  die "WORKER_REPLICAS='${replicas}' (from ${source_of_value}) must be an integer between 1 and 16"
fi
info "WORKER_REPLICAS=${replicas} (from ${source_of_value})"

# ==========================================================================================================
# Template: one n8n worker = docker-compose.yml's `*n8n-base` + `*n8n-env` + the n8n-worker-1 stanza, written
# out in full. @N@ is replaced by the worker index. Quoted heredoc: every ${...} below is a COMPOSE
# interpolation (resolved from versions.env/.env at `docker compose` time), never bash.
# Key order = the base anchor's order, then the service's own keys, so a textual diff against
# docker-compose.yml is easy; `compose config` sorts keys anyway.
# (`IFS= read -r -d ''` slurps the heredoc verbatim: with the default IFS, read would strip the
# leading indentation of the first line and the YAML would no longer nest under `services:`.)
# ==========================================================================================================
IFS= read -r -d '' worker_template <<'YAML' || true
  n8n-worker-@N@:
    # --- x-n8n-base ---
    image: ${N8N_IMAGE}:${N8N_VERSION}@${N8N_DIGEST:?run make pin}
    restart: unless-stopped
    stop_grace_period: 40s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp
      - /home/node/.cache
      - /home/node/.npm
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
    networks:
      - proxy
      - internal
    volumes:
      - n8n_data:/home/node/.n8n
      - n8n_files:/home/node/.n8n-files
@DEV_VOLUME@
@DEV_EXTRA_HOSTS@
    # --- n8n-worker-1 stanza ---
    command: ["worker", "--concurrency=${WORKER_CONCURRENCY:-10}"]
    environment:
@DEV_ENV@
      # --- x-n8n-env (identical on main, webhooks and every worker) ---
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD (make init)}
      DB_POSTGRESDB_POOL_SIZE: "4"
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: valkey
      QUEUE_BULL_REDIS_PORT: "6379"
      QUEUE_BULL_REDIS_PASSWORD: ${VALKEY_PASSWORD:?set VALKEY_PASSWORD (make init)}
      QUEUE_BULL_REDIS_DB: "0"
      QUEUE_BULL_PREFIX: n8n
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY:?set N8N_ENCRYPTION_KEY (make init)}
      N8N_DEFAULT_BINARY_DATA_MODE: database
      N8N_RUNNERS_MODE: external
      N8N_RUNNERS_AUTH_TOKEN: ${N8N_RUNNERS_AUTH_TOKEN:?set N8N_RUNNERS_AUTH_TOKEN (make init)}
      N8N_RUNNERS_BROKER_LISTEN_ADDRESS: 0.0.0.0
      N8N_RUNNERS_TASK_TIMEOUT: ${RUNNERS_TASK_TIMEOUT:-300}
      N8N_HOST: ${DOMAIN:?set DOMAIN}
      N8N_PROTOCOL: https
      N8N_PORT: "5678"
      N8N_WEBHOOK_URL: ${PUBLIC_URL:?set PUBLIC_URL (make init)}
      N8N_EDITOR_BASE_URL: ${PUBLIC_URL:?set PUBLIC_URL (make init)}
      N8N_PROXY_HOPS: "1"
      N8N_SECURE_COOKIE: "true"
      N8N_SAMESITE_COOKIE: lax
      N8N_LOG_LEVEL: info
      N8N_LOG_OUTPUT: console
      N8N_LOG_FORMAT: json
      N8N_METRICS: "true"
      N8N_METRICS_INCLUDE_QUEUE_METRICS: "true"
      N8N_METRICS_INCLUDE_DEFAULT_METRICS: "true"
      N8N_METRICS_QUEUE_METRICS_INTERVAL: "20"
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE:-Asia/Ho_Chi_Minh}
      TZ: ${TZ:-Asia/Ho_Chi_Minh}
      N8N_GRACEFUL_SHUTDOWN_TIMEOUT: ${N8N_GRACEFUL_SHUTDOWN_TIMEOUT:-30}
      N8N_CONCURRENCY_PRODUCTION_LIMIT: ${N8N_CONCURRENCY_PRODUCTION_LIMIT:--1}
      EXECUTIONS_DATA_PRUNE: ${EXECUTIONS_DATA_PRUNE:-true}
      EXECUTIONS_DATA_MAX_AGE: ${EXECUTIONS_DATA_MAX_AGE:-336}
      EXECUTIONS_DATA_PRUNE_MAX_COUNT: ${EXECUTIONS_DATA_PRUNE_MAX_COUNT:-10000}
      EXECUTIONS_DATA_SAVE_ON_SUCCESS: ${EXECUTIONS_DATA_SAVE_ON_SUCCESS:-all}
      EXECUTIONS_DATA_SAVE_ON_ERROR: ${EXECUTIONS_DATA_SAVE_ON_ERROR:-all}
      EXECUTIONS_DATA_SAVE_ON_PROGRESS: ${EXECUTIONS_DATA_SAVE_ON_PROGRESS:-false}
      EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS: ${EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS:-true}
      EXECUTIONS_TIMEOUT: ${EXECUTIONS_TIMEOUT:--1}
      EXECUTIONS_TIMEOUT_MAX: ${EXECUTIONS_TIMEOUT_MAX:-3600}
      N8N_BLOCK_ENV_ACCESS_IN_NODE: ${N8N_BLOCK_ENV_ACCESS_IN_NODE:-true}
      N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES: ${N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES:-true}
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: ${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS:-true}
      N8N_GIT_NODE_DISABLE_BARE_REPOS: ${N8N_GIT_NODE_DISABLE_BARE_REPOS:-true}
      N8N_DIAGNOSTICS_ENABLED: ${N8N_DIAGNOSTICS_ENABLED:-false}
      N8N_PERSONALIZATION_ENABLED: ${N8N_PERSONALIZATION_ENABLED:-false}
      N8N_HIRING_BANNER_ENABLED: ${N8N_HIRING_BANNER_ENABLED:-false}
      N8N_TEMPLATES_ENABLED: ${N8N_TEMPLATES_ENABLED:-true}
      N8N_VERSION_NOTIFICATIONS_ENABLED: ${N8N_VERSION_NOTIFICATIONS_ENABLED:-true}
      N8N_PUBLIC_API_DISABLED: ${N8N_PUBLIC_API_DISABLED:-false}
      NODES_EXCLUDE: '${NODES_EXCLUDE:-["n8n-nodes-base.executeCommand","n8n-nodes-base.localFileTrigger"]}'
      # --- worker-only keys (same as n8n-worker-1) ---
      QUEUE_HEALTH_CHECK_ACTIVE: "true"
      QUEUE_WORKER_LOCK_DURATION: "60000"
      QUEUE_WORKER_LOCK_RENEW_TIME: "10000"
      QUEUE_WORKER_STALLED_INTERVAL: "30000"
      N8N_WEBHOOK_RESPONSE_RELAY_OFFLOAD_ENABLED: "true"
      N8N_WEBHOOK_RESPONSE_RELAY_SIZE_MAX: "64"
      N8N_EVENTBUS_LOGWRITER_LOGBASENAME: eventlog-n8n-worker-@N@
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:5678/healthz/readiness"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 90s
    depends_on:
      n8n-main:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: ${MEM_LIMIT_WORKER:-1g}
YAML

# compose.dev.yml (auto-included when TLS_MODE=internal) lists the STATIC services only, so the dev CA
# trust it merges into n8n-worker-1/2 (extra_hosts, the /certs volume, NODE_EXTRA_CA_CERTS) is written
# inline here for worker-3..N — same keys, same values — when .env says TLS_MODE=internal. The merged
# model of worker-N therefore equals worker-1's in both TLS modes. ($'...' keeps the ${DOMAIN:?} literal.)
dev_volume_line=$'\n      - caddy_data:/certs:ro'
dev_extra_hosts_lines=$'\n    extra_hosts:\n      - "${DOMAIN:?set DOMAIN}:host-gateway"'
dev_env_line=$'\n      NODE_EXTRA_CA_CERTS: /certs/caddy/pki/authorities/local/root.crt'
tls_mode="$(env_get TLS_MODE)"
dev_trust=0
if [[ "${tls_mode}" == "internal" ]]; then
  dev_trust=1
fi

# expand_worker N  -> the worker body for index N with the dev-trust placeholders filled in or removed
expand_worker() {
  local n="${1}"
  local body="${worker_template//@N@/${n}}"
  if (( dev_trust )); then
    body="${body//$'\n'@DEV_VOLUME@/${dev_volume_line}}"
    body="${body//$'\n'@DEV_EXTRA_HOSTS@/${dev_extra_hosts_lines}}"
    body="${body//$'\n'@DEV_ENV@/${dev_env_line}}"
  else
    body="${body//$'\n'@DEV_VOLUME@/}"
    body="${body//$'\n'@DEV_EXTRA_HOSTS@/}"
    body="${body//$'\n'@DEV_ENV@/}"
  fi
  printf '%s\n' "${body}"
}

# ==========================================================================================================
# Template: the worker's runner sidecar = `*runners-base` + `*runners-env` + the n8n-worker-1-runners stanza.
# ==========================================================================================================
IFS= read -r -d '' runners_template <<'YAML' || true
  n8n-worker-@N@-runners:
    # --- x-runners-base ---
    image: ${RUNNERS_IMAGE}:${N8N_VERSION}@${RUNNERS_DIGEST:?run make pin}
    command: ${RUNNERS_LANGS:-javascript}
    restart: unless-stopped
    stop_grace_period: 15s
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- -T 3 http://127.0.0.1:5680/healthz | grep -q ok"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s
    deploy:
      resources:
        limits:
          memory: ${MEM_LIMIT_RUNNERS:-512m}
    # --- n8n-worker-1-runners stanza ---
    environment:
      # --- x-runners-env ---
      N8N_RUNNERS_AUTH_TOKEN: ${N8N_RUNNERS_AUTH_TOKEN:?set N8N_RUNNERS_AUTH_TOKEN (make init)}
      N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT: "15"
      N8N_RUNNERS_MAX_CONCURRENCY: ${RUNNERS_MAX_CONCURRENCY:-5}
      N8N_RUNNERS_TASK_TIMEOUT: ${RUNNERS_TASK_TIMEOUT:-300}
      N8N_RUNNERS_LAUNCHER_GRACEFUL_SHUTDOWN_TIMEOUT: "10"
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE:-Asia/Ho_Chi_Minh}
      # --- sidecar-specific ---
      N8N_RUNNERS_TASK_BROKER_URI: http://n8n-worker-@N@:5679
    depends_on:
      n8n-worker-@N@:
        condition: service_healthy
YAML

# --- compose.scale.yml -------------------------------------------------------------------------------------
if (( replicas > 2 )); then
  tmp_scale="$(mktemp "${scale_file}.XXXXXX")"
  {
    printf '# compose.scale.yml — GENERATED by scripts/render.sh from WORKER_REPLICAS=%s. DO NOT EDIT: run "make render".\n' "${replicas}"
    printf '# Adds n8n-worker-3..%s and their runner sidecars, fully expanded (YAML anchors cannot cross files).\n' "${replicas}"
    printf '# Must stay equivalent to n8n-worker-1 / n8n-worker-1-runners in docker-compose.yml (contract §10).\n'
    printf '# The lib.sh compose() helper and the Makefile add "-f compose.scale.yml" automatically while this file exists.\n'
    if (( dev_trust )); then
      printf '# TLS_MODE=internal: the dev CA trust of compose.dev.yml is written inline for these workers.\n'
    fi
    printf 'services:\n'
    for (( n = 3; n <= replicas; n++ )); do
      printf '\n'
      expand_worker "${n}"
      printf '\n%s\n' "${runners_template//@N@/${n}}"
    done
  } >"${tmp_scale}"
  chmod 644 "${tmp_scale}"
  mv -f "${tmp_scale}" "${scale_file}"
  if (( dev_trust )); then
    ok "compose.scale.yml: n8n-worker-3..${replicas} + runner sidecars written (with dev CA trust, TLS_MODE=internal)"
  else
    ok "compose.scale.yml: n8n-worker-3..${replicas} + runner sidecars written"
  fi
elif (( replicas == 1 )); then
  # n8n-worker-2 is static in docker-compose.yml. An override that assigns it a profile makes Compose ignore the pair
  # unless that profile is enabled (verified: `config --services` drops it), which is how one worker is expressed.
  tmp_scale="$(mktemp "${scale_file}.XXXXXX")"
  {
    printf '# compose.scale.yml — GENERATED by scripts/render.sh from WORKER_REPLICAS=1. DO NOT EDIT: run "make render".\n'
    printf '# Parks the static n8n-worker-2 pair behind the "parked" profile: Compose neither starts nor waits for it\n'
    printf '# (make scale-workers N=1 also removes its containers). WORKER_REPLICAS=2 + make render deletes this file.\n'
    printf 'services:\n  n8n-worker-2:\n    profiles: ["parked"]\n  n8n-worker-2-runners:\n    profiles: ["parked"]\n'
  } >"${tmp_scale}"
  chmod 644 "${tmp_scale}"
  mv -f "${tmp_scale}" "${scale_file}"
  ok "compose.scale.yml: n8n-worker-2 + its runners parked (WORKER_REPLICAS=1)"
else
  if [[ -e "${scale_file}" ]]; then
    rm -f "${scale_file}"
    ok "compose.scale.yml removed (WORKER_REPLICAS=2: workers 1 and 2 are static)"
  else
    info "compose.scale.yml not needed (WORKER_REPLICAS=2)"
  fi
fi

# --- Prometheus file_sd targets ----------------------------------------------------------------------------
# One target per worker that actually runs (WORKER_REPLICAS=1 parks worker 2, so it is not scraped).
scrape_count="${replicas}"
mkdir -p "${targets_dir}"
joined=''
sep=''
for (( n = 1; n <= scrape_count; n++ )); do
  joined+="${sep}\"n8n-worker-${n}:5678\""
  sep=', '
done
tmp_targets="$(mktemp "${targets_file}.XXXXXX")"
printf '[\n  {\n    "targets": [%s]\n  }\n]\n' "${joined}" >"${tmp_targets}"
chmod 644 "${tmp_targets}"
if command -v jq >/dev/null 2>&1; then
  jq -e . "${tmp_targets}" >/dev/null || die "internal error: generated ${targets_file} is not valid JSON"
fi
mv -f "${tmp_targets}" "${targets_file}"
ok "monitoring/prometheus/targets/n8n.json: ${scrape_count} worker target(s)"
