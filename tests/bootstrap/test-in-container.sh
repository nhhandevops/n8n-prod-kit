#!/usr/bin/env bash
# =============================================================================
# tests/bootstrap/test-in-container.sh — run scripts/bootstrap-host.sh inside a
# throw-away container of every supported distribution and assert the outcome.
# =============================================================================
#
# For each image (one container per image, started with --rm):
#   1. pull it when missing — timed separately, because a registry failure is a
#      network/quota problem, not a bootstrap bug, and the table says which it was
#   2. stream scripts/bootstrap-host.sh over the container's stdin and run it the
#      way users do, i.e. the piped form:
#        cat bootstrap-host.sh | bash -s -- --no-start --yes --no-group
#      (--no-start: no systemd in a container; --yes: no tty; --no-group: no SUDO_USER)
#   3. assert `docker --version` works and `docker compose version` is >= 2.30
#      (the kit's preflight minimum)
#   4. run the script a SECOND time: it must exit 0 within IDEMPOTENT_MAX_SECONDS
#      (idempotency — nothing to install, no apt-get update, no downloads)
#   5. print a summary table with timings; exit 1 if any image did not PASS
#
# The matrix uses Docker-Hub-quota-free mirrors whose digests equal the library
# images (public.ecr.aws for ubuntu/debian/almalinux, quay.io for Rocky). Hub's
# library rockylinux:9 is a stale 2023 build and library rockylinux:10 does not
# exist, so Rocky comes from quay.io/rockylinux/rockylinux. Anonymous Hub pulls
# are capped at 100/h per IP and shared CI runners do hit HTTP 429.
#
# The script is sent over stdin instead of a bind mount so the test also works
# against a remote DOCKER_HOST and needs no SELinux relabelling of the repo.
#
# Usage:  tests/bootstrap/test-in-container.sh [-h|--help]
# Env:    IMAGES="img1 img2 ..."      override the matrix (space separated)
#         PARALLEL=2                  containers at a time (apt/dnf are CPU-bound; 2 suits a 4-vCPU box)
#         LOG_DIR=path                per-image logs + .result files (default: mktemp -d under TMPDIR)
#         NAME_PREFIX=n8nkit-bt       container-name prefix (cleanup can target it)
#         IDEMPOTENT_MAX_SECONDS=30   upper bound for the second run
# Exit:   0 all PASS · 1 any FAIL / ERROR / PULL-FAIL · 64 usage error
# Needs:  docker (a working daemon), bash >= 4.4, coreutils
# =============================================================================
set -euo pipefail

script_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
REPO_ROOT="$(cd "${script_dir}/../.." && pwd)"
readonly REPO_ROOT
readonly BOOTSTRAP="${REPO_ROOT}/scripts/bootstrap-host.sh"

readonly DEFAULT_IMAGES=(
  public.ecr.aws/docker/library/ubuntu:24.04
  public.ecr.aws/docker/library/ubuntu:26.04
  public.ecr.aws/docker/library/debian:13
  quay.io/rockylinux/rockylinux:9
  quay.io/rockylinux/rockylinux:10
  public.ecr.aws/docker/library/almalinux:9
)
PARALLEL="${PARALLEL:-2}"
NAME_PREFIX="${NAME_PREFIX:-n8nkit-bt}"
IDEMPOTENT_MAX_SECONDS="${IDEMPOTENT_MAX_SECONDS:-30}"
LOG_DIR="${LOG_DIR:-}"

IMAGE_LIST=()        # the matrix actually run
SLUGS=()             # per-image short names (container name + log/result file stem)
STARTED_NAMES=()     # containers this run created (for cleanup on Ctrl-C)

# --- logging (same prefixes as the kit's lib.sh; this test must not depend on it) ---
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_INFO=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_FAIL=$'\e[31m' C_RST=$'\e[0m'
else
  C_INFO="" C_OK="" C_WARN="" C_FAIL="" C_RST=""
fi
readonly C_INFO C_OK C_WARN C_FAIL C_RST
log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s[info]%s %s\n' "${C_INFO}" "${C_RST}" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "${C_OK}" "${C_RST}" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "${C_WARN}" "${C_RST}" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "${C_FAIL}" "${C_RST}" "$*" >&2; }
die()  { fail "$1"; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Usage: tests/bootstrap/test-in-container.sh [-h|--help]

Runs scripts/bootstrap-host.sh (piped form, --no-start --yes --no-group) twice inside
one throw-away container per image, asserts docker + compose >= 2.30 and a fast
idempotent second run, then prints a table. Exit 1 if any image fails.

Environment knobs:
  IMAGES="img1 img2"          matrix override (default: ubuntu 24.04/26.04, debian 13,
                              rocky 9/10, almalinux 9 from quota-free mirrors)
  PARALLEL=2                  containers at a time
  LOG_DIR=path                where <slug>.log / <slug>.result land (default: mktemp -d)
  NAME_PREFIX=n8nkit-bt       container-name prefix
  IDEMPOTENT_MAX_SECONDS=30   the second run must finish within this
EOF
}

