#!/usr/bin/env bash
# compose/backup/lib.sh — shared helpers for the scripts INSIDE the backup container (sourced, never run).
#
# Paths: /state (volume backup_state: metrics, reports and the job lock; survives restarts and is shared by the cron
# sidecar and every `compose run backup` one-shot), /work (volume backup_work: a fetched and decrypted bundle waiting to
# be restored — emptied on every exit of `make restore`), /tmp (tmpfs, size BACKUP_TMPFS_SIZE: everything transient),
# /run/secrets/age-key.txt (the host's age identity, read-only), /backups/local and /backups/external (bind mounts).
# Bundle format v1: <name>.tar.age = age(tar(db.dump, key-bundle.env, manifest.json)), recipients = host key + recovery
# key; <name> = n8n-<UTC YYYYmmddTHHMMSSZ>-<kind>[-<label>], stored under <remote>/<kind>/ (daily bundles also under
# <remote>/monthly/). Files on a remote that do not match that layout are ignored: never listed, restored or pruned.
# shellcheck disable=SC2310,SC2311,SC2312,SC2034  # SC2034: constants used by the scripts that source this file

if [[ -n "${__KIT_BACKUP_LIB:-}" ]]; then
  return 0
fi
__KIT_BACKUP_LIB=1

export LC_ALL=C   # byte-wise string comparison: bundle names sort by their UTC timestamp

STATE_DIR=/state
WORK_DIR=/work
AGE_IDENTITY="${AGE_KEY_FILE:-/run/secrets/age-key.txt}"
BUNDLE_FORMAT=1
LOCK_FILE="${STATE_DIR}/backup.lock"
KINDS_RE='(daily|monthly|manual|pre-upgrade|pre-restore)'
NAME_RE='^n8n-[0-9]{8}T[0-9]{6}Z-(daily|manual|pre-upgrade|pre-restore)(-[a-z0-9.-]+)?\.tar\.age$'

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "${*}" >&2; }
info() { log "[info] ${*}"; }
ok() { log "[ OK ] ${*}"; }
warn() { log "[warn] ${*}"; }
fail() { log "[FAIL] ${*}"; }
die() {
  fail "${1}"
  exit "${2:-1}"
}

# BACKUP_REMOTES entries the kit accepts: the two bind mounts (optionally a sub-directory) or an rclone remote
# "name:bucket/path". Anything else — "r2/bucket" without the colon, "backups", "/tmp/x" — would be a path INSIDE the
# container (its RAM tmpfs), i.e. backups that vanish on the next restart while every check reports OK.
remote_ok() {
  local r="${1%/}"
  [[ "${r}" != *..* ]] || return 1
  [[ "${r}" =~ ^/backups/(local|external)(/[A-Za-z0-9._-]+)*$ || "${r}" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9._/-]*$ ]]
}

# validate_remotes — every entry of BACKUP_REMOTES is acceptable (prints each bad one). Call it in the main shell.
validate_remotes() {
  local r bad=0
  for r in ${BACKUP_REMOTES:-}; do
    if ! remote_ok "${r}"; then
      fail "BACKUP_REMOTES entry '${r}' is not /backups/local, /backups/external[/dir] or an rclone remote 'name:bucket/path'"
      bad=1
    fi
  done
  return "${bad}"
}

# Remotes from BACKUP_REMOTES (space separated), trailing slash removed; invalid entries are skipped (validate first).
remotes() {
  local r
  for r in ${BACKUP_REMOTES:-}; do
    if remote_ok "${r}"; then
      printf '%s\n' "${r%/}"
    fi
  done
}

