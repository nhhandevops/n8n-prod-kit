#!/usr/bin/env bash
# compose/backup/backup.sh [--kind daily|manual|pre-upgrade|pre-restore] [--name LABEL]
#
# 1. pg_dump -Fc of the n8n database (binary data lives there too: N8N_DEFAULT_BINARY_DATA_MODE=database)
# 2. key-bundle.env — N8N_ENCRYPTION_KEY + versions: without the key a restored database cannot decrypt credentials
# 3. manifest.json — sizes, sha256s, row counts (counted IN the dump, so they match it exactly), versions
# 4. tar | age to the host key AND the recovery key -> n8n-<UTC ts>-<kind>[-label].tar.age
# 5. copy to EVERY remote in BACKUP_REMOTES under <kind>/; a daily run also makes sure the current UTC month has a
#    bundle under monthly/ (self-healing: a failed or skipped 1st is filled in by the next daily run)
# 6. retention, by the UTC timestamp in the name: daily/ older than BACKUP_RETENTION_DAILY_DAYS, monthly/ older than
#    BACKUP_RETENTION_MONTHLY_DAYS — but never the BACKUP_RETENTION_MIN_KEEP newest of either (a clock that jumps
#    ahead must not empty a remote) and never the bundle just written; manual/, pre-upgrade/, pre-restore/ are kept
# 7. metrics in /state/metrics.prom; Telegram on failure (and on success if BACKUP_NOTIFY_SUCCESS=true)
# Success = every remote received the bundle (and its monthly copy). ANY failure — bad configuration, a held lock,
# pg_dump, a full tmpfs, age, an upload — sets backup_last_status 0 for every remote and alerts. Exit 0 only on full
# success; prints "BACKUP OK <name> <bytes>" then.
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail
# shellcheck source=lib.sh
source /opt/backup/lib.sh

kind=daily
label=''
while (( $# > 0 )); do
  case "${1}" in
    --kind) kind="${2:-}"; shift 2 ;;
    --name) label="${2:-}"; shift 2 ;;
    *) die "usage: backup.sh [--kind daily|manual|pre-upgrade|pre-restore] [--name LABEL]" 2 ;;
  esac
done
case "${kind}" in
  daily | manual | pre-upgrade | pre-restore) ;;
  *) die "unknown --kind '${kind}'" 2 ;;
esac
label="$(printf '%s' "${label}" | tr -c 'a-zA-Z0-9.-' '-' | tr '[:upper:]' '[:lower:]')"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="n8n-${stamp}-${kind}${label:+-${label}}"
work=''
stage=configuration
reported=0

# Every remote gets status 0 (the previous success timestamps are kept, so the age-based alert stays correct) and the
# operator is told — for failures anywhere, not only during the upload.
record_failure() {   # record_failure WHAT
  local r lbl prev
  {
    printf '# HELP backup_last_success_timestamp_seconds Unix time of the last successful backup per remote\n'
    printf '# TYPE backup_last_success_timestamp_seconds gauge\n'
    for r in ${BACKUP_REMOTES:-}; do
      lbl="$(label_of "${r%/}")"
      prev="$(grep -F "backup_last_success_timestamp_seconds{remote=\"${lbl}\"}" "${STATE_DIR}/metrics.d/backup.prom" 2>/dev/null | sed -n 1p || true)"
      if [[ -n "${prev}" ]]; then
        printf '%s\n' "${prev}"
      fi
      printf 'backup_last_status{remote="%s"} 0\n' "${lbl}"
    done
    printf 'backup_last_attempt_timestamp_seconds %s\n' "$(date +%s)"
  } | write_metrics backup || warn "could not write the failure metrics to ${STATE_DIR}"
  /opt/backup/notify.sh error "backup ${name} FAILED — ${1}"
}
on_exit() {
  local rc=$?
  if [[ -n "${work}" ]]; then
    rm -rf "${work}"
  fi
  if (( rc != 0 && reported == 0 )); then
    record_failure "${stage} failed (exit ${rc}) — make logs SERVICE=backup"
  fi
  exit "${rc}"
}
trap on_exit EXIT

