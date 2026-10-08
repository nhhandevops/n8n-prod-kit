# warning_bug_and_solutions.md — n8n Production Kit

Format per entry: symptom → root cause → how to verify → fix → date.

## 2026-10-07 · hadolint install script failed: "release assets not found"

- **Symptom:** `install-devtools.sh` aborted at the hadolint step after apt + gh had already installed.
- **Root cause:** the script expected a per-asset `hadolint-Linux-x86_64.sha256` file. Since v2.15.x the release ships one `checksums.sha256` and lowercase asset names (`hadolint-linux-x86_64`).
- **Verify:** `curl -fsSL https://api.github.com/repos/hadolint/hadolint/releases/latest | jq -r '.assets[].name'`.
- **Fix:** download `checksums.sha256`, take the line whose last field is `hadolint-linux-x86_64`, compare with `sha256sum`. Same pattern belongs in `scripts/bootstrap-host.sh` / CI when hadolint is pinned there: pin the version + sha256 in the script instead of resolving "latest" at run time.

## 2026-10-07 · VMware: VM shows as powered off but a `.vmem.lck` lock directory exists

- **Symptom:** `vmrun list` → 0 running VMs, yet `<vm-folder>\server1-<id>.vmem.lck\` is present (dated weeks earlier).
- **Root cause:** stale lock from an unclean host shutdown; only `vmware-tray.exe` was running.
- **Verify:** `Get-Process vmware, vmware-vmx` → none; lock directory timestamp old.
- **Fix:** nothing to delete — VMware clears it on next power-on (choose "Take Ownership" if prompted). Edit `.vmx` only while no `vmware-vmx.exe` runs; keep a backup copy of the `.vmx` first.

## 2026-10-07 · Build plan drafted for the wrong machine

- **Symptom:** build plan §2/§6 assumed an MSI desktop with WSL2 (a different Windows user, 32 GB, a different project folder); the machine in use is a laptop (16 GB, Windows 10, no WSL distro) whose only Linux is the VMware VM `server1` (Ubuntu 26.04).
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

## 2026-10-07 · Remote script dies silently right after `make up` / `docker compose up`

- **Symptom:** a script sent to the VM as `ssh host 'bash -s' <<'EOF' … EOF` prints nothing after the `compose up` step; later commands never run, no error.
- **Root cause:** `bash -s` reads the script from stdin and `docker compose up` (and `make up`) also read stdin — they swallow the rest of the script.
- **Fix:** copy the script to a file first (`ssh host 'cat > /tmp/x.sh' <<'EOF' … EOF; ssh host 'bash /tmp/x.sh </dev/null'`), or redirect stdin of such commands from /dev/null.

## 2026-10-07 · shellcheck SC2016 on a `printf '…`cmd`…'` line

- **Symptom:** `make lint` fails with SC2016 "Expressions don't expand in single quotes" on a comment-generating printf.
- **Root cause:** backticks inside a single-quoted string look like a command substitution to shellcheck's heuristic.
- **Fix:** drop the backticks in generated comments (or use double quotes with escaping when expansion is wanted).

## 2026-10-07 · Every test container has "No route to host" / cannot resolve DNS on the build VM

- **Symptom:** the bootstrap container matrix failed 6/6 within a minute: `curl: (6) Could not resolve host: download.docker.com`, apt "Unable to locate package"; meanwhile the kit's own containers (user-defined networks) had full egress.
- **Root cause:** the default bridge `docker0` on the long-lived VM was link-DOWN with no IPv4 address (only fe80::), so containers on the default network had no gateway. User-defined bridges (`n8nkit_proxy`, compose networks) were unaffected.
- **Verify:** `ip -4 -br addr show docker0` (empty = broken); `docker run --rm ubuntu:24.04 bash -c "</dev/tcp/1.1.1.1/443"` → "No route to host".
- **Fix:** `sudo ip addr add 172.17.0.1/16 dev docker0 && sudo ip link set docker0 up` (no daemon restart, other projects untouched); the test harness now creates its own network (`--network <prefix>-net`) so it never depends on docker0.

## 2026-10-08 · SECURITY: n8n's Prometheus metrics were public at https://DOMAIN/metrics

- **Symptom:** `curl https://<domain>/metrics` answered HTTP 200 with ~180 `n8n_*` series (workflow counts, queue depth, process info) to anyone on the Internet.
- **Root cause:** `N8N_METRICS=true` makes n8n-main serve `/metrics`; Caddy's catch-all `handle` proxies every path not matched earlier to n8n-main, so the endpoint was published.
- **Verify:** `curl -s -o /dev/null -w '%{http_code}' https://<domain>/metrics` → must be 404.
- **Fix:** `handle /metrics* { respond 404 }` in the Caddyfile before the catch-all; Prometheus (S6) scrapes over the internal network. Smoke 06 asserts the 404 on every run. Shipped in 9f88b4c.