# Prometheus-safe label value
label_of() {
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

# Metrics live in one file per topic under /state/metrics.d; metrics.prom is their concatenation (node-exporter's
# textfile collector reads it; `make doctor` reads it). Writes are atomic (temp file + mv).
write_metrics() {   # write_metrics TOPIC  (metric lines on stdin)
  local topic="${1}" dir="${STATE_DIR}/metrics.d" tmp
  mkdir -p "${dir}"
  tmp="$(mktemp "${dir}/.${topic}.XXXXXX")"
  cat >"${tmp}"
  mv -f "${tmp}" "${dir}/${topic}.prom"
  tmp="$(mktemp "${STATE_DIR}/.metrics.XXXXXX")"
  cat "${dir}"/*.prom >"${tmp}" 2>/dev/null || true
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${STATE_DIR}/metrics.prom"
}

# One backup / restore test / restore apply at a time across ALL backup containers: the lock file is on the shared
# /state volume (a lock on /tmp would only exclude jobs inside the same container). The image's flock is BusyBox's,
# which has no -w: poll with -n instead.
take_lock() {   # take_lock [WAIT_SECONDS]
  local wait="${1:-900}" waited=0
  exec 9>"${LOCK_FILE}" || return 1
  until flock -n 9; do
    if (( waited >= wait )); then
      return 1
    fi
    if (( waited == 0 )); then
      info "waiting for another backup / restore test / restore to finish (up to ${wait} s)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

recipients() {   # age -r arguments for every configured public key
  local -a args=()
  [[ -n "${BACKUP_AGE_PUBLIC_KEY:-}" ]] && args+=(-r "${BACKUP_AGE_PUBLIC_KEY}")
  [[ -n "${BACKUP_AGE_RECOVERY_PUBLIC_KEY:-}" ]] && args+=(-r "${BACKUP_AGE_RECOVERY_PUBLIC_KEY}")
  if (( ${#args[@]} == 0 )); then
    die "BACKUP_AGE_PUBLIC_KEY is empty — run make init (it generates the age keys)"
  fi
  printf '%s\n' "${args[@]}"
}

# Number of X25519 recipient stanzas in an age file's header (2 = host key + recovery key).
recipient_count() {
  awk '/^---/ { exit } /^-> X25519 / { n++ } END { print n + 0 }' "${1}"
}

# Every kit bundle on one remote: "<remote>\t<kind>/<file>" lines. Returns non-zero when the remote cannot be listed
# (the reason is in /tmp/rclone-list.err) — an unreachable remote is an error, never an empty list. A local remote
# whose directory does not exist yet (rclone exit 3) has no bundles.
list_remote() {
  local remote="${1}" out rc=0 path
  out="$(rclone lsf -R --files-only --include 'n8n-*.tar.age' "${remote}" 2>/tmp/rclone-list.err)" || rc=$?
  if (( rc == 3 )) && [[ "${remote}" == /* ]]; then
    return 0
  elif (( rc != 0 )); then
    return 1
  fi
  while IFS= read -r path; do
    if [[ "${path%%/*}" =~ ^${KINDS_RE}$ && "${path}" == */* && "${path#*/}" != */* && "${path##*/}" =~ ${NAME_RE} ]]; then
      printf '%s\t%s\n' "${remote}" "${path}"
    fi
  done <<<"${out}"
}

