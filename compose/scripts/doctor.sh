#!/usr/bin/env bash
# compose/scripts/doctor.sh — "what is wrong with my n8n?" (`make doctor`, test case TC-026).
#
# Read-only. One line per check in the lib.sh formats ([ OK ] / [warn] / [FAIL]), every FAIL and most warns carrying
# the fix. Exit 1 when at least one FAIL was printed. Designed to be pasted into a bug report.
#
# Checks: .env permissions and key length · n8n vs runners version lock · every service running+healthy (unhealthy ones
# get their last 20 log lines) and restart counts · ports actually served by caddy · DNS vs this host's public IP ·
# certificate expiry (ACME modes) · disk on the Docker root · clock sync · Postgres connections, size, execution pruning ·
# Valkey eviction policy, AOF, memory · N8N_ENDPOINT_* overrides (would break the Caddyfile routing) · recovery key still
# on this host · backups (from S5) · SELinux/firewalld on RHEL hosts · WSL hints.
#
# DOCTOR_SIMULATE=lowdisk,nokey,baddns,unhealthy  injects failures so the output format and exit code can be tested
# without breaking a real host (TC-026).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

need_cmd docker ss df awk grep openssl date
fails=0
warns=0
flag_fail() { fail "${*}"; fails=$((fails + 1)); }
flag_warn() { warn "${*}"; warns=$((warns + 1)); }
simulate="${DOCTOR_SIMULATE:-}"
sim() { [[ ",${simulate}," == *",${1},"* ]]; }
if [[ -n "${simulate}" ]]; then
  info "DOCTOR_SIMULATE=${simulate} — some failures below are injected on purpose"
fi

section() { log ""; log "── ${*}"; }

# ---------------------------------------------------------------------------------------------------------------------
section "configuration"
if [[ ! -f .env ]]; then
  flag_fail ".env missing — run: make init DOMAIN=<your-domain>"
  die "doctor: ${fails} problem(s)"