## 2026-10-08 · Smoke: login fails with HTTP 429 after a few runs

- **Symptom:** `make smoke` twice in a row → 03 fails at "API key available"; `POST /rest/login` answers 429 `Retry-After: 17`.
- **Root cause:** n8n rate-limits `/rest/login` to **5 attempts per window per client IP** (`x-ratelimit-limit: 5`); not configurable by env. Each run logged in several times.
- **Fix:** the suite reuses a valid session cookie (`GET /rest/login` with the cookie) and the saved API key, makes exactly two login attempts per run (one wrong, one right), and waits out a 429 using `Retry-After`.

## 2026-10-08 · Smoke: random "no worker log mentions execution N"

- **Symptom:** 05 sometimes reports that no worker logged the execution, although the line is in the logs.
- **Root cause:** `compose logs … | grep -q …` under `set -o pipefail`: grep exits on the first match, `docker compose logs` gets SIGPIPE, and pipefail reports the pipeline as failed.
- **Fix:** capture the output first (`logs="$(compose logs …)"`), then `grep -q … <<<"${logs}"`. Rule for the suite: never pipe into an early-exiting reader (`grep -q`, `head`, `awk … exit`) under pipefail.

## 2026-10-08 · Smoke: queue counter "did not increase" on fast runs

- **Symptom:** `n8n_scaling_mode_queue_jobs_completed` unchanged right after the executions finished.
- **Root cause:** main refreshes its queue gauges every `N8N_METRICS_QUEUE_METRICS_INTERVAL` seconds (20 in the kit).
- **Fix:** the check waits up to 45 s for the next refresh.

## 2026-10-08 · n8n 2.x API facts the smoke suite relies on

- Deleting a workflow via the public API: `POST /api/v1/workflows/{id}/deactivate` first (DELETE on an active one → 409; retry once more if it still answers 409 right after deactivation).
- Repeating owner setup → 400 "Instance owner already setup"; `/rest/settings` → `data.userManagement.showSetupOnFirstLoad` tells whether an owner exists.
- API key labels must be unique per user (duplicate → 500 "There is already an entry with this name"); the suite replaces its own `kit-smoke` key.
- Code nodes run in the runner sandbox **without network and without `fetch`** ("fetch is not defined"); `this.helpers.httpRequest(...)` works because the worker executes it (worker has egress + the dev CA). Document for template authors.
- Worker log line per job: `Worker finished execution <id> (job <n>)` (JSON, level info).

## 2026-10-08 · Postgres "invalid input syntax for type integer: NaN" (upstream, harmless)

- **Symptom:** 2 errors per smoke run in the Postgres log, statement `SELECT DISTINCT "distinctAlias"."ExecutionEntity_id" … FROM (SELECT "ExecutionEntity"…`.
- **What it is NOT:** none of the public API calls (`/api/v1/executions` with/without `workflowId`, `limit`, `status`; `/api/v1/workflows/{id}`) trigger it, with or without existing executions (bisected on the VM).
- **What it is:** an n8n-internal paginated executions query issued around webhook-triggered executions; n8n handles the error (executions succeed, nothing logged on the n8n side).
- **Action:** smoke 04 counts new occurrences and warns; report upstream with the statement when convenient.

## 2026-10-08 · n8n-main crashes after every container RESTART: EACCES mkdir /home/node/.cache/n8n