# --- configuration (a mistake here must alert too: it would otherwise silently stop every nightly backup) ----------
validate_remotes || die "fix BACKUP_REMOTES in .env" 2
mapfile -t targets < <(remotes)
if (( ${#targets[@]} == 0 )); then
  die "BACKUP_REMOTES is empty — nowhere to store the backup (e.g. BACKUP_REMOTES=\"r2:n8n-backups/prod /backups/external\")" 2
fi
keep_daily="${BACKUP_RETENTION_DAILY_DAYS:-30}"
keep_monthly="${BACKUP_RETENTION_MONTHLY_DAYS:-365}"
min_keep="${BACKUP_RETENTION_MIN_KEEP:-7}"
for setting in "BACKUP_RETENTION_DAILY_DAYS=${keep_daily}" "BACKUP_RETENTION_MONTHLY_DAYS=${keep_monthly}" \
  "BACKUP_RETENTION_MIN_KEEP=${min_keep}"; do
  [[ "${setting#*=}" =~ ^[1-9][0-9]{0,4}$ ]] ||
    die "${setting%%=*}='${setting#*=}' must be a whole number >= 1 (e.g. 30) — 0 would delete every bundle, '30d' would keep all" 2
done
if [[ -z "${BACKUP_AGE_PUBLIC_KEY:-}" ]]; then
  die "BACKUP_AGE_PUBLIC_KEY is empty — run make init (it generates the age keys)" 2
fi
if [[ -z "${BACKUP_AGE_RECOVERY_PUBLIC_KEY:-}" && "${BACKUP_ALLOW_SINGLE_RECIPIENT:-false}" != "true" ]]; then
  die "BACKUP_AGE_RECOVERY_PUBLIC_KEY is empty — this backup could only be opened with this host's own key, which is lost with the host. Put the recovery public key back into .env (age-keygen -y <recovery key file>) or set BACKUP_ALLOW_SINGLE_RECIPIENT=true" 2
fi

# --- one job at a time (cron + make backup-now + the safety backup of make restore run in different containers) ----
stage="waiting for the backup lock"
take_lock 900 || die "another backup, restore test or restore is still running after 15 min"

started="$(date +%s)"
work="$(mktemp -d /tmp/backup.XXXXXX)"
info "backup ${name} -> ${targets[*]}"

stage=pg_dump
pg_dump -Fc -Z6 -f "${work}/db.dump"
stage="manifest"
workflows="$(dump_rows workflow_entity "${work}/db.dump")"
credentials="$(dump_rows credentials_entity "${work}/db.dump")"
server="$(psql -Atc 'show server_version')"
{
  printf '# n8n Production Kit key bundle — restore needs this key to decrypt the credentials in db.dump\n'
  printf 'N8N_ENCRYPTION_KEY=%s\n' "${N8N_ENCRYPTION_KEY:?N8N_ENCRYPTION_KEY not set in the backup container}"
  printf 'N8N_VERSION=%s\nDOMAIN=%s\nPOSTGRES_SERVER_VERSION=%s\nCREATED_AT=%s\nBUNDLE_FORMAT=%s\n' \
    "${N8N_VERSION:-}" "${DOMAIN:-}" "${server}" "${stamp}" "${BUNDLE_FORMAT}"
} >"${work}/key-bundle.env"
chmod 0600 "${work}/key-bundle.env"
jq -n --arg name "${name}" --arg kind "${kind}" --arg created "${stamp}" --arg n8n "${N8N_VERSION:-}" \
  --arg pg "${server}" --arg domain "${DOMAIN:-}" --argjson format "${BUNDLE_FORMAT}" \
  --argjson workflows "${workflows}" --argjson credentials "${credentials}" \
  --arg dsum "$(sha256sum "${work}/db.dump" | cut -d' ' -f1)" --argjson dsize "$(stat -c %s "${work}/db.dump")" \
  --arg ksum "$(sha256sum "${work}/key-bundle.env" | cut -d' ' -f1)" \
  '{name: $name, kind: $kind, created_at: $created, bundle_format: $format, n8n_version: $n8n, postgres_version: $pg,
    domain: $domain, counts: {workflows: $workflows, credentials: $credentials},
    files: {"db.dump": {sha256: $dsum, bytes: $dsize}, "key-bundle.env": {sha256: $ksum}}}' >"${work}/manifest.json"

stage="encryption (age)"
mapfile -t rcpt < <(recipients)
bundle="${work}/${name}.tar.age"
tar -C "${work}" -cf - db.dump key-bundle.env manifest.json | age "${rcpt[@]}" -o "${bundle}"
rm -f "${work}/db.dump"   # the plaintext is no longer needed; frees the tmpfs for the uploads
bytes="$(stat -c %s "${bundle}")"

# ensure_monthly REMOTE — the current UTC month has a bundle under monthly/ (copies this one when it has none yet)
month="${stamp:0:6}"
ensure_monthly() {
  local have
  have="$(rclone lsf --files-only --include "n8n-${month}*.tar.age" "${1}/monthly" 2>/dev/null || true)"
  if [[ -n "${have}" ]]; then
    return 0
  fi
  rclone copyto "${bundle}" "${1}/monthly/${name}.tar.age" 2>>/tmp/rclone.err && info "${1}/monthly/${name}.tar.age"
}
# prune DIR DAYS — delete kit bundles whose UTC name is older than DAYS, keeping the min_keep newest and this one
prune() {
  local dir="${1}" cutoff n i=0 rc=0
  local -a names=()
  cutoff="$(date -u -d "@$(( $(date +%s) - ${2} * 86400 ))" +%Y%m%dT%H%M%SZ)"
  mapfile -t names < <(rclone lsf --files-only --include 'n8n-*.tar.age' "${dir}" 2>/dev/null | grep -E "${NAME_RE}" | sort -r)
  for n in "${names[@]}"; do
    i=$((i + 1))
    if (( i <= min_keep )) || [[ "${n}" == "${name}.tar.age" || ! "${n:4:16}" < "${cutoff}" ]]; then
      continue
    fi
    if rclone deletefile "${dir}/${n}" 2>>/tmp/rclone.err; then
      info "retention: deleted ${dir}/${n}"
    else
      rc=1
    fi
  done
  return "${rc}"
}

stage=upload
failed=0
now="$(date +%s)"
declare -a metric_lines=() warnings=()
: >/tmp/rclone.err
for remote in "${targets[@]}"; do
  lbl="$(label_of "${remote}")"
  problem=''
  if ! rclone copyto "${bundle}" "${remote}/${kind}/${name}.tar.age" 2>>/tmp/rclone.err; then
    problem="upload failed"
  elif [[ "${kind}" == "daily" ]]; then
    ensure_monthly "${remote}" || problem="monthly copy failed"
    prune "${remote}/daily" "${keep_daily}" || warnings+=("${remote}/daily: retention could not delete every expired bundle")
    prune "${remote}/monthly" "${keep_monthly}" || warnings+=("${remote}/monthly: retention could not delete every expired bundle")
  fi
  if [[ -z "${problem}" ]]; then
    ok "${remote}/${kind}/${name}.tar.age (${bytes} bytes)"
    metric_lines+=("backup_last_success_timestamp_seconds{remote=\"${lbl}\"} ${now}" "backup_last_status{remote=\"${lbl}\"} 1")
  else
    fail "${remote}: ${problem} — $(tail -3 /tmp/rclone.err | tr '\n' ' ')"
    failed=$((failed + 1))
    # keep the previous success timestamp so BackupMissing alerts on age, not on a single failed attempt
    prev="$(grep -F "backup_last_success_timestamp_seconds{remote=\"${lbl}\"}" "${STATE_DIR}/metrics.d/backup.prom" 2>/dev/null | sed -n 1p || true)"
    if [[ -n "${prev}" ]]; then
      metric_lines+=("${prev}")
    fi
    metric_lines+=("backup_last_status{remote=\"${lbl}\"} 0")
  fi
done
duration=$(( $(date +%s) - started ))
{
  printf '# HELP backup_last_success_timestamp_seconds Unix time of the last successful backup per remote\n'
  printf '# TYPE backup_last_success_timestamp_seconds gauge\n'
  printf '%s\n' "${metric_lines[@]}" | sort
  printf 'backup_last_attempt_timestamp_seconds %s\n' "${now}"
  printf 'backup_last_size_bytes %s\nbackup_last_duration_seconds %s\n' "${bytes}" "${duration}"
  printf 'backup_info{name="%s",kind="%s"} 1\n' "${name}" "${kind}"
} | write_metrics backup
reported=1

summary="${name}: ${bytes} bytes, ${workflows} workflows, ${credentials} credentials, ${duration}s"
if (( failed > 0 )); then
  /opt/backup/notify.sh error "backup ${summary} — ${failed} of ${#targets[@]} remote(s) FAILED"
  die "backup incomplete: ${failed} of ${#targets[@]} remote(s) failed"
fi
for w in "${warnings[@]}"; do
  warn "${w}"
  /opt/backup/notify.sh warn "backup ${name}: ${w}"
done
if [[ "${BACKUP_NOTIFY_SUCCESS:-false}" == "true" ]]; then
  /opt/backup/notify.sh ok "backup ${summary} -> ${#targets[@]} remote(s)"
fi
ok "backup complete: ${summary}"
printf 'BACKUP OK %s %s\n' "${name}" "${bytes}"
