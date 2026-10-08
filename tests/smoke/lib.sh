#!/usr/bin/env bash
# tests/smoke/lib.sh — helpers shared by tests/smoke/run.sh and every NN-*.sh smoke script.
#
# The smoke suite talks to a RUNNING stack the way a user does — through Caddy on PUBLIC_URL — and looks inside
# containers only where the outside cannot see (worker logs, metrics, Valkey keys, Postgres rows). It is
# idempotent: the owner account and an API key are created once and remembered in compose/.smoke/ (gitignored,
# mode 700); every run creates its own uniquely named "kit-smoke-<nonce>" workflows and run.sh removes them.
#
# API (scripts call only these):
#   BASE_URL, DOMAIN, TLS_MODE, STATE_DIR, CURL_TLS[]   set on source
#   check "description" cmd...    run cmd; print [ OK ]/[FAIL]; count failures (never exits)
#   finish                        exit 1 if any check failed in this script
#   req METHOD PATH [curl args]   HTTP via Caddy; sets REQ_STATUS; body in "$(req_body)", headers via header_of
#   api METHOD PATH [json]        req with the API key + JSON content type
#   header_of NAME                value of a response header of the last req (case-insensitive)
#   wait_for SECONDS "what" cmd...  retry cmd every 2 s until it succeeds or the time is up
#   state_get KEY / state_set KEY VALUE   small key=value store shared between scripts (compose/.smoke/state.env)
#   ensure_owner / ensure_session / ensure_api_key   create or reuse the owner, a login cookie, an API key
#   main_metric NAME              value of an n8n-main Prometheus series (read inside the container)
#   delete_smoke_workflows        deactivate + delete every workflow whose name starts with "kit-smoke-"
# shellcheck disable=SC2310,SC2311,SC2312

if [[ -n "${__KIT_SMOKE_LIB:-}" ]]; then
  return 0
fi
__KIT_SMOKE_LIB=1

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KIT_DIR="$(cd "${SMOKE_DIR}/../../compose" && pwd)"
export KIT_DIR
# shellcheck source=../../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}" || exit 1

need_cmd curl jq docker openssl
if [[ ! -f .env ]]; then
  die "compose/.env not found — run 'make init' and 'make up' before the smoke suite"
fi

STATE_DIR="${KIT_DIR}/.smoke"
mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
STATE_FILE="${STATE_DIR}/state.env"
COOKIE_JAR="${STATE_DIR}/cookies.txt"

BASE_URL="$(env_get PUBLIC_URL)"
BASE_URL="${BASE_URL%/}"
DOMAIN="$(env_get DOMAIN)"
TLS_MODE="$(env_get TLS_MODE)"
if [[ -z "${BASE_URL}" || -z "${DOMAIN}" ]]; then
  die "PUBLIC_URL / DOMAIN empty in .env — re-run make init"
fi

# How curl trusts the certificate: the kit's dev CA for internal TLS (exported by `make dev-ca`), the system trust
# store for Let's Encrypt, and no verification for the Let's Encrypt STAGING CA (untrusted by design).
CURL_TLS=()
case "${TLS_MODE}" in
  internal)
    if [[ ! -s "${KIT_DIR}/secrets/dev-root.crt" ]]; then
      "${KIT_DIR}/scripts/dev-ca.sh" >/dev/null
    fi
    CURL_TLS=(--cacert "${KIT_DIR}/secrets/dev-root.crt")
    ;;
  acme-staging)
    CURL_TLS=(-k)
    ;;
  *)
    ;;
esac

# --- checks ----------------------------------------------------------------------------------------------------------
SMOKE_FAILED=0
check() {
  local desc="${1}"
  shift
  if "${@}"; then
    ok "${desc}"
  else
    fail "${desc}"
    SMOKE_FAILED=$((SMOKE_FAILED + 1))
  fi
}

finish() {
  if (( SMOKE_FAILED > 0 )); then
    exit 1
  fi
  exit 0
}

# --- HTTP ------------------------------------------------------------------------------------------------------------
REQ_STATUS=000
req() {
  local method="${1}" path="${2}"
  shift 2
  REQ_STATUS="$(curl -sS --max-time 60 "${CURL_TLS[@]}" -o "${STATE_DIR}/last.body" -D "${STATE_DIR}/last.headers" \
    -w '%{http_code}' -X "${method}" "${@}" "${BASE_URL}${path}" 2>"${STATE_DIR}/last.err" || true)"
  REQ_STATUS="${REQ_STATUS:-000}"
}