fi
env_mode="$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env)"
if [[ "${env_mode}" == "600" ]]; then ok ".env mode 600"; else flag_fail ".env mode is ${env_mode} — chmod 600 .env"; fi
key="$(env_get N8N_ENCRYPTION_KEY)"
if sim nokey; then key=""; fi
if (( ${#key} >= 32 )); then
  ok "N8N_ENCRYPTION_KEY present (${#key} chars) — is it in your password manager?"
else
  flag_fail "N8N_ENCRYPTION_KEY is missing or shorter than 32 chars — every credential depends on it; restore it from your password manager (never generate a new one over an existing database)"
fi
domain="$(env_get DOMAIN)"; tls_mode="$(env_get TLS_MODE)"; http_port="$(env_get HTTP_PORT)"; https_port="$(env_get HTTPS_PORT)"
http_port="${http_port:-80}"; https_port="${https_port:-443}"
if grep -qE '^[[:space:]]*N8N_ENDPOINT_[A-Z_]+=' .env; then
  flag_fail "N8N_ENDPOINT_* is set in .env — the Caddyfile routes n8n's DEFAULT paths; custom endpoint names would be sent to the wrong process. Remove the override (or edit caddy/Caddyfile to match)"
else
  ok "no N8N_ENDPOINT_* overrides (Caddyfile routing matches n8n's defaults)"
fi
if [[ -f secrets/age-recovery-key.txt ]]; then
  key_age_days=$(( ( $(date +%s) - $(stat -c %Y secrets/age-recovery-key.txt) ) / 86400 ))
  recovery_pub="$(docker run --rm --network none --user "$(id -u):$(id -g)" --entrypoint age-keygen \
    -v "${KIT_DIR}/secrets/age-recovery-key.txt:/k.txt:ro,z" n8nkit/backup:local -y /k.txt 2>/dev/null || true)"
  if [[ -n "${recovery_pub}" && "${recovery_pub}" != "$(env_get BACKUP_AGE_RECOVERY_PUBLIC_KEY)" ]]; then
    flag_fail "BACKUP_AGE_RECOVERY_PUBLIC_KEY in .env is not the public key of secrets/age-recovery-key.txt — new backups are encrypted to a key you may not have; set it to: ${recovery_pub}"
  fi
  if (( key_age_days > 7 )); then
    flag_warn "secrets/age-recovery-key.txt has been on this host for ${key_age_days} days — store it in your password manager and run make detach-recovery-key; a backup that can be decrypted from the same host it protects is not a recovery plan"
  else
    ok "recovery key on host for ${key_age_days} day(s) — move it off-host within 7 days (make detach-recovery-key)"
  fi
elif [[ -n "$(env_get BACKUP_AGE_RECOVERY_PUBLIC_KEY)" ]]; then
  ok "recovery key detached (private half off-host; backups are still encrypted to it)"
else
  flag_warn "no recovery key: BACKUP_AGE_RECOVERY_PUBLIC_KEY is empty — backups can only be opened with this host's key"
fi
backup_enabled="$(env_get BACKUP_ENABLED)"
backup_enabled="${backup_enabled:-true}"   # the compose default
if [[ "${backup_enabled}" == "true" && ! -s secrets/age-key.txt ]]; then
  flag_fail "secrets/age-key.txt is missing — backups cannot be encrypted or restore-tested (re-run make init FORCE=1 only if you also restore the old key)"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "version lock"
project="$(_kit_project_name)"
container_of() { docker ps -aq --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=${1}" | head -1 || true; }
image_tag_of() {   # prints the tag of a running container's image, e.g. 2.42.4
  local cid img
  cid="$(container_of "${1}")"
  [[ -n "${cid}" ]] || return 0
  img="$(docker inspect --format '{{.Config.Image}}' "${cid}")"
  img="${img%%@*}"
  printf '%s\n' "${img##*:}"
}
n8n_tag="$(image_tag_of n8n-main)"; runners_tag="$(image_tag_of n8n-worker-1-runners)"
pinned="$(env_get N8N_VERSION versions.env)"
if [[ -z "${n8n_tag}" ]]; then
  flag_warn "n8n-main is not running — version lock checked from versions.env only (N8N_VERSION=${pinned})"
elif [[ "${n8n_tag}" == "${runners_tag}" && "${n8n_tag}" == "${pinned}" ]]; then
  ok "n8n ${n8n_tag} = runners ${runners_tag} = versions.env ${pinned}"
else
  flag_fail "version mismatch: n8n-main ${n8n_tag:-?}, runners ${runners_tag:-?}, versions.env ${pinned} — run: make pin && make up (the runners image MUST match n8n)"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "services"
mapfile -t services < <(compose config --services 2>/dev/null || true)
unhealthy=0
for svc in "${services[@]}"; do
  cid="$(container_of "${svc}")"
  if [[ -z "${cid}" ]]; then
    flag_fail "${svc}: no container — run: make up"; unhealthy=$((unhealthy + 1)); continue
  fi
  state="$(docker inspect --format '{{.State.Status}}' "${cid}")"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
  restarts="$(docker inspect --format '{{.RestartCount}}' "${cid}")"
  if sim unhealthy && [[ "${svc}" == "n8n-worker-2" ]]; then state=running; health=unhealthy; fi
  if [[ "${state}" == "running" && ( "${health}" == "healthy" || "${health}" == "none" ) ]]; then
    if (( restarts > 0 )); then
      flag_warn "${svc}: healthy but restarted ${restarts}x since creation — check: make logs SERVICE=${svc} SINCE=24h"
    else
      ok "${svc}: ${state}/${health}"
    fi
  else
    flag_fail "${svc}: ${state}/${health} — last 20 log lines follow"
    docker logs --tail 20 "${cid}" 2>&1 | sed 's/^/        /' >&2 || true
    unhealthy=$((unhealthy + 1))
  fi
done

# ---------------------------------------------------------------------------------------------------------------------
section "edge"
for port in "${http_port}" "${https_port}"; do
  if ss -Hltn "( sport = :${port} )" 2>/dev/null | grep -q .; then
    ok "port ${port} is being served"
  else
    flag_fail "nothing listens on port ${port} — is caddy running? (make status; make logs SERVICE=caddy)"
  fi
done
domain_ip="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1; exit}' || true)"
if [[ "${tls_mode}" == "internal" ]]; then
  ok "TLS_MODE=internal: certificates come from the kit's local CA (12 h leaf certs, renewed automatically) — DNS ${domain} -> ${domain_ip:-unresolved}"
else
  public_ip="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)"
  if sim baddns; then domain_ip="203.0.113.1"; fi
  if [[ -z "${domain_ip}" ]]; then
    flag_fail "DNS: ${domain} does not resolve — ACME cannot issue; create the record pointing at this host"
  elif [[ -n "${public_ip}" && "${domain_ip}" != "${public_ip}" ]]; then
    flag_fail "DNS: ${domain} -> ${domain_ip} but this host is ${public_ip} — fix the record; until then Let's Encrypt keeps failing (and counting attempts)"
  else
    ok "DNS: ${domain} -> ${domain_ip}${public_ip:+ (= public IP)}"
  fi
  not_after="$(echo | openssl s_client -connect "127.0.0.1:${https_port}" -servername "${domain}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [[ -z "${not_after}" ]]; then
    flag_warn "could not read the certificate on 127.0.0.1:${https_port} — caddy down, or ACME still in progress (make logs SERVICE=caddy)"
  else
    days_left=$(( ( $(date -d "${not_after}" +%s) - $(date +%s) ) / 86400 ))
    if (( days_left < 0 )); then
      flag_fail "certificate EXPIRED (${not_after}) — caddy could not renew: check DNS, port ${http_port}/${https_port} reachability from the Internet, and make logs SERVICE=caddy"
    elif (( days_left < 14 )); then
      flag_warn "certificate expires in ${days_left} days (${not_after}) — caddy renews at 30 days left; if this keeps dropping, renewal is failing (make logs SERVICE=caddy)"
    else
      ok "certificate valid for ${days_left} more days"
    fi
  fi
fi

# ---------------------------------------------------------------------------------------------------------------------
section "host"
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
pct="$(df --output=pcent "${docker_root}" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)"
if sim lowdisk; then pct=93; fi
if (( pct >= 90 )); then
  flag_fail "disk ${pct}% used under ${docker_root} — Postgres and Valkey stop writing at 100%: prune images (docker image prune -a), lower EXECUTIONS_DATA_MAX_AGE, or add space"
elif (( pct >= 80 )); then
  flag_warn "disk ${pct}% used under ${docker_root} — plan space before it reaches 90% (docker system df shows what Docker holds)"
else
  ok "disk ${pct}% used under ${docker_root}"
fi
ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
case "${ntp}" in
  yes) ok "clock synchronised (NTP)" ;;
  no) flag_warn "clock NOT synchronised — TLS and job locks suffer: timedatectl set-ntp true" ;;
  *) flag_warn "clock sync state unknown — verify NTP manually" ;;
esac
if grep -qi microsoft /proc/version 2>/dev/null; then
  info "WSL detected: a port that looks free here can still be held by Windows (netstat -ano on the Windows side); the clock drifts after sleep (sudo hwclock -s)"
fi
if command -v getenforce >/dev/null 2>&1; then
  se="$(getenforce 2>/dev/null || echo unknown)"
  ok "SELinux: ${se} (bind mounts carry :z, so Enforcing is fine)"
fi
if command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  fw_services="$(firewall-cmd --list-services 2>/dev/null || true)"
  if [[ "${fw_services}" == *http* && "${fw_services}" == *https* ]]; then
    ok "firewalld active, http/https allowed"
  else
    flag_fail "firewalld active but http/https not allowed (services: ${fw_services:-none}) — firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload"
  fi
fi

# ---------------------------------------------------------------------------------------------------------------------
section "database"
if [[ "$(service_health postgres)" == "healthy" ]]; then
  pg() { compose exec -T postgres psql -U n8n -d n8n -Atc "${1}" 2>/dev/null || true; }
  conns="$(pg "select count(*) from pg_stat_activity where datname='n8n'")"
  max_conns="$(pg "show max_connections")"
  size="$(pg "select pg_size_pretty(pg_database_size('n8n'))")"
  if [[ -n "${conns}" && -n "${max_conns}" ]] && (( conns * 100 / max_conns >= 80 )); then
    flag_warn "postgres: ${conns}/${max_conns} connections in use — lower DB_POSTGRESDB_POOL_SIZE or WORKER_REPLICAS, or raise max_connections in docker-compose.yml"
  else
    ok "postgres: ${conns:-?}/${max_conns:-?} connections, database ${size:-?}"
  fi
  exec_stats="$(pg "select count(*), coalesce(extract(epoch from (now() - min(\"startedAt\")))/3600, 0)::int from execution_entity")"
  exec_count="${exec_stats%%|*}"; oldest_h="${exec_stats##*|}"
  prune="$(env_get EXECUTIONS_DATA_PRUNE)"; max_age="$(env_get EXECUTIONS_DATA_MAX_AGE)"; max_age="${max_age:-336}"
  if [[ "${prune:-true}" == "true" ]] && (( oldest_h > max_age * 2 )); then
    flag_warn "executions: ${exec_count} rows, oldest ${oldest_h} h > 2 x EXECUTIONS_DATA_MAX_AGE (${max_age} h) — pruning seems stalled (main prunes hourly; check make logs SERVICE=n8n-main for 'prun')"
  else
    ok "executions: ${exec_count} rows, oldest ${oldest_h} h (prune=${prune:-true}, max age ${max_age} h)"
  fi
else
  flag_warn "postgres not healthy — database checks skipped"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "queue"
if [[ "$(service_health valkey)" == "healthy" ]]; then
  vk() { compose exec -T valkey sh -c "VALKEYCLI_AUTH=\$VALKEY_PASSWORD valkey-cli ${1}" 2>/dev/null | tr -d '\r' || true; }
  policy="$(vk 'config get maxmemory-policy' | tail -1)"
  aof="$(vk 'config get appendonly' | tail -1)"
  used="$(vk 'info memory' | awk -F: '/^used_memory:/ {print $2}')"; maxmem="$(vk 'info memory' | awk -F: '/^maxmemory:/ {print $2}')"
  if [[ "${policy}" == "noeviction" ]]; then ok "valkey: maxmemory-policy noeviction (Bull jobs are never evicted)"; else flag_fail "valkey: maxmemory-policy is '${policy}' — Bull loses jobs under eviction; the kit's command sets noeviction, check docker-compose.yml"; fi
  if [[ "${aof}" == "yes" ]]; then ok "valkey: AOF persistence on"; else flag_fail "valkey: appendonly is '${aof}' — a restart would drop the queue; the kit's command sets --appendonly yes"; fi
  if [[ -n "${used}" && -n "${maxmem}" ]] && (( maxmem > 0 )) && (( used * 100 / maxmem >= 80 )); then
    flag_warn "valkey: memory $((used / 1048576)) MiB of $((maxmem / 1048576)) MiB — near noeviction errors; raise --maxmemory and MEM_LIMIT_VALKEY together, and check for stuck jobs"
  else
    ok "valkey: memory $(( ${used:-0} / 1048576 )) MiB of $(( ${maxmem:-0} / 1048576 )) MiB"
  fi
else
  flag_warn "valkey not healthy — queue checks skipped"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "backups"
backup_remotes="$(env_get BACKUP_REMOTES)"
if [[ "${backup_enabled}" != "true" ]]; then
  flag_warn "BACKUP_ENABLED is not true — no scheduled backups protect the database (make backup-now works manually)"
elif [[ -z "${backup_remotes}" ]]; then
  flag_fail "BACKUP_REMOTES is empty — nothing is backed up; set e.g. BACKUP_REMOTES=\"r2:n8n-backups/prod\" (+ RCLONE_CONFIG_R2_*) and make up"
elif [[ "$(service_health backup)" != "healthy" ]]; then
  flag_fail "backup service is $(service_health backup) — make logs SERVICE=backup"
else
  metrics="$(compose exec -T backup cat /state/metrics.prom 2>/dev/null || true)"
  now="$(date +%s)"
  for remote in ${backup_remotes}; do
    remote="${remote%/}"
    last="$(awk -v r="backup_last_success_timestamp_seconds{remote=\"${remote}\"}" '$1 == r { print $2 }' <<<"${metrics}")"
    status="$(awk -v r="backup_last_status{remote=\"${remote}\"}" '$1 == r { print $2 }' <<<"${metrics}")"
    if [[ -z "${last}" && "${status}" == "0" ]]; then
      flag_fail "every backup to ${remote} has failed so far — make logs SERVICE=backup SINCE=48h; make backup-now"
    elif [[ -z "${last}" ]]; then
      schedule="$(env_get BACKUP_SCHEDULE)"
      flag_warn "no successful backup to ${remote} yet — run make backup-now (the nightly job runs on cron '${schedule:-0 2 * * *}')"
    else
      age_h=$(( (now - ${last%.*}) / 3600 ))
      if (( age_h >= 26 )); then
        flag_fail "last successful backup to ${remote} was ${age_h} h ago — make logs SERVICE=backup SINCE=48h; make backup-now"
      elif [[ "${status}" == "0" ]]; then
        flag_fail "the LAST backup attempt to ${remote} failed (previous success ${age_h} h ago) — make logs SERVICE=backup; make backup-now"
      else
        ok "backup to ${remote}: last success ${age_h} h ago"
      fi
    fi
  done
  size="$(awk '$1 == "backup_last_size_bytes" { print $2 }' <<<"${metrics}")"
  tmpfs_mb="$(size_mb "$(env_get BACKUP_TMPFS_SIZE)")"
  tmpfs_mb="${tmpfs_mb:-1024}"
  if [[ -n "${size}" ]] && (( ${size%.*} * 5 / 1048576 > tmpfs_mb * 2 )); then
    flag_warn "the last bundle is $(( ${size%.*} / 1048576 )) MiB, over 40 % of BACKUP_TMPFS_SIZE (${tmpfs_mb} MiB) — backups and the restore test will soon run out of scratch space; raise BACKUP_TMPFS_SIZE and MEM_LIMIT_BACKUP together"
  fi
  rt_success="$(awk '$1 == "restore_test_last_success_timestamp_seconds" { print $2 }' <<<"${metrics}")"
  rt_status="$(awk '$1 == "restore_test_last_status" { print $2 }' <<<"${metrics}")"
  if [[ "${rt_status}" == "0" ]]; then
    flag_fail "the last restore test FAILED — make restore-test shows why; a backup that does not restore is not a backup"
  elif [[ -z "${rt_success}" ]]; then
    flag_warn "no restore test has run yet — make restore-test (weekly from cron)"
  else
    rt_days=$(( (now - ${rt_success%.*}) / 86400 ))
    if (( rt_days > 8 )); then
      flag_warn "last successful restore test was ${rt_days} days ago (expected weekly)"
    else
      ok "restore test passed ${rt_days} day(s) ago"
    fi
  fi
fi

# ---------------------------------------------------------------------------------------------------------------------
section "monitoring"
profiles=",$(env_get COMPOSE_PROFILES | tr -d ' '),"
if [[ "${profiles}" != *",monitoring,"* ]]; then
  ok "monitoring profile off — COMPOSE_PROFILES=monitoring adds Prometheus, Grafana, Loki and alerts (docs/operations/monitoring.md)"
elif [[ "$(service_health prometheus)" != "healthy" ]]; then
  flag_fail "prometheus is $(service_health prometheus) — make logs SERVICE=prometheus"
else
  targets="$(compose exec -T prometheus wget -qO- 'http://127.0.0.1:9090/api/v1/targets?state=active' 2>/dev/null || true)"
  down="$(jq -r '.data.activeTargets[]? | select(.health != "up") | "\(.labels.job) \(.labels.instance): \(.lastError)"' <<<"${targets}" 2>/dev/null || true)"
  total="$(jq -r '.data.activeTargets | length' <<<"${targets}" 2>/dev/null || echo 0)"
  if [[ -z "${targets}" ]]; then
    flag_warn "could not read the Prometheus targets"
  elif [[ -n "${down}" ]]; then
    while IFS= read -r line; do
      flag_fail "scrape target down: ${line}"
    done <<<"${down}"
  else
    ok "prometheus: all ${total} scrape targets up"
  fi
  if grep -q 'type: telegram' monitoring/grafana/provisioning/alerting/notifications.yml 2>/dev/null; then
    ok "alerts are sent to Telegram"
  else
    flag_warn "alerts are NOT sent anywhere (ALERT_TELEGRAM_BOT_TOKEN / ALERT_TELEGRAM_CHAT_ID empty) — they only show in Grafana → Alerting"
  fi
  if [[ "$(service_health grafana)" == "healthy" ]]; then
    auth="$(printf '%s:%s' "$(env_get GRAFANA_ADMIN_USER)" "$(env_get GRAFANA_ADMIN_PASSWORD)" | base64 | tr -d '\n')"
    alerts="$(compose exec -T grafana wget -qO- --header "Authorization: Basic ${auth}" \
      'http://127.0.0.1:3000/grafana/api/prometheus/grafana/api/v1/alerts' 2>/dev/null || true)"
    firing="$(jq -r '.data.alerts[]? | select(.state == "Alerting" or .state == "firing") | .labels.alertname' <<<"${alerts}" 2>/dev/null | sort -u || true)"
    if [[ -z "${alerts}" ]]; then
      flag_warn "could not read Grafana's alerts (GRAFANA_ADMIN_PASSWORD changed after Grafana's first start?)"
    elif [[ -n "${firing}" ]]; then
      flag_warn "alerts firing now: $(tr '\n' ' ' <<<"${firing}")— Grafana → Alerting → Alert rules"
    else
      ok "grafana: no alert firing"
    fi
  else
    flag_fail "grafana is $(service_health grafana) — make logs SERVICE=grafana"
  fi
fi

# ---------------------------------------------------------------------------------------------------------------------
log ""
if (( fails > 0 )); then
  die "doctor: ${fails} problem(s), ${warns} warning(s) — fix the [FAIL] lines first"
fi
ok "doctor: no problems found (${warns} warning(s))"
