#!/usr/bin/env bash
# compose/scripts/preflight.sh — "will `make up` work on this host?" (contract §7, test case TC-002).
#
# One line per check, in the lib.sh formats:  [ OK ] / [warn] / [FAIL] <what> — <how to fix>
# WARN never blocks; the script exits 1 when at least one FAIL was printed. Every check is read-only.
# Checks: docker/compose versions · .env present, 0600, required keys · image digests pinned · HTTP/HTTPS ports free
# (naming the process that holds them) · disk ≥ 10 GB on the Docker root · RAM ≥ 3.5 GB · ≥ 2 CPUs · clock synchronised ·
# vm.overcommit_memory (Valkey) · DNS of DOMAIN (internal: resolves; acme*: must equal this host's public IP) · kuma.DOMAIN
# when KUMA_ENABLED=on.
# Optional shellcheck checks that fight the "function in an if/pipeline" style this script is built on
# (a file-wide directive must precede the first command):
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

failures=0
flag_fail() {
  fail "${*}"
  failures=$((failures + 1))
}

# version_ge A B — true when dotted version A >= B (sort -V does the comparison).
version_ge() {
  [[ "$(printf '%s\n%s\n' "${2}" "${1}" | sort -V | head -1)" == "${2}" ]]
}

# --- docker & compose -----------------------------------------------------------------------------------------------
need_cmd docker ss df awk grep
docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
if [[ -z "${docker_version}" ]]; then
  flag_fail "docker daemon not reachable — is Docker running and is $(id -un) in the docker group? (log out/in after usermod)"
elif version_ge "${docker_version}" 27.0; then
  ok "docker ${docker_version} (>= 27)"
else
  flag_fail "docker ${docker_version} is older than 27 — run scripts/bootstrap-host.sh or upgrade docker-ce"
fi
compose_version="$(docker compose version --short 2>/dev/null | sed 's/^v//' || true)"
if [[ -z "${compose_version}" ]]; then
  flag_fail "docker compose plugin missing — install docker-compose-plugin (scripts/bootstrap-host.sh)"
elif version_ge "${compose_version}" 2.30; then
  ok "docker compose ${compose_version} (>= 2.30)"
else
  flag_fail "docker compose ${compose_version} is older than 2.30 — upgrade docker-compose-plugin"
fi

# --- .env ------------------------------------------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  flag_fail ".env missing — run: make init DOMAIN=<your-domain>"
  die "preflight: ${failures} problem(s)"
fi
env_mode="$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env)"
if [[ "${env_mode}" == "600" ]]; then
  ok ".env mode 600"
else
  flag_fail ".env mode is ${env_mode} — chmod 600 .env (it holds the encryption key)"
fi
for key in DOMAIN TLS_MODE ACME_EMAIL PUBLIC_URL N8N_ENCRYPTION_KEY POSTGRES_PASSWORD VALKEY_PASSWORD N8N_RUNNERS_AUTH_TOKEN; do
  if [[ -n "$(env_get "${key}")" ]]; then
    ok "${key} set"
  else
    flag_fail "${key} is empty in .env — re-run make init (FORCE=1 overwrites) or set it by hand"
  fi
done
domain="$(env_get DOMAIN)"
tls_mode="$(env_get TLS_MODE)"
http_port="$(env_get HTTP_PORT)"
https_port="$(env_get HTTPS_PORT)"
http_port="${http_port:-80}"
https_port="${https_port:-443}"
case "${tls_mode}" in
  acme | acme-staging | internal) ok "TLS_MODE=${tls_mode}" ;;
  *) flag_fail "TLS_MODE='${tls_mode}' is not one of acme | acme-staging | internal" ;;
esac
if [[ "${http_port}" == "${https_port}" ]]; then
  flag_fail "HTTP_PORT and HTTPS_PORT are both ${http_port} — they must differ"
fi

# --- image pins ------------------------------------------------------------------------------------------------------
if "${KIT_DIR}/scripts/pin.sh" --check >/dev/null 2>&1; then
  ok "image digests pinned in versions.env"
