#!/usr/bin/env bash
# =============================================================================
# scripts/new-dev-vm.sh — turn a fresh Ubuntu VM into a kit dev host, in one run
# =============================================================================
#
# For a brand-new Ubuntu 26.04 (or 24.04) VM: run it as your normal user (with sudo), not as root.
#
#   curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/new-dev-vm.sh -o new-dev-vm.sh
#   bash new-dev-vm.sh                       # or, from a clone: scripts/new-dev-vm.sh
#   bash new-dev-vm.sh --help
#
# WHAT IT DOES, IN ORDER
#   1. base packages: git curl ca-certificates make jq (apt)
#   2. the repository: clones it to --dir (default ~/src/n8n-prod-kit), or fast-forwards an existing clone;
#      git core.autocrlf=false and init.defaultBranch=main when they are unset
#   3. host prep: sudo scripts/bootstrap-host.sh --yes (Docker Engine + Compose, vm.overcommit_memory=1, docker group)
#   4. dev tools for `make lint` (skip with --no-dev-tools): age, yamllint, python3-venv, gh from apt; shellcheck
#      v0.11.0 and hadolint v2.15.1 sha256-verified exactly as CI pins them (x86_64); mkdocs in ~/.venvs/mkdocs
#   5. scripts/dev-host-catchup.sh under the docker group (sg docker), so no log-out is needed in between:
#      make init, monitoring (with >= 4 vCPU), Telegram and R2 at hidden prompts, make up, the recovery key,
#      status / doctor / smoke. Its options go after `--`.
# Every step checks first, so a second run only does what is still missing.
# shellcheck disable=SC2310,SC2312
set -euo pipefail

REPO_URL="https://github.com/nhhandevops/n8n-prod-kit"
DIR="${HOME}/src/n8n-prod-kit"
PORTS="8080:8443"
DEV_TOOLS=1
CATCHUP_ARGS=()

say() { printf '\n== %s\n' "${1}" >&2; }
ok() { printf '[ OK ] %s\n' "${1}" >&2; }
info() { printf '[info] %s\n' "${1}" >&2; }
warn() { printf '[warn] %s\n' "${1}" >&2; }
die() { printf '[FAIL] %s\n' "${1}" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: new-dev-vm.sh [--dir PATH] [--ports HTTP:HTTPS] [--no-dev-tools] [-- dev-host-catchup options]
  --dir PATH           where the clone lives (default: ~/src/n8n-prod-kit, or the clone this script is in)
  --ports HTTP:HTTPS   host ports for the kit (default 8080:8443 — 80/443 stay free for other projects on the VM;
                       use 80:443 on a VM that runs only the kit)
  --no-dev-tools       skip shellcheck / hadolint / yamllint / age / mkdocs / gh (they are needed for make lint)
  -- …                 everything after -- goes to scripts/dev-host-catchup.sh (e.g. -- --no-r2 --no-smoke)
EOF
}

# A copy that already sits in a kit clone uses that clone.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${here}/dev-host-catchup.sh" && -d "${here}/../.git" ]]; then
  DIR="$(cd "${here}/.." && pwd)"
fi

while (($#)); do
  case "${1}" in
    --dir) DIR="${2:?--dir needs a path}"; shift ;;
    --ports) PORTS="${2:?--ports needs HTTP:HTTPS}"; shift ;;
    --no-dev-tools) DEV_TOOLS=0 ;;
    --) shift; CATCHUP_ARGS=("${@}"); break ;;
    -h | --help) usage; exit 0 ;;
    *) usage; die "unknown option: ${1}" ;;
  esac
  shift
done
[[ "${PORTS}" =~ ^[0-9]+:[0-9]+$ ]] || die "--ports must look like 8080:8443"

# --- 0. the machine -------------------------------------------------------------------------------------------------
say "0. this machine"
[[ "$(id -u)" != "0" ]] || die "run this as your normal user (it uses sudo where needed), not as root"
[[ -r /etc/os-release ]] || die "/etc/os-release is missing — not a supported Linux"
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  ubuntu:* | debian:* | *:*debian*) ok "${PRETTY_NAME:-${ID}} ($(uname -m)), $(nproc) vCPU, $(free -g | awk '/^Mem:/ {print $2}') GB RAM" ;;
  *) die "this script installs with apt (Ubuntu/Debian); on Rocky/Alma follow n8n-kit-HANDOFF.md §4.1-4.2 by hand, then scripts/dev-host-catchup.sh" ;;
esac
sudo -v || die "sudo is needed for packages and Docker"
(($(nproc) >= 4)) || warn "$(nproc) vCPU: the monitoring profile wants about 4 — the catch-up step will leave it off"