# -----------------------------------------------------------------------------
# The script that runs INSIDE each container (bash, as root). It is a quoted
# heredoc, so nothing expands here; the bootstrap script arrives on stdin.
# It always prints one "@@RESULT key=value ..." line, even when a stage fails,
# and exits 0 only when every assertion holds.
# -----------------------------------------------------------------------------
read -r -d '' INNER <<'EOF' || true
set -u
S=/n8nkit-bootstrap-host.sh
MAXS="${IDEMPOTENT_MAX_SECONDS:-30}"
rc1=-1 rc2=-1 t1=-1 t2=-1 rcd=-1 rcc=-1 dver=none cver=none compose_ok=0 status=FAIL note=""
emit() { echo "@@RESULT status=${status} rc1=${rc1} t1=${t1} rc2=${rc2} t2=${t2} docker=${dver} compose=${cver} note=${note:-ok}"; }
if ! cat >"${S}"; then note=copy-failed; emit; exit 1; fi
sz=$(wc -c <"${S}")
if [ "${sz:-0}" -lt 1000 ]; then note="script-truncated(${sz}B)"; emit; exit 1; fi
ver=$(grep -m1 '^readonly SCRIPT_VERSION=' "${S}" || echo 'SCRIPT_VERSION=?')
echo "## received bootstrap-host.sh (${sz} bytes): ${ver}"
os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?} [ID=${ID:-?} VERSION_ID=${VERSION_ID:-?} PLATFORM_ID=${PLATFORM_ID:-}]")
echo "## os: ${os}"
if (exec 3</dev/tty) 2>/dev/null; then tty=yes; else tty=no; fi
uid=$(id -u)
echo "## uid=${uid} tty=${tty}"
echo
echo "########## run 1:  cat bootstrap-host.sh | bash -s -- --no-start --yes --no-group"
t0=$(date +%s)
cat "${S}" | bash -s -- --no-start --yes --no-group
rc1=$?
t1=$(( $(date +%s) - t0 ))
echo "########## run 1 exit=${rc1} after ${t1}s"
echo
echo "########## checks"
dv=$(docker --version 2>&1); rcd=$?
echo "docker --version        -> rc=${rcd}: ${dv}"
dver=$(printf '%s\n' "${dv}" | sed -nE 's/^Docker version ([^,]+),.*/\1/p')
[ -n "${dver}" ] || dver=none
cv=$(docker compose version 2>&1); rcc=$?
echo "docker compose version  -> rc=${rcc}: ${cv}"
cvs=$(docker compose version --short 2>/dev/null); cvs=${cvs#v}
[ -n "${cvs}" ] && cver=${cvs}
maj=${cver%%.*}; rest=${cver#*.}; min=${rest%%.*}
case "${maj}:${min}" in
  *[!0-9:]*|:*|*:) compose_ok=0 ;;
  *) if [ "${maj}" -gt 2 ] || { [ "${maj}" -eq 2 ] && [ "${min}" -ge 30 ]; }; then compose_ok=1; fi ;;
esac
echo "compose >= 2.30         -> ${compose_ok} (parsed '${cver}')"
echo
echo "########## run 2 (idempotency): same command again, must exit 0 within ${MAXS}s"
t0=$(date +%s)
cat "${S}" | bash -s -- --no-start --yes --no-group
rc2=$?
t2=$(( $(date +%s) - t0 ))
echo "########## run 2 exit=${rc2} after ${t2}s"
echo
[ "${rc1}" -eq 0 ]        || note="${note}run1-exit=${rc1},"
[ "${rcd}" -eq 0 ]        || note="${note}docker-cli-missing,"
[ "${rcc}" -eq 0 ]        || note="${note}compose-missing,"
[ "${compose_ok}" -eq 1 ] || note="${note}compose<2.30,"
[ "${rc2}" -eq 0 ]        || note="${note}run2-exit=${rc2},"
[ "${t2}" -le "${MAXS}" ] || note="${note}run2-slow(${t2}s>${MAXS}s),"
if [ -z "${note}" ]; then status=PASS; fi
emit
[ "${status}" = PASS ]
EOF
readonly INNER