else
  flag_fail "versions.env has unpinned images — run: make pin"
fi

# --- backups ---------------------------------------------------------------------------------------------------------
# The backup service bind-mounts secrets/age-key.txt: if the file is missing Docker would create a DIRECTORY there.
if [[ -d secrets/age-key.txt ]]; then
  flag_fail "secrets/age-key.txt is a directory (Docker created it when the key was missing) — remove it and re-run make init FORCE=1"
elif [[ ! -s secrets/age-key.txt ]]; then
  flag_fail "secrets/age-key.txt is missing — the backup service cannot start; run make init (it generates the age keys)"
else
  ok "age backup key present"
fi
if [[ -z "$(env_get BACKUP_AGE_PUBLIC_KEY)" ]]; then
  flag_fail "BACKUP_AGE_PUBLIC_KEY is empty in .env — re-run make init FORCE=1 (keeps the existing age keys)"
fi
if [[ -z "$(env_get BACKUP_AGE_RECOVERY_PUBLIC_KEY)" && "$(env_get BACKUP_ALLOW_SINGLE_RECIPIENT)" != "true" ]]; then
  flag_fail "BACKUP_AGE_RECOVERY_PUBLIC_KEY is empty — backups would only open with this host's key, which is lost with the host; put the recovery public key back (age-keygen -y <recovery key file>) or set BACKUP_ALLOW_SINGLE_RECIPIENT=true"
fi
backup_remotes="$(env_get BACKUP_REMOTES)"
for remote in ${backup_remotes}; do
  remote="${remote%/}"
  if [[ "${remote}" == *..* ]] || ! [[ "${remote}" =~ ^/backups/(local|external)(/[A-Za-z0-9._-]+)*$ || "${remote}" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9._/-]*$ ]]; then
    flag_fail "BACKUP_REMOTES entry '${remote}' is not /backups/local, /backups/external[/dir] or an rclone remote 'name:bucket/path' — anything else is written inside the container and lost on restart"
  fi
done
for setting in BACKUP_RETENTION_DAILY_DAYS BACKUP_RETENTION_MONTHLY_DAYS BACKUP_RETENTION_MIN_KEEP; do
  value="$(env_get "${setting}")"
  if [[ -n "${value}" && ! "${value}" =~ ^[1-9][0-9]{0,4}$ ]]; then
    flag_fail "${setting}='${value}' must be a whole number >= 1 — 0 would delete every bundle, '30d' would keep all"
  fi
done
tmpfs_mb="$(size_mb "$(env_get BACKUP_TMPFS_SIZE)")"
mem_mb="$(size_mb "$(env_get MEM_LIMIT_BACKUP)")"
tmpfs_mb="${tmpfs_mb:-1024}"
mem_mb="${mem_mb:-1536}"
if (( mem_mb < tmpfs_mb + 256 )); then
  flag_fail "MEM_LIMIT_BACKUP (${mem_mb} MiB) must be at least BACKUP_TMPFS_SIZE (${tmpfs_mb} MiB) + 256 MiB — the tmpfs counts against the memory limit and a growing dump would be OOM-killed"
fi
backup_local_path="$(env_get BACKUP_LOCAL_PATH)"
if [[ -n "${backup_local_path}" ]]; then
  problem="$(backup_path_problem "${backup_local_path}")"
  if [[ -n "${problem}" ]]; then
    flag_fail "BACKUP_LOCAL_PATH=${backup_local_path} ${problem}"
  elif command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "${backup_local_path}" && ! mountpoint -q "$(dirname "${backup_local_path}")"; then
    warn "BACKUP_LOCAL_PATH=${backup_local_path} is not on a mount of its own — if the external disk is not mounted, /backups/external lands on the root disk"
  else
    ok "BACKUP_LOCAL_PATH=${backup_local_path} usable"
  fi
elif [[ " ${backup_remotes} " == *" /backups/external"* ]]; then
  warn "BACKUP_REMOTES lists /backups/external but BACKUP_LOCAL_PATH is empty — it is the same directory as /backups/local, not a second copy"
