#!/usr/bin/env bash
# compose/scripts/lib.sh — shared shell library of the n8n Production Kit (S2 contract §6).
#
# Every script under compose/scripts/ sources this file exactly like this:
#     # shellcheck source=lib.sh
#     source "${KIT_DIR}/scripts/lib.sh"
# Other authors (Makefile, preflight.sh, status.sh, dev-ca.sh, trust-ca.sh) code against the
# function names, arguments and output formats documented below WITHOUT reading the bodies, so a
# signature or output change here is a contract change (update CONTRACT.md §6 first).
#
# Design rules:
#   * Everything prints to STDERR except the functions whose job is to print a value
#     (env_get, rand_hex, rand_b64, service_health) — callers capture those with "$(...)".
#   * No function changes the caller's cwd or shell options (compose runs in the same shell,
#     load_env only toggles `set -a` around the two source lines).
#   * Sourceable twice without side effects (guard right below).
#   * shellcheck-clean under `enable=all`: braces on every expansion, [[ ]], quoted expansions.

# ---------------------------------------------------------------------------------------------
# Double-source guard. Makefile recipes and scripts chain each other (init.sh -> render.sh ->
# pin.sh), and each of them sources this file; the second source must be a no-op.
# ---------------------------------------------------------------------------------------------
if [[ -n "${__KIT_LIB:-}" ]]; then
  return 0
fi
__KIT_LIB=1

# ---------------------------------------------------------------------------------------------
# KIT_DIR: absolute path of compose/ (this file lives in compose/scripts/). Scripts set it before
# sourcing (contract §1); when a script forgets, derive it from this file's own location so the
# relative file names below (.env, versions.env, docker-compose.yml) always resolve.
# ${BASH_SOURCE[0]:-$0} (not ${BASH_SOURCE[0]}) keeps `set -u` happy under `bash -c`/piped input.
# ---------------------------------------------------------------------------------------------
if [[ -z "${KIT_DIR:-}" ]]; then
  __kit_lib_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
  KIT_DIR="$(cd "${__kit_lib_dir}/.." && pwd)"
  unset __kit_lib_dir
fi

# ---------------------------------------------------------------------------------------------
# Colour: only when stderr is a terminal AND NO_COLOR is unset (https://no-color.org). Logs piped
# into files or CI output therefore never contain escape codes.
# ---------------------------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  __kit_c_red=$'\e[31m'
  __kit_c_green=$'\e[32m'
  __kit_c_yellow=$'\e[33m'
  __kit_c_blue=$'\e[34m'
  __kit_c_bold=$'\e[1m'
  __kit_c_reset=$'\e[0m'
else
  __kit_c_red=''
  __kit_c_green=''
  __kit_c_yellow=''
  __kit_c_blue=''
  __kit_c_bold=''
  __kit_c_reset=''
fi

# ---------------------------------------------------------------------------------------------
# Logging (all to stderr so command substitutions stay clean).
#   log  msg   plain line, no prefix (banners, tables)
#   info msg   "[info] msg"
#   ok   msg   "[ OK ] msg"
#   warn msg   "[warn] msg"
#   fail msg   "[FAIL] msg"      (does NOT exit — preflight prints many FAIL lines then exits once)
#   die  msg [code]   fail + exit (default code 1)
# ---------------------------------------------------------------------------------------------
log() {
  printf '%s\n' "${*}" >&2
}

info() {
  printf '%s[info]%s %s\n' "${__kit_c_blue}" "${__kit_c_reset}" "${*}" >&2
}

ok() {
  printf '%s[ OK ]%s %s\n' "${__kit_c_green}" "${__kit_c_reset}" "${*}" >&2
}

warn() {
  printf '%s[warn]%s %s\n' "${__kit_c_yellow}" "${__kit_c_reset}" "${*}" >&2
}

fail() {
  printf '%s[FAIL]%s %s\n' "${__kit_c_red}" "${__kit_c_reset}" "${*}" >&2
}

die() {
  fail "${1:-fatal error}"
  exit "${2:-1}"
}

# Red, bold, framed block for the messages a human must not skim past (init's key banner,
# FORCE warnings). Each argument is one line.
banner_red() {
  local line
  printf '%s%s' "${__kit_c_red}" "${__kit_c_bold}" >&2
  printf '%s\n' '=================================================================================' >&2
  for line in "${@}"; do
    if [[ -z "${line}" ]]; then
      printf '\n' >&2
    else
      printf '  %s\n' "${line}" >&2
    fi
  done
  printf '%s\n' '=================================================================================' >&2
  printf '%s' "${__kit_c_reset}" >&2
}

