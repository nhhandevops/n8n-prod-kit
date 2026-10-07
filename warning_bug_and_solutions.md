# warning_bug_and_solutions.md — n8n Production Kit

Format per entry: symptom → root cause → how to verify → fix → date.

## 2026-10-07 · hadolint install script failed: "release assets not found"

- **Symptom:** `install-devtools.sh` aborted at the hadolint step after apt + gh had already installed.
- **Root cause:** the script expected a per-asset `hadolint-Linux-x86_64.sha256` file. Since v2.15.x the release ships one `checksums.sha256` and lowercase asset names (`hadolint-linux-x86_64`).
- **Verify:** `curl -fsSL https://api.github.com/repos/hadolint/hadolint/releases/latest | jq -r '.assets[].name'`.
- **Fix:** download `checksums.sha256`, take the line whose last field is `hadolint-linux-x86_64`, compare with `sha256sum`. Same pattern belongs in `scripts/bootstrap-host.sh` / CI when hadolint is pinned there: pin the version + sha256 in the script instead of resolving "latest" at run time.

## 2026-10-07 · VMware: VM shows as powered off but a `.vmem.lck` lock directory exists

- **Symptom:** `vmrun list` → 0 running VMs, yet `D:\vms\server1\server1-<id>.vmem.lck\` is present (dated weeks earlier).
- **Root cause:** stale lock from an unclean host shutdown; only `vmware-tray.exe` was running.
- **Verify:** `Get-Process vmware, vmware-vmx` → none; lock directory timestamp old.
- **Fix:** nothing to delete — VMware clears it on next power-on (choose "Take Ownership" if prompted). Edit `.vmx` only while no `vmware-vmx.exe` runs; keep a backup copy of the `.vmx` first.

## 2026-10-07 · Build plan drafted for the wrong machine

- **Symptom:** build plan §2/§6 assumed an MSI desktop with WSL2 (user `nguye`, 32 GB, `D:\Hobbies\…`); the machine in use is a laptop (16 GB, Windows 10, no WSL distro) whose only Linux is the VMware VM `server1` (Ubuntu 26.04).
- **Root cause:** the plan was written from a different session/host without re-checking the environment.
- **Verify:** `Get-CimInstance Win32_ComputerSystem`; `wsl -l -v`; `vmrun list`; `%APPDATA%\VMware\inventory.vmls`.
- **Fix:** §2/§5/§6/§17/§18 of the build plan rewritten for the VM (ports 8080/8443, Remote-SSH, Ubuntu 26.04 in the bootstrap/CI matrix); HANDOFF §3/§4/§7 updated. Rule going forward: start every machine-setup session with the read-only host/VM inventory block before editing plans.

## 2026-10-07 · Shared VM: ports 80/443 and disk nearly full

- **Symptom:** `ss -ltnp` on `server1` shows host nginx on :80 and nginx-proxy-manager on :443/:81; root disk 81 % used (15 GB free), `docker system df` → 13 GB build cache with 0 active entries.
- **Root cause:** the VM hosts five other compose projects; months of builds left cache behind.
- **Verify:** `docker system df`; `docker builder du`; `df -h /`.
- **Fix:** `docker builder prune -af` + `docker image prune -af` (→ 32 GB free; running projects untouched); kit runs on `HTTP_PORT=8080 HTTPS_PORT=8443`; `make preflight` must name the PID holding a port (TC-002) — this VM is a natural test for it.

## 2026-10-07 · S2 fact sweep: upstream assumptions that were wrong (verified on the real images; decisions in HANDOFF §3)

Each line: symptom you would have seen → root cause → fix. Verified on n8n 2.42.3/2.42.4, Caddy 2.11.7, Postgres 18.6-alpine, Valkey 9.1.2-alpine, Compose 5.1.

**Caddy**
- `caddy validate` → "Unexpected next token after '{' on same line" → Caddyfile blocks must be multi-line (`{` ends the line, one directive per line, `}` alone); snippets too (`tls { ca … }`, `basic_auth { … }`) → validate in the image before shipping.
- UI allow-list returns 401 instead of 403 for foreign IPs → Caddy orders `basic_auth` before `respond` → wrap `@denied … / respond @denied 403 / basic_auth {…}` in a `route { }` block.
- 401/403/502 responses carry `server: Caddy` and no HSTS → security headers are not applied to Caddy-generated errors → `handle_errors { import security_headers; respond "{err.status_code} {err.status_text}" }`.
- Container exits 255 "exec /usr/bin/caddy: operation not permitted" with `cap_drop: [ALL]` → the binary carries file capability `cap_net_bind_service=ep`; exec fails when it is outside the bounding set, even as root → `cap_add: [NET_BIND_SERVICE]` is mandatory.
- Healthcheck `wget http://localhost:2019/` fails → busybox resolves localhost to ::1, the admin API listens on 127.0.0.1 only → probe `127.0.0.1`.
- `basic_auth` never matches → the bcrypt hash in `.env` was interpolated by Compose (`$F5Ch…` treated as a variable; compose warns "variable is not set") → single-quote the value or double every `$`.
- n8n (uid 1000) cannot read Caddy's `root.crt` through the shared volume → Caddy (root) writes `pki/` as 0700/0600 → run caddy as `user: "1000:1000"` (image dirs /data, /config are 1777); root.crt is then readable by n8n.
- `servers { metrics }` prints a deprecation → global `metrics` option. Caddy tries to install its CA into the container trust store → `skip_install_trust`.
- http→https redirect loses the dev port → Caddy appends a port only when its own `https_port` ≠ 443 → make the container listen on the published numbers (`http_port {$HTTP_PORT}` / `https_port {$HTTPS_PORT}`, ports `8443:8443`).