fi
if [[ "$(env_get BACKUP_ENABLED)" != "false" && -z "${backup_remotes}" ]]; then
  warn "BACKUP_REMOTES is empty — nothing will be backed up; set an off-host target (e.g. r2:n8n-backups/prod) before going live"
fi

# --- monitoring profile -------------------------------------------------------------------------------------------
profiles=",$(env_get COMPOSE_PROFILES | tr -d ' '),"
monitoring_on=0
if [[ "${profiles}" == *",monitoring,"* ]]; then
  monitoring_on=1
fi
kuma_profile=0
if [[ "${profiles}" == *",kuma,"* ]]; then
  kuma_profile=1
fi
kuma_enabled="$(env_get KUMA_ENABLED)"
if (( kuma_profile )) && [[ "${kuma_enabled}" != "on" ]]; then
  flag_fail "COMPOSE_PROFILES has 'kuma' but KUMA_ENABLED is '${kuma_enabled:-off}' — Caddy would not publish it; set KUMA_ENABLED=on (or drop the profile)"
elif (( ! kuma_profile )) && [[ "${kuma_enabled}" == "on" ]]; then
  flag_fail "KUMA_ENABLED=on but COMPOSE_PROFILES has no 'kuma' — kuma.DOMAIN would answer 502; set COMPOSE_PROFILES=monitoring,kuma (or KUMA_ENABLED=off)"
fi
if (( monitoring_on )); then
  if [[ -z "$(env_get GRAFANA_ADMIN_PASSWORD)" ]]; then
    flag_fail "GRAFANA_ADMIN_PASSWORD is empty — set one (make init generates it) before enabling the monitoring profile"
  else
    ok "monitoring profile: Grafana at $(env_get PUBLIC_URL)grafana/"
  fi
  if [[ -z "$(env_get ALERT_TELEGRAM_BOT_TOKEN)" || -z "$(env_get ALERT_TELEGRAM_CHAT_ID)" ]]; then
    warn "ALERT_TELEGRAM_BOT_TOKEN / ALERT_TELEGRAM_CHAT_ID are not set — alerts are only shown in Grafana, nobody is notified"
  fi
fi

# --- ports -----------------------------------------------------------------------------------------------------------
# A port held by THIS stack's caddy (make up on a running stack) is fine; anything else must be named.
project="$(_kit_project_name)"
own_ports="$(docker ps --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=caddy" \
  --format '{{.Ports}}' 2>/dev/null || true)"
for port in "${http_port}" "${https_port}"; do
  listener="$(ss -Hltnp "( sport = :${port} )" 2>/dev/null | head -1 || true)"
  if [[ -z "${listener}" ]]; then
    ok "port ${port} free"
  elif [[ "${own_ports}" == *":${port}->"* ]]; then
    ok "port ${port} held by this stack's caddy (already running)"
  else
    proc="$(printf '%s' "${listener}" | grep -oE 'users:\(\("[^"]+",pid=[0-9]+' | sed -E 's/users:\(\("([^"]+)",pid=([0-9]+)/\1 (pid \2)/' || true)"
    flag_fail "port ${port} is in use by ${proc:-an unknown process} — stop it, or set HTTP_PORT/HTTPS_PORT in .env (make init HTTP_PORT=8080 HTTPS_PORT=8443). On Windows/WSL hosts check 'netstat -ano' on the Windows side too."
  fi
done

# --- resources -------------------------------------------------------------------------------------------------------
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
free_gb="$(df -BG --output=avail "${docker_root}" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)"
if (( free_gb >= 10 )); then
  ok "disk: ${free_gb} GB free under ${docker_root}"
else
  flag_fail "disk: only ${free_gb} GB free under ${docker_root} (need >= 10) — prune images (docker system prune) or add space"
fi
ram_mb="$(awk '/^MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
if (( monitoring_on )) && (( ram_mb < 5000 )); then
  warn "RAM: ${ram_mb} MB — the monitoring profile adds ~1 GB to the core stack; 6 GB+ is comfortable"
fi
if (( ram_mb >= 3500 )); then
  ok "RAM: ${ram_mb} MB"
else
  flag_fail "RAM: ${ram_mb} MB (need >= 3500 for the core stack) — use a bigger host or lower MEM_LIMIT_* and WORKER_CONCURRENCY"
fi
cpus="$(nproc 2>/dev/null || echo 1)"
if (( cpus >= 2 )); then
  ok "CPUs: ${cpus}"
else
  flag_fail "CPUs: ${cpus} (need >= 2)"
fi

# --- clock -----------------------------------------------------------------------------------------------------------
# TLS and Let's Encrypt break on skewed clocks; Bull job locks (60 s) assume sane time across containers.
if command -v timedatectl >/dev/null 2>&1; then
  ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  case "${ntp_sync}" in
    yes) ok "clock synchronised (NTP)" ;;
    no) warn "clock NOT synchronised — enable NTP: timedatectl set-ntp true (VMs: also after host sleep)" ;;
    *) warn "clock sync state unknown (timedatectl unavailable) — make sure NTP is running" ;;
  esac
