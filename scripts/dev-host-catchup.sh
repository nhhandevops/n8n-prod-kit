#!/usr/bin/env bash
# =============================================================================
# scripts/dev-host-catchup.sh — bring a dev/test host up to the repository's current state
# =============================================================================
#
# For a host that already ran the kit and fell behind (another computer, a VM that was off for a
# week), and for a host with a fresh clone. Run it from the clone, as your own user (in the docker
# group), after scripts/bootstrap-host.sh has prepared the machine. It is safe to run again: every
# step checks first and only changes what is missing.
#
# WHAT IT DOES, IN ORDER
#   1. git: fetch, switch to the branch (default main), fast-forward only — stops on local changes
#   2. compose/.env: `make init DOMAIN=…` when this clone has none yet (a fresh host)
#   3. n8n: `make upgrade` when versions.env pins a newer n8n than this host's database last used
#      (it takes a backup first and runs the migrations in order; "nothing to upgrade" otherwise)
#   4. monitoring: COMPOSE_PROFILES gains monitoring,kuma and KUMA_ENABLED=on       (--no-monitoring)
#   5. Telegram alerts: bot token (hidden) + chat id, only when .env has none        (--no-telegram)
#   6. R2 off-site backups: key id + secret (hidden) + endpoint, only when BACKUP_REMOTES has no r2:
#      target; the target is r2:<bucket>/<prefix>, one prefix per host (--r2-prefix) (--no-r2)
#   7. `make up` — applies everything above, the compose changes git brought, and the pins
#   8. proof: a test message for a new Telegram token; backup-now + restore-test for a new R2 target
#   9. the recovery key: offers `make detach-recovery-key` while it is still on this host
#  10. checks: make status, make doctor, make smoke (--no-smoke); a summary with what is left
#
# Secrets are read at hidden prompts, written to compose/.env (mode 600) and never printed or
# passed on a command line. Press Enter at a prompt to skip that part.
#
# HOW TO RUN
#   scripts/dev-host-catchup.sh --check      # read-only: what this host has and what a run would do
#   scripts/dev-host-catchup.sh              # do it
#   scripts/dev-host-catchup.sh --help
# A fresh host: git clone, sudo scripts/bootstrap-host.sh, log out and in, then this script
# (add --ports 8080:8443 when something else owns 80/443).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
KIT_DIR="${REPO}/compose"
# shellcheck source=../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: scripts/dev-host-catchup.sh [--check] [options]
  --check              read-only: report this host's state and what a run would change
  --branch NAME        git branch to follow (default: main)
  --domain NAME        DOMAIN for make init on a fresh host (default: n8n.localtest.me)
  --ports HTTP:HTTPS   host ports for make init when 80/443 are taken (e.g. 8080:8443)
  --r2-bucket NAME     R2 bucket for off-site backups (default: n8n-backups)
  --r2-prefix NAME     this host's folder in the bucket (default: dev-<short hostname>)
  --no-monitoring      leave COMPOSE_PROFILES as it is
  --no-telegram        do not ask for Telegram alert settings
  --no-r2              do not ask for R2 settings
  --no-smoke           skip make smoke at the end
EOF
}

# --- options --------------------------------------------------------------------------------------------------------
CHECK=0
BRANCH=main
DOMAIN_ARG=n8n.localtest.me
PORTS=''
R2_BUCKET=n8n-backups
R2_PREFIX="dev-$(hostname -s 2>/dev/null || echo host)"
DO_MONITORING=1
DO_TELEGRAM=1
DO_R2=1
DO_SMOKE=1