# ---------------------------------------------------------------------------------------------
# need_cmd cmd...   die listing EVERY missing command at once (one round-trip, not one per tool).
# ---------------------------------------------------------------------------------------------
need_cmd() {
  local cmd
  local -a missing=()
  for cmd in "${@}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing required command(s): ${missing[*]} — install them (scripts/bootstrap-host.sh does) and retry"
  fi
}

# ---------------------------------------------------------------------------------------------
# load_env   export every key of versions.env then .env into the current shell (set -a).
# For shell consumers of simple scalar keys (DOMAIN, TLS_MODE, PUBLIC_URL, ports...). The compose
# command never needs it: Compose parses both files itself via --env-file. Because this uses bash
# `source`, .env must stay bash-compatible — exactly what .env.example and env_set produce
# (values with $ or spaces are single-quoted). Dies when .env is missing (run `make init`).
# ---------------------------------------------------------------------------------------------
load_env() {
  if [[ ! -f "${KIT_DIR}/versions.env" ]]; then
    die "${KIT_DIR}/versions.env not found — the kit checkout is incomplete"
  fi
  if [[ ! -f "${KIT_DIR}/.env" ]]; then
    die "${KIT_DIR}/.env not found — run 'make init DOMAIN=<your-domain>' first"
  fi
  set -a
  # shellcheck source=/dev/null
  source "${KIT_DIR}/versions.env"
  # shellcheck source=/dev/null
  source "${KIT_DIR}/.env"
  set +a
}

# ---------------------------------------------------------------------------------------------
# env_get KEY [file]   print the value of KEY from a dotenv file (default .env) WITHOUT sourcing it,
# decoded the way Compose's dotenv parser reads it; prints nothing (exit 0) when KEY is absent.
#   KEY=bare value        -> "bare value"  (trailing " # comment" stripped, $$ collapsed to $)
#   KEY='single quoted'   -> literal contents, nothing interpreted
#   KEY="double quoted"   -> contents with \" -> ", \\ -> \ and $$ -> $
#   export KEY=...        -> accepted (dotenv syntax)
# Last definition wins (dotenv semantics). CRLF files are tolerated. Not handled on purpose:
# ${OTHER} references inside bare/double-quoted values (Compose would expand them) — the kit never
# writes such values. Pure bash, so a .env with arbitrary content can never execute anything.
# ---------------------------------------------------------------------------------------------
env_get() {
  local key="${1:?env_get: KEY required}"
  local file="${2:-${KIT_DIR}/.env}"
  local line raw='' found=0
  local bs="\\" dq='"' dl='$'
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "${line}" =~ ^export[[:space:]]+(.*)$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi
    if [[ "${line}" == "${key}="* ]]; then
      raw="${line#"${key}="}"
      found=1
    fi
  done <"${file}"
  if (( found == 0 )); then
    return 0
  fi
  # trim both ends
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  case "${raw}" in
    \'*\')
      raw="${raw#\'}"
      raw="${raw%\'}"
      ;;
    \"*\")
      raw="${raw#\"}"
      raw="${raw%\"}"
      raw="${raw//"${bs}${dq}"/${dq}}"
      raw="${raw//"${bs}${bs}"/${bs}}"
      raw="${raw//"${dl}${dl}"/${dl}}"
      ;;
    *)
      # bare value: an inline comment starts at the first whitespace followed by '#'
      raw="${raw%%[[:space:]]#*}"
      raw="${raw%"${raw##*[![:space:]]}"}"
      raw="${raw//"${dl}${dl}"/${dl}}"
      ;;
  esac
  printf '%s\n' "${raw}"
}