else
  warn "timedatectl not found — cannot verify clock synchronisation"
fi

# --- kernel knob for Valkey -------------------------------------------------------------------------------------------
overcommit="$(sysctl -n vm.overcommit_memory 2>/dev/null || echo unknown)"
if [[ "${overcommit}" == "1" ]]; then
  ok "vm.overcommit_memory=1"
else
  warn "vm.overcommit_memory=${overcommit} — Valkey warns and may fail AOF rewrites under memory pressure: sudo sysctl -w vm.overcommit_memory=1 (bootstrap-host.sh persists it)"
fi

# --- DNS -------------------------------------------------------------------------------------------------------------
resolve4() {
  getent ahostsv4 "${1}" 2>/dev/null | awk '{print $1; exit}' || true
}
domain_ip="$(resolve4 "${domain}")"
if [[ "${tls_mode}" == "internal" ]]; then
  if [[ -n "${domain_ip}" ]]; then
    ok "DNS: ${domain} -> ${domain_ip} (internal TLS: any address is fine)"
  else
    warn "DNS: ${domain} does not resolve on this host — add it to /etc/hosts (127.0.0.1 ${domain}) so in-workflow calls work"
  fi
else
  public_ip="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${domain_ip}" ]]; then
    flag_fail "DNS: ${domain} does not resolve — create the A/AAAA record pointing at this host before ACME can issue a certificate"
  elif [[ -z "${public_ip}" ]]; then
    warn "DNS: ${domain} -> ${domain_ip}; could not determine this host's public IP (api.ipify.org unreachable) — verify it matches"
  elif [[ "${domain_ip}" == "${public_ip}" ]]; then
    ok "DNS: ${domain} -> ${domain_ip} = this host's public IP"
  else
    flag_fail "DNS: ${domain} -> ${domain_ip} but this host's public IP is ${public_ip} — fix the record (or use TLS_MODE=acme-staging while testing to avoid Let's Encrypt rate limits)"
  fi
  if [[ "$(env_get KUMA_ENABLED)" == "on" ]]; then
    kuma_ip="$(resolve4 "kuma.${domain}")"
    if [[ -n "${kuma_ip}" && ( -z "${public_ip}" || "${kuma_ip}" == "${public_ip}" ) ]]; then
      ok "DNS: kuma.${domain} -> ${kuma_ip}"
    else
      flag_fail "DNS: kuma.${domain} -> '${kuma_ip:-unresolved}' — KUMA_ENABLED=on needs that record on this host too (or set KUMA_ENABLED=off)"
    fi
  fi
fi

# --- verdict ---------------------------------------------------------------------------------------------------------
if (( failures > 0 )); then
  die "preflight: ${failures} problem(s) — fix them and re-run make preflight"
fi
ok "preflight: all checks passed"
