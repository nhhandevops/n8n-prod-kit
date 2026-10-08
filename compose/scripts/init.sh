#!/usr/bin/env bash
# compose/scripts/init.sh — create compose/.env (secrets included) and the age backup keys from
# .env.example. S2 contract §7 "init.sh" / TC-001.
#
# Usage (normally through make, which passes the variables through):
#   make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com [HTTP_PORT=80] [HTTPS_PORT=443] [FORCE=1] [CI=1]
#   DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443 bash scripts/init.sh
#
# Inputs are ENVIRONMENT variables (never positional arguments):
#   DOMAIN       required. Dev domains (*.localtest.me, *.local, *.test, *.internal, *.home.arpa,
#                localhost, IPv4) switch TLS_MODE to internal and BACKUP_REMOTES to /backups/local.
#   ACME_EMAIL   required for public domains (Let's Encrypt account); dev domains get dev@example.com.
#   HTTP_PORT / HTTPS_PORT   defaults 80 / 443; a non-443 HTTPS_PORT is appended to PUBLIC_URL.
#   TLS_MODE     optional override (acme | acme-staging | internal) of the rule above.
#   FORCE=1      overwrite an existing .env (backed up to .env.bak.<timestamp>) — DESTRUCTIVE:
#                new secrets, so credentials encrypted with the old N8N_ENCRYPTION_KEY are lost.
#   CI=1 / YES=1 no prompts (confirm answers yes).
# Exit codes: 0 ok · 1 usage/validation/self-check failure · 2 ".env already exists" (no FORCE).
#
# What it does, in order (contract §7):
#   1. validate inputs; refuse to touch an existing .env unless FORCE=1 (then back it up)
#   2. cp .env.example .env (mode 600 before anything secret lands in it); set DOMAIN, ACME_EMAIL,
#      HTTP_PORT, HTTPS_PORT, PUBLIC_URL, TLS_MODE, BACKUP_REMOTES
#   3. generate the secrets (N8N_ENCRYPTION_KEY 64 chars, passwords/tokens hex)
#   4. age keys -> secrets/age-key.txt + secrets/age-recovery-key.txt (kept if they already exist:
#      rotating them silently would orphan every existing backup); public keys into .env
#   5. mkdir secrets backups monitoring/prometheus/targets; chmod 700 secrets; chmod 600 .env secrets/*;
#      run render.sh (compose.scale.yml + Prometheus targets)
#   6. self-check (TC-001) and the red "store your keys" banner
set -euo pipefail
shopt -s inherit_errexit

__script_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
KIT_DIR="$(cd "${__script_dir}/.." && pwd)"
unset __script_dir
cd "${KIT_DIR}"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: DOMAIN=<host> [ACME_EMAIL=<mail>] [HTTP_PORT=80] [HTTPS_PORT=443] [TLS_MODE=acme|acme-staging|internal]
       [FORCE=1] [CI=1] scripts/init.sh
   or: make init DOMAIN=<host> ACME_EMAIL=<mail> [HTTP_PORT=…] [HTTPS_PORT=…] [FORCE=1]

Creates compose/.env from .env.example with generated secrets and the age backup keys.
Dev domains (*.localtest.me, *.local, *.test, *.internal, *.home.arpa, localhost, IPv4) get
TLS_MODE=internal and ACME_EMAIL=dev@example.com automatically; public domains need ACME_EMAIL.
An existing .env is never overwritten without FORCE=1 (exit 2).
USAGE
}

# --- arguments: only -h/--help is accepted; everything else comes from the environment ----------
for arg in "${@}"; do
  case "${arg}" in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unexpected argument '${arg}' — pass settings as environment variables"
      ;;
  esac
done

# --- 1. inputs ------------------------------------------------------------------------------------
domain="${DOMAIN:-}"
if [[ -z "${domain}" ]]; then
  usage
  die "DOMAIN is required (e.g. make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com)"
