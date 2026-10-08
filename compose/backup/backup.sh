#!/usr/bin/env bash
# compose/backup/backup.sh [--kind daily|manual|pre-upgrade|pre-restore] [--name LABEL]
#
# 1. pg_dump -Fc of the n8n database (binary data lives there too: N8N_DEFAULT_BINARY_DATA_MODE=database)
# 2. key-bundle.env — N8N_ENCRYPTION_KEY + versions: without the key a restored database cannot decrypt credentials
# 3. manifest.json — sizes, sha256s, row counts, versions (restore verifies the sha256s)
# 4. tar | age to the host key AND the recovery key -> n8n-<UTC ts>-<kind>[-label].tar.age
# 5. copy to EVERY remote in BACKUP_REMOTES under <kind>/ (daily backups taken on the 1st also go to monthly/)
# 6. retention: daily/ older than BACKUP_RETENTION_DAILY_DAYS, monthly/ older than BACKUP_RETENTION_MONTHLY_DAYS;
#    manual/, pre-upgrade/ and pre-restore/ are kept until deleted by hand
# 7. metrics in /state/metrics.prom; Telegram on failure (and on success if BACKUP_NOTIFY_SUCCESS=true)
# Success = every remote received the bundle. Exit 1 otherwise. Prints "BACKUP OK <name> <bytes>" on success.
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
mapfile -t targets < <(remotes)
if (( ${#targets[@]} == 0 )); then
  die "BACKUP_REMOTES is empty — nowhere to store the backup (e.g. BACKUP_REMOTES=\"r2:n8n-backups/prod /backups/external\")"
fi

# one backup at a time (cron + a manual run could overlap)
exec 9>/tmp/backup.lock
flock -n 9 || die "another backup is running"

started="$(date +%s)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="n8n-${stamp}-${kind}${label:+-${label}}"
work="$(mktemp -d /tmp/backup.XXXXXX)"
trap 'rm -rf "${work}"' EXIT
info "backup ${name} -> ${targets[*]}"

pg_dump -Fc -Z6 -f "${work}/db.dump"
workflows="$(psql -Atc 'select count(*) from workflow_entity')"
credentials="$(psql -Atc 'select count(*) from credentials_entity')"
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

mapfile -t rcpt < <(recipients)
bundle="${work}/${name}.tar.age"
tar -C "${work}" -cf - db.dump key-bundle.env manifest.json | age "${rcpt[@]}" -o "${bundle}"
bytes="$(stat -c %s "${bundle}")"

failed=0
day="$(date +%d)"
now="$(date +%s)"
declare -a metric_lines=()
for remote in "${targets[@]}"; do
  lbl="$(label_of "${remote}")"
  if rclone copyto "${bundle}" "${remote}/${kind}/${name}.tar.age" 2>/tmp/rclone.err; then
    if [[ "${kind}" == "daily" && "${day}" == "01" ]]; then
      rclone copyto "${bundle}" "${remote}/monthly/${name}.tar.age" 2>>/tmp/rclone.err || warn "${remote}: monthly copy failed"
    fi
    if [[ "${kind}" == "daily" ]]; then
      rclone delete --min-age "${BACKUP_RETENTION_DAILY_DAYS:-30}d" --include 'n8n-*.tar.age' "${remote}/daily" 2>/dev/null || true
      rclone delete --min-age "${BACKUP_RETENTION_MONTHLY_DAYS:-365}d" --include 'n8n-*.tar.age' "${remote}/monthly" 2>/dev/null || true
    fi
    ok "${remote}/${kind}/${name}.tar.age (${bytes} bytes)"
    metric_lines+=("backup_last_success_timestamp_seconds{remote=\"${lbl}\"} ${now}" "backup_last_status{remote=\"${lbl}\"} 1")
  else
    fail "${remote}: upload failed — $(tail -3 /tmp/rclone.err | tr '\n' ' ')"
    failed=$((failed + 1))
    # keep the previous success timestamp so BackupMissing alerts on age, not on a single failed attempt
    prev="$(grep -F "backup_last_success_timestamp_seconds{remote=\"${lbl}\"}" "${STATE_DIR}/metrics.d/backup.prom" 2>/dev/null | head -1 || true)"
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

summary="${name}: ${bytes} bytes, ${workflows} workflows, ${credentials} credentials, ${duration}s"
if (( failed > 0 )); then
  /opt/backup/notify.sh error "backup ${summary} — ${failed} of ${#targets[@]} remote(s) FAILED"
  die "backup incomplete: ${failed} of ${#targets[@]} remote(s) failed"
fi
if [[ "${BACKUP_NOTIFY_SUCCESS:-false}" == "true" ]]; then
  /opt/backup/notify.sh ok "backup ${summary} -> ${#targets[@]} remote(s)"
fi
ok "backup complete: ${summary}"
printf 'BACKUP OK %s %s\n' "${name}" "${bytes}"