parse_args() {
  while (($#)); do
    case "${1}" in
      --check) CHECK=1 ;;
      --branch) BRANCH="${2:?--branch needs a name}"; shift ;;
      --domain) DOMAIN_ARG="${2:?--domain needs a name}"; shift ;;
      --ports) PORTS="${2:?--ports needs HTTP:HTTPS}"; shift ;;
      --r2-bucket) R2_BUCKET="${2:?--r2-bucket needs a name}"; shift ;;
      --r2-prefix) R2_PREFIX="${2:?--r2-prefix needs a name}"; shift ;;
      --no-monitoring) DO_MONITORING=0 ;;
      --no-telegram) DO_TELEGRAM=0 ;;
      --no-r2) DO_R2=0 ;;
      --no-smoke) DO_SMOKE=0 ;;
      -h | --help) usage; exit 0 ;;
      *) usage; die "unknown option: ${1}" ;;
    esac
    shift
  done
  if [[ -n "${PORTS}" && ! "${PORTS}" =~ ^[0-9]+:[0-9]+$ ]]; then
    die "--ports must look like 8080:8443 (got '${PORTS}')"
  fi
  if [[ ! "${R2_BUCKET}" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ || ! "${R2_PREFIX}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "--r2-bucket must be a bucket name (lowercase, digits, -) and --r2-prefix a plain folder name"
  fi
}

# --- small helpers --------------------------------------------------------------------------------------------------
SUMMARY=()
note() { SUMMARY+=("${1}"); }   # one line for the summary at the end
section() { printf '\n== %s\n' "${1}" >&2; }
has_tty() { (exec 3</dev/tty) 2>/dev/null; }

# ask_secret VAR PROMPT   hidden input from the terminal into VAR (empty when skipped or no terminal)
ask_secret() {
  local __reply=''
  if has_tty; then
    printf '%s' "${2}" >&2
    read -rs __reply </dev/tty || __reply=''
    printf '\n' >&2
  fi
  printf -v "${1}" '%s' "${__reply//[[:space:]]/}"
}

# ask_plain VAR PROMPT   visible input (not secret) from the terminal into VAR
ask_plain() {
  local __reply=''
  if has_tty; then
    printf '%s' "${2}" >&2
    read -r __reply </dev/tty || __reply=''
  fi
  printf -v "${1}" '%s' "${__reply//[[:space:]]/}"
}

# telegram_api METHOD   call the Bot API with the token from .env without putting it on a command line
telegram_api() {
  local token
  token="$(env_get ALERT_TELEGRAM_BOT_TOKEN)"
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "${token}" "${1}" |
    curl -sS -m 20 -K - "${@:2}" 2>/dev/null || true
}

project_has_database() {
  docker volume inspect "$(_kit_project_name)_pg_data" >/dev/null 2>&1
}

# --- 0. the host ----------------------------------------------------------------------------------------------------
preconditions() {
  section "host"
  [[ "$(id -u)" != "0" ]] || die "run this as your own user (in the docker group), not as root"
  need_cmd git make docker curl jq
  docker info >/dev/null 2>&1 ||
    die "Docker is not reachable — run 'sudo scripts/bootstrap-host.sh', then log out and back in (docker group)"
  # shellcheck source=/dev/null
  ok "$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}"), docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), repo ${REPO}"
}

# --- 1. git ---------------------------------------------------------------------------------------------------------
step_git() {
  section "1. git (${BRANCH})"
  local before current dirty behind
  git -C "${REPO}" fetch -q origin "${BRANCH}" || die "git fetch origin ${BRANCH} failed (network? branch name?)"
  before="$(git -C "${REPO}" rev-parse --short HEAD)"
  current="$(git -C "${REPO}" rev-parse --abbrev-ref HEAD)"
  dirty="$(git -C "${REPO}" status --porcelain --untracked-files=no | wc -l)"
  behind="$(git -C "${REPO}" rev-list --count "HEAD..origin/${BRANCH}")"
  if ((CHECK)); then
    info "on ${current} at ${before}; ${behind} commit(s) behind origin/${BRANCH}; ${dirty} locally changed tracked file(s)"
    ((dirty == 0)) || warn "a run stops here until the local changes are committed or stashed (git status)"
    note "git: ${behind} commit(s) to pull"
    return 0
  fi
  if ((dirty > 0)); then
    git -C "${REPO}" status --short --untracked-files=no >&2
    die "tracked files are changed locally (above) — commit or stash them first; nothing was changed"
  fi
  if [[ "${current}" != "${BRANCH}" ]]; then
    if git -C "${REPO}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
      git -C "${REPO}" checkout -q "${BRANCH}"
    else
      git -C "${REPO}" checkout -q -b "${BRANCH}" "origin/${BRANCH}"
    fi
  fi
  git -C "${REPO}" merge -q --ff-only "origin/${BRANCH}" ||
    die "this clone has commits origin/${BRANCH} does not — merge by hand (git log origin/${BRANCH}..HEAD); nothing else was changed"
  ok "${before} -> $(git -C "${REPO}" log --oneline -1)"
  note "git: ${BRANCH} at $(git -C "${REPO}" rev-parse --short HEAD) (was ${before})"
}