fi
if [[ ! "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  die "DOMAIN '${domain}' is not a valid host name (letters, digits, dots, dashes; no scheme, no port, no path)"
fi

http_port="${HTTP_PORT:-80}"
https_port="${HTTPS_PORT:-443}"
for port in "${http_port}" "${https_port}"; do
  # 10# forces decimal so a leading zero (0080) is neither octal nor an arithmetic error
  if [[ ! "${port}" =~ ^[0-9]{1,5}$ ]] || (( 10#${port} < 1 || 10#${port} > 65535 )); then
    die "port '${port}' is not a number between 1 and 65535 (HTTP_PORT=${http_port} HTTPS_PORT=${https_port})"
  fi
done
if [[ "${http_port}" == "${https_port}" ]]; then
  die "HTTP_PORT and HTTPS_PORT must differ (both are ${http_port})"
fi

# Dev domain => internal CA, dummy ACME e-mail, local backups. Captured once here because
# is_dev_domain is a predicate function (set -e is suspended inside `if`, hence the directive).
dev_domain=0
# shellcheck disable=SC2310
if is_dev_domain "${domain}"; then
  dev_domain=1
fi

acme_email="${ACME_EMAIL:-}"
if [[ -z "${acme_email}" ]]; then
  if (( dev_domain )); then
    acme_email="dev@example.com"
  else
    die "ACME_EMAIL is required for the public domain '${domain}': Let's Encrypt registers the account with it (expiry warnings). Example: make init DOMAIN=${domain} ACME_EMAIL=ops@${domain#*.}"
  fi
fi
if [[ ! "${acme_email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  die "ACME_EMAIL '${acme_email}' does not look like an e-mail address"
fi

tls_mode="${TLS_MODE:-}"
if [[ -z "${tls_mode}" ]]; then
  if (( dev_domain )); then
    tls_mode="internal"
  else
    tls_mode="acme"
  fi
fi
case "${tls_mode}" in
  acme | acme-staging | internal) ;;
  *)
    die "TLS_MODE '${tls_mode}' is not one of acme | acme-staging | internal"
    ;;
esac

if [[ "${https_port}" == "443" ]]; then
  public_url="https://${domain}/"
else
  public_url="https://${domain}:${https_port}/"
fi

if [[ ! -f "${KIT_DIR}/.env.example" ]]; then
  die "${KIT_DIR}/.env.example is missing — the kit checkout is incomplete"
fi
need_cmd openssl awk mktemp

# --- existing .env: exit 2, or FORCE=1 with a backup -----------------------------------------------
if [[ -e "${KIT_DIR}/.env" ]]; then
  if [[ "${FORCE:-}" != "1" ]]; then
    warn ".env already exists — nothing changed. Edit it in place, or re-run with FORCE=1 to regenerate it"
    warn "(FORCE=1 creates NEW secrets: credentials encrypted with the current N8N_ENCRYPTION_KEY become unreadable)"
    exit 2
  fi
  banner_red \
    "FORCE=1: .env will be REPLACED and ALL secrets regenerated." \
    "A fresh N8N_ENCRYPTION_KEY makes every credential stored in Postgres UNREADABLE." \
    "Keep the backup (.env.bak.<timestamp>) until you are sure you do not need the old key." \
    "The age backup keys in secrets/ are kept (existing backups stay decryptable)."
  # shellcheck disable=SC2310
  if ! confirm "Overwrite .env and generate new secrets?"; then
    die "aborted — .env untouched"
  fi
  # the recovery key's private half may already be detached (make detach-recovery-key): keep its PUBLIC half, or a
  # regenerated .env would silently switch new backups to a fresh recovery key nobody has stored
  previous_recovery_pub="$(env_get BACKUP_AGE_RECOVERY_PUBLIC_KEY)"
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -p "${KIT_DIR}/.env" "${KIT_DIR}/.env.bak.${ts}"
  chmod 600 "${KIT_DIR}/.env.bak.${ts}"
  warn "previous .env saved as .env.bak.${ts} (mode 600)"
fi

# --- 2. .env from the example, identity keys ---------------------------------------------------------
info "writing .env for DOMAIN=${domain} (tls=${tls_mode}, ports ${http_port}/${https_port})"
cp "${KIT_DIR}/.env.example" "${KIT_DIR}/.env"
chmod 600 "${KIT_DIR}/.env"   # before any secret is written into it
env_set DOMAIN "${domain}"
env_set TLS_MODE "${tls_mode}"
env_set ACME_EMAIL "${acme_email}"
env_set HTTP_PORT "${http_port}"
env_set HTTPS_PORT "${https_port}"
env_set PUBLIC_URL "${public_url}"
if (( dev_domain )); then
  # local backups: the ./backups bind mount — a dev box has no rclone remote
  env_set BACKUP_REMOTES "/backups/local"
  info "dev domain: TLS_MODE=internal (local CA, run 'make trust-ca'), ACME_EMAIL=${acme_email}, BACKUP_REMOTES=/backups/local"
fi

# --- 3. secrets -------------------------------------------------------------------------------------
# N8N_ENCRYPTION_KEY: 48 random bytes -> 64 base64 chars (n8n accepts any string; 64 is the
# documented strength). Passwords/tokens are hex so they are always plain .env tokens (no quoting,
# no shell/YAML/URL escaping issues anywhere they are used).
secret_key="$(rand_b64 48)"
env_set N8N_ENCRYPTION_KEY "${secret_key}"
secret_pg="$(rand_hex 24)"
env_set POSTGRES_PASSWORD "${secret_pg}"
secret_valkey="$(rand_hex 24)"
env_set VALKEY_PASSWORD "${secret_valkey}"
secret_runners="$(rand_hex 32)"
env_set N8N_RUNNERS_AUTH_TOKEN "${secret_runners}"
secret_grafana="$(rand_hex 12)"
env_set GRAFANA_ADMIN_PASSWORD "${secret_grafana}"
unset secret_key secret_pg secret_valkey secret_runners secret_grafana
ok "secrets generated (N8N_ENCRYPTION_KEY, POSTGRES_PASSWORD, VALKEY_PASSWORD, N8N_RUNNERS_AUTH_TOKEN, GRAFANA_ADMIN_PASSWORD)"

# --- 5a. directories first (the age keys land in secrets/) -------------------------------------------
mkdir -p "${KIT_DIR}/secrets" "${KIT_DIR}/backups" "${KIT_DIR}/monitoring/prometheus/targets"
chmod 700 "${KIT_DIR}/secrets"

# --- 4. age keys (backups are S5, but the keys are generated now so the recovery key can be stored
#        off-host from day one). Existing keys are NEVER replaced: that would orphan old backups. ---
age_keys_done=0
# age-keygen from the host, or — when the host has no age — from the kit's backup image (built on demand). The image
# runs as the caller's uid so the key file belongs to the operator; `make up` then hands it to the backup container.
age_keygen() {   # age_keygen [-o FILE | -y FILE]
  if command -v age-keygen >/dev/null 2>&1; then
    age-keygen "${@}"
    return
  fi
  if ! docker image inspect n8nkit/backup:local >/dev/null 2>&1; then
    info "age-keygen not installed — building the backup image to use its age"
    compose build --quiet backup >&2
  fi
  local mode="${1}" file="${2}"
  docker run --rm --user "${my_uid}:${my_gid}" --entrypoint age-keygen -v "${KIT_DIR}/secrets:/k:z" n8nkit/backup:local \
    "${mode}" "/k/${file##*/}"
}
my_uid="$(id -u)"
my_gid="$(id -g)"
recovery_file="${KIT_DIR}/secrets/age-recovery-key.txt"
if [[ -s "${KIT_DIR}/secrets/age-key.txt" ]]; then
  info "secrets/age-key.txt already exists — kept (public key re-read from it)"
else
  age_keygen -o "${KIT_DIR}/secrets/age-key.txt" 2>/dev/null
  ok "secrets/age-key.txt generated"
fi
age_pub="$(age_keygen -y "${KIT_DIR}/secrets/age-key.txt")"
if [[ -s "${recovery_file}" ]]; then
  info "secrets/age-recovery-key.txt already exists — kept"
  age_recovery_pub="$(age_keygen -y "${recovery_file}")"
elif [[ -n "${previous_recovery_pub:-}" ]]; then
  info "recovery key is detached (private half off-host) — keeping its public key from the previous .env"
  age_recovery_pub="${previous_recovery_pub}"
else
  age_keygen -o "${recovery_file}" 2>/dev/null
  ok "secrets/age-recovery-key.txt generated — move it off this host: make detach-recovery-key"
  age_recovery_pub="$(age_keygen -y "${recovery_file}")"
fi
if [[ -z "${age_pub}" || -z "${age_recovery_pub}" ]]; then
  die "could not derive the age public keys (is Docker running? is age installed?)"
fi
env_set BACKUP_AGE_PUBLIC_KEY "${age_pub}"
env_set BACKUP_AGE_RECOVERY_PUBLIC_KEY "${age_recovery_pub}"
age_keys_done=1

# --- 5b. permissions, render ----------------------------------------------------------------------------
chmod 600 "${KIT_DIR}/.env"
# only files this user owns: after `make up`, secrets/age-key.txt belongs to the backup container's uid (0440)
find "${KIT_DIR}/secrets" -maxdepth 1 -type f -user "${my_uid}" -exec chmod 600 {} +
bash "${KIT_DIR}/scripts/render.sh"

# --- 6. self-check (TC-001) ----------------------------------------------------------------------------
info "self-check"
failures=0

check_key_len="$(env_get N8N_ENCRYPTION_KEY)"
if (( ${#check_key_len} >= 32 )); then
  ok "N8N_ENCRYPTION_KEY is ${#check_key_len} chars (>= 32)"
else
  fail "N8N_ENCRYPTION_KEY is only ${#check_key_len} chars"
  failures=$((failures + 1))
fi
unset check_key_len

for secret_name in N8N_ENCRYPTION_KEY POSTGRES_PASSWORD VALKEY_PASSWORD N8N_RUNNERS_AUTH_TOKEN GRAFANA_ADMIN_PASSWORD; do
  check_val="$(env_get "${secret_name}")"
  if [[ -n "${check_val}" ]]; then
    ok "${secret_name} is set"
  else
    fail "${secret_name} is empty"
    failures=$((failures + 1))
  fi
done
unset check_val

env_mode="$(stat -c '%a' "${KIT_DIR}/.env" 2>/dev/null || stat -f '%Lp' "${KIT_DIR}/.env")"
if [[ "${env_mode}" == "600" ]]; then
  ok ".env mode is 600"
else
  fail ".env mode is ${env_mode}, expected 600"
  failures=$((failures + 1))
fi

if bash "${KIT_DIR}/scripts/pin.sh" --check; then
  ok "versions.env digests present (pin.sh --check)"
else
  fail "versions.env has empty digests — run 'make pin'"
  failures=$((failures + 1))
fi

if command -v docker >/dev/null 2>&1; then
  # shellcheck disable=SC2310
  if compose config -q; then
    ok "docker compose config parses with the new .env"
  else
    fail "docker compose config failed with the new .env (see the error above)"
    failures=$((failures + 1))
  fi
else
  warn "docker not found — skipped 'compose config' (run scripts/bootstrap-host.sh, then 'make config')"
fi

if (( failures > 0 )); then
  die "self-check failed (${failures} problem(s)) — .env was written, fix the problems above before 'make up'"
fi

# --- banner ---------------------------------------------------------------------------------------------
banner_lines=(
  "STORE THESE IN A PASSWORD MANAGER NOW — THEY CANNOT BE RECOVERED LATER"
  ""
  "  N8N_ENCRYPTION_KEY   in ${KIT_DIR}/.env        (reveal: grep '^N8N_ENCRYPTION_KEY=' .env)"
)
if (( age_keys_done )); then
  banner_lines+=("  recovery age key     ${KIT_DIR}/secrets/age-recovery-key.txt  (keep a copy OFF this host)")
fi
banner_lines+=(
  ""
  "Losing the encryption key = every stored credential is unreadable."
  "Losing the recovery key   = encrypted backups cannot be restored on a new host."
)
banner_red "${banner_lines[@]}"
ok "init done for ${public_url} — next: make lint, make up"