**Compose / YAML**
- A service with its own `environment:` silently drops the shared env → `<<:` merge is shallow → separate `x-n8n-env` anchor merged *inside* `environment:`.
- Valkey accepts the literal password `$VALKEY_PASSWORD` → exec-form `command: ["valkey-server","--requirepass","$$VALKEY_PASSWORD"]` never expands → shell form `["sh","-c","exec valkey-server --requirepass \"$$VALKEY_PASSWORD\" …"]` (also hides it from `docker inspect`/`ps`).
- Valkey AOF files owned `valkey:ping` → image user is uid 999 / gid **1000**, not 999:999 → `user: "999:1000"`.
- `valkey-cli ping` healthcheck reports healthy with a wrong password → exit 0 on NOAUTH/WRONGPASS → `CMD-SHELL VALKEYCLI_AUTH=$$PW valkey-cli ping | grep -q PONG`.
- Postgres "healthy" ~2 s before it accepts TCP → socket `pg_isready` answers initdb's temporary server → `pg_isready -h 127.0.0.1 -U n8n -d n8n`.
- `compose up --wait` fails on a one-shot that exits 0 → by design → no one-shots in the default profile.
- `make pin` / pulls fail with HTTP 429 on the build VM → Docker Hub anonymous quota (100 pulls/h per IP, shared with the other projects on the VM) → Hub tags-API fallback in `pin.sh`; `ghcr.io/n8n-io/*` and `public.ecr.aws/docker/library/*` mirrors (identical digests); `docker login` in CI.