# --- 1. base packages -----------------------------------------------------------------------------------------------
say "1. base packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates make jq
ok "git $(git --version | awk '{print $3}'), curl, make, jq"

# --- 2. the repository ----------------------------------------------------------------------------------------------
say "2. the repository (${DIR})"
[[ -n "$(git config --global core.autocrlf || true)" ]] || git config --global core.autocrlf false
[[ -n "$(git config --global init.defaultBranch || true)" ]] || git config --global init.defaultBranch main
if [[ -d "${DIR}/.git" ]]; then
  ok "clone exists — dev-host-catchup.sh brings it up to date in step 5"
else
  mkdir -p "$(dirname "${DIR}")"
  git clone -q "${REPO_URL}" "${DIR}"
  ok "cloned ${REPO_URL} at $(git -C "${DIR}" log --oneline -1)"
fi

# --- 3. host prep ---------------------------------------------------------------------------------------------------
say "3. host prep (scripts/bootstrap-host.sh)"
sudo bash "${DIR}/scripts/bootstrap-host.sh" --yes

# --- 4. dev tools ---------------------------------------------------------------------------------------------------
install_pinned() {   # install_pinned NAME URL SHA256 [TAR_MEMBER]
  local name="${1}" url="${2}" sha="${3}" member="${4:-}" tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/download" "${url}"
  printf '%s  %s\n' "${sha}" "${tmp}/download" | sha256sum -c --quiet - || { rm -rf "${tmp}"; die "${name}: sha256 mismatch for ${url}"; }
  if [[ -n "${member}" ]]; then
    tar -xJf "${tmp}/download" -C "${tmp}" "${member}"
    sudo install -m 755 "${tmp}/${member}" "/usr/local/bin/${name}"
  else
    sudo install -m 755 "${tmp}/download" "/usr/local/bin/${name}"
  fi
  rm -rf "${tmp}"
}

say "4. dev tools"
if ((DEV_TOOLS == 0)); then
  info "skipped (--no-dev-tools) — make lint needs them; n8n-kit-HANDOFF.md §4.2 has the commands"
else
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq age yamllint python3-venv
  if ! command -v gh >/dev/null 2>&1; then
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh; then
      warn "gh is not in this release's apt sources — see https://cli.github.com"
    fi
  fi
  if [[ "$(uname -m)" == "x86_64" ]]; then
    if [[ "$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')" != "0.11.0" ]]; then
      install_pinned shellcheck https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz \
        8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 shellcheck-v0.11.0/shellcheck
    fi
    if [[ "$(hadolint --version 2>/dev/null | grep -o '2\.15\.1' || true)" != "2.15.1" ]]; then
      install_pinned hadolint https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-x86_64 \
        c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
    fi
  else
    warn "$(uname -m): take shellcheck v0.11.0 and hadolint v2.15.1 for this architecture from their release pages (HANDOFF §4.2)"
  fi
  if [[ ! -x "${HOME}/.venvs/mkdocs/bin/mkdocs" ]]; then
    python3 -m venv "${HOME}/.venvs/mkdocs"
    "${HOME}/.venvs/mkdocs/bin/pip" install -q -r "${DIR}/requirements-docs.txt"
  fi
  mkdir -p "${HOME}/.local/bin"
  ln -sfn "${HOME}/.venvs/mkdocs/bin/mkdocs" "${HOME}/.local/bin/mkdocs"
  ok "age $(age --version 2>/dev/null), yamllint, shellcheck $(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}'), hadolint $(hadolint --version 2>/dev/null | grep -o '[0-9.]*' | head -1), mkdocs, gh $(gh --version 2>/dev/null | awk 'NR == 1 {print $3}')"
fi

# --- 5. the kit -----------------------------------------------------------------------------------------------------
say "5. the kit (scripts/dev-host-catchup.sh, under the docker group)"
catchup=("${DIR}/scripts/dev-host-catchup.sh")
if [[ ! -f "${DIR}/compose/.env" ]]; then
  catchup+=(--ports "${PORTS}")
fi
catchup+=("${CATCHUP_ARGS[@]}")
if id -nG | tr ' ' '\n' | grep -qx docker; then
  "${catchup[@]}"
else
  # bootstrap-host.sh just added this user to the docker group; sg applies it without logging out and in.
  sg docker -c "$(printf '%q ' "${catchup[@]}")"
fi

say "next"
cat >&2 <<EOF
  * Log out and back in once, so every new shell has the docker group.
  * gh auth login && gh auth setup-git        (only if you will push or watch CI from this VM)
  * On Windows: the hosts entry and the dev CA that the summary above printed; ~/.ssh/config Host entry for this VM.
  * Continue with n8n-kit-HANDOFF.md §2 "Next up" — and docs/runbook.md for a hands-on pass.
EOF