# ---------------------------------------------------------------------------------------------
# env_set KEY VALUE [file]   replace every "KEY=..." line in place, or append "KEY=VALUE" when the
# key is absent (default file .env; the file is created if missing). Comments, order and the other
# lines are untouched. VALUE is encoded so that BOTH Compose's dotenv parser and bash `source`
# (load_env) read it back unchanged:
#   plain token  [A-Za-z0-9_./:@+=,%-]   -> KEY=value
#   anything else without a single quote  -> KEY='value'      (literal for Compose AND bash —
#                                            this is why a bcrypt hash like $2a$14$... is safe)
#   contains a single quote               -> KEY="value" with \ -> \\, " -> \", $ -> $$
#                                            (exact for Compose; bash `source` would expand the
#                                            $$ — such values are rare and documented, not used
#                                            by the kit itself)
# Implementation: awk writes a temp file next to the target, the temp file receives the target's
# mode (so .env stays 0600), then mv replaces the target atomically. The value travels through the
# environment (ENVIRON), never through awk -v, so backslashes are not re-interpreted.
# ---------------------------------------------------------------------------------------------
env_set() {
  local key="${1:?env_set: KEY required}"
  local value="${2-}"
  local file="${3:-${KIT_DIR}/.env}"
  local quoted tmp mode
  local bs="\\" dq='"' dl='$'
  if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    die "env_set: invalid key name '${key}'"
  fi
  if [[ "${value}" =~ ^[A-Za-z0-9_./:@+=,%-]*$ ]]; then
    quoted="${value}"
  elif [[ "${value}" != *"'"* ]]; then
    quoted="'${value}'"
  elif [[ "${value}" == *'`'* ]]; then
    # inside double quotes a backtick is command substitution for anything that sources .env with bash (load_env),
    # and Compose has no escape for it — such a value cannot be stored safely
    die "env_set: the value for ${key} contains both ' and \` — not supported in .env"
  else
    quoted="${value//"${bs}"/${bs}${bs}}"
    quoted="${quoted//"${dq}"/${bs}${dq}}"
    quoted="${quoted//"${dl}"/${dl}${dl}}"
    quoted="${dq}${quoted}${dq}"
  fi
  tmp="$(mktemp "${file}.XXXXXX")"
  if [[ -f "${file}" ]]; then
    KEY="${key}" LINE="${key}=${quoted}" awk '
      BEGIN { k = ENVIRON["KEY"]; l = ENVIRON["LINE"]; done = 0 }
      {
        s = $0
        sub(/\r$/, "", s)
        sub(/^[ \t]+/, "", s)
        sub(/^export[ \t]+/, "", s)
        if (index(s, k "=") == 1) { print l; done = 1; next }
        print
      }
      END { if (!done) print l }
    ' "${file}" >"${tmp}"
    mode="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}")"
    chmod "${mode}" "${tmp}"
  else
    printf '%s=%s\n' "${key}" "${quoted}" >"${tmp}"
  fi
  mv -f "${tmp}" "${file}"
}

# ---------------------------------------------------------------------------------------------
# size_mb SIZE   Docker/compose size ("1536m", "2g", "512M", "1048576k", plain bytes) -> whole MiB;
# prints nothing for an unparsable value.
# ---------------------------------------------------------------------------------------------
size_mb() {
  local v="${1,,}" n unit
  if [[ ! "${v}" =~ ^([0-9]+)([bkmg]?)b?$ ]]; then
    return 0
  fi
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "${unit}" in
    g) printf '%s\n' "$(( n * 1024 ))" ;;
    m) printf '%s\n' "${n}" ;;
    k) printf '%s\n' "$(( n / 1024 ))" ;;
    *) printf '%s\n' "$(( n / 1048576 ))" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# backup_path_problem PATH   why PATH must not be BACKUP_LOCAL_PATH (prints the reason; prints