req_body() {
  cat "${STATE_DIR}/last.body" 2>/dev/null || true
}

header_of() {
  local name="${1,,}"
  awk -v h="${name}:" 'tolower($1) == h { sub(/\r$/, ""); $1 = ""; sub(/^ /, ""); print; exit }' \
    "${STATE_DIR}/last.headers" 2>/dev/null || true
}

status_is() {
  [[ "${REQ_STATUS}" == "${1}" ]]
}

api() {
  local method="${1}" path="${2}" data="${3:-}"
  local key
  key="$(cat "${STATE_DIR}/api-key" 2>/dev/null || true)"
  if [[ -n "${data}" ]]; then
    req "${method}" "${path}" -H "X-N8N-API-KEY: ${key}" -H 'Content-Type: application/json' --data "${data}"
  else
    req "${method}" "${path}" -H "X-N8N-API-KEY: ${key}"
  fi
}

wait_for() {
  local timeout="${1}" what="${2}"
  shift 2
  local deadline=$((SECONDS + timeout))
  until "${@}"; do
    if (( SECONDS >= deadline )); then
      warn "timed out after ${timeout}s waiting for: ${what}"
      return 1
    fi
    sleep 2
  done
}

# --- shared state ----------------------------------------------------------------------------------------------------
state_get() {
  env_get "${1}" "${STATE_FILE}"
}

state_set() {
  env_set "${1}" "${2}" "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
}

# --- n8n accounts ----------------------------------------------------------------------------------------------------
# Owner credentials: SMOKE_OWNER_EMAIL/SMOKE_OWNER_PASSWORD from the environment win (an instance whose owner was
# created by hand), else compose/.smoke/owner.env, else a fresh owner is created on an instance that has none.
ensure_owner() {
  if [[ -n "${SMOKE_OWNER_EMAIL:-}" && -n "${SMOKE_OWNER_PASSWORD:-}" ]]; then
    return 0
  fi
  if [[ -f "${STATE_DIR}/owner.env" ]]; then
    SMOKE_OWNER_EMAIL="$(env_get SMOKE_OWNER_EMAIL "${STATE_DIR}/owner.env")"
    SMOKE_OWNER_PASSWORD="$(env_get SMOKE_OWNER_PASSWORD "${STATE_DIR}/owner.env")"
    return 0
  fi
  req GET /rest/settings
  local first_load
  first_load="$(req_body | jq -r '.data.userManagement.showSetupOnFirstLoad // empty')"
  if [[ "${first_load}" != "true" ]]; then
    fail "this instance already has an owner but compose/.smoke/owner.env is missing — export SMOKE_OWNER_EMAIL and SMOKE_OWNER_PASSWORD"
    return 1
  fi
  SMOKE_OWNER_EMAIL="smoke-owner@example.com"
  # n8n requires 8+ chars with a digit and an uppercase letter
  SMOKE_OWNER_PASSWORD="Kit$(rand_hex 12)9"
  req POST /rest/owner/setup -H 'Content-Type: application/json' --data "$(jq -nc --arg e "${SMOKE_OWNER_EMAIL}" \
    --arg p "${SMOKE_OWNER_PASSWORD}" '{email: $e, firstName: "Kit", lastName: "Smoke", password: $p}')"
  if ! status_is 200; then
    fail "owner setup failed: HTTP ${REQ_STATUS} $(req_body | head -c 200)"
    return 1
  fi
  env_set SMOKE_OWNER_EMAIL "${SMOKE_OWNER_EMAIL}" "${STATE_DIR}/owner.env"
  env_set SMOKE_OWNER_PASSWORD "${SMOKE_OWNER_PASSWORD}" "${STATE_DIR}/owner.env"
  chmod 600 "${STATE_DIR}/owner.env"
  info "created owner ${SMOKE_OWNER_EMAIL} (password in compose/.smoke/owner.env)"
}