# Resolve NAME or "latest" to "<remote>\t<kind>/<file>". Exit 1 = not found, 2 = a remote could not be listed.
#   latest  the newest bundle by its UTC name, EXCLUDING pre-restore/ (the safety copy `make restore` takes — right
#           after a restore, "latest" would otherwise undo it) and names more than a day in the future (a clock that
#           jumped ahead must not pin "latest" for weeks; they are reported). Every remote must be listable: an
#           unreachable one could hold the newest backup — pass FROM to pick a remote explicitly.
#   NAME    exact basename, with or without .tar.age; the first remote (BACKUP_REMOTES order) holding it wins.
resolve_bundle() {   # resolve_bundle NAME [FROM]
  local want="${1}" from="${2:-}" r line path n limit best='' best_name='' unreachable=0
  local -a rs=() lines=()
  if [[ -n "${from}" ]]; then
    rs=("${from%/}")
  else
    mapfile -t rs < <(remotes)
  fi
  for r in "${rs[@]}"; do
    if list_remote "${r}" >/tmp/resolve.lst; then
      mapfile -t -O "${#lines[@]}" lines </tmp/resolve.lst
    else
      warn "cannot list ${r}: $(tail -1 /tmp/rclone-list.err 2>/dev/null)"
      unreachable=$((unreachable + 1))
    fi
  done
  limit="$(date -u -d "@$(( $(date +%s) + 86400 ))" +%Y%m%dT%H%M%SZ)"
  for line in "${lines[@]}"; do
    path="${line#*$'\t'}"
    n="${path##*/}"
    if [[ "${want}" == "latest" ]]; then
      [[ "${path%%/*}" != "pre-restore" ]] || continue
      if [[ "${n:4:16}" > "${limit}" ]]; then
        warn "ignoring ${line%%$'\t'*}/${path}: its timestamp is in the future (clock jump?) — restore it by name if wanted"
        continue
      fi
      if [[ "${n}" > "${best_name}" ]]; then   # strictly newer: on a tie the first remote wins
        best="${line}"
        best_name="${n}"
      fi
    elif [[ "${n}" == "${want%.tar.age}.tar.age" ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
  done
  if [[ "${want}" == "latest" ]] && (( unreachable > 0 )); then
    fail "${unreachable} remote(s) could not be listed — the newest backup may be there; fix the remote or choose one with FROM=<remote>"
    return 2
  fi
  if [[ -n "${best}" ]]; then
    printf '%s\n' "${best}"
    return 0
  fi
  if (( unreachable > 0 )); then
    return 2
  fi
  return 1
}

# Decrypt + unpack a bundle file into DIR, verify every sha256 listed in its manifest and that the manifest names the
# file it came from (a renamed copy of an old bundle must not pose as a newer one).
unpack_bundle() {   # unpack_bundle FILE DIR EXPECTED_NAME
  local file="${1}" dir="${2}" expected="${3%.tar.age}" f want have
  [[ -r "${AGE_IDENTITY}" ]] || die "age identity ${AGE_IDENTITY} not readable (run make up — it fixes the permissions)"
  mkdir -p "${dir}"
  age -d -i "${AGE_IDENTITY}" "${file}" | tar -xf - -C "${dir}" || return 1
  [[ -s "${dir}/manifest.json" && -s "${dir}/db.dump" && -s "${dir}/key-bundle.env" ]] || return 1
  have="$(jq -r '.name // empty' "${dir}/manifest.json")"
  if [[ "${have}" != "${expected}" ]]; then
    fail "the bundle file is called ${expected} but its manifest says '${have}' — renamed or planted file, refusing it"
    return 1
  fi
  for f in db.dump key-bundle.env; do
    want="$(jq -r --arg f "${f}" '.files[$f].sha256 // empty' "${dir}/manifest.json")"
    have="$(sha256sum "${dir}/${f}" | cut -d' ' -f1)"
    if [[ -z "${want}" || "${want}" != "${have}" ]]; then
      fail "${f}: sha256 mismatch (manifest ${want:-missing}, file ${have})"
      return 1
    fi
  done
}

bundle_key() {   # the N8N_ENCRYPTION_KEY stored in an unpacked bundle
  grep -E '^N8N_ENCRYPTION_KEY=' "${1}/key-bundle.env" | sed -n 1p | cut -d= -f2-
}

key_hint() {   # key_hint KEY — "abcd…wxyz (64 chars)": enough to compare with a password manager, useless to an attacker
  local k="${1}"
  if (( ${#k} < 12 )); then
    printf '(%s chars)' "${#k}"
  else
    printf '%s…%s (%s chars)' "${k:0:4}" "${k: -4}" "${#k}"
  fi
}

# Rows of TABLE inside a pg_dump -Fc archive (0 when the table is absent). Counting the archive itself — not the live
# database — keeps the manifest consistent with the dump's snapshot even while n8n is writing.
dump_rows() {   # dump_rows TABLE DUMPFILE
  pg_restore --data-only --table="${1}" -f - "${2}" | awk '/^COPY / { c = 1; next } c && /^\\\.$/ { c = 0; next } c { n++ } END { print n + 0 }'
}
