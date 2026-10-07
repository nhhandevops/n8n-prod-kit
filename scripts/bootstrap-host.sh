#!/usr/bin/env bash
# =============================================================================
# scripts/bootstrap-host.sh — prepare a fresh Linux host for the n8n Production Kit
# =============================================================================
#
# This is the FIRST thing a user runs on a new VPS. It installs Docker Engine and
# the Compose plugin from Docker's official repository, the few tools the kit's
# Makefile needs (make, jq, git, curl), and applies the host settings the kit's
# `make preflight` later checks for. It is idempotent: a second run changes nothing
# and finishes in about a second.
#
# WHAT IT DOES, IN ORDER
#   1. detects the distribution from /etc/os-release
#   2. adds Docker's package repository
#        apt family : /etc/apt/keyrings/docker.asc + deb822 /etc/apt/sources.list.d/docker.sources
#        dnf family : /etc/yum.repos.d/docker-ce.repo (copied verbatim from download.docker.com)
#   3. installs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
#      make jq git (+ curl ca-certificates gnupg on apt; EL already ships curl, see DNF_PKGS)
#   4. sets vm.overcommit_memory=1 now and persistently (Valkey needs it)
#   5. enables + starts docker.service                       (skip with --no-start)
#   6. adds the invoking sudo user to the `docker` group     (skip with --no-group)
#   7. opens http/https in firewalld when firewalld is running (EL hosts)
#   8. prints `docker --version`, `docker compose version`, what it did and what it did NOT do
#
# HOW TO RUN (always as root; the script re-executes itself with sudo when it can)
#   curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash -s -- --yes
#   sudo bash scripts/bootstrap-host.sh              # from a clone; asks before changing anything
#   bash scripts/bootstrap-host.sh --help
#
# SUPPORTED (verified 2026-10-07, see FACTS/verify:bootstrap in the kit's docs)
#   Ubuntu 24.04 / 26.04, Debian 12 / 13, RHEL / Rocky / AlmaLinux / CentOS Stream / Oracle Linux 9 and 10.
#   Other apt/dnf releases are attempted with a warning; anything else exits 2.
#
# DESIGN NOTES (why the script looks the way it does)
#   * `curl ... | bash` means stdin IS the script. Nothing here may read stdin:
#     prompts go through /dev/tty, and main() runs with stdin redirected from
#     /dev/null so apt/dnf/curl can never swallow the rest of the script.
#     Also, in that form $0 is "bash" and BASH_SOURCE is empty, so every reference
#     is `${BASH_SOURCE[0]:-}` (a bare `${BASH_SOURCE[0]}` aborts under set -u).
#   * The whole script is parsed before main() runs (it is the last line), so a
#     truncated download executes nothing.
#   * Every file write is compare-then-replace, every package step is checked
#     against dpkg/rpm first: re-running is safe and fast.
#   * Nothing is ever uninstalled. Conflicting packages (docker.io, podman-docker,
#     runc, ...) make the script stop with the exact removal command (exit 3).
#   * Shellcheck: `enable=all` clean. Helper functions report through globals
#     (WRITE_RESULT, MISSING, ...) instead of exit codes, because under `set -e` a
#     function used in an `if`/`||` condition silently loses errexit (SC2310).
#
# EXIT CODES
#   0 ok · 1 usage error, aborted at the prompt, or a command failed
#   2 unsupported distribution · 3 conflicting packages installed · 4 docker.service did not come up
# =============================================================================

set -Eeuo pipefail

# Printed in the banner so an operator can tell WHICH copy of the script ran
# (a stale copy on the host is the classic "but I fixed that" failure).
readonly SCRIPT_VERSION="2026-10-07.2"

# Predictable output from dpkg/rpm/getenforce/apt regardless of the host locale
# ("C" always exists, so this never triggers "setlocale: cannot change locale").
export LC_ALL=C

# ---------------------------------------------------------------------------
# Settings a maintainer may want to change
# ---------------------------------------------------------------------------
# The kit's `make preflight` requires Docker >= 27 and Compose >= 2.30; the
# bootstrap only WARNS when an already-installed Docker is older than that.
readonly DOCKER_MIN_MAJOR=27
readonly COMPOSE_MIN_MAJOR=2
readonly COMPOSE_MIN_MINOR=30

# apt family package list (Docker's official five + the kit's tools).
# gnupg is not strictly needed any more (apt >= 2.4 reads the ASCII-armoured
# docker.asc directly) but it is cheap and some operators expect `gpg` to exist.
readonly APT_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                   make jq curl git ca-certificates gnupg)
# dnf family package list. NEVER add `curl` here: EL9 images ship curl-minimal and
# "dnf install curl" aborts the WHOLE transaction with a curl-minimal conflict
# (verified on Rocky/Alma 9.8, CentOS Stream 9, RHEL 9). /usr/bin/curl already
# exists on every EL9/EL10 host (curl-minimal or full curl).
readonly DNF_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                   make jq git)

