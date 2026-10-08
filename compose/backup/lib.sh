#!/usr/bin/env bash
# compose/backup/lib.sh — shared helpers for the scripts INSIDE the backup container (sourced, never run).
#
# Paths: /state (volume backup_state: metrics + reports, survives restarts), /work (volume backup_work: a fetched and
# decrypted bundle waiting to be restored), /tmp (tmpfs, size BACKUP_TMPFS_SIZE: everything transient),
# /run/secrets/age-key.txt (the host's age identity, read-only), /backups/local and /backups/external (bind mounts).
# Bundle format v1: <name>.tar.age = age(tar(db.dump, key-bundle.env, manifest.json)), recipients = host key + recovery
# key; <name> = n8n-<UTC YYYYmmddTHHMMSSZ>-<kind>[-<label>], stored under <remote>/<kind>/.
# shellcheck disable=SC2310,SC2311,SC2312,SC2034  # SC2034: constants used by the scripts that source this file

if [[ -n "${__KIT_BACKUP_LIB:-}" ]]; then
  return 0
fi
__KIT_BACKUP_LIB=1

STATE_DIR=/state
WORK_DIR=/work
AGE_IDENTITY="${AGE_KEY_FILE:-/run/secrets/age-key.txt}"
BUNDLE_FORMAT=1

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "${*}" >&2; }
info() { log "[info] ${*}"; }
ok() { log "[ OK ] ${*}"; }
warn() { log "[warn] ${*}"; }
fail() { log "[FAIL] ${*}"; }
die() {
  fail "${1}"
  exit "${2:-1}"
}

# Remotes from BACKUP_REMOTES (space separated). A path starting with "/" is a local directory inside the container.
remotes() {
  local r
  for r in ${BACKUP_REMOTES:-}; do
    printf '%s\n' "${r%/}"
  done
}

# Prometheus-safe label value
label_of() {
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

# Metrics live in one file per topic under /state/metrics.d; metrics.prom is their concatenation (node-exporter's
# textfile collector reads it in S6; `make doctor` reads it now). Writes are atomic (temp file + mv).
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

recipients() {   # age -r arguments for every configured public key
  local -a args=()
  [[ -n "${BACKUP_AGE_PUBLIC_KEY:-}" ]] && args+=(-r "${BACKUP_AGE_PUBLIC_KEY}")
  [[ -n "${BACKUP_AGE_RECOVERY_PUBLIC_KEY:-}" ]] && args+=(-r "${BACKUP_AGE_RECOVERY_PUBLIC_KEY}")
  if (( ${#args[@]} == 0 )); then
    die "BACKUP_AGE_PUBLIC_KEY is empty — run make init (it generates the age keys)"
  fi
  printf '%s\n' "${args[@]}"
}

# Every bundle on one remote, newest first: "<remote>\t<kind>/<file>"
list_remote() {
  local remote="${1}" path
  rclone lsf -R --files-only --include 'n8n-*.tar.age' "${remote}" 2>/dev/null | while IFS= read -r path; do
    printf '%s\t%s\n' "${remote}" "${path}"
  done
}

# Resolve NAME (or "latest") to "<remote>\t<kind>/<file>" across the remotes (or only FROM when given).
resolve_bundle() {   # resolve_bundle NAME [FROM]
  local want="${1}" from="${2:-}" r line
  local -a lines=()
  for r in $(if [[ -n "${from}" ]]; then printf '%s\n' "${from%/}"; else remotes; fi); do
    while IFS= read -r line; do
      lines+=("${line}")
    done < <(list_remote "${r}")
  done
  if (( ${#lines[@]} == 0 )); then
    return 1
  fi
  if [[ "${want}" == "latest" ]]; then
    # names carry a UTC timestamp right after "n8n-": sort on the basename, newest first
    printf '%s\n' "${lines[@]}" | awk -F'\t' '{ n = $2; sub(/.*\//, "", n); print n "\t" $0 }' | sort -r | head -1 | cut -f2-
  else
    want="${want%.tar.age}"
    printf '%s\n' "${lines[@]}" | awk -F'\t' -v w="${want}.tar.age" '{ n = $2; sub(/.*\//, "", n); if (n == w) { print; exit } }'
  fi
}

# Decrypt + unpack a bundle file into DIR and verify every sha256 listed in its manifest.
unpack_bundle() {   # unpack_bundle FILE DIR
  local file="${1}" dir="${2}" f want have
  [[ -r "${AGE_IDENTITY}" ]] || die "age identity ${AGE_IDENTITY} not readable (run make up — it fixes the permissions)"
  mkdir -p "${dir}"
  age -d -i "${AGE_IDENTITY}" "${file}" | tar -xf - -C "${dir}" || return 1
  [[ -s "${dir}/manifest.json" && -s "${dir}/db.dump" && -s "${dir}/key-bundle.env" ]] || return 1
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
  grep -E '^N8N_ENCRYPTION_KEY=' "${1}/key-bundle.env" | head -1 | cut -d= -f2-
}
