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
  if (( key_age_days > 7 )); then
    flag_warn "secrets/age-recovery-key.txt has been on this host for ${key_age_days} days — copy it to your password manager and remove it here (make detach-recovery-key, from S5); a backup that can be decrypted from the same host it protects is not a recovery plan"
  else
    ok "recovery key on host for ${key_age_days} day(s) (move it off-host within 7 days)"
  fi
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
if [[ "$(env_get BACKUP_ENABLED)" == "true" ]]; then
  info "backup checks (last backup age per remote, last restore test) arrive with the backup sidecar in S5"
else
  flag_warn "BACKUP_ENABLED is not true — nothing protects the database yet (backups arrive in S5; until then: make a manual pg_dump)"
fi

# ---------------------------------------------------------------------------------------------------------------------
log ""
if (( fails > 0 )); then
  die "doctor: ${fails} problem(s), ${warns} warning(s) — fix the [FAIL] lines first"
fi
ok "doctor: no problems found (${warns} warning(s))"