# --- 2. .env --------------------------------------------------------------------------------------------------------
FRESH=0
step_env() {
  section "2. compose/.env"
  if [[ -f "${KIT_DIR}/.env" ]]; then
    ok "present (DOMAIN=$(env_get DOMAIN), PUBLIC_URL=$(env_get PUBLIC_URL))"
    return 0
  fi
  FRESH=1
  local -a args=("DOMAIN=${DOMAIN_ARG}")
  if [[ -n "${PORTS}" ]]; then
    args+=("HTTP_PORT=${PORTS%%:*}" "HTTPS_PORT=${PORTS##*:}")
  fi
  if ((CHECK)); then
    info "none yet — a run does: make init ${args[*]}"
    note ".env: make init ${args[*]}"
    return 0
  fi
  make -C "${KIT_DIR}" init "${args[@]}"
  note ".env: created by make init ${args[*]}"
}

# --- 3. n8n version -------------------------------------------------------------------------------------------------
step_version() {
  section "3. n8n version"
  local pinned running
  if ((CHECK)); then
    pinned="$(git -C "${REPO}" show "origin/${BRANCH}:compose/versions.env" 2>/dev/null | sed -n 's/^N8N_VERSION=//p')"
  else
    pinned="$(env_get N8N_VERSION "${KIT_DIR}/versions.env")"
  fi
  running="$(image_version_of n8n-main)"
  if ((FRESH)) || ! project_has_database; then
    info "no database yet — make up installs n8n ${pinned} directly"
    note "n8n: ${pinned} (new installation)"
    return 0
  fi
  if ((CHECK)); then
    info "pinned on origin/${BRANCH}: ${pinned}; n8n-main runs: ${running:-nothing (stack down — make upgrade asks the database)}"
    if [[ -n "${running}" && "${running}" != "${pinned}" ]]; then
      note "n8n: make upgrade ${running} -> ${pinned} (backup first)"
    else
      note "n8n: make upgrade decides (nothing to do when ${pinned} already runs)"
    fi
    return 0
  fi
  # make upgrade reads what runs (or what the database last used) itself: "nothing to upgrade" when the pin already
  # runs, an upgrade with a backup first when the pin is newer, a clear refusal when it is older.
  make -C "${KIT_DIR}" upgrade YES=1
  note "n8n: $(image_version_of n8n-main) (versions.env pins ${pinned})"
}

# --- 4. monitoring profiles -----------------------------------------------------------------------------------------
step_profiles() {
  section "4. monitoring + Uptime Kuma"
  ((DO_MONITORING)) || { info "skipped (--no-monitoring)"; return 0; }
  local profiles want p
  profiles="$(env_get COMPOSE_PROFILES)"
  want="${profiles}"
  for p in monitoring kuma; do
    [[ ",${want}," == *",${p},"* ]] || want="${want:+${want},}${p}"
  done
  if [[ "${want}" == "${profiles}" && "$(env_get KUMA_ENABLED)" == "on" ]]; then
    ok "already on (COMPOSE_PROFILES=${profiles}, KUMA_ENABLED=on)"
    note "monitoring: on"
    return 0
  fi
  # Grafana, Prometheus, Loki and Kuma on top of n8n want about 4 vCPU (runbook E1); preflight only demands 2.
  local cpus
  cpus="$(nproc 2>/dev/null || echo 1)"
  if ((cpus < 4)); then
    warn "this host has ${cpus} vCPU — the monitoring profile wants about 4 (runbook E1): raise the VM's vCPUs, then run this again"
    note "monitoring: NOT switched on — ${cpus} vCPU (raise to 4, then re-run)"
    return 0
  fi
  if ((CHECK)); then
    info "a run sets COMPOSE_PROFILES=${want} and KUMA_ENABLED=on (Grafana, Prometheus, Loki, Uptime Kuma — about 1.5 GB more RAM)"
    note "monitoring: to be switched on"
    return 0
  fi
  env_set COMPOSE_PROFILES "${want}"
  env_set KUMA_ENABLED on
  ok "COMPOSE_PROFILES=${want}, KUMA_ENABLED=on"
  note "monitoring: switched on"
}