- **Symptom:** after `docker compose restart`, a host reboot or `make restore` (stop + start), n8n-main loops: `EACCES: permission denied, mkdir '/home/node/.cache/n8n'`; webhooks and workers never start (they wait for main). Fresh `make up` was always fine — so S2–S4 tests never saw it.
- **Root cause:** Docker mounts a tmpfs on a directory that does NOT exist in the image as root:root **1777 on the first start but 0755 after a restart** (verified on Docker 29.5 with alpine and the n8n image). `/tmp` is unaffected (exists in the image). The S3 read-only change put `~/.cache` and `~/.npm` on such tmpfs mounts.
- **Verify:** `docker run -d --name t --read-only --tmpfs /data alpine sleep 600; docker exec t stat -c %a /data; docker restart t; docker exec t stat -c %a /data` → 1777 then 755.
- **Fix:** explicit options `- /home/node/.cache:uid=1000,gid=1000,mode=0700` (same for `.npm`, also in render.sh's template). Regression check: a full `docker compose restart` is now part of the S5 verification. Shipped in f4980b4.

## 2026-10-08 · Docker build fails: rclone "Invalid value when setting --version from environment variable RCLONE_VERSION"

- **Symptom:** the backup image build dies right after all sha256 checks passed.
- **Root cause:** rclone maps EVERY `RCLONE_<FLAG>` environment variable to a flag. The Dockerfile build arg `RCLONE_VERSION=v1.75.1` is visible as an environment variable to `RUN`, so `rclone version` saw `--version=v1.75.1`.
- **Fix:** download build args are named `PKG_*` (`PKG_RCLONE_VERSION`, …). Never name any variable `RCLONE_<something>` unless it is meant as an rclone flag/config.

## 2026-10-08 · Backup container cannot write /state ("mkdir /state/metrics.d: Permission denied")

- **Root cause:** a named volume mounted on a path that does not exist in the image is created root-owned; the backup container runs as uid 70.
- **Fix:** the image creates `/state` and `/work` owned by 70 (Docker copies that into NEW volumes); `scripts/backup-perms.sh` chowns volumes that already exist. Note: a chown through `compose run` fails — the service has `cap_drop: [ALL]`, and root without CAP_CHOWN cannot chown; the fix uses a plain `docker run` one-shot.

## 2026-10-08 · Backup container (uid 70) cannot read secrets/age-key.txt (0600, owned by the operator)

- **Fix:** `scripts/backup-perms.sh` (run by `make up`, backup-now, restore, restore-test) sets the key to `70:<operator group> 0440` and `backups/` to `70:<operator group> 2775` through a root one-shot of the backup image — no sudo, and the operator can still read the key and manage the files. `init.sh` therefore only chmods files the caller owns, and derives public keys via the group read.

## 2026-10-08 · Docker build: `| head` under pipefail fails the RUN

- Same SIGPIPE trap as the smoke suite (S4): `rclone version | head -1` in a `SHELL ["/bin/ash","-eo","pipefail","-c"]` RUN → rclone exits 141 → build fails. Use `| sed -n 1p` (reads everything).

## 2026-10-08 · CI: `make up` fails with "toomanyrequests: Rate exceeded" from public.ecr.aws

- **Symptom:** the smoke job fails in "Bring the stack up" while pulling; a docs-only commit turned CI red.
- **Root cause:** the AWS public registry throttles anonymous bursts; `compose pull` fetches every image in parallel. (Docker Hub has its own 100 pulls/h limit, which is why CI uses the mirrors.)
- **Fix:** `make up` / `make pull` retry the pull (and the backup image build) three times with 20 s / 40 s pauses (`with_retry` in compose/Makefile); `make pull` also skips the locally built backup image (`--ignore-buildable`).

## 2026-10-08 · Adversarial review of the S5 backup/restore code (3 agents) — 28 findings, all fixed the same day

Three independent reviewers (restore/DR data loss · backup truthfulness · security) attacked commit c0e8c1d; most
findings were reproduced on the VM with throw-away containers. Each entry below: symptom → root cause → verify → fix.
Regression test for the worst ones: `tests/ci/dr-drill.sh` (CI runs it on every change).

### Disaster recovery left n8n unable to start ("Mismatching encryption keys")
- **Symptom:** the documented new-host restore (`make init` → `make up` → `make restore … ADOPT_KEY=1`) ended with n8n-main crash-looping; the S5 "verified" DR test had not followed that order.
- **Root cause:** n8n caches its key in `/home/node/.n8n/config` (volume n8n_data) on first start and refuses an `N8N_ENCRYPTION_KEY` that differs from it.
- **Verify:** start n8n with key A on a volume, restart with key B → `Error: Mismatching encryption keys`.
- **Fix:** `make restore` deletes that file after every successful swap (n8n re-creates it from .env). dr-drill.sh proves the whole procedure.

### pg_restore failure after the DROP left an EMPTY live database
- **Root cause:** DROP and CREATE ran in autocommit; only pg_restore was transactional, and the docs claimed "one transaction".
- **Fix:** restore into a staging DB `n8n_restore`, verify its counts, swap atomically (`ALTER DATABASE … RENAME` twice inside one transaction — verified to work in PG 18), keep the replaced DB as `n8n_prev` until the stack is healthy. A corrupt dump now leaves the live DB untouched and n8n is restarted (verified with a planted truncated dump).

### `latest` could be chosen by anyone who can write to a target, by a clock jump, or be the pre-restore safety copy
- **Root cause:** `latest` = newest basename of any `n8n-*.tar.age`; names were never validated or bound to the content; pre-restore copies counted; an unlistable remote was silently skipped.
- **Fix:** strict name/layout regex; `latest` skips `pre-restore/` and names > 1 day in the future; the manifest must name the file it came from (a renamed old bundle is refused); `latest` refuses when any remote cannot be listed (use `FROM=`).

### The weekly restore test ran an untrusted bundle's SQL as superuser before any authenticity check
- **Root cause:** age gives confidentiality, not origin — anyone with write access to a target can encrypt to the PUBLIC keys; the key check came after `pg_restore -U postgres`.
- **Fix:** key match (+ 2 recipients) checked first; pg_restore runs as a NOSUPERUSER role (verified: `COPY … PROGRAM` denied; n8n's `uuid-ossp` is a trusted extension, so the restore still works). ADOPT_KEY now shows key hints and asks for a human comparison.

### Backup failures before the upload loop were silent
- **Symptom:** pg_dump error, full tmpfs, OOM, malformed recovery key, retention typo → exit, no Telegram, metrics still "status 1".
- **Fix:** EXIT handler in backup.sh: any failure sets `backup_last_status 0` for every remote (previous success timestamps kept) and alerts with the failed stage. Doctor FAILs on a failed last attempt and on a remote that never succeeded.

### Retention: `0` deleted the backup just written, `30d` silently disabled pruning, a forward clock jump could empty every remote
- **Fix:** whole numbers ≥ 1 required (backup.sh and preflight); pruning by the UTC name, never the bundle just written, never below `BACKUP_RETENTION_MIN_KEEP` (7) newest; errors reported instead of `2>/dev/null || true`. Monthly copies are self-healing (first daily of each UTC month).

### Other fixes from the review
- `BACKUP_REMOTES` typo without a colon (`r2/bucket`) wrote into the container tmpfs → validated in backup.sh, preflight.
- Recovery key: an empty `BACKUP_AGE_RECOVERY_PUBLIC_KEY` produced host-key-only bundles silently → refused (`BACKUP_ALLOW_SINGLE_RECIPIENT=true` overrides); restore test asserts 2 recipients; doctor checks the on-host recovery file matches .env; `make detach-recovery-key` is always interactive and makes you paste the key back before shredding.
- Defaults MEM_LIMIT_BACKUP 1g < BACKUP_TMPFS_SIZE 2g (tmpfs counts against the cgroup → OOM) → 1536m / 1g, preflight enforces mem ≥ tmpfs + 256m, doctor warns when bundles outgrow the tmpfs.
- Counts in the manifest were taken outside pg_dump's snapshot → counted in the dump itself (`pg_restore --data-only --table`).
- The safety backup ran while n8n was still writing → n8n is stopped first. The key check happens before the safety backup and the stop.
- Plaintext dump + key stayed in the backup_work volume after an aborted/failed restore → EXIT trap empties it on every exit; `make restore-clean`.
- Lock on each container's own /tmp → `/state/backup.lock`, shared by cron and every `compose run`; host-side flock for `make restore`.
- Restore test only ever looked at one remote → it verifies every remote's newest bundle and fails when it is older than 26 h.
- N8N_ENCRYPTION_KEY on the openssl command line and the Telegram token on curl's (both readable by every host user in /proc) → `-pass env:`, `curl -K -`.
- backup-perms.sh chowned whatever BACKUP_LOCAL_PATH named, as root (`$HOME`, `/`) → refused unless empty or kit-only and outside system dirs/$HOME.
- ADOPT_KEY wrote an unvalidated key into .env; env_set could store a backtick inside double quotes → key format check; env_set refuses `'` + backtick.
- `.env.bak.*` not git-ignored → `compose/.env.*`. Community packages were lost on a new host → `N8N_REINSTALL_MISSING_PACKAGES=true`; the n8n_files volume is documented as not covered.
- Open (HANDOFF §5): n8n connects as the Postgres bootstrap superuser, so live restores run as superuser (safe only after the key check); n8n_files not backed up.

## 2026-10-08 · BusyBox flock has no `-w`: "flock: unrecognized option: w"

- **Symptom:** every backup failed in seconds with "another backup … is still running after 15 min".
- **Root cause:** the backup image (Postgres alpine) ships BusyBox `flock` (`-s -x -u -n` only); `flock -w 900` is a usage error, which the code read as "lock busy". The OPS-004 rule "check the real tool before writing code" was skipped for this one flag.
- **Verify:** `docker run --rm --entrypoint flock n8nkit/backup:local -w 1 9` → usage text.
- **Fix:** poll `flock -n` every 5 s up to the timeout (lib.sh `take_lock`). Every other tool flag the new code uses was then checked in the image in one pass.

## 2026-10-08 · bash regex `{16,256}` is invalid: the genuine key was "unexpected format"

- **Symptom:** the DR drill's `ADOPT_KEY=1` restore refused the real 64-char key.
- **Root cause:** POSIX regex repetition counts are capped at RE_DUP_MAX = 255; `[[ x =~ ^…{16,256}$ ]]` is a compile error, and `[[ ]]` returns 2 (false) without stopping a script.
- **Verify:** `[[ abc =~ ^a{1,256}$ ]]` → `invalid repetition count(s)`.
- **Fix:** `{16,255}`. Found only because the drill runs the real procedure — exactly why it is in CI now.

## 2026-10-08 · S6 monitoring: five facts that only a real start showed (CI, 6 rounds while the VM was offline)

### Grafana does not expand environment variables in alert RULE files
- **Symptom:** alert annotations with `{{ $$values.A }}` failed to parse ("error parsing template"); a smoke check showed `${KIT_PROJECT}` stayed literal inside a rule's PromQL.
- **Root cause:** Grafana's file provisioning expands `$VAR` in data sources, dashboards providers and contact points, but not in alert rule groups (neither queries nor annotations), and it does not turn `$$` into `$` there.
- **Verify:** `GET /api/v1/provisioning/alert-rules` returns the expression exactly as written.
- **Fix:** rules use no environment at all (plain `$values` / `$labels` in templates; ContainerRestarting alerts per Compose project instead of filtering on the project name). The Telegram contact point DOES expand `$ALERT_TELEGRAM_BOT_TOKEN` — smoke 09 proves it through the decrypted export (`/api/v1/provisioning/contact-points/export?decrypt=true`).

### The Loki image has no shell tools
- **Symptom:** `dependency failed to start: container n8nkit-loki-1 is unhealthy`, Loki itself running fine.
- **Root cause:** the healthcheck `wget … /ready` cannot run — the image ships no wget/curl.
- **Fix:** no container healthcheck for Loki (Prometheus scrapes it; MonitoringTargetDown alerts); Alloy depends on `service_started`.

### Alloy as root with cap_drop ALL cannot enter the image's own directories
- **Symptom:** Alloy restart loop: `mkdir /var/lib/alloy/data: permission denied` — first as the image user (cannot read the Docker socket either), then even as root.
- **Root cause:** `/var/lib/alloy` and `/etc/alloy` belong to the image user `alloy`; root without CAP_DAC_OVERRIDE (cap_drop ALL) is checked like any other user.
- **Fix:** `user: "0:0"` (socket) and data/config at root-owned paths (`/alloy-data`, `/config.alloy`) instead of re-adding capabilities.

### `make doctor` right after `make up` saw a stale scrape error
- **Symptom:** "scrape target down: n8n-worker-1:5678 … connection refused" although the workers were healthy (the worker server binds `::`, verified in n8n's source).
- **Root cause:** Prometheus starts first; its last scrape (15 s interval) predated the workers' start.
- **Fix:** doctor re-reads the targets once after 20 s before reporting.

### Windows git: new scripts committed without the executable bit; empty dirs vanish in `git stash -u`
- **Symptom:** CI step `tests/ci/dr-drill.sh: Permission denied`; a freshly created empty `dashboards/` directory was gone after a stash round trip.
- **Fix:** `git update-index --chmod=+x <file>` for every new script committed from Windows (check with `git ls-files -s`); create directories right before writing into them. Also: in this Bash tool `\\` inside heredocs collapses to `\` — patch scripts are written as files (memory note).