# Packages that break the install if present. Verified against Docker's own
# repository metadata (noble Packages index and the el9 primary.xml, 2026-10-07):
#   docker-ce      Conflicts: docker.io (deb)  /  docker, docker-ee, docker-io (rpm)
#   docker-ce-cli  Conflicts: docker-cli, docker.io (deb)
#   containerd.io  Conflicts + Replaces/Obsoletes: containerd, runc (deb AND rpm)
# So apt would silently REMOVE docker.io/containerd/runc to satisfy docker-ce, and
# dnf would swap out containerd/runc through the Obsoletes — which breaks a podman
# setup that uses runc. podman-docker ships /usr/bin/docker (file conflict with
# docker-ce-cli → the transaction fails); Ubuntu's docker-compose-v2/docker-buildx
# ship the same cli-plugin paths as Docker's plugins. The operator should decide,
# so the script stops and names them (exit 3). The remaining names are the old
# package names Docker's docs list for removal (harmless when absent).
readonly APT_CONFLICTS=(docker.io docker-doc docker-compose-v2 docker-buildx podman-docker containerd runc)
readonly DNF_CONFLICTS=(docker docker-io docker-engine docker-ee docker-ee-cli docker-engine-cs containerd runc podman-docker)

readonly APT_KEYRING=/etc/apt/keyrings/docker.asc
readonly APT_SOURCES=/etc/apt/sources.list.d/docker.sources
readonly APT_LEGACY_LIST=/etc/apt/sources.list.d/docker.list   # the pre-2024 one-line form
# One repo file for every EL variant: Docker's docs name centos/ for CentOS Stream
# and rhel/ for RHEL and say nothing about Rocky/Alma; both files serve the same
# rpms for el9/el10 (rhel/ is a strict subset) and both resolve $releasever to
# 9/10 on Rocky, Alma, CentOS Stream, Oracle and RHEL (verified).
readonly DNF_REPO=/etc/yum.repos.d/docker-ce.repo
readonly DNF_REPO_URL=https://download.docker.com/linux/centos/docker-ce.repo
readonly SYSCTL_FILE=/etc/sysctl.d/90-n8nkit.conf

readonly KIT_REPO_URL=https://github.com/nhhandevops/n8n-prod-kit.git

# ---------------------------------------------------------------------------
# Flags and run-state globals
# ---------------------------------------------------------------------------
ASSUME_YES=0      # --yes      : no confirmation prompt (mandatory when there is no terminal)
NO_START=0        # --no-start : do not enable/start docker.service (containers, image builds, CI)
NO_GROUP=0        # --no-group : do not touch group membership
BOOTSTRAP_RC=0    # final exit code (4 when the daemon did not come up; everything else dies immediately)

OS_ID="" OS_LIKE="" OS_VERSION_ID="" OS_MAJOR="" OS_CODENAME="" OS_PLATFORM_ID="" OS_PRETTY=""
OS_FAMILY=""      # apt | dnf
APT_DISTRO=""     # ubuntu | debian  (path component under https://download.docker.com/linux/)

# "Return values" of helpers (see DESIGN NOTES on SC2310).
WRITE_RESULT=""   # written | unchanged
MISSING=()        # packages from APT_PKGS/DNF_PKGS that are not installed
CONFLICTS=()      # packages from *_CONFLICTS that ARE installed

DID=()            # summary lines: what changed on this host
SKIPPED=()        # summary lines: what was deliberately NOT done, and why

# ---------------------------------------------------------------------------
# Logging — same prefixes and colour rule as compose/scripts/lib.sh (which this
# standalone script cannot source: it runs before the repo is cloned).
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_INFO=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_FAIL=$'\e[31m' C_BOLD=$'\e[1m' C_RST=$'\e[0m'
else
  C_INFO="" C_OK="" C_WARN="" C_FAIL="" C_BOLD="" C_RST=""
fi
readonly C_INFO C_OK C_WARN C_FAIL C_BOLD C_RST

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s[info]%s %s\n' "${C_INFO}" "${C_RST}" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "${C_OK}" "${C_RST}" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "${C_WARN}" "${C_RST}" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "${C_FAIL}" "${C_RST}" "$*" >&2; }
step() { printf '\n%s==> %s%s\n' "${C_BOLD}" "$*" "${C_RST}" >&2; }
die()  { fail "$1"; exit "${2:-1}"; }
did()     { DID+=("$*"); }
skipped() { SKIPPED+=("$*"); }

# Any unexpected non-zero command (set -e) ends here with a readable line instead
# of bash's silent exit. Line numbers are relative to the piped text under
# curl|bash — still useful. Inline on purpose: shellcheck cannot see that a
# function is reached through a trap and would report it as unused (SC2329).
trap 'fail "bootstrap aborted: a command failed at line ${LINENO}: ${BASH_COMMAND}"; exit 1' ERR