# -----------------------------------------------------------------------------
# One image. Runs in a background subshell, so it must never abort silently:
# every outcome is written to the .result file as "key=value ..." tokens.
# -----------------------------------------------------------------------------
run_one() {   # $1 image  $2 slug
  local image="$1" slug="$2" name logf result now t0 pull_s=0 total_s=0 rc=0 line
  name="${NAME_PREFIX}-${slug}"
  logf="${LOG_DIR}/${slug}.log"
  result="${LOG_DIR}/${slug}.result"
  now="$(date -u +%FT%TZ)"
  printf '### image: %s\n### container: %s\n### started: %s\n' "${image}" "${name}" "${now}" >"${logf}"

  t0="${SECONDS}"
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    # Registries answer transient 5xx / token errors now and then (seen on public.ecr.aws from a GitHub runner):
    # three attempts with growing pauses before the image counts as unpullable.
    local attempt pulled=0
    for attempt in 1 2 3; do
      printf '### pulling (not present locally), attempt %s\n' "${attempt}" >>"${logf}"
      if docker pull -q "${image}" >>"${logf}" 2>&1; then
        pulled=1
        break
      fi
      sleep $(( attempt * 10 ))
    done
    if (( pulled == 0 )); then
      pull_s=$(( SECONDS - t0 ))
      printf 'status=PULL-FAIL pull=%s note=registry-pull-failed-after-3-attempts(see-log)\n' "${pull_s}" >"${result}"
      return 0
    fi
  fi
  pull_s=$(( SECONDS - t0 ))

  # -i: the bootstrap script is the container's stdin (the inner script saves it,
  # then pipes it into bash exactly like a user would). Proxy variables are passed
  # through only when set on the host (docker's `-e NAME` semantics).
  t0="${SECONDS}"
  docker run --rm -i --name "${name}" --label "${NAME_PREFIX}=1" --network "${TEST_NET}" \
    -e "IDEMPOTENT_MAX_SECONDS=${IDEMPOTENT_MAX_SECONDS}" \
    -e http_proxy -e https_proxy -e no_proxy -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY \
    "${image}" bash -c "${INNER}" <"${BOOTSTRAP}" >>"${logf}" 2>&1 || rc=$?
  total_s=$(( SECONDS - t0 ))

  line="$(grep -m1 '^@@RESULT ' "${logf}" || true)"
  if [[ -z "${line}" ]]; then
    printf 'status=ERROR pull=%s total=%s note=no-result-line(docker-rc=%s)\n' "${pull_s}" "${total_s}" "${rc}" >"${result}"
    return 0
  fi
  printf '%s pull=%s total=%s docker_rc=%s\n' "${line#@@RESULT }" "${pull_s}" "${total_s}" "${rc}" >"${result}"
}

# Ctrl-C / TERM: `docker run --rm` containers would otherwise keep installing
# packages in the background until their own exit.
# shellcheck disable=SC2329,SC2317  # reached through the INT/TERM trap, not by a direct call (SC2317 = older shellcheck's code)
cleanup_on_signal() {
  local n
  fail "interrupted — removing containers"
  for n in "${STARTED_NAMES[@]}"; do
    docker rm -f "${n}" >/dev/null 2>&1 || true
  done
  docker network rm "${TEST_NET:-}" >/dev/null 2>&1 || true
  exit 130
}

# Summary table from the .result files. Reports through the FAILURES global
# (a return code in `print_table || x=$?` would disable errexit inside, SC2310).
FAILURES=0
print_table() {
  local slug result content tok status
  local -a tokens
  local -A kv
  FAILURES=0
  log ""
  printf '%-3s %-44s %-9s %5s %6s %6s %-8s %-7s %s\n' '#' 'image' 'status' 'pull' 'run1' 'run2' 'docker' 'compose' 'note' >&2
  printf '%-3s %-44s %-9s %5s %6s %6s %-8s %-7s %s\n' '--' '-----' '------' '----' '----' '----' '------' '-------' '----' >&2
  local i=0
  for slug in "${SLUGS[@]}"; do
    i=$((i + 1))
    result="${LOG_DIR}/${slug}.result"
    kv=()
    content=""
    if [[ -f "${result}" ]]; then
      content="$(<"${result}")"
    else
      warn "${slug}: no result file (the worker subshell died before writing it) — see ${LOG_DIR}/${slug}.log"
    fi
    read -r -a tokens <<<"${content}"
    for tok in "${tokens[@]}"; do
      kv["${tok%%=*}"]="${tok#*=}"
    done
    status="${kv[status]:-ERROR}"
    if [[ "${status}" != PASS ]]; then
      FAILURES=$((FAILURES + 1))
    fi
    printf '%-3s %-44s %-9s %5s %6s %6s %-8s %-7s %s\n' \
      "${i}" "${IMAGE_LIST[i - 1]}" "${status}" "${kv[pull]:-?}s" "${kv[t1]:-?}s" "${kv[t2]:-?}s" \
      "${kv[docker]:-?}" "${kv[compose]:-?}" "${kv[note]:-no-result-file}" >&2
  done
  # CI only ever sees stdout/stderr, never ${LOG_DIR}: show the tail of every non-PASS image's log right here,
  # so a registry error or a failing dnf transaction is visible without re-running anything.
  for slug in "${SLUGS[@]}"; do
    result="${LOG_DIR}/${slug}.result"
    if [[ ! -f "${result}" ]] || ! grep -q '^status=PASS' "${result}"; then
      log ""
      log "---- ${slug}: last 25 lines of ${LOG_DIR}/${slug}.log"
      tail -n 25 "${LOG_DIR}/${slug}.log" 2>/dev/null | sed 's/^/    /' >&2 || true
    fi
  done
  log ""
  log "logs: ${LOG_DIR}/<slug>.log  (slugs: ${SLUGS[*]})"
}

main() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" 64 ;;
    esac
  fi
  if [[ ! "${PARALLEL}" =~ ^[1-9][0-9]*$ ]]; then
    die "PARALLEL must be a positive integer (got '${PARALLEL}')" 64
  fi
  if [[ ! "${IDEMPOTENT_MAX_SECONDS}" =~ ^[0-9]+$ ]]; then
    die "IDEMPOTENT_MAX_SECONDS must be an integer (got '${IDEMPOTENT_MAX_SECONDS}')" 64
  fi
  if [[ ! -f "${BOOTSTRAP}" ]]; then
    die "bootstrap script not found: ${BOOTSTRAP}" 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "docker is not installed on this host" 1
  fi
  if ! docker info >/dev/null 2>&1; then
    die "the docker daemon is not reachable (DOCKER_HOST=${DOCKER_HOST:-unset})" 1
  fi
  # Cheap fail-fast before spending minutes in containers.
  bash -n "${BOOTSTRAP}"

  if [[ -n "${IMAGES:-}" ]]; then
    read -r -a IMAGE_LIST <<<"${IMAGES}"
  else
    IMAGE_LIST=("${DEFAULT_IMAGES[@]}")
  fi
  if [[ ${#IMAGE_LIST[@]} -eq 0 ]]; then
    die "IMAGES is empty" 64
  fi
  if [[ -z "${LOG_DIR}" ]]; then
    LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/n8nkit-bootstrap-test.XXXXXX")"
  else
    mkdir -p "${LOG_DIR}"
  fi

  local version_line
  version_line="$(grep -m1 '^readonly SCRIPT_VERSION=' "${BOOTSTRAP}" || true)"
  info "bootstrap-host.sh under test: ${BOOTSTRAP} (${version_line:-no version line})"
  info "matrix (${#IMAGE_LIST[@]} images, ${PARALLEL} at a time, second run must finish within ${IDEMPOTENT_MAX_SECONDS}s):"
  local image base slug idx=0 running
  for image in "${IMAGE_LIST[@]}"; do
    idx=$((idx + 1))
    base="${image##*/}"                      # ubuntu:24.04
    base="${base//[^A-Za-z0-9_.-]/-}"        # ubuntu-24.04 (valid container-name chars)
    slug="$(printf '%02d' "${idx}")-${base}"
    SLUGS+=("${slug}")
    log "  ${slug}  ${image}"
  done
  log "logs: ${LOG_DIR}"

  trap cleanup_on_signal INT TERM

  # A bridge network of our own for the test containers: it does not depend on the host's default bridge
  # (on a long-lived VM docker0 was once found DOWN without an IPv4 address — every container got "No route
  # to host" and the whole matrix failed on DNS) and it is removed together with the containers.
  TEST_NET="${NAME_PREFIX}-net"
  docker network inspect "${TEST_NET}" >/dev/null 2>&1 || docker network create --label "${NAME_PREFIX}=1" "${TEST_NET}" >/dev/null

  idx=0
  for image in "${IMAGE_LIST[@]}"; do
    slug="${SLUGS[idx]}"
    idx=$((idx + 1))
    running="$(jobs -rp | wc -l)"
    while (( running >= PARALLEL )); do
      wait -n || true
      running="$(jobs -rp | wc -l)"
    done
    info "start ${slug}: ${image}"
    STARTED_NAMES+=("${NAME_PREFIX}-${slug}")
    run_one "${image}" "${slug}" &
  done
  wait
  trap - INT TERM
  docker network rm "${TEST_NET}" >/dev/null 2>&1 || true

  print_table
  if [[ "${FAILURES}" -eq 0 ]]; then
    ok "all ${#IMAGE_LIST[@]} images passed"
    exit 0
  fi
  fail "${FAILURES} of ${#IMAGE_LIST[@]} images did not pass — see the logs above"
  exit 1
}

main "$@"