# n8n rate-limits POST /rest/login to 5 attempts per window per client IP (HTTP 429 + Retry-After, not configurable),
# so the suite logs in as rarely as possible: a still-valid session cookie is reused, and a 429 is waited out.
#   login_attempt BODY_JSON   one POST /rest/login, waiting out at most two 429s
#   ensure_session [fresh]    reuse the cookie when it is still valid (unless "fresh"), else log in
login_attempt() {
  local body="${1}" attempt wait
  for attempt in 1 2 3; do
    rm -f "${COOKIE_JAR}"
    req POST /rest/login -c "${COOKIE_JAR}" -H 'Content-Type: application/json' --data "${body}"
    if ! status_is 429; then
      return 0
    fi
    wait="$(header_of Retry-After)"
    wait="${wait:-30}"
    info "n8n login rate limit hit (5 per window) — waiting ${wait}s (attempt ${attempt})"
    sleep $((wait + 1))
  done
}

ensure_session() {
  ensure_owner || return 1
  if [[ "${1:-}" != "fresh" && -s "${COOKIE_JAR}" ]]; then
    req GET /rest/login -b "${COOKIE_JAR}"
    if status_is 200; then
      return 0
    fi
  fi
  login_attempt "$(jq -nc --arg e "${SMOKE_OWNER_EMAIL}" --arg p "${SMOKE_OWNER_PASSWORD}" '{emailOrLdapLoginId: $e, password: $p}')"
  status_is 200
}

ensure_api_key() {
  if [[ -s "${STATE_DIR}/api-key" ]]; then
    api GET '/api/v1/workflows?limit=1'
    if status_is 200; then
      return 0
    fi
  fi
  ensure_session || return 1
  local scopes key old
  # n8n refuses a second key with the same label; a "kit-smoke" key whose secret we no longer have is useless, so
  # replace it — the suite keeps exactly one key and never accumulates them.
  req GET /rest/api-keys -b "${COOKIE_JAR}"
  for old in $(req_body | jq -r '.data.items[]? | select(.label == "kit-smoke") | .id'); do
    req DELETE "/rest/api-keys/${old}" -b "${COOKIE_JAR}"
  done
  req GET /rest/api-keys/scopes -b "${COOKIE_JAR}"
  scopes="$(req_body | jq -c '.data')"
  req POST /rest/api-keys -b "${COOKIE_JAR}" -H 'Content-Type: application/json' \
    --data "{\"label\":\"kit-smoke\",\"scopes\":${scopes},\"expiresAt\":null}"
  key="$(req_body | jq -r '.data.rawApiKey // empty')"
  if [[ -z "${key}" ]]; then
    fail "could not create an API key: HTTP ${REQ_STATUS} $(req_body | head -c 200)"
    return 1
  fi
  printf '%s\n' "${key}" >"${STATE_DIR}/api-key"
  chmod 600 "${STATE_DIR}/api-key"
}

# --- inside the stack ------------------------------------------------------------------------------------------------
main_metric() {
  # captured first, then parsed: no early-exiting reader on a pipe (see the pipefail note in 05)
  local metrics
  metrics="$(compose exec -T n8n-main wget -qO- http://127.0.0.1:5678/metrics 2>/dev/null || true)"
  awk -v m="${1}" '$1 == m && !found { print $2; found = 1 }' <<<"${metrics}"
}

workflow_from_fixture() {   # FIXTURE NAME PATH [URL]  -> workflow JSON on stdout
  local fixture="${SMOKE_DIR}/fixtures/${1}" name="${2}" path="${3}" url="${4:-}"
  jq -c --arg n "${name}" --arg p "${path}" --arg u "${url}" '
    .name = $n
    | (.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.path) = $p
    | (.nodes[] | select(.type == "n8n-nodes-base.code") | .parameters.jsCode) |= gsub("__URL__"; $u)' "${fixture}"
}

delete_smoke_workflows() {
  local id
  api GET '/api/v1/workflows?limit=250'
  status_is 200 || return 0
  for id in $(req_body | jq -r '.data[] | select(.name | startswith("kit-smoke-")) | .id'); do
    api POST "/api/v1/workflows/${id}/deactivate"
    # deactivation settles asynchronously; DELETE can answer 409 for a moment, hence the retry loop
    local tries=0
    until api DELETE "/api/v1/workflows/${id}" && status_is 200; do
      tries=$((tries + 1))
      if (( tries >= 10 )); then
        warn "could not delete smoke workflow ${id} (HTTP ${REQ_STATUS})"
        break
      fi
      sleep 2
    done
  done
}