usage() {
  cat <<'EOF'
Usage: bootstrap-host.sh [-y|--yes] [--no-start] [--no-group] [-h|--help]

Prepares a fresh Linux host for the n8n Production Kit: Docker Engine + Compose
plugin from Docker's official repository, make/jq/git, vm.overcommit_memory=1,
docker.service enabled, the sudo user in the docker group, http/https in firewalld.
Idempotent: safe to run again.

Options
  -y, --yes       do not ask for confirmation. REQUIRED when no terminal is available
                  (curl | bash over ssh without -t, cloud-init, CI).
      --no-start  do not enable/start docker.service (containers, image builds).
      --no-group  do not add the invoking sudo user (SUDO_USER) to the docker group.
  -h, --help      show this help and exit.

Supported: Ubuntu 24.04/26.04, Debian 12/13, RHEL/Rocky/AlmaLinux/CentOS Stream/Oracle Linux 9 and 10.

Exit codes: 0 ok | 1 usage error, aborted, or a command failed | 2 unsupported distribution
            3 conflicting packages installed (the exact removal command is printed) | 4 docker.service did not come up

Examples
  curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash -s -- --yes
  sudo bash scripts/bootstrap-host.sh
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)   ASSUME_YES=1 ;;
      --no-start) NO_START=1 ;;
      --no-group) NO_GROUP=1 ;;
      -h|--help)  usage; exit 0 ;;
      *)          usage >&2; die "unknown argument: $1" 1 ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------
# Root. Re-exec through sudo only when we are a real file: in the piped form
# stdin has been partially consumed and $0 is "bash", so there is nothing to
# re-execute — we tell the user the exact command instead.
# ---------------------------------------------------------------------------
require_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi
  local self="${BASH_SOURCE[0]:-}"
  if [[ -n "${self}" && -f "${self}" ]] && command -v sudo >/dev/null 2>&1; then
    info "not running as root — re-executing with sudo (you may be asked for your password)"
    exec sudo -- bash "${self}" "$@"
  fi
  die "must run as root:  sudo bash bootstrap-host.sh [flags]   or   curl -fsSL URL | sudo bash -s -- [flags]" 1
}

# ---------------------------------------------------------------------------
# Distribution detection (every value defaulted: Debian has no ID_LIKE at all,
# CentOS Stream has VERSION_ID="9" without a minor, Oracle/RHEL have ID_LIKE="fedora"
# only — so the EL family is matched on ID or PLATFORM_ID, never on ID_LIKE alone).
# ---------------------------------------------------------------------------
detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-release not found — cannot detect the distribution" 2
  fi
  # shellcheck disable=SC1091  # system file, not part of the repo
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_MAJOR="${OS_VERSION_ID%%.*}"
  OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"   # Mint/Pop set UBUNTU_CODENAME to their Ubuntu base
  OS_PLATFORM_ID="${PLATFORM_ID:-}"
  OS_PRETTY="${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"

  case "${OS_ID}" in
    ubuntu|debian)                   OS_FAMILY=apt ;;
    rhel|centos|rocky|almalinux|ol)  OS_FAMILY=dnf ;;
    *)
      if [[ " ${OS_LIKE} " == *" debian "* || " ${OS_LIKE} " == *" ubuntu "* ]]; then
        OS_FAMILY=apt
      elif [[ "${OS_PLATFORM_ID}" == "platform:el9" || "${OS_PLATFORM_ID}" == "platform:el10" ]]; then
        OS_FAMILY=dnf
      fi
      ;;
  esac

  case "${OS_FAMILY}" in
    apt)
      if [[ "${OS_ID}" == ubuntu || " ${OS_LIKE} " == *" ubuntu "* ]]; then
        APT_DISTRO=ubuntu
      else
        APT_DISTRO=debian
      fi
      if [[ -z "${OS_CODENAME}" ]]; then
        die "cannot determine the release codename (VERSION_CODENAME/UBUNTU_CODENAME missing in /etc/os-release)" 2
      fi
      case "${OS_ID}:${OS_VERSION_ID}" in
        ubuntu:24.04|ubuntu:26.04|debian:12|debian:13)
          ok "detected ${OS_PRETTY} (apt family, codename ${OS_CODENAME}) — a verified target" ;;
        *)
          warn "detected ${OS_PRETTY} (apt family, codename ${OS_CODENAME}) — not a kit-verified release; Docker must serve '${OS_CODENAME}' at https://download.docker.com/linux/${APT_DISTRO}/dists/ for this to work" ;;
      esac
      ;;
    dnf)
      if [[ ! "${OS_MAJOR}" =~ ^[0-9]+$ ]]; then
        die "cannot parse VERSION_ID='${OS_VERSION_ID}' into a major release" 2
      fi
      case "${OS_MAJOR}" in
        9|10) ok "detected ${OS_PRETTY} (EL${OS_MAJOR}, dnf family) — a verified target" ;;
        *)    warn "detected ${OS_PRETTY} (EL${OS_MAJOR}) — not a kit-verified release (9 and 10 are); continuing with Docker's el${OS_MAJOR} repository" ;;
      esac
      ;;
    *)
      fail "unsupported distribution: ID='${OS_ID}' ID_LIKE='${OS_LIKE}' PLATFORM_ID='${OS_PLATFORM_ID}' (${OS_PRETTY})"
      log  "       Supported: Ubuntu 24.04/26.04, Debian 12/13, RHEL/Rocky/AlmaLinux/CentOS Stream/Oracle Linux 9 and 10."
      log  "       Install Docker Engine + Compose plugin by hand (https://docs.docker.com/engine/install/),"
      log  "       set vm.overcommit_memory=1, then continue with 'make preflight'."
      exit 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Confirmation. stdin is not usable (it may be the script itself), so we read