# --- 5. Telegram ----------------------------------------------------------------------------------------------------
TELEGRAM_NEW=0
step_telegram() {
  section "5. Telegram alerts"
  ((DO_TELEGRAM)) || { info "skipped (--no-telegram)"; return 0; }
  if [[ -n "$(env_get ALERT_TELEGRAM_BOT_TOKEN)" && -n "$(env_get ALERT_TELEGRAM_CHAT_ID)" ]]; then
    if [[ "$(telegram_api getMe | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
      ok "configured, and Telegram accepts the token"
      note "telegram: configured"
    else
      warn "configured, but Telegram does not accept the token (revoked?) — replace it as in HANDOFF §2 Next up, item 1"
      note "telegram: TOKEN REJECTED by Telegram"
    fi
    return 0
  fi
  if ((CHECK)); then
    info "not configured — a run asks for the bot token (hidden) and the chat id"
    note "telegram: to be asked for"
    return 0
  fi
  local token chat
  info "the bot token comes from @BotFather; the chat id is the number alerts go to (groups start with -100). Enter skips."
  ask_secret token "Telegram bot token (hidden): "
  if [[ -z "${token}" ]]; then
    warn "skipped — alerts stay visible in Grafana only"
    note "telegram: skipped"
    return 0
  fi
  [[ "${token}" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { unset token; die "that does not look like a bot token (digits:letters); nothing was written"; }
  ask_plain chat "Telegram chat id: "
  [[ "${chat}" =~ ^-?[0-9]+$ ]] || { unset token; die "the chat id must be a number; nothing was written"; }
  env_set ALERT_TELEGRAM_BOT_TOKEN "${token}"
  env_set ALERT_TELEGRAM_CHAT_ID "${chat}"
  unset token
  TELEGRAM_NEW=1
  ok "written to .env (applied by make up below)"
  note "telegram: configured now"
}

# --- 6. R2 ----------------------------------------------------------------------------------------------------------
R2_NEW=0
step_r2() {
  section "6. R2 off-site backups"
  ((DO_R2)) || { info "skipped (--no-r2)"; return 0; }
  local remotes key secret endpoint target
  remotes="$(env_get BACKUP_REMOTES)"
  if [[ " ${remotes} " == *" r2:"* ]]; then
    ok "configured (BACKUP_REMOTES=${remotes})"
    note "r2: ${remotes}"
    return 0
  fi
  target="r2:${R2_BUCKET}/${R2_PREFIX}"
  if ((CHECK)); then
    info "not configured — a run asks for the R2 key id + secret (hidden) and the endpoint, then backs up to ${target}"
    note "r2: to be asked for (${target})"
    return 0
  fi
  info "the values from Cloudflare R2 → Manage API tokens (Object Read & Write, bucket ${R2_BUCKET}); Enter skips."
  ask_secret key "R2 Access Key ID (hidden): "
  if [[ -z "${key}" ]]; then
    warn "skipped — backups stay on this host only"
    note "r2: skipped"
    return 0
  fi
  ask_secret secret "R2 Secret Access Key (hidden): "
  ask_plain endpoint "R2 endpoint (https://<account-id>.r2.cloudflarestorage.com): "
  endpoint="${endpoint%/}"
  if [[ -z "${secret}" || ! "${endpoint}" =~ ^https://[A-Za-z0-9.-]+\.r2\.cloudflarestorage\.com$ ]]; then
    unset key secret
    die "the secret is empty or the endpoint is not an R2 endpoint; nothing was written"
  fi
  env_set RCLONE_CONFIG_R2_ACCESS_KEY_ID "${key}"
  env_set RCLONE_CONFIG_R2_SECRET_ACCESS_KEY "${secret}"
  env_set RCLONE_CONFIG_R2_ENDPOINT "${endpoint}"
  unset key secret
  env_set BACKUP_REMOTES "${target}${remotes:+ ${remotes}}"
  R2_NEW=1
  ok "written to .env: BACKUP_REMOTES=$(env_get BACKUP_REMOTES)"
  note "r2: configured now (${target})"
}

# --- 7. make up -----------------------------------------------------------------------------------------------------
step_up() {
  section "7. make up"
  ((CHECK)) && { info "a run does: make up"; return 0; }
  make -C "${KIT_DIR}" up
}

# --- 8. proof for what was configured just now -----------------------------------------------------------------------
step_prove() {
  ((CHECK)) && return 0
  if ((TELEGRAM_NEW)); then
    section "8a. Telegram test message"
    local chat
    chat="$(env_get ALERT_TELEGRAM_CHAT_ID)"
    if [[ "$(telegram_api sendMessage --data-urlencode "chat_id=${chat}" \
      --data-urlencode "text=n8n kit: $(hostname -s) caught up to $(git -C "${REPO}" rev-parse --short HEAD)" |
      jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
      ok "sent — check Telegram"
    else
      warn "Telegram refused the test message (token or chat id?) — fix it in .env, then make up"
      note "telegram: test message FAILED"
    fi
  fi
  if ((R2_NEW)); then
    section "8b. first backup to R2, then the restore test"
    make -C "${KIT_DIR}" backup-now NAME=catchup-r2
    make -C "${KIT_DIR}" restore-test
  fi
}

# --- 9. recovery key ------------------------------------------------------------------------------------------------
step_recovery_key() {
  section "9. recovery key"
  if [[ ! -f "${KIT_DIR}/secrets/age-recovery-key.txt" ]]; then
    ok "detached (only BACKUP_AGE_RECOVERY_PUBLIC_KEY is on this host)"
    note "recovery key: detached"
    return 0
  fi
  warn "the recovery key is still on this host — it belongs in your password manager"
  if ((CHECK)) || ! has_tty; then
    note "recovery key: ON THIS HOST — make -C compose detach-recovery-key"
    return 0
  fi
  if confirm "Detach it now? (open your password manager first; the screen will show the key — paste it nowhere else)"; then
    make -C "${KIT_DIR}" detach-recovery-key
    note "recovery key: detached now"
  else
    note "recovery key: ON THIS HOST — make -C compose detach-recovery-key"
  fi
}

# --- 10. checks -----------------------------------------------------------------------------------------------------
FAILED=0
step_checks() {
  section "10. checks"
  if ((CHECK)); then
    if [[ -f "${KIT_DIR}/.env" ]] && project_has_database; then
      make -C "${KIT_DIR}" status || true
    fi
    return 0
  fi
  if make -C "${KIT_DIR}" status; then note "status: every service running and healthy"; else note "status: PROBLEMS (above)"; FAILED=1; fi
  if make -C "${KIT_DIR}" doctor; then note "doctor: no problems"; else note "doctor: PROBLEMS (above)"; FAILED=1; fi
  if ((DO_SMOKE)); then
    if make -C "${KIT_DIR}" smoke; then note "smoke: all passed"; else note "smoke: FAILED (above)"; FAILED=1; fi
  fi
}

summary() {
  local line ip domain https_port
  section "summary$( ((CHECK)) && printf ' (--check: nothing was changed)')"
  for line in "${SUMMARY[@]}"; do
    printf '  %s\n' "${line}" >&2
  done
  domain="$(env_get DOMAIN 2>/dev/null || true)"
  domain="${domain:-${DOMAIN_ARG}}"
  https_port="$(env_get HTTPS_PORT 2>/dev/null || true)"
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '\n  A browser on another machine needs, in its hosts file:  %s %s kuma.%s\n' "${ip:-<this-host-ip>}" "${domain}" "${domain}" >&2
  printf '  and the dev CA: make -C compose trust-ca prints the Windows certutil line.\n' >&2
  printf '  Then open https://%s%s/ — and see n8n-kit-HANDOFF.md §2 "Next up" for what is left.\n' "${domain}" \
    "$([[ -n "${https_port}" && "${https_port}" != "443" ]] && printf ':%s' "${https_port}")" >&2
}

main() {
  parse_args "${@}"
  preconditions
  step_git
  step_env
  step_version
  step_profiles
  step_telegram
  step_r2
  step_up
  step_prove
  step_recovery_key
  step_checks
  summary
  ((FAILED == 0)) || die "some checks failed — see the summary"
  ((CHECK)) || ok "this host is caught up"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "${@}"
fi