**n8n 2.x**
- Main shows the editor (HTTP 200) for `/webhook/x` even with `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` → misrouted production paths fall through to the SPA, no 404 → the proxy must route them explicitly; smoke tests must assert `X-Kit-Upstream`.
- Startup warning about `WEBHOOK_URL` → deprecated alias since 2.35 → `N8N_WEBHOOK_URL`.
- Binary data plan (`filesystem` on a shared volume) → docs: filesystem mode is unsupported in queue mode; the queue-mode default is `database` → `N8N_DEFAULT_BINARY_DATA_MODE=database` (S3/Azure need a licence).
- `n8n-main-runners` sidecar would retry forever → with `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` main starts no task broker; webhooks never need one → runners only on workers.
- `N8N_NATIVE_PYTHON_RUNNER` ignored → does not exist; the Python runner is the sidecar's command argument (`javascript python`).
- Dead names: `N8N_RUNNERS_ENABLED`, `QUEUE_WORKER_MAX_STALLED_COUNT`, `N8N_CONFIG_FILES`, `N8N_MFA_ENFORCED` (real: `N8N_MFA_ENFORCED_ENABLED`, only with `N8N_SECURITY_POLICY_MANAGED_BY_ENV=true`).
- Worker has no `/healthz` → only with `QUEUE_HEALTH_CHECK_ACTIVE=true` (`N8N_METRICS` alone gives `/metrics` only).
- Runner container "running" but silent for 60 s, then exits **0** with a wrong token → `restart: unless-stopped` (on-failure never restarts exit 0); the launcher `/healthz` is liveness only.
- `compose down` kills runners with exit 137 → launcher graceful period ≈ 50 s vs Compose default 10 s → `N8N_RUNNERS_LAUNCHER_GRACEFUL_SHUTDOWN_TIMEOUT=10` + `stop_grace_period: 15s`.
- Code tasks die at 60 s on the sidecar → the launcher forces `N8N_RUNNERS_TASK_TIMEOUT=60` → set 300 on the runners container too.
- `sort -u` dropped `DB_TYPE` from the env-name list → en_US.UTF-8 collation treats `DB_TYPE` = `DB_TYPE_` → `LC_ALL=C sort -u`.
- `n8n worker --help` refuses to run → workers require `N8N_ENCRYPTION_KEY` even for --help; main/webhook silently generate one if unset (mismatch risk) → set it on every role.
- Postgres 16 logs "compatibility support only" → ship 17+ (kit: 18).

**Host bootstrap (EL family)**
- `dnf install … curl` aborts the whole transaction on EL9 → `curl-minimal` conflict → never list `curl` on EL9 (`/usr/bin/curl` already exists).
- `dnf config-manager addrepo --from-repofile` → "unrecognized arguments" on EL9 AND EL10 → all EL10 (Rocky/Alma/CentOS Stream/RHEL/Oracle 10.2) still ship dnf 4.20; that syntax is Fedora-only → copy the `.repo` file into `/etc/yum.repos.d/` (no plugin needed).
- `rockylinux:9` library image is Rocky 9.3 from 2023 and `rockylinux:10` does not exist → `rockylinux/rockylinux:9|10` (quay.io mirror).
- `ID_LIKE` misses Oracle/RHEL (only "fedora") → match `ID` or `PLATFORM_ID=platform:el9|el10`; Debian has no `ID_LIKE` at all (`${ID_LIKE:-}` under `set -u`).
- `systemctl is-enabled firewalld` says enabled inside a container → guard with `command -v firewall-cmd && command -v systemctl && systemctl is-active --quiet firewalld`.
- Piped `curl | sudo bash`: `$USER` is root → use `$SUDO_USER` for the docker group; `read -p` eats the script → `/dev/tty`, guarded by `(exec 3</dev/tty) 2>/dev/null`.

## 2026-10-07 · shellcheck file-wide `disable` directive ignored

- **Symptom:** `shellcheck -x` still reports SC2310/SC2312 although `# shellcheck disable=SC2310,SC2311,SC2312` is in the file.
- **Root cause:** a file-wide directive must come BEFORE the first command; placed after `set -euo pipefail` it only covers the next command.
- **Fix:** put the directive between the header comments and `set -euo pipefail` (done in preflight/status/dev-ca/trust-ca/lint).

## 2026-10-07 · Code node fails with "process is not defined" in the runners sidecar

- **Symptom:** a webhook workflow returns 500; the worker logs `ReferenceError: process is not defined` from the Code node.
- **Root cause:** expected — the external task runner sandbox blocks `process`/env access (N8N_BLOCK_ENV_ACCESS_IN_NODE, 2.x default). My smoke test used `process.version`.
- **Fix:** keep test Code nodes to pure JS over `$input`/`$execution`; this is the security feature working, not a kit bug.