# /dev/tty — and only when it really opens: `[[ -c /dev/tty ]]` is true even in
# an ssh session without -t, where open() fails with "No such device or address".
# ---------------------------------------------------------------------------
confirm_proceed() {
  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    info "--yes given: no confirmation prompt"
    return 0
  fi
  local answer=""
  if (exec 3</dev/tty) 2>/dev/null; then
    read -r -p "Proceed? [y/N] " answer </dev/tty || answer=""
    case "${answer}" in
      y|Y|yes|YES|Yes) return 0 ;;
      *) die "aborted — nothing was changed" 1 ;;
    esac
  fi
  die "no terminal available for the confirmation prompt — re-run with --yes (piped form: curl -fsSL URL | sudo bash -s -- --yes)" 1
}

describe_plan() {
  log ""
  log "This will, on ${OS_PRETTY}:"
  case "${OS_FAMILY}" in
    apt)
      log "  1. write ${APT_KEYRING} and the deb822 source ${APT_SOURCES} (suite '${OS_CODENAME}', stable)"
      log "  2. apt-get install ${APT_PKGS[*]}"
      ;;
    *)
      log "  1. write ${DNF_REPO} (copied from ${DNF_REPO_URL})"
      log "  2. dnf install ${DNF_PKGS[*]}"
      ;;
  esac
  log "  3. set vm.overcommit_memory=1 (runtime + ${SYSCTL_FILE})"
  if [[ "${NO_START}" -eq 1 ]]; then
    log "  4. NOT enable/start docker.service (--no-start)"
  else
    log "  4. systemctl enable --now docker"
  fi
  if [[ "${NO_GROUP}" -eq 1 ]]; then
    log "  5. NOT change group membership (--no-group)"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != root ]]; then
    log "  5. usermod -aG docker ${SUDO_USER}"
  else
    log "  5. NOT change group membership (no non-root SUDO_USER)"
  fi
  log "  6. open http/https in firewalld if it is running; leave SELinux as it is"
  log "Nothing is uninstalled. Re-running is safe."
  log ""
}

# ---------------------------------------------------------------------------
# Package-state helpers (globals MISSING / CONFLICTS; see DESIGN NOTES)
# ---------------------------------------------------------------------------
# dpkg-query's db:Status-Status prints "installed" only for fully installed
# packages ("config-files" for removed-but-not-purged ones, which `dpkg -s` would
# also accept) and exits 1 with a message on stderr for unknown names.
# (Inlined rather than a helper function: `x="$(helper)"` would disable errexit
# inside the helper — shellcheck SC2311.)
compute_packages_apt() {
  MISSING=() CONFLICTS=()
  local p state
  for p in "${APT_PKGS[@]}"; do
    # shellcheck disable=SC2016  # ${db:Status-Status} is a dpkg-query format string, not a shell expansion
    state="$(dpkg-query -W -f='${db:Status-Status}' "${p}" 2>/dev/null || true)"
    if [[ "${state}" != "installed" ]]; then
      MISSING+=("${p}")
    fi
  done
  for p in "${APT_CONFLICTS[@]}"; do
    # shellcheck disable=SC2016  # same dpkg-query format string
    state="$(dpkg-query -W -f='${db:Status-Status}' "${p}" 2>/dev/null || true)"
    if [[ "${state}" == "installed" ]]; then
      CONFLICTS+=("${p}")
    fi
  done
}

compute_packages_dnf() {
  MISSING=() CONFLICTS=()
  local p
  for p in "${DNF_PKGS[@]}"; do
    if ! rpm -q "${p}" >/dev/null 2>&1; then
      MISSING+=("${p}")
    fi
  done
  for p in "${DNF_CONFLICTS[@]}"; do
    if rpm -q "${p}" >/dev/null 2>&1; then
      CONFLICTS+=("${p}")
    fi
  done
}