# nothing when it is fine). backup-perms.sh hands that directory to the backup container's uid as
# root, so a wrong value could lock the operator out of $HOME (sshd refuses keys in a home dir it
# does not own) or open a system directory to a group. Accepted: an existing directory that is
# empty or holds only what the kit writes there (the kind directories), outside system paths.
# ---------------------------------------------------------------------------------------------
backup_path_problem() {
  local p="${1}" real entry base home_real
  if [[ ! -d "${p}" ]]; then
    printf 'does not exist (mount the external disk / NAS first)\n'
    return 0
  fi
  real="$(cd "${p}" && pwd -P)"
  case "${real}" in
    / | /home | /mnt | /media | /srv | /opt | /var | /tmp | /var/tmp | /root | /data | /backup | /backups |       /bin | /bin/* | /boot | /boot/* | /dev | /dev/* | /etc | /etc/* | /lib | /lib/* | /lib32 | /lib32/* |       /lib64 | /lib64/* | /proc | /proc/* | /run | /run/* | /sbin | /sbin/* | /sys | /sys/* | /usr | /usr/* |       /var/lib | /var/lib/* | /var/log | /var/log/*)
      printf 'is a system directory (%s) — use a dedicated sub-directory, e.g. /mnt/usb/n8n-backups\n' "${real}"
      return 0
      ;;
    *) ;;
  esac
  home_real=''
  if [[ -n "${HOME:-}" && -d "${HOME}" ]]; then
    home_real="$(cd "${HOME}" && pwd -P)" || home_real=''
  fi
  if [[ "${real}" == "${home_real}" || "${KIT_DIR}/" == "${real}/"* ]]; then
    printf 'is your home directory or contains the kit (%s) — use a dedicated sub-directory\n' "${real}"
    return 0
  fi
  for entry in "${real}"/* "${real}"/.[!.]*; do
    [[ -e "${entry}" ]] || continue
    base="${entry##*/}"
    case "${base}" in
      daily | monthly | manual | pre-upgrade | pre-restore | lost+found) ;;
      *)
        printf 'already holds other files (%s) — the kit changes its owner; use an empty sub-directory, e.g. %s/n8n-backups\n' "${base}" "${real}"
        return 0
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------------------------
# is_dev_domain DOMAIN   exit 0 when DOMAIN can never get a public certificate: *.localtest.me
# (and localtest.me itself, both resolve to 127.0.0.1), localhost / *.localhost, *.local, *.test,
# *.internal, *.home.arpa, and IPv4 literals. init.sh switches such domains to TLS_MODE=internal,
# a dummy ACME_EMAIL and local backups. Case-insensitive.
# ---------------------------------------------------------------------------------------------
is_dev_domain() {
  local d="${1:-}"
  d="${d,,}"
  case "${d}" in
    localhost | *.localhost | localtest.me | *.localtest.me | *.local | *.test | *.internal | *.home.arpa)
      return 0
      ;;
    *)
      ;;
  esac
  [[ "${d}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# ---------------------------------------------------------------------------------------------
# rand_hex N   N random bytes as 2N hex chars.     rand_b64 N   N random bytes as base64 (one line;
# 48 bytes -> exactly 64 chars, the N8N_ENCRYPTION_KEY format). openssl is the CSPRNG every host has.
# ---------------------------------------------------------------------------------------------
rand_hex() {
  openssl rand -hex "${1:?rand_hex: byte count required}"
}

rand_b64() {
  local b64
  b64="$(openssl rand -base64 "${1:?rand_b64: byte count required}")"
  # openssl wraps base64 at 64 columns: join the lines so the caller always gets one token
  printf '%s\n' "${b64//$'\n'/}"
}

# ---------------------------------------------------------------------------------------------
# confirm "question"   ask y/N on the real terminal. Returns 0 for yes, 1 for no.
#   CI=1 or YES=1            -> auto-yes, nothing is asked (unattended runs)
#   no usable /dev/tty       -> die with the hint to pass YES=1 (a prompt nobody can answer would
#                               hang `curl | bash`, cron and CI; (exec 3</dev/tty) is the only
#                               reliable "is there really a terminal" probe — [[ -t 0 ]] lies under
#                               `bash -s` and inside make)
# ---------------------------------------------------------------------------------------------
confirm() {
  local question="${1:-Continue?}"
  local reply=''
  if [[ "${CI:-}" == "1" || "${YES:-}" == "1" ]]; then
    info "${question} [auto-yes: CI/YES set]"
    return 0
  fi
  if ! (exec 3</dev/tty) 2>/dev/null; then
    die "no terminal to answer '${question}' — re-run with YES=1 (or CI=1) to confirm non-interactively"
  fi
  printf '%s [y/N] ' "${question}" >&2
  read -r reply </dev/tty || reply=''
  [[ "${reply}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------------------------
# compose args...   THE compose command of contract §4 (the Makefile builds the identical list):
#   docker compose --project-directory compose/ --env-file versions.env --env-file .env
#                  -f docker-compose.yml [-f compose.dev.yml if TLS_MODE=internal]
#                  [-f compose.scale.yml if it exists]
# Later --env-file entries override earlier ones (verified), so .env beats versions.env. Absolute
# paths make the call cwd-independent; --project-directory keeps relative bind mounts rooted in
# compose/. TLS_MODE is read from .env (not the shell) exactly like the Makefile's grep does.
# ---------------------------------------------------------------------------------------------
compose() {
  local tls_mode
  local -a files=(-f "${KIT_DIR}/docker-compose.yml")
  tls_mode="$(env_get TLS_MODE)"
  if [[ "${tls_mode}" == "internal" ]]; then
    files+=(-f "${KIT_DIR}/compose.dev.yml")
  fi
  if [[ -f "${KIT_DIR}/compose.scale.yml" ]]; then
    files+=(-f "${KIT_DIR}/compose.scale.yml")
  fi
  docker compose --project-directory "${KIT_DIR}" \
    --env-file "${KIT_DIR}/versions.env" --env-file "${KIT_DIR}/.env" \
    "${files[@]}" "${@}"
}

# Project name as Compose computes it: COMPOSE_PROJECT_NAME from the shell, else from .env
# (the kit sets n8nkit there), else the directory name normalised like Compose does.
_kit_project_name() {
  local project="${COMPOSE_PROJECT_NAME:-}"
  if [[ -z "${project}" ]]; then
    project="$(env_get COMPOSE_PROJECT_NAME)"
  fi
  if [[ -z "${project}" ]]; then
    project="$(basename "${KIT_DIR}")"
    project="${project,,}"
    project="${project//[^a-z0-9_-]/}"
  fi
  printf '%s\n' "${project}"
}

# ---------------------------------------------------------------------------------------------
# service_health SVC   print one word for the service's container:
#   healthy | unhealthy | starting   (from docker inspect .State.Health)
#   none      container exists but defines no healthcheck (counts as healthy while running —
#             the caller checks .State.Status itself, e.g. status.sh)
#   missing   no container for that service in this project (never created, or removed)
# Containers are found through the labels Compose stamps on them, so this works without parsing
# the compose files and even while compose.scale.yml has just been deleted. The first container
# is used when a service was scaled with --scale.
# ---------------------------------------------------------------------------------------------
service_health() {
  local svc="${1:?service_health: SERVICE required}"
  local project cids cid
  project="$(_kit_project_name)"
  cids="$(docker ps -aq \
    --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=${svc}")" ||
    die "docker ps failed — is the Docker daemon running and are you in the docker group?"
  cid="${cids%%$'\n'*}"
  if [[ -z "${cid}" ]]; then
    printf 'missing\n'
    return 0
  fi
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}"
}

# ---------------------------------------------------------------------------------------------
# Versions and upgrades (S7) — used by upgrade.sh, rollback.sh, doctor.sh and the version guard
# that `make up`, `make restart`, scale.sh and restore.sh run before they start n8n.
#   UPGRADE_DIR / UPGRADE_STATE   compose/.upgrade/ (gitignored) and its state.env: the upgrade or
#                                 rollback in progress or last finished (keys documented in upgrade.sh)
# ---------------------------------------------------------------------------------------------
UPGRADE_DIR="${KIT_DIR}/.upgrade"
UPGRADE_STATE="${UPGRADE_DIR}/state.env"

# version_ge A B   true when dotted version A >= B (sort -V does the comparison).
version_ge() {
  local lowest
  lowest="$(printf '%s\n%s\n' "${2}" "${1}" | sort -V)"
  [[ "${lowest%%$'\n'*}" == "${2}" ]]
}

# is_release_version V   plain x.y.z — what n8n publishes as releases (no latest/next/beta/rc tags).
is_release_version() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# kit_container SVC   id of the service's container in this project (running or stopped), empty when none.
kit_container() {
  local project
  project="$(_kit_project_name)"
  docker ps -aq --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=${1:?kit_container: SERVICE required}" | head -1 || true
}

# image_version_of SVC   the version label (org.opencontainers.image.version) of the image SVC's container
# runs — the truth about what runs: the tag in Config.Image follows whatever N8N_VERSION Compose was given,
# even with an older digest. Empty when there is no container.
image_version_of() {
  local cid
  cid="$(kit_container "${1}")"
  [[ -n "${cid}" ]] || return 0
  docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${cid}" 2>/dev/null || true
}

# image_digest_of SVC   the sha256 digest SVC's container was created from (the part after @ in
# Config.Image — the kit always pins one). Empty when there is no container or no digest.
image_digest_of() {
  local cid img
  cid="$(kit_container "${1}")"
  [[ -n "${cid}" ]] || return 0
  img="$(docker inspect --format '{{.Config.Image}}' "${cid}" 2>/dev/null || true)"
  [[ "${img}" == *@sha256:* ]] && printf '%s\n' "${img##*@}"
  return 0
}

# kit_psql SQL   one query against n8n's database as its owner (inside the postgres container), unaligned,
# tuples only. Non-zero when postgres is not running or the query fails.
kit_psql() {
  compose exec -T postgres psql -X -At -v ON_ERROR_STOP=1 -U n8n -d n8n -c "${1}" 2>/dev/null
}

# db_n8n_version   the n8n version that last started against the database (n8n's own
# instance_version_history, one row per version change); empty when unknown (postgres down, older n8n).
db_n8n_version() {
  kit_psql "select major || '.' || minor || '.' || patch from instance_version_history order by \"createdAt\" desc, id desc limit 1" |
    head -1 || true
}

# db_migration_mark   "<count>:<newest timestamp>" of n8n's migrations table — changes exactly when a migration ran.
db_migration_mark() {
  kit_psql 'select count(*) || chr(58) || coalesce(max("timestamp"), 0) from migrations' | head -1 || true
}

# upgrade_phase   PHASE of the upgrade/rollback in .upgrade/state.env; empty when there never was one.
upgrade_phase() {
  [[ -f "${UPGRADE_STATE}" ]] || return 0
  env_get PHASE "${UPGRADE_STATE}"
}

# upgrade_pending   true while an upgrade or rollback is unfinished (any PHASE but done / rolled-back / aborted).
upgrade_pending() {
  local phase
  phase="$(upgrade_phase)"
  [[ -n "${phase}" && ! "${phase}" =~ ^(done|rolled-back|aborted)$ ]]
}

# version_guard "WHAT"   die before WHAT would start n8n on the wrong version:
#   * an upgrade or rollback is unfinished — it owns the stack until `make upgrade RESUME=1` / `make rollback`;
#   * versions.env pins a NEWER n8n than this installation runs — that is an upgrade, and only `make upgrade`
#     takes the backup and runs the migrations in order;
#   * versions.env pins an OLDER n8n than the database was last used with — n8n would start on the newer schema
#     without a word (it ignores migrations it does not know).
# "Runs" = the version label of n8n-main's container; without one (after make down) the database's own record.
# Skipped inside make upgrade / make rollback (KIT_UPGRADE_INTERNAL=1); FORCE_VERSION=1 is the expert override.
version_guard() {
  local what="${1:-this command}" pinned running seen project phase
  [[ "${KIT_UPGRADE_INTERNAL:-}" == "1" ]] && return 0
  if upgrade_pending; then
    phase="$(upgrade_phase)"
    die "an upgrade is unfinished (PHASE=${phase}; make doctor shows it) — finish it with 'make upgrade RESUME=1' or undo it with 'make rollback' before ${what}"
  fi
  pinned="$(env_get N8N_VERSION "${KIT_DIR}/versions.env")"
  running="$(image_version_of n8n-main)"
  seen="n8n-main runs"
  if [[ -z "${running}" ]]; then
    project="$(_kit_project_name)"
    if docker volume inspect "${project}_pg_data" >/dev/null 2>&1; then
      # the stack is down but has a database: ask it which n8n used it last
      compose up -d --wait postgres >/dev/null 2>&1 || true
      running="$(db_n8n_version)"
      seen="the database was last used by"
    fi
  fi
  if [[ -z "${running}" || "${running}" == "${pinned}" ]]; then
    return 0
  fi
  if [[ "${FORCE_VERSION:-}" == "1" ]]; then
    warn "FORCE_VERSION=1: versions.env pins n8n ${pinned}, ${seen} ${running} — continuing anyway"
    return 0
  fi
  if version_ge "${pinned}" "${running}"; then
    die "versions.env pins n8n ${pinned}, ${seen} ${running} — apply the new version with 'make upgrade' (it takes a backup, then runs the migrations in order), not ${what}"
  fi
  die "versions.env pins n8n ${pinned}, but ${seen} ${running} — n8n cannot go back on a database a newer version migrated. After 'make upgrade' use 'make rollback'; if versions.env came from git, pin forward: PIN_ONLY='N8N RUNNERS' make pin N8N_VERSION=${running}"
}