# Stop when a conflicting package is installed. apt would remove docker.io & co.
# on its own, dnf would abort the transaction; in both cases the operator should
# make that call, so we print the exact command and exit 3.
abort_on_conflicts() {
  if [[ ${#CONFLICTS[@]} -eq 0 ]]; then
    return 0
  fi
  fail "conflicting packages are installed: ${CONFLICTS[*]}"
  if [[ "${OS_FAMILY}" == apt ]]; then
    log "       Remove them first, then re-run:  apt-get remove -y ${CONFLICTS[*]}"
  else
    log "       Remove them first, then re-run:  dnf remove -y ${CONFLICTS[*]}"
  fi
  log "       (docker-ce replaces docker.io/podman-docker; containerd.io replaces containerd/runc.)"
  exit 3
}

# ---------------------------------------------------------------------------
# File helpers — compare before replacing, so re-runs leave mtimes alone and the
# summary can say "unchanged". Modes are set explicitly via install(1) (umask-proof).
# ---------------------------------------------------------------------------
write_file() {   # $1 dest  $2 mode  $3 content → WRITE_RESULT
  local dest="$1" mode="$2" content="$3" tmp old new
  tmp="$(mktemp)"
  printf '%s' "${content}" >"${tmp}"
  if [[ -f "${dest}" ]]; then
    old="$(sha256sum <"${dest}")"
    new="$(sha256sum <"${tmp}")"
    if [[ "${old}" == "${new}" ]]; then
      rm -f "${tmp}"
      WRITE_RESULT=unchanged
      return 0
    fi
  fi
  install -m "${mode}" "${tmp}" "${dest}"
  rm -f "${tmp}"
  WRITE_RESULT=written
}

# Download $2 to $1 unless $1 already exists and contains $3 (a sanity marker:
# a captive portal or a 404 page must never end up as a keyring or repo file).
# Existing files are NOT re-downloaded: Docker's key and repo file are long-lived,
# and this keeps re-runs working offline. Delete the file to force a refresh.
# The marker is matched with grep -F (fixed string): "[docker-ce-stable]" is a
# bracket expression to a regex grep ("Invalid range end" for r-c) and the EL
# path aborted with a false "unexpected content" exactly like that in testing.
fetch_file() {   # $1 dest  $2 url  $3 marker → WRITE_RESULT
  local dest="$1" url="$2" marker="$3" tmp
  if [[ -s "${dest}" ]] && grep -qF -- "${marker}" "${dest}"; then
    WRITE_RESULT=unchanged
    return 0
  fi
  tmp="$(mktemp)"
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    die "download failed: ${url} (no network? proxy? DNS?)" 1
  fi
  if ! grep -qF -- "${marker}" "${tmp}"; then
    rm -f "${tmp}"
    die "unexpected content from ${url} (expected '${marker}') — captive portal or mirror problem?" 1
  fi
  install -m 0644 "${tmp}" "${dest}"
  rm -f "${tmp}"
  WRITE_RESULT=written
}

# ---------------------------------------------------------------------------
# apt family (Ubuntu / Debian) — Docker's current official recipe: ASCII keyring
# in /etc/apt/keyrings + a deb822 .sources file (the one-line docker.list form
# is the legacy variant; both work, docs moved to deb822 in 2024).
# ---------------------------------------------------------------------------
install_apt() {
  # No debconf dialogs; no needrestart "which services to restart?" screen on
  # Ubuntu Server; wait up to 5 min for the dpkg lock instead of failing when
  # unattended-upgrades is still running right after first boot.
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  local apt_opts=(-y -q -o DPkg::Lock::Timeout=300)

  # 1. prerequisites: the keyring download needs curl + CA certificates, and
  #    minimal cloud images / containers ship neither (verified: ubuntu:24.04 has no curl).
  if ! command -v curl >/dev/null 2>&1 || [[ ! -r /etc/ssl/certs/ca-certificates.crt ]]; then
    info "installing prerequisites (ca-certificates curl)"
    apt-get -q update || die "apt-get update failed before adding Docker's repository — fix the existing sources first" 1
    apt-get "${apt_opts[@]}" install ca-certificates curl
    did "installed ca-certificates curl (needed to fetch Docker's key)"
  fi

  # 2. keyring: /etc/apt/keyrings is the directory apt reads Signed-By keys from;
  #    a+r because apt downloads as the unprivileged _apt user.
  install -d -m 0755 /etc/apt/keyrings
  fetch_file "${APT_KEYRING}" "https://download.docker.com/linux/${APT_DISTRO}/gpg" "BEGIN PGP PUBLIC KEY BLOCK"
  chmod a+r "${APT_KEYRING}"
  if [[ "${WRITE_RESULT}" == written ]]; then
    did "wrote ${APT_KEYRING}"
  else
    ok "${APT_KEYRING} present"
  fi

  # 3. deb822 source — the six lines of Docker's current official recipe
  #    (docs.docker.com/engine/install/ubuntu|debian, fetched 2026-10-07).
  #    Suites = the Ubuntu base codename even on derivatives; Architectures pins
  #    the host arch so apt does not look for i386/armhf indexes on multi-arch
  #    hosts (the repo has none → noisy warnings).
  local arch sources
  arch="$(dpkg --print-architecture)"
  sources="Types: deb
URIs: https://download.docker.com/linux/${APT_DISTRO}
Suites: ${OS_CODENAME}
Components: stable
Architectures: ${arch}
Signed-By: ${APT_KEYRING}
"
  write_file "${APT_SOURCES}" 0644 "${sources}"
  local sources_changed="${WRITE_RESULT}"
  if [[ "${sources_changed}" == written ]]; then
    did "wrote ${APT_SOURCES} (deb822: ${APT_DISTRO} ${OS_CODENAME} stable, ${arch})"
  else
    ok "${APT_SOURCES} unchanged"
  fi
  if [[ -f "${APT_LEGACY_LIST}" ]]; then
    warn "legacy ${APT_LEGACY_LIST} also exists: apt will warn 'configured multiple times'. Remove it when convenient:  rm ${APT_LEGACY_LIST}"
  fi

  # 4. packages — only when something is missing (makes re-runs ~1 s and offline-safe).
  compute_packages_apt
  abort_on_conflicts
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "all packages already installed: ${APT_PKGS[*]}"
    skipped "package installation (everything already installed; to upgrade:  apt-get update && apt-get install --only-upgrade ${APT_PKGS[*]})"
    if [[ "${sources_changed}" == written ]]; then
      apt-get -q update || die "apt-get update failed after writing ${APT_SOURCES} — is '${OS_CODENAME}' listed at https://download.docker.com/linux/${APT_DISTRO}/dists/ ?" 1
    fi
    return 0
  fi
  info "missing: ${MISSING[*]} — installing"
  apt-get -q update || die "apt-get update failed — is '${OS_CODENAME}' listed at https://download.docker.com/linux/${APT_DISTRO}/dists/ ?" 1
  apt-get "${apt_opts[@]}" install "${APT_PKGS[@]}"
  did "installed ${MISSING[*]}"
}

# ---------------------------------------------------------------------------
# dnf family (RHEL / Rocky / Alma / CentOS Stream / Oracle) — the repo file is
# copied straight into /etc/yum.repos.d. No dnf-plugins-core / config-manager:
# the plugin is not preinstalled on Rocky/Alma, and the dnf5 syntax
# (`addrepo --from-repofile`) fails on EL9 AND EL10 — both are dnf4 (verified).
# ---------------------------------------------------------------------------
install_dnf() {
  if ! command -v dnf >/dev/null 2>&1; then
    die "dnf not found — only dnf-based EL releases (9/10) are supported" 2
  fi
  fetch_file "${DNF_REPO}" "${DNF_REPO_URL}" "[docker-ce-stable]"
  if [[ "${WRITE_RESULT}" == written ]]; then
    did "wrote ${DNF_REPO} (stable channel; \$releasever resolves to ${OS_MAJOR})"
  else
    ok "${DNF_REPO} present"
  fi

  compute_packages_dnf
  abort_on_conflicts
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "all packages already installed: ${DNF_PKGS[*]}"
    skipped "package installation (everything already installed; to upgrade:  dnf upgrade ${DNF_PKGS[*]})"
    return 0
  fi
  info "missing: ${MISSING[*]} — installing (~100 rpms on EL9/10, Docker's GPG key is imported from the repo file)"
  # -y also accepts the GPG key named in the repo file (fingerprint 060A 61C5 ... 621E 9F35).
  # docker-ce pulls container-selinux automatically, so SELinux hosts need nothing extra.
  dnf -y install "${DNF_PKGS[@]}"
  did "installed ${MISSING[*]}"
}

# ---------------------------------------------------------------------------
# vm.overcommit_memory=1 — Valkey/Redis fork() for background saves; with the
# default 0 the kernel may refuse the fork on a loaded host and Valkey logs
# "WARNING Memory overcommit must be enabled!". The kit's preflight checks it.
# ---------------------------------------------------------------------------
configure_sysctl() {
  local content="# n8n Production Kit (scripts/bootstrap-host.sh) — do not edit by hand, re-run the script.
# Valkey (the kit's queue broker) forks to write its AOF/RDB; with the default
# heuristic overcommit (0) that fork can fail under memory pressure. 1 = always allow.
vm.overcommit_memory = 1
"
  # /etc/sysctl.d exists on every systemd host; minimal images and chroots may
  # lack it, and install(1) into a missing directory would abort the run.
  install -d -m 0755 "$(dirname "${SYSCTL_FILE}")"
  write_file "${SYSCTL_FILE}" 0644 "${content}"
  if [[ "${WRITE_RESULT}" == written ]]; then
    did "wrote ${SYSCTL_FILE} (vm.overcommit_memory = 1, applied at every boot)"
  else
    ok "${SYSCTL_FILE} unchanged"
  fi

  local current=""
  if [[ -r /proc/sys/vm/overcommit_memory ]]; then
    read -r current </proc/sys/vm/overcommit_memory
  fi
  if [[ "${current}" == "1" ]]; then
    ok "vm.overcommit_memory is already 1"
    return 0
  fi
  # sysctl(8) lives in procps, which minimal images may lack (Rocky base image has
  # none) — writing /proc/sys directly is the same operation. Neither exit code is
  # trusted: procps' `sysctl -w` returns 0 even when the write fails with
  # "Read-only file system" (seen on Ubuntu 24.04 in a container), so the value
  # is read back and only THAT decides what we report.
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -q -w vm.overcommit_memory=1 2>/dev/null || true
  else
    printf '1\n' >/proc/sys/vm/overcommit_memory 2>/dev/null || true
  fi
  local after=""
  if [[ -r /proc/sys/vm/overcommit_memory ]]; then
    read -r after </proc/sys/vm/overcommit_memory
  fi
  if [[ "${after}" == "1" ]]; then
    ok "vm.overcommit_memory set to 1 (was '${current}')"
    did "set vm.overcommit_memory=1 at runtime"
  else
    # Inside a container /proc/sys is read-only: the file is still correct for the host.
    warn "could not set vm.overcommit_memory at runtime (read-only /proc/sys — running inside a container?); ${SYSCTL_FILE} applies at next boot"
    skipped "runtime vm.overcommit_memory=1 (read-only /proc/sys; value is still '${after:-unreadable}')"
  fi
}

# ---------------------------------------------------------------------------
# docker.service — enable at boot and start now. `Requires=containerd.service`
# in the unit starts containerd too. We then wait for the API to answer, because
# the kit's next step (`make up`) needs a working daemon, not just a started unit.
# ---------------------------------------------------------------------------
configure_service() {
  if [[ "${NO_START}" -eq 1 ]]; then
    skipped "docker.service enable/start (--no-start). Later:  systemctl enable --now docker"
    return 0
  fi
  # /run/systemd/system exists only when systemd is PID 1 — `command -v systemctl`
  # alone is true in many containers where it cannot operate.
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    warn "systemd is not running here (container or non-systemd init) — docker.service not enabled/started"
    skipped "docker.service enable/start (no running systemd). Start the daemon the way your init does"
    return 0
  fi
  systemctl enable --now docker.service
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if docker info >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  local server
  if server="$(docker info --format '{{.ServerVersion}}' 2>/dev/null)"; then
    ok "docker.service enabled and running (server ${server})"
    did "enabled + started docker.service"
  else
    fail "docker.service was enabled but the daemon does not answer after ${i}x2 s — inspect:  systemctl status docker ; journalctl -u docker -n 50"
    BOOTSTRAP_RC=4
  fi
}

# ---------------------------------------------------------------------------
# docker group — under `curl | sudo bash`, $USER is root; the invoking account is
# in SUDO_USER (verified). Membership is root-equivalent: say so, and say that it
# only takes effect in a NEW login session.
# ---------------------------------------------------------------------------
configure_group() {
  if [[ "${NO_GROUP}" -eq 1 ]]; then
    skipped "docker group membership (--no-group). Later:  usermod -aG docker <deploy-user>"
    return 0
  fi
  local user="${SUDO_USER:-}"
  if [[ -z "${user}" || "${user}" == root ]]; then
    info "no non-root SUDO_USER (the script ran directly as root) — nobody added to the docker group"
    skipped "docker group membership (no non-root SUDO_USER). Later:  usermod -aG docker <deploy-user>"
    return 0
  fi
  if ! id -u "${user}" >/dev/null 2>&1; then
    warn "SUDO_USER='${user}' is not a local account — docker group not changed"
    skipped "docker group membership (SUDO_USER '${user}' not found)"
    return 0
  fi
  # The docker-ce package creates the group; keep the documented groupadd as a fallback.
  if ! getent group docker >/dev/null; then
    groupadd docker
  fi
  local groups
  groups="$(id -nG "${user}")"
  if [[ " ${groups} " == *" docker "* ]]; then
    ok "${user} is already in the docker group"
    return 0
  fi
  usermod -aG docker "${user}"
  ok "added ${user} to the docker group"
  did "added ${user} to the docker group — LOG OUT AND BACK IN (or run: newgrp docker) before using docker without sudo. docker-group members are root-equivalent."
}

# ---------------------------------------------------------------------------
# firewalld (EL hosts) — Caddy publishes 80/443 (+443/udp for HTTP/3). Docker's
# published ports bypass firewalld's INPUT rules on most setups, but opening the
# services keeps the policy honest for hosts where the docker zone/backend is
# stricter. Nothing is done unless firewalld is actually RUNNING: the systemctl
# guard matters because `systemctl is-enabled` says "enabled" even in a container
# and the Rocky 9 image has no systemctl at all.
# This branch CANNOT be exercised in the container test matrix (no D-Bus/daemon:
# firewall-cmd exits 36); only the syntax and the offline equivalent were
# verified. Treat it as "ran on a real host" only after the first real EL deploy.
# ---------------------------------------------------------------------------
configure_firewalld() {
  if command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 \
     && systemctl is-active --quiet firewalld; then
    # --add-service on an already-open service prints "Warning: ALREADY_ENABLED" and exits 0 → idempotent.
    firewall-cmd --permanent --add-service=http --add-service=https
    firewall-cmd --reload
    ok "firewalld: http + https opened permanently (ssh untouched)"
    did "opened http/https in firewalld (permanent, reloaded) — note: untested in containers, verify with: firewall-cmd --list-services"
    return 0
  fi
  info "firewalld not running — no firewall changes made"
  if command -v ufw >/dev/null 2>&1; then
    skipped "firewall changes: ufw hosts need nothing for 80/443 (Docker publishes ports through its own iptables chains, ahead of ufw's INPUT rules); keep ssh allowed"
  else
    skipped "firewall changes (firewalld not running); if a cloud firewall/security group exists, allow tcp 80, tcp 443 and udp 443"
  fi
}

# SELinux stays enforcing. docker-ce already installed container-selinux and the
# kit's compose files label bind mounts with :z, so nothing needs relaxing.
note_selinux() {
  if ! command -v getenforce >/dev/null 2>&1; then
    return 0
  fi
  local mode
  mode="$(getenforce 2>/dev/null || true)"
  case "${mode}" in
    Enforcing)
      info "SELinux is Enforcing and stays so: container-selinux came with docker-ce; the kit's bind mounts carry :z (no setenforce 0 needed)"
      ;;
    *)
      info "SELinux: ${mode:-unknown}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Result: versions (what `make preflight` will test), summary, next steps
# ---------------------------------------------------------------------------
report_versions() {
  local docker_v compose_v
  docker_v="$(docker --version 2>&1 || true)"
  compose_v="$(docker compose version 2>&1 || true)"
  log "${docker_v}"
  log "${compose_v}"

  # Soft checks against the kit's minimums — relevant when packages were already
  # installed (from an older run or a pinned repo) and therefore not upgraded.
  local num major rest minor
  num="${docker_v#Docker version }"
  num="${num%%,*}"
  major="${num%%.*}"
  if [[ "${major}" =~ ^[0-9]+$ ]]; then
    if (( major < DOCKER_MIN_MAJOR )); then
      warn "Docker ${num} is older than the kit's minimum ${DOCKER_MIN_MAJOR}.x — upgrade before 'make up'"
    fi
  else
    fail "docker CLI is not working ('${docker_v}')"
    BOOTSTRAP_RC=1
  fi
  num="$(docker compose version --short 2>/dev/null || true)"
  num="${num#v}"
  major="${num%%.*}"
  rest="${num#*.}"
  minor="${rest%%.*}"
  if [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]]; then
    if (( major < COMPOSE_MIN_MAJOR || (major == COMPOSE_MIN_MAJOR && minor < COMPOSE_MIN_MINOR) )); then
      warn "Compose ${num} is older than the kit's minimum ${COMPOSE_MIN_MAJOR}.${COMPOSE_MIN_MINOR} — upgrade docker-compose-plugin"
    fi
  else
    fail "docker compose plugin is not working ('${compose_v}')"
    BOOTSTRAP_RC=1
  fi
}

print_summary() {
  local line
  log ""
  log "${C_BOLD}Done on this host:${C_RST}"
  if [[ ${#DID[@]} -eq 0 ]]; then
    log "  (nothing — everything was already in place)"
  fi
  for line in "${DID[@]}"; do
    log "  + ${line}"
  done
  log "${C_BOLD}Deliberately NOT done:${C_RST}"
  if [[ ${#SKIPPED[@]} -eq 0 ]]; then
    log "  (nothing)"
  fi
  for line in "${SKIPPED[@]}"; do
    log "  - ${line}"
  done
  log ""
  log "${C_BOLD}Next:${C_RST}"
  log "  git clone ${KIT_REPO_URL} && cd n8n-prod-kit/compose"
  log "  make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com   # then: make preflight && make up"
  log "  (re-login first if you were just added to the docker group)"
}

main() {
  parse_args "$@"
  info "n8n-prod-kit bootstrap-host.sh ${SCRIPT_VERSION} (yes=${ASSUME_YES} no-start=${NO_START} no-group=${NO_GROUP})"
  require_root "$@"

  step "Detect distribution"
  detect_os
  describe_plan
  confirm_proceed

  step "Docker repository and packages"
  case "${OS_FAMILY}" in
    apt) install_apt ;;
    *)   install_dnf ;;
  esac

  step "Kernel: vm.overcommit_memory"
  configure_sysctl

  step "docker.service"
  configure_service

  step "docker group"
  configure_group

  step "Firewall and SELinux"
  configure_firewalld
  note_selinux

  step "Result"
  report_versions
  print_summary
  if [[ "${BOOTSTRAP_RC}" -ne 0 ]]; then
    fail "bootstrap finished with problems (exit ${BOOTSTRAP_RC}) — see [FAIL] lines above"
  else
    ok "bootstrap complete"
  fi
  exit "${BOOTSTRAP_RC}"
}

# stdin may be the script itself (curl | bash): give main() /dev/null so no child
# command can ever consume the remaining script text. Prompts use /dev/tty.
main "$@" </dev/null
