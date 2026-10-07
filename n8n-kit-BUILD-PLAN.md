# n8n Production Kit — Build Plan

> **How to read this file (added 2026-10-07).** This is the session-by-session build plan written before S0. Sessions S0–S3 are done (see `n8n-kit-HANDOFF.md`). Where §8–§11 (service table, env anchor, Caddyfile, `.env.example`) differ from the code in `compose/`, **the code and HANDOFF §3 (decisions of 2026-10-07) win** — those sections were corrected after a verification sweep against the real images (list in `warning_bug_and_solutions.md`). §6 describes one specific dev machine (a shared VM); HANDOFF §4 has the generic resume steps for any machine. Sessions S4–S10 (§15) are the work still ahead.

Oct 6, 2026 · @An

## 1. At a glance

This plan turns the planning-only bundle at the planning bundle (outside the repo) into a running Compose kit on the laptop's Ubuntu VM `server1` first, then adds batteries, AWS Terraform, a Helm chart, and a public launch. Repo-to-be: `github.com/nhhandevops/n8n-prod-kit` (public, MIT).

**What the kit is:** self-hosted n8n in queue mode (main + webhook processors + workers, Postgres, queue, Caddy TLS, encrypted off-host backups, monitoring, safe upgrades), shipped as Docker Compose for a VPS (Target A), Terraform for AWS (Target B), and, new in this plan, a Helm chart (Target C), plus Vietnamese-business workflow templates.

**Milestones** (T = the day Session 1 starts):

1. **M0** Compose kit — T + 2 weeks (planned; ≈ 35 h of evenings plus 3 outside testers makes T + 3–4 weeks more realistic — HANDOFF §7)
2. **M1** Batteries (backups, monitoring, runbooks, 5 templates) — T + 5 weeks
3. **M2** Terraform AWS — T + 8 weeks
4. **M2.5** Helm chart (new) — T + 10 weeks
5. **M3** Public launch — T + 3 months
6. **M4** Business (setups + retainers) — T + 6 months

**Effort:** M0 plus the first M1 slice ≈ 35 h over 2–3 weeks of evenings; templates ≈ 10 h; M2 ≈ 20 h; M2.5 ≈ 15 h; M3 ≈ 10 h.

## 2. What changed since PLAN.md was written

Three upstream facts changed (verified 2026-10-06 against docs.n8n.io, GitHub and the n8n router source), and the build machine starts from zero.

### n8n is on 2.x (stable 2.42.3; 2.43.0 is a pre-release from today)

2.0 was a hardening release:

- Postgres is required.
- Task runners run in **external mode** via a separate `n8nio/runners` sidecar, same version as n8n; main and every worker need one.
- Code-node env access is blocked; ExecuteCommand and LocalFileTrigger are disabled.
- In-memory binary mode is removed.
- The image is non-root (`node`, uid 1000, Node 26 alpine, busybox `wget`, no `curl`).
- Save vs Publish workflow model.
- `QUEUE_WORKER_MAX_STALLED_COUNT` removed.
- Supported Postgres: 16 / 17 / 18.
- Routing: the **webhook** process serves `/webhook/*`, `/webhook-waiting/*`, `/form/*`, `/form-waiting/*`, `/mcp/*`; **main** serves `/webhook-test/*`, `/form-test/*`, `/mcp-test/*`.

### Promtail is EOL (2026-03-02)

Grafana Alloy ships logs to Loki instead.

### Redis is tri-licensed (RSALv2 / SSPL / AGPLv3)

Valkey 9.1 is BSD-licensed, protocol-compatible with n8n's ioredis client, and an ElastiCache engine. Valkey is the default queue backend.

### This machine

Verified 2026-10-07. The original draft assumed an MSI desktop with WSL2; the laptop An actually works on has no WSL distro, but it has a Linux VM — the kit is built there.

| Item | State |
| --- | --- |
| Host | Laptop (4c/8t, 16 GB), Windows 10 Pro; small internal SSD (about 15 GB free per partition), external USB SSD with about 200 GB free; VMware Workstation 25 |
| Build host | VM `server1` = Ubuntu 26.04 LTS (kernel 7.0), 4 vCPU, 7 GB (raised from 5), NAT `<vm-ip>`, `ssh k8svm` (key auth, user `<vm-user>`, passwordless sudo) |
| Present in the VM | Docker 29.5.2 + Compose 5.1.4 (containerd image store, cgroup v2, AppArmor), kubectl 1.36 / helm / kind, make, jq, curl, git (identity set), python 3.14; dev tools from §6 step 3 installed |
| Shared with | 5 other compose projects + host nginx (ports 80/443/81 taken); root disk 77 GB, 32 GB free after pruning Docker cache/images |
| On Windows | git, gh (not logged in on the VM yet), VS Code + Remote-SSH, OpenSSH client; no Docker, no WSL distro |

## 3. Decisions

Recorded in HANDOFF §3 (newest first) on 2026-10-06/07; both original HANDOFF §7 questions are answered there and the machines table lists the laptop + VM `server1`.

| Decision | Why | Rejected |
| --- | --- | --- |
| Pin **n8n 2.42.3** + `n8nio/runners:2.42.3`; both use one `${N8N_VERSION}` in `compose/versions.env` (tag + digest) | Current stable; version lock enforced by construction | `latest` tag; version in `.env` |
| **Valkey 9.1** queue backend (`noeviction`, AOF `everysec`); Redis documented as drop-in | BSD, Linux Foundation, ElastiCache engine | Redis 7/8 |
| **Grafana Alloy** replaces Promtail | Promtail EOL | Promtail |
| **Postgres 18** (`postgres:18-alpine`, volume at `/var/lib/postgresql`); backup image built `FROM postgres:18-alpine` | n8n supports 16–18; 19 is imminent; `pg_dump` always matches the server | 16 / 17 |
| **Explicit numbered services** `n8n-webhook-1/2`, `n8n-worker-1/2`, each worker with its own `-runners` sidecar (YAML anchors); `make scale-workers` renders `compose.scale.yml` | Runners pair 1:1 with workers; Caddy dynamic `a` upstreams have no active health checks; `docker kill n8n-worker-1` demos are trivial | `deploy.replicas`; one shared runners service |
| **Routing:** `/webhook/*`, `/webhook-waiting/*`, `/form/*`, `/form-waiting/*`, `/mcp/*` → webhook pool; everything else incl. `*-test/*` → main; `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` | Matches n8n's router; main stays free for UI/triggers | Sending all `/webhook*` to the pool |
| **Backups multi-target via rclone:** `BACKUP_REMOTES` = any mix of Cloudflare R2, AWS S3, local/external disk or NAS mount (`BACKUP_LOCAL_PATH` bind-mounted into the sidecar) | User asked for R2 + S3 + external disk; rclone makes 3-2-1 a config line; R2 is the demo default (free egress), S3 for Target B | Single-target script |
| **Two age recipients:** host automation key (unattended weekly restore test) + offline recovery key (moved off-host after `make init`) | Bucket alone stays useless; root on the VPS already has the live DB anyway | Single key; GPG |
| `scripts/bootstrap-host.sh` installs Docker Engine + compose + make/jq/curl/git on **Ubuntu 24.04 / Debian (apt)** and the **RHEL 9/10 family (dnf:** Rocky, AlmaLinux, CentOS Stream, Oracle, RHEL) | User wants CentOS-family support; production-preferred free RHEL rebuilds are Rocky 9 / AlmaLinux 9 (CentOS Stream is RHEL's rolling upstream, documented as not-for-prod). Tested in `ubuntu:24.04` / `ubuntu:26.04` / `rockylinux:9` containers in CI; SELinux/firewalld verified once on a real AlmaLinux 9 VM or Rocky VPS before claiming support (HANDOFF §7) | CentOS-Stream-only |
| **Target C — Kubernetes Helm chart** as M2.5 (after Terraform) | User asked for Kubernetes; same topology (runners as in-pod sidecars), CloudNativePG or external DB, Valkey StatefulSet, Ingress + cert-manager, KEDA on queue depth; kind on the VM (already installed) and in CI | Out of scope (PLAN §1.6) |
| **Dev = the Ubuntu 26.04 VM `server1`** (VMware, `ssh k8svm`), kit on ports **8080/8443**; Ubuntu 26.04 supported next to 24.04 in `bootstrap-host.sh` and the CI matrix | Only Linux on this laptop; Docker already there; mirrors a VPS closely enough; the VM is shared and 80/443 are taken; Docker's apt repo already serves `resolute` | WSL2 + Docker Engine (no distro installed, 16 GB host), Docker Desktop, reinstalling the VM as 24.04 |
| **Repo public from day one** at `nhhandevops/n8n-prod-kit` | No-secrets discipline from commit 1; free Actions minutes | Private until M0 |
| Grafana at `https://DOMAIN/grafana/`, Uptime Kuma at `kuma.DOMAIN` | One cert/domain; `*.localtest.me` resolves too | Extra ports |

## 4. Architecture (delta vs PLAN.md §2; the rest stands)

Same topology as PLAN.md §2.2, with four changes: Valkey replaces Redis, every n8n main/worker gets a 1:1 runners sidecar, Caddy routes by n8n's real path list, and the backup sidecar writes to several remotes.

&#91;embedded content: Compose topology · Caddy, 2 webhook processors, main, 2 workers, 5 runners sidecars, shared state, backups, monitoring\]

Caddy sends production webhook, form and MCP paths to the webhook pool and everything else to main; main and each worker talk to their own runners sidecar over port 5679. All n8n roles share Valkey, Postgres and the `n8n_data` volume (arrows shown from the workers and one per row to keep the picture clear); the backup sidecar reads Postgres and the volume, encrypts with two age keys, and copies to every remote in `BACKUP_REMOTES`, with an hourly cert-check on top. The monitoring profile scrapes `/metrics` from main, webhooks and workers and ships container logs through Alloy to Loki.

### Per-role environment summary (full anchor in §8)

| Role | Env on top of the shared `x-n8n-common` anchor |
| --- | --- |
| Shared (`x-n8n-common`) | DB, queue, `EXECUTIONS_MODE=queue`, `N8N_ENCRYPTION_KEY`, `N8N_DEFAULT_BINARY_DATA_MODE=filesystem`, runners broker settings, `WEBHOOK_URL`, `N8N_PROXY_HOPS=1`, metrics, security hardening, `GENERIC_TIMEZONE`/`TZ=Asia/Ho_Chi_Minh` |
| main | `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`, `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` |
| webhook | `command: webhook` + response-relay offload |
| worker | `command: worker --concurrency=N` + `QUEUE_HEALTH_CHECK_ACTIVE=true` + lock/stall tuning |
| runners | `N8N_RUNNERS_TASK_BROKER_URI=http://<paired>:5679`, `N8N_RUNNERS_AUTH_TOKEN`, `N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT=15`, `N8N_RUNNERS_MAX_CONCURRENCY=5`, optional `N8N_NATIVE_PYTHON_RUNNER` |

**Backup sidecar** (`FROM postgres:18-alpine` + age + rclone + supercronic): 02:00 backup → `BACKUP_REMOTES` (R2 | S3 | local disk); Sunday 03:00 restore-test; hourly cert-check.

**`--profile monitoring`:** prometheus 3.5 LTS · grafana 13 (`/grafana/`) · loki 3.7 · alloy 1.17 · node-exporter · cadvisor · uptime-kuma 2 (`kuma.DOMAIN`).

## 5. Resources

The local phase costs 0 đ; paid items start with the demo VPS at the M0 gate.

### Accounts

| Account | Use | Notes / cost |
| --- | --- | --- |
| GitHub `nhhandevops` | Repo, Pages, Actions, Dependabot | Have; enable Pages + Actions + Dependabot |
| Cloudflare | R2 bucket `n8n-backups` + S3-API token scoped to it | Free; 10 GB, zero egress; may require a card on file |
| AWS account | M2; S3 bucket for the S3 backup path (can be created earlier for TC-011 on both remotes) | $20/month budget alarm |
| Telegram bot via @BotFather | Alerts; chat id via `getUpdates` | Free |
| VPS provider | Demo host (M0 gate); Ubuntu 24.04 and one Rocky/Alma 9 run for the RHEL path | Hetzner CX22 ≈ €4/mo or VN provider 150–300k đ/mo |
| Domain | Demos; until then `n8n.localtest.me` | ≈ 200k đ/yr |

### Hardware / local

VM `server1`: 4 vCPU / 7 GB (6.2 GB usable, other projects idle at ≈ 1.1 GB). Core stack ≈ 3.5 GB RAM fits; with monitoring ≈ 5–6 GB → stop the heavy neighbours (ollama, kind) during those sessions. ≈ 10 GB disk incl. images; 32 GB free after the 2026-10-07 prune. The "external disk" backup target is tested with a USB stick passed through to the VM (VMware → Removable Devices) or simply a second local path.

### Tools (inside the VM)

Already present: Docker Engine 29.5.2 + Compose 5.1.4 + buildx · make · jq · curl · git · gh · shellcheck · yamllint · hadolint · age · rclone · python3-venv + mkdocs-material · kubectl / helm / kind. VS Code on Windows + Remote-SSH extension. Later: terraform ≥ 1.9 + tflint (M2); k3s or kind for the chart (M2.5).

### Images to pin (`compose/versions.env`, digests via `make pin`)

| Service | Image:tag |
| --- | --- |
| n8n main / webhook / worker | `docker.n8n.io/n8nio/n8n:2.42.3` |
| runners sidecars | `n8nio/runners:2.42.3` (same `${N8N_VERSION}`) |
| caddy | `caddy:2.11.4-alpine` |
| postgres | `postgres:18-alpine` |
| valkey | `valkey/valkey:9.1-alpine` |
| prometheus | `prom/prometheus:v3.5.x` (LTS) |
| grafana | `grafana/grafana-oss:13.x` |
| loki / alloy | `grafana/loki:3.7.x` / `grafana/alloy:v1.17.x` |
| node-exporter / cadvisor | `prom/node-exporter:v1.12.1` / `gcr.io/cadvisor/cadvisor:v0.60.6` |
| uptime-kuma | `louislam/uptime-kuma:2` |
| backup | built locally: `postgres:18-alpine` + age 1.3.2 + rclone 1.75.1 + supercronic 0.2.49 (sha256-pinned downloads) |

### Time

M0 + first M1 slice ≈ 35 h (sessions in §15) · M1 rest (templates) ≈ 10 h · M2 ≈ 20 h · M2.5 ≈ 15 h · M3 ≈ 10 h.

## 6. Step-by-step: set up this laptop's VM and run the kit

Everything runs inside the Ubuntu 26.04 VM `server1` (VMware Workstation 25 on the Windows 10 laptop); Windows only hosts the browser, VS Code and `ssh k8svm`. State on 2026-10-07 in brackets. Each step ends with a verify line.

1. **VM sizing** [done]. `memsize = "7168"`, `numvcpus = "4"` in `server1.vmx` (edit only while the VM is off). The host has 16 GB; do not go above 8 GB. *Verify in the VM:* `free -g` → ≈ 6 total, `nproc` → 4.
2. **Docker Engine** [present: 29.5.2 + Compose 5.1.4, containerd image store, cgroup v2, `<vm-user>` in `docker` group]. Nothing to install here; `scripts/bootstrap-host.sh` is exercised in `ubuntu:24.04` / `ubuntu:26.04` / `rockylinux:9` containers (S3) and on the demo VPS. *Verify:* `docker run --rm hello-world`; `docker compose version` ≥ 2.30.
3. **Dev tools** [done 2026-10-07]: age 1.2.1, shellcheck 0.11, hadolint 2.15.1 (sha256-checked binary), yamllint 1.37, rclone 1.75.1, gh 2.102, mkdocs-material in `~/.venvs/mkdocs` (`~/.local/bin/mkdocs`), make/jq/curl/git/unzip. Later: terraform + tflint (M2); kubectl/helm/kind are already present (M2.5). *Verify:* `make --version && age --version && shellcheck --version && hadolint --version && yamllint --version && rclone version && gh --version && mkdocs --version`.
4. **Git + GitHub** [identity, `core.autocrlf=false`, `init.defaultBranch=main` done]. An: `gh auth login` (HTTPS, device code in the Windows browser), then `gh auth setup-git`. *Verify:* `gh auth status` → logged in as nhhandevops.
5. **VS Code** [Remote-SSH installed on Windows]. Open the project with `code --remote ssh-remote+k8svm /home/<vm-user>/src/n8n-prod-kit`. *Verify:* status bar shows "SSH: k8svm".
6. **Clone location.** `mkdir -p ~/src && cd ~/src && gh repo clone nhhandevops/n8n-prod-kit` (after S1), on the VM's ext4 — never a VMware shared folder (`/mnt/hgfs` cannot hold chmod 600 files). A Windows-side copy, if any, is for reading only; never edit both without pulling. *Verify:* `df -T .` → ext4; `touch x && chmod 600 x && stat -c %a x` → 600.
7. **Ports and names.** The VM is shared: host nginx owns :80, nginx-proxy-manager owns :443/:81, and :3000 :8025 :8081 :8753 :8888 :9999 belong to other projects. The kit uses `HTTP_PORT=8080 HTTPS_PORT=8443` (free; `make init` folds the port into `WEBHOOK_URL` / `N8N_EDITOR_BASE_URL`). Windows hosts file (admin): `<vm-ip> n8n.localtest.me kuma.n8n.localtest.me`. The VM's `/etc/hosts` currently maps `n8n.localtest.me` → `::1`; change it to `127.0.0.1` and add `kuma.n8n.localtest.me` in S2 (containers get the name via `compose.dev.yml` `extra_hosts: host-gateway`). *Verify:* Windows `ping n8n.localtest.me` → <vm-ip>; VM `getent hosts n8n.localtest.me` → 127.0.0.1; `ss -ltn | grep -E ':(8080|8443) '` → empty.
8. **RAM budget.** 6.2 GB usable; the other projects idle at ≈ 1.1 GB; the core kit (≈ 3.5 GB) fits. For `--profile monitoring` (+1.5–2 GB) stop the heavy neighbours first (e.g. a local Ollama container, the kind cluster) and start them again afterwards. *Verify:* `free -g` shows ≥ 4 available before `make up`.
9. **First run** (after S2–S4 exist). `cd ~/src/n8n-prod-kit/compose && make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443` (→ `TLS_MODE=internal`, local backup target, secrets generated, red banner to store `N8N_ENCRYPTION_KEY` + recovery key in the password manager) → `make preflight` → `make up` (2–3 min first pull) → `make status` (TC-003) → `make smoke` (TC-004…006) → `make trust-ca` (exports `compose/.smoke/root.crt`; on Windows: `scp k8svm:src/n8n-prod-kit/compose/.smoke/root.crt %USERPROFILE%\Downloads\n8nkit-root.crt`, then admin `certutil -addstore -f ROOT %USERPROFILE%\Downloads\n8nkit-root.crt`) → open `https://n8n.localtest.me:8443` → `make doctor` all OK. Optional: `COMPOSE_PROFILES=monitoring make up` → `https://n8n.localtest.me:8443/grafana/`, `https://kuma.n8n.localtest.me:8443`.
10. **RHEL path (S3).** No RHEL guest on this laptop: `make bootstrap-test` runs `rockylinux:9` (install-only) in a container; the real SELinux/firewalld run happens once on an AlmaLinux 9 VM (the K: USB SSD has 200 GB free) or a one-off Rocky VPS — HANDOFF §7.
11. **VM quirks.** `tools.syncTime=FALSE` but NTP is active — after the host sleeps, check `timedatectl` (`make doctor` checks skew). The VM disk is a growable 80 GB vmdk on D: with 72 GB allocated while D: has 18 GB free: keep D: ≥ 10 GB free or move the VM folder to K:. Docker on the VM also runs 15 containers of other projects; `make clean` only touches compose project `n8nkit`.
12. **VPS (M0 gate).** Unchanged: fresh Ubuntu 24.04 (then once on Rocky/Alma 9): `curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash` (or clone + run) → `make init DOMAIN=n8n.example.com ACME_EMAIL=…` → `make preflight` → `make up` → `make status` — ≤ 15 min using only `docs/quickstart.md` (TC-025). This is where ports 80/443 and ACME are exercised.

## 7. Repository skeleton (M0 + first M1 slice)

```text
n8n-prod-kit/
├── README.md                      # public face: pitch, 15-min quickstart, topology diagram, badges, "need help?" link
├── n8n-kit-README.md  n8n-kit-PLAN.md  n8n-kit-HANDOFF.md  n8n-kit-CHANGELOG.md   # project memory (moved from the bundle)
├── CLAUDE.md  LICENSE (MIT)  .gitignore  .gitattributes  .editorconfig  .yamllint  .hadolint.yaml  .shellcheckrc
├── .github/
│   ├── ISSUE_TEMPLATE/{bug,template-request,question}.yml + config.yml
│   ├── PULL_REQUEST_TEMPLATE.md  CODEOWNERS  dependabot.yml
│   └── workflows/ ci.yml  weekly-latest-n8n.yml  bootstrap-matrix.yml  docs.yml
├── scripts/ bootstrap-host.sh      # host prep: detect apt/dnf → Docker Engine + compose plugin + make/jq/curl/git;
│                                   # RHEL: EPEL, firewalld http/https, SELinux kept enforcing
├── compose/
│   ├── docker-compose.yml  compose.dev.yml  compose.scale.yml (GENERATED, gitignored)  versions.env  .env.example  Makefile
│   ├── caddy/ Caddyfile  tls-internal.caddy  tls-acme.caddy  tls-acme-staging.caddy  ui-protect-off.caddy  ui-protect-on.caddy
│   ├── scripts/ lib.sh init.sh preflight.sh status.sh doctor.sh render.sh pin.sh upgrade.sh rollback.sh scale.sh
│   │            loadtest.sh chaos.sh trust-ca.sh import-template.sh export-workflows.sh
│   ├── backup/ Dockerfile entrypoint.sh lib.sh backup.sh restore.sh restore-test.sh cert-check.sh notify.sh crontab.tmpl
│   ├── monitoring/ prometheus/{prometheus.yml, targets/n8n.json (GENERATED)}
│   │               grafana/provisioning/{datasources,dashboards,alerting}/*.yaml
│   │               grafana/dashboards/{n8n-overview,host,backups}.json  loki/loki.yml  alloy/config.alloy
│   ├── secrets/.gitkeep            # age-key.txt, age-recovery-key.txt (gitignored)
│   └── backups/.gitkeep            # local backup target for dev/CI (gitignored)
├── tests/smoke/ run.sh lib.sh 01-health.sh 02-tls.sh 03-owner.sh 04-webhook-routing.sh 05-execution-on-worker.sh
│                06-metrics.sh 07-backup.sh 08-restore-test.sh  fixtures/{wf-webhook-echo,wf-schedule-tick,cred-header-auth}.json
├── tests/bootstrap/ test-in-container.sh   # runs bootstrap-host.sh inside ubuntu:24.04, ubuntu:26.04 and rockylinux:9 (install-only)
├── docs/ mkdocs.yml index.md quickstart.md quickstart.vi.md architecture.md configuration.md security.md compat.md faq.md contributing.md
│         operations/{backup-restore,upgrade-rollback,scaling,monitoring-alerts,chaos-drills,rebuild-vps,local-dev,rhel-hosts}.md   # local-dev covers a Linux VM, WSL2 and a bare Linux box
├── templates/README.md             # M1 slice 2
├── terraform/README.md             # M2
└── k8s/README.md                   # M2.5 (Helm chart)
```

### Key file contents

| File | Contents |
| --- | --- |
| `CLAUDE.md` | The 7 agent rules from `n8n-kit-README.md` + `make help` cheat-sheet + conventions (bash `set -euo pipefail`, shellcheck clean, 2-space YAML, Conventional Commits) + placeholder rule (`example.com`, `n8n.localtest.me`, `203.0.113.0/24`) + DoD + "never run `make clean`/`restore` on a user's stack unasked" |
| `.gitignore` | `compose/.env`, `compose/secrets/*`, `compose/backups/*`, `compose/compose.scale.yml`, `compose/monitoring/prometheus/targets/*.json`, `compose/.smoke/`, `compose/.upgrade/`, `*.age`, `site/`, `.venv/`, `.terraform/`, `*.tfstate*`, `terraform.tfvars`, `!*.example`, `!**/.gitkeep` |
| `.gitattributes` | `* text=auto eol=lf`, `*.sh text eol=lf`, `Makefile text eol=lf`, `*.png binary` |
| Lint configs | yamllint (line-length 160, truthy keys off, document-start off); hadolint (ignore DL3018 with comment — binaries are sha256-pinned instead); shellcheckrc (`enable=all`, `source-path=SCRIPTDIR`) |
| Issue templates | `bug.yml` asks kit version (`make version`), n8n version, target, OS, `make doctor` + `make status` output, `.env` KEYS only (`make env-keys`) |
| PR template | Checklist: smoke output pasted, docs page updated, CHANGELOG Unreleased, `make lint` green, no real domains/IPs |

## 8. Compose services (`compose/docker-compose.yml`, project `n8nkit`)

**Common to every service:** networks `internal` (`internal: true`) + `proxy`; `restart: unless-stopped`; `security_opt: [no-new-privileges:true]`; `cap_drop: [ALL]`; json-file logging 20m × 5; `deploy.resources.limits` from `MEM_LIMIT_*`. Images as `${X_IMAGE}:${X_VERSION}@${X_DIGEST:?run make pin}`. Bind mounts carry `:z` so SELinux-enforcing RHEL hosts work.

| Service | Image / command | Key env | Healthcheck | depends\_on | Notes |
| --- | --- | --- | --- | --- | --- |
| **caddy** | caddy; ports `${HTTP_PORT:-80}:80`, `${HTTPS_PORT:-443}:443` | `DOMAIN TLS_MODE ACME_EMAIL UI_PROTECT UI_ALLOW_CIDR UI_BASIC_AUTH_USER/HASH WEBHOOK_UPSTREAMS` | `wget -qO- http://127.0.0.1:2019/config/` | n8n-main healthy | root but only `cap_add: [NET_BIND_SERVICE]`; `read_only`; volumes `caddy_data`, `caddy_config`, `./caddy:/etc/caddy:ro,z`; both networks; 256m |
| **postgres** | `postgres:18-alpine`; `command: postgres -c shared_buffers=256MB -c max_connections=150 -c log_min_duration_statement=2000` | `POSTGRES_USER=n8n POSTGRES_DB=n8n POSTGRES_PASSWORD POSTGRES_INITDB_ARGS=--data-checksums` | `pg_isready -U n8n -d n8n` | — | volume `pg_data:/var/lib/postgresql` (18 path); `read_only` + tmpfs `/var/run/postgresql`, `/tmp`; `user: "70:70"`; 1g |
| **valkey** | `valkey-server --requirepass $$VALKEY_PASSWORD --appendonly yes --appendfsync everysec --maxmemory 256mb --maxmemory-policy noeviction --save ""` | `VALKEY_PASSWORD` | `VALKEYCLI_AUTH=$$VALKEY_PASSWORD valkey-cli ping \| grep -q PONG` | — | `valkey_data:/data`; `read_only`; `user: "999:999"`; 384m |
| **n8n-main** | n8n image, default cmd | `*n8n-common` + `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` | `wget -qO- http://127.0.0.1:5678/healthz/readiness`, start\_period 90s | postgres, valkey healthy | `n8n_data:/home/node/.n8n` (shared; binaryData inside); tmpfs `/tmp`; try `read_only`; 1g |
| **n8n-main-runners** | runners image | `N8N_RUNNERS_TASK_BROKER_URI=http://n8n-main:5679 N8N_RUNNERS_AUTH_TOKEN N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT=15 N8N_RUNNERS_MAX_CONCURRENCY=5 N8N_NATIVE_PYTHON_RUNNER=${RUNNERS_PYTHON:-false}` | `wget -qO- http://127.0.0.1:5680/healthz` | n8n-main healthy | internal only; `read_only` + tmpfs; 512m |
| **n8n-webhook-1, -2** | `command: webhook` (anchor `x-n8n-webhook`) | `*n8n-common` + `N8N_WEBHOOK_RESPONSE_RELAY_OFFLOAD_ENABLED=true N8N_WEBHOOK_RESPONSE_RELAY_SIZE_MAX=64` | `/healthz` | n8n-main healthy (migrations first) | 512m each |
| **n8n-worker-1, -2** | `command: worker --concurrency=${WORKER_CONCURRENCY:-10}` (anchor `x-n8n-worker`) | `*n8n-common` + `QUEUE_HEALTH_CHECK_ACTIVE=true QUEUE_WORKER_LOCK_DURATION=60000 QUEUE_WORKER_LOCK_RENEW_TIME=10000 QUEUE_WORKER_STALLED_INTERVAL=30000` | `/healthz/readiness` on 5678 | n8n-main healthy | 1g each |
| **n8n-worker-N-runners** | runners image (anchor `x-runners`) | `N8N_RUNNERS_TASK_BROKER_URI=http://n8n-worker-N:5679` | `:5680/healthz` | its worker healthy | 1:1 pairing |
| **backup** | `build: ./backup` | `PGHOST=postgres PGUSER PGPASSWORD PGDATABASE N8N_ENCRYPTION_KEY N8N_VERSION DOMAIN BACKUP_* RCLONE_CONFIG_* ALERT_TELEGRAM_*` | `pgrep -x supercronic` | postgres healthy | `backup_state:/state` (textfile metrics, shared with node-exporter); `./secrets/age-key.txt:/run/secrets/age-key.txt:ro,z`; `./backups:/backups/local:z`; `${BACKUP_LOCAL_PATH:-./backups}:/backups/external:z`; `n8n_data:/n8n:ro`; `caddy_data:/caddy:ro`; tmpfs `/tmp:size=${BACKUP_TMPFS_SIZE:-2g}`; `user: "70:70"`; 1g |
| **profile `monitoring`:** prometheus, grafana, loki, alloy, node-exporter, cadvisor, uptime-kuma | pinned | §14 | `/-/healthy`, `/api/health`, `/ready`, `/-/ready`, `/metrics`, `/healthz`, `extra/healthcheck` | — | `profiles: ["monitoring"]`; enabled by `COMPOSE_PROFILES=monitoring` |

### `x-n8n-common` env anchor

```text
DB_TYPE=postgresdb  DB_POSTGRESDB_HOST=postgres  DB_POSTGRESDB_PORT=5432  DB_POSTGRESDB_DATABASE=n8n  DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD  DB_POSTGRESDB_POOL_SIZE=4
EXECUTIONS_MODE=queue  QUEUE_BULL_REDIS_HOST=valkey  QUEUE_BULL_REDIS_PORT=6379  QUEUE_BULL_REDIS_PASSWORD  QUEUE_BULL_REDIS_DB=0  QUEUE_BULL_PREFIX=n8n
N8N_ENCRYPTION_KEY  N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_RUNNERS_MODE=external  N8N_RUNNERS_AUTH_TOKEN  N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0
N8N_HOST=${DOMAIN}  N8N_PROTOCOL=https  N8N_PORT=5678  WEBHOOK_URL=https://${DOMAIN}/  N8N_EDITOR_BASE_URL=https://${DOMAIN}/
N8N_PROXY_HOPS=1  N8N_SECURE_COOKIE=true  N8N_SAMESITE_COOKIE=lax
N8N_LOG_LEVEL=info  N8N_LOG_OUTPUT=console  N8N_LOG_FORMAT=json
N8N_METRICS=true  N8N_METRICS_INCLUDE_QUEUE_METRICS=true  N8N_METRICS_INCLUDE_DEFAULT_METRICS=true  N8N_METRICS_QUEUE_METRICS_INTERVAL=20
GENERIC_TIMEZONE  TZ  N8N_GRACEFUL_SHUTDOWN_TIMEOUT  + all EXECUTIONS_* and security vars from .env (§10)
```

**`compose.dev.yml`** (auto-included when `TLS_MODE=internal`): `extra_hosts: ["${DOMAIN}:host-gateway"]` on n8n services (self-calls work in dev), `caddy_data:/certs:ro` + `NODE_EXTRA_CA_CERTS=/certs/caddy/pki/authorities/local/root.crt`.

**`compose.scale.yml`** (generated by `make render`): `n8n-worker-3..N` + runners, fully expanded.

## 9. Caddyfile design

One site block per domain; the webhook pool matches n8n's path list first, everything else falls through to main.

```caddyfile
{
	email {$ACME_EMAIL}
	servers { metrics }
	admin localhost:2019
}

(security_headers) {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy strict-origin-when-cross-origin
		Permissions-Policy "camera=(), microphone=(), geolocation=()"
		-Server
	}
}

(pool_health) {
	lb_policy round_robin
	lb_try_duration 5s
	lb_retries 2
	health_uri /healthz
	health_interval 10s
	health_timeout 3s
	health_status 200
	fail_duration 30s
	max_fails 2
	header_down +X-Kit-Upstream {upstream_hostport}
}

{$DOMAIN} {
	import security_headers
	import /etc/caddy/tls-{$TLS_MODE:acme}.caddy      # internal = `tls internal`; acme = empty; acme-staging = LE staging CA
	encode zstd gzip
	log { output stdout  format json }
	request_body { max_size 64MB }

	handle /healthz         { reverse_proxy n8n-main:5678 }
	handle /healthz/webhook { rewrite * /healthz  reverse_proxy {$WEBHOOK_UPSTREAMS:n8n-webhook-1:5678 n8n-webhook-2:5678} { import pool_health } }

	@pool path /webhook/* /webhook-waiting/* /form/* /form-waiting/* /mcp/*
	handle @pool { reverse_proxy {$WEBHOOK_UPSTREAMS:n8n-webhook-1:5678 n8n-webhook-2:5678} { import pool_health } }

	handle /grafana/* { reverse_proxy grafana:3000 }

	handle {                                            # UI, /rest, /api, *-test/*, push websocket
		import /etc/caddy/ui-protect-{$UI_PROTECT:off}.caddy
		reverse_proxy n8n-main:5678 { health_uri /healthz  health_interval 10s  header_down +X-Kit-Upstream {upstream_hostport} }
	}
}

kuma.{$DOMAIN} {
	import security_headers
	import /etc/caddy/tls-{$TLS_MODE:acme}.caddy
	reverse_proxy uptime-kuma:3001
}
```

- **`ui-protect-on.caddy`:** `@denied not remote_ip {$UI_ALLOW_CIDR:0.0.0.0/0 ::/0}` → 403, plus `basic_auth` with a `caddy hash-password` hash (`make ui-auth USER=…`). Pool and health routes match earlier, so webhooks stay open (TC-019).
- HTTP→HTTPS, HSTS, websocket upgrade and `X-Forwarded-*` are Caddy defaults (`N8N_PROXY_HOPS=1`).
- `X-Kit-Upstream` proves routing in the smoke suite (TC-005).
- `caddy validate` runs in CI.
- Caddy `{$VAR}` is substituted before parsing (multi-token OK; `{$VAR:default}` works) — verified.

## 10. `.env.example` and `make init`

Grouped per PLAN §2.4, every line commented (what / default / why).

```ini
# 1. IDENTITY & EDGE
DOMAIN=n8n.example.com   TLS_MODE=acme   ACME_EMAIL=admin@example.com      # acme | acme-staging | internal
UI_PROTECT=off   UI_ALLOW_CIDR=   UI_BASIC_AUTH_USER=   UI_BASIC_AUTH_HASH=
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh   TZ=Asia/Ho_Chi_Minh

# 2. SECRETS — generated by `make init`, never commit, chmod 600
N8N_ENCRYPTION_KEY=        # LOSING THIS = LOSING ALL CREDENTIALS (also inside every backup bundle)
POSTGRES_PASSWORD=   VALKEY_PASSWORD=   N8N_RUNNERS_AUTH_TOKEN=   GRAFANA_ADMIN_PASSWORD=

# 3. TOPOLOGY & SIZING
WORKER_REPLICAS=2   WORKER_CONCURRENCY=10   RUNNERS_PYTHON=false
MEM_LIMIT_MAIN=1g MEM_LIMIT_WEBHOOK=512m MEM_LIMIT_WORKER=1g MEM_LIMIT_RUNNERS=512m MEM_LIMIT_POSTGRES=1g

# 4. EXECUTIONS (n8n defaults, exposed as knobs)
EXECUTIONS_DATA_PRUNE=true EXECUTIONS_DATA_MAX_AGE=336 EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000
EXECUTIONS_DATA_SAVE_ON_SUCCESS=all EXECUTIONS_DATA_SAVE_ON_ERROR=all EXECUTIONS_DATA_SAVE_ON_PROGRESS=false EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=true
EXECUTIONS_TIMEOUT=-1 EXECUTIONS_TIMEOUT_MAX=3600 N8N_CONCURRENCY_PRODUCTION_LIMIT=-1 N8N_GRACEFUL_SHUTDOWN_TIMEOUT=30

# 5. SECURITY (opinionated)
N8N_BLOCK_ENV_ACCESS_IN_NODE=true N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true N8N_RESTRICT_FILE_ACCESS_TO=/home/node/.n8n/files
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true N8N_GIT_NODE_DISABLE_BARE_REPOS=true N8N_DIAGNOSTICS_ENABLED=false
N8N_PERSONALIZATION_ENABLED=false N8N_HIRING_BANNER_ENABLED=false N8N_TEMPLATES_ENABLED=true N8N_VERSION_NOTIFICATIONS_ENABLED=true
N8N_PUBLIC_API_DISABLED=false N8N_MFA_ENFORCED_ENABLED=false
NODES_EXCLUDE=["n8n-nodes-base.executeCommand","n8n-nodes-base.localFileTrigger"]

# 6. BACKUPS — multi-target: space-separated rclone destinations (any mix of R2, S3, local/external disk, NAS, any rclone remote)
BACKUP_ENABLED=true
BACKUP_REMOTES="r2:n8n-backups/prod"            # e.g. "r2:n8n-backups/prod s3:my-bucket/n8n /backups/external"; dev/CI: "/backups/local"
BACKUP_LOCAL_PATH=                               # host path of an external disk / NAS mount → appears as /backups/external
BACKUP_SCHEDULE="0 2 * * *"  RESTORE_TEST_SCHEDULE="0 3 * * 0"  CERT_CHECK_SCHEDULE="17 * * * *"
BACKUP_RETENTION_DAILY=30  BACKUP_RETENTION_MONTHLY=12  BACKUP_INCLUDE_BINARY=false  BACKUP_TMPFS_SIZE=2g  BACKUP_NOTIFY_SUCCESS=false
BACKUP_AGE_PUBLIC_KEY=age1…            # host automation key (secrets/age-key.txt)
BACKUP_AGE_RECOVERY_PUBLIC_KEY=age1…   # OFFLINE recovery key; private half must leave this host
RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_ACCESS_KEY_ID= RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=
RCLONE_CONFIG_R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com RCLONE_CONFIG_R2_ACL=private
RCLONE_CONFIG_S3_TYPE=s3 RCLONE_CONFIG_S3_PROVIDER=AWS RCLONE_CONFIG_S3_REGION=ap-southeast-1 RCLONE_CONFIG_S3_ACCESS_KEY_ID= RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=

# 7. MONITORING & ALERTS
COMPOSE_PROFILES=                      # "monitoring" to enable
ALERT_TELEGRAM_BOT_TOKEN= ALERT_TELEGRAM_CHAT_ID=   GRAFANA_ADMIN_USER=admin   LOKI_RETENTION=336h   PROM_RETENTION=15d

# 8. LOCAL-DEV OVERRIDES
COMPOSE_PROJECT_NAME=n8nkit   HTTP_PORT=80   HTTPS_PORT=443
```

### `make init DOMAIN=… [ACME_EMAIL=…] [BACKUP_REMOTES=…] [FORCE=1]` (`scripts/init.sh`)

1. Refuses to overwrite an existing `.env` (exit 2; `FORCE=1` warns that a new key makes existing credentials unreadable). Idempotent otherwise.
2. `cp .env.example .env`. `*.localtest.me` | `localhost` → `TLS_MODE=internal`, `BACKUP_REMOTES=/backups/local`, `ACME_EMAIL=dev@example.com`.
3. Generates `N8N_ENCRYPTION_KEY` (`openssl rand -base64 48`, 64 chars), DB/Valkey passwords (hex 24), runners token (hex 32), Grafana password (hex 12); written with awk.
4. `age-keygen` → `secrets/age-key.txt` + `secrets/age-recovery-key.txt` (fallback `docker run --rm n8nkit/backup age-keygen`); public keys into `.env`.
5. `chmod 600 .env secrets/*`; `make render`; red banner: store `N8N_ENCRYPTION_KEY` + recovery key in the password manager, then `make detach-recovery-key`.
6. Self-check (TC-001): key ≥ 32 chars, secrets non-empty, mode 600, `docker compose config -q` passes. `CI=1` = no prompts.

## 11. Makefile targets

`make help` is the default (built from `##` comments). `COMPOSE := docker compose --env-file versions.env --env-file .env -f docker-compose.yml $(wildcard compose.scale.yml)` plus `-f compose.dev.yml` when `TLS_MODE=internal`.

| Target | What it does | TC |
| --- | --- | --- |
| `init` | §10 | TC-001 |
| `preflight` | docker ≥ 27 / compose ≥ 2.30; `.env` 600 + required vars; DNS of `DOMAIN` (= public IP in acme, 127.0.0.1 in internal); ports 80/443 free, naming the PID/process (`ss -ltnp`; WSL hint for Windows listeners); disk ≥ 10 GB; RAM ≥ 3.5 GB; CPUs ≥ 2; clock skew < 60 s; digests present; `BACKUP_LOCAL_PATH` mounted if set | TC-002 |
| `pin [N8N_VERSION=x]` | `docker buildx imagetools inspect --format '{{.Manifest.Digest}}'` for every `*_VERSION` → rewrite `*_DIGEST` in `versions.env` | TC-020 part |
| `render` | Write `compose.scale.yml` (if `WORKER_REPLICAS>2`) and `monitoring/prometheus/targets/n8n.json` | — |
| `up` | preflight → render → build backup → pull → `up -d --wait --wait-timeout 180` → status | TC-003 |
| `down` / `restart SERVICE=` / `pull` / `ps` / `logs SERVICE= [SINCE=]` | Wrappers | — |
| `status` | Service/health/uptime/restarts table; exit 1 if any unhealthy; prints login URL + (dev) CA-trust hint | TC-003 |
| `smoke [ONLY=04,05]` | §12 | TC-003–006, 011–012 |
| `doctor` | OK/WARN/FAIL lines, each with a fix: `.env` perms, key length, n8n = runners version, DNS vs public IP, cert expiry, ports, disk ≥ 80 %, restart counts + last 20 log lines of unhealthy services, Postgres connections/size/prune, Valkey noeviction + AOF, last backup age per remote, last restore-test, clock skew, `N8N_ENDPOINT_*` overrides vs Caddyfile, recovery key still on host > 7 days, SELinux/firewalld state on RHEL, WSL hints. `DOCTOR_SIMULATE=lowdisk,nokey,baddns` for tests | TC-026 |
| `backup-now [NAME=]` | `run --rm backup backup.sh --kind manual` → every remote in `BACKUP_REMOTES` | TC-011 |
| `restore BACKUP=latest\|<name> [FROM=<remote>] [AGE_KEY=path]` | Confirm → stop `n8n-*` → fetch (first remote holding it, or `FROM`) + decrypt → compare bundle key with `.env` (offer to write) → `pg_restore --clean --if-exists` → `up -d --wait` → smoke | TC-012 |
| `restore-test` | `exec backup restore-test.sh` (§13) | TC-012/013 |
| `upgrade N8N_VERSION=x` | Guard x > current → `backup-now NAME=pre-upgrade-<old>-<x>` → save `versions.env` to `.upgrade/previous.env` → `pin N8N_VERSION=x` → pull → `up -d --wait n8n-main` (migrations alone) → `up -d --wait` rest → smoke; failure prints `make rollback` | TC-014 |
| `rollback` | Restore `versions.env` from `.upgrade/previous.env` → `down n8n-*` → `restore BACKUP=pre-upgrade-… --yes` → `up -d --wait` → smoke | TC-015 |
| `scale-workers N=` | 1 ≤ N ≤ 16; set `WORKER_REPLICAS`; render; `up -d --wait --remove-orphans`; verify N `/healthz` + N worker targets | TC-007 |
| `loadtest N=200 [P=20]` | Parallel POSTs to the smoke webhook; status histogram; poll executions until N succeeded; elapsed + peak `queue_jobs_waiting` | demo 6 |
| `chaos SCENARIO=worker\|redis\|main` | §15 S8 | TC-008/009/010 |
| `import-template NAME=` / `export-workflows [OUT=]` | `n8n import:workflow` via exec n8n-main + public-API activate / `export:workflow --backup` + `export:credentials --backup` → `./backups/exports/<ts>/` | TC-021 / — |
| `ui-auth USER=` | `caddy hash-password` → `UI_BASIC_AUTH_*`, `UI_PROTECT=on`, caddy reload | TC-019 |
| `trust-ca` | Caddy root CA → `compose/.smoke/root.crt` (0644) + host trust store (`update-ca-certificates` / `update-ca-trust`); copies to `/mnt/c/Users/$USER/Downloads/` when running under WSL; prints the `scp` + Windows `certutil -addstore -f ROOT` lines for a remote browser | dev |
| `lint` | hadolint, shellcheck, yamllint, `compose config -q`, `caddy validate`, `mkdocs build --strict` | CI |
| `bootstrap-test` | `tests/bootstrap/test-in-container.sh` (`ubuntu:24.04` + `ubuntu:26.04` + `rockylinux:9`) | bootstrap |
| `version` / `env-keys` / `detach-recovery-key` / `clean` (prompts; deletes volumes) | Utilities | bug template |

## 12. Smoke suite and CI

`tests/smoke/run.sh` runs `NN-*.sh` in order; `lib.sh` provides `req` (curl with `--cacert .smoke/root.crt --fail-with-body`, cookie jar), `wait_for`, `assert_eq`, `compose`. State lives in `compose/.smoke/` (gitignored, 600). Fails fast; prints a PASS/FAIL table.

| Script | Asserts | TC |
| --- | --- | --- |
| `01-health.sh` | Every expected service running + healthy ≤ 180 s; worker count = `WORKER_REPLICAS` | TC-003 |
| `02-tls.sh` | `http://` → 308 → https 200; HSTS / nosniff / X-Frame-Options; chain validates (dev CA or system); `/healthz` → `X-Kit-Upstream: n8n-main:5678`; `/healthz/webhook` → `n8n-webhook-*` | TC-004 |
| `03-owner.sh` | `GET /rest/settings` → if first load: `POST /rest/owner/setup {email,firstName,lastName,password}` (saved to `.smoke/owner.env`); `POST /rest/login {emailOrLdapLoginId,password}` → cookie; `GET /rest/api-keys/scopes` → `POST /rest/api-keys {label:"kit-smoke",scopes,expiresAt:null}` → `data.rawApiKey` → `.smoke/api-key` | setup |
| `04-webhook-routing.sh` | `POST /api/v1/workflows` from `fixtures/wf-webhook-echo.json` (Webhook path `kit-smoke-<nonce>`, `responseMode: lastNode`, Set node echoing `body.ping` + `$execution.id`); `POST /api/v1/workflows/{id}/activate` (2.x publish); `POST https://DOMAIN/webhook/kit-smoke-<nonce>` echoes nonce with `X-Kit-Upstream ~ ^n8n-webhook-[0-9]+:5678$`; `POST /webhook-test/…` with no listener → 404 from n8n-main | TC-005 |
| `05-execution-on-worker.sh` | `GET /api/v1/executions?workflowId&status=success` → 1 ≤ 60 s; worker logs contain the execution id (exact string captured in S4); main `/metrics` `n8n_scaling_mode_queue_jobs_completed` +≥1; `valkey-cli --scan --pattern 'n8n:*'` non-empty; Postgres `execution_entity.status='success'` | TC-006 |
| `06-metrics.sh` | main + each worker `/metrics` expose `n8n_` + queue gauges; Caddy `caddy_http_requests_total` | TC-017 part |
| `07-backup.sh` (M1) | `make backup-now` → object present on every remote in `BACKUP_REMOTES` under `manual/`; decrypt with host key → tar holds `db.dump` (PGDMP magic), `key-bundle.env` with key = `.env`, `manifest.json` sha256s | TC-011 |
| `08-restore-test.sh` (M1) | `make restore-test` exit 0; report: `workflow_count ≥ 1`, `credential_decrypt: ok`, `restore_test_last_success_timestamp_seconds` updated | TC-012/013 |

### GitHub Actions workflows

| Workflow | Trigger | Steps |
| --- | --- | --- |
| `ci.yml` (ubuntu-24.04) | Every PR | lint → smoke (`/etc/hosts` entry for `n8n.localtest.me` + `kuma.`; `make init DOMAIN=n8n.localtest.me CI=1`; `make up --wait-timeout 300`; `make smoke`; `make restore BACKUP=latest --yes` + `make smoke ONLY=04,05`; logs artifact on failure) → `smoke-monitoring` (separate job: Prometheus targets all up, Grafana `/api/health`, 3 dashboards) |
| `bootstrap-matrix.yml` | Weekly + on `scripts/**` | `bootstrap-host.sh --no-start` inside `ubuntu:24.04`, `ubuntu:26.04` and `rockylinux:9` containers (package install + `docker --version` + `docker compose version`; daemon start skipped) |
| `weekly-latest-n8n.yml` | Monday 02:00 UTC | Resolve the latest stable tag from the GitHub Releases API (never the `latest` docker tag, keeps runners equal) → `make pin N8N_VERSION=$v` → smoke; failure → `gh issue create --label n8n-upstream` |
| `docs.yml` | PR / main | `mkdocs build --strict` on PR; Pages deploy on main |

## 13. Backups (multi-target, encrypted, restore-tested)

### Image (`compose/backup/Dockerfile`)

`FROM postgres:18-alpine@sha256:…` → `apk add --no-cache bash jq curl tzdata openssl` → age 1.3.2, rclone 1.75.1, supercronic 0.2.49 release tarballs with `sha256sum -c` → `COPY *.sh /opt/backup/` → `USER 70` → entrypoint renders the crontab from `*_SCHEDULE` and `exec supercronic -passthrough-logs`. The same image runs one-shots via `compose run --rm backup <script>`.

### `backup.sh [--kind daily|manual|pre-upgrade] [--name N]`

1. `pg_dump -Fc -Z6` → `db.dump`.
2. `key-bundle.env` (`N8N_ENCRYPTION_KEY`, `N8N_VERSION`, `DOMAIN`, DB user/db, kit version).
3. Optional `binary.tar` (`BACKUP_INCLUDE_BINARY=true`).
4. `manifest.json` (ts, versions, sizes, sha256s).
5. `tar czf - . | age -r $BACKUP_AGE_PUBLIC_KEY -r $BACKUP_AGE_RECOVERY_PUBLIC_KEY > n8n-<ts>.tar.gz.age`.
6. For each remote in `BACKUP_REMOTES`: `rclone copyto` to `<remote>/<kind>/` (+ `monthly/` on day 1); retention `rclone delete --min-age` (daily/monthly only; manual + pre-upgrade kept); per-remote result recorded.
7. Overall status = success only if every remote succeeded (partial success → WARN + Telegram).

Local/external disk targets are plain paths (`/backups/local`, `/backups/external`); rclone treats them as local remotes. The sidecar writes them as uid 70 (`bootstrap-host.sh`/docs show `chown 70` or `chmod 1777` for the mount).

Metrics to `/state/metrics.prom`: `backup_last_success_timestamp_seconds{remote=}`, `backup_last_size_bytes`, `backup_last_duration_seconds`, `backup_info{name,kind}`. `notify.sh` → Telegram on failure (success optional).

### `restore.sh <name|latest> [--from <remote>]` (orchestrated by `compose/scripts/restore.sh`)

`rclone lsf` across remotes (first that has it, or `--from`) → fetch → `age -d -i /run/secrets/age-key.txt` (or ad-hoc `AGE_KEY`) → sha256 verify → host stops `n8n-main n8n-webhook-* n8n-worker-* *-runners` → `dropdb --force && createdb && pg_restore --no-owner --no-privileges` → key diff vs `.env` (prompt / `--yes`) → `up -d --wait` → smoke. Order = official guidance (stop → key → DB → start).

### `restore-test.sh` (Sunday 03:00)

Fetch latest daily → decrypt → `initdb /tmp/scratch` → `pg_ctl start -p 5499 -k /tmp` → `pg_restore` → counts of `workflow_entity`, `credentials_entity` → decrypt one credential with the bundle key via `openssl enc -d -aes-256-cbc -md md5 -pass pass:$KEY -base64 -A` (n8n's cipher is OpenSSL `Salted__` compatible — verify in S5; fallback: scratch `n8n export:credentials --decrypted` container) → `jq -e type` → stop → metrics (`restore_test_last_success_timestamp_seconds`, `restore_test_last_status`, `restore_test_workflow_count`) + JSON report → Telegram "Restore test OK: 12 workflows, 5 credentials, 42 MB, 38 s" / FAILED (TC-013).

### `cert-check.sh` (hourly)

`openssl s_client -connect caddy:443 -servername $DOMAIN` → `cert_expiry_timestamp_seconds` (feeds the < 14 d alert without a blackbox exporter).

## 14. Monitoring (profile `monitoring`)

| Component | Configuration |
| --- | --- |
| Prometheus 3.5 LTS | `--storage.tsdb.retention.time=${PROM_RETENTION}`, `retention.size=2GB`; jobs `n8n-main`, `n8n-webhook` (static), `n8n-worker` (`file_sd` from `targets/n8n.json` — no docker socket), `caddy` (internal-only site `:2020 { metrics }`), `node-exporter:9100` (`--collector.textfile.directory=/state`), `cadvisor:8080`, self; 15 s scrape |
| Loki 3.7 | Single binary; schema v13 tsdb, filesystem, `retention_enabled`, `retention_period: ${LOKI_RETENTION}`, `auth_enabled: false` |
| Alloy 1.17 | `/var/run/docker.sock:ro`; `discovery.docker` → `discovery.relabel` (service, project, container from compose labels) → `loki.source.docker` → `loki.process` (`stage.json` for n8n level/message, Caddy status/upstream; `stage.labels {level}`) → `loki.write` |
| node-exporter / cAdvisor | `pid: host`, `/:/host:ro,rslave`; cAdvisor standard ro mounts |
| Uptime Kuma 2 | Monitors `https://DOMAIN/healthz`, `/healthz/webhook`, `/` keyword "n8n"; public status page optional; configured in UI, documented |
| Grafana 13 | `GF_SERVER_ROOT_URL=https://${DOMAIN}/grafana/`, `GF_SERVER_SERVE_FROM_SUB_PATH=true`, admin password from `.env`, sign-up off, analytics off; provisioning: datasources (uids `prometheus`, `loki`), dashboards dir, alerting (Telegram contact point from `$ALERT_TELEGRAM_*`, root policy, `group_wait 30s`, `repeat_interval 4h`), rules folder "n8n-kit", eval 30 s |

### Alert rules

| Alert | Expr | for |
| --- | --- | --- |
| N8nUIDown | `up{job="n8n-main"} == 0` | 2m |
| WebhookPoolDown | `sum(up{job="n8n-webhook"}) == 0` | 1m (fires < 3 min, TC-018) |
| WorkerMissing | `count(up{job="n8n-worker"} == 0) > 0` | 5m |
| QueueBacklog | `n8n_scaling_mode_queue_jobs_waiting > 500` | 5m |
| ExecutionFailureRate | `increase(failed[15m]) / clamp_min(increase(completed[15m]) + increase(failed[15m]), 1) > 0.10` (exact counter names from `/metrics` in S6) | 15m |
| BackupMissing | `time() - min(backup_last_success_timestamp_seconds) > 26*3600` or `absent(...)` | 5m |
| RestoreTestFailed | `restore_test_last_status == 0` or `time() - restore_test_last_success_timestamp_seconds > 8*86400` | 5m |
| DiskHigh | `1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes > 0.8` | 10m |
| CertExpiring | `cert_expiry_timestamp_seconds - time() < 14*86400` | 1h |
| ContainerRestarting | `changes(container_start_time_seconds{name=~"n8nkit.*"}[15m]) > 2` | 0 |

### Dashboards (built in UI, exported JSON)

- **n8n Overview** — executions/min, success vs failed, queue waiting/active, worker count, active jobs per worker, webhook RPS + 5xx (Caddy), main/worker RSS + event-loop lag, recent error logs (Loki). p95 execution duration is not exposed by n8n metrics → from Loki if the worker log carries a duration, else dropped (note the deviation from PLAN §2.12).
- **Host** — node CPU/RAM/disk/net, per-container CPU/mem, restarts.
- **Backups** — last backup age/size per remote, restore-test status/age/count, cert days left.

## 15. Build sessions (ordered)

Eleven sessions, ≈ 35 h over 2–3 weeks of evenings, take the kit from docs to a tagged v0.1.0.

| # | Goal | Files | Commands / verification | Record |
| --- | --- | --- | --- | --- |
| **S0** (3 h) | Docs + machine ready | PLAN.md (§1.6 Target C; §2.3 Valkey/Alloy/runners/PG18/multi-target backups/bootstrap; §2.5 pool paths; §2.13 tree), HANDOFF (§1 M2.5 row, §3 decisions, §4 laptop + VM, §7 answered), CHANGELOG Unreleased; §6 steps 1–8 | `ssh k8svm`; `docker run hello-world`; tool versions; `gh auth status` | Set T; "Last updated" line — docs + machine done 2026-10-07 except `gh auth login` + Windows hosts entry |
| **S1** (2 h) | Repo bootstrap | `gh repo create nhhandevops/n8n-prod-kit --public --license mit`; README.md, CLAUDE.md, .gitignore, .gitattributes, .editorconfig, lint configs, issue/PR templates, ci.yml (lint only), placeholder dirs (templates/, terraform/, k8s/ READMEs); move the 4 bundle files in | `make lint` (empty-safe); push; CI lint green; enable Pages + Dependabot | CHANGELOG "Added: repo skeleton" |
| **S2** (4 h) | Compose core + bootstrap script | versions.env, scripts/pin.sh, docker-compose.yml, caddy/\*, .env.example, scripts/{lib,init,render}.sh, minimal Makefile, scripts/bootstrap-host.sh (apt/dnf detection, Docker repo per family, EPEL on RHEL, firewalld http/https, `--no-start` flag) | `make init DOMAIN=n8n.localtest.me` (TC-001), `make pin`, `make up`, `make status` (TC-003), http→https + headers (TC-004), browser owner setup, run a Code node (proves runners), POST a webhook → `X-Kit-Upstream` (manual TC-005); `read_only` outcome per service noted | CHANGELOG "Added: compose core (n8n 2.42.3 queue mode)"; HANDOFF §5 tech debt |
| **S3** (3 h) | Operability + RHEL path | scripts/{preflight,status,doctor,scale}.sh, full Makefile, compose.dev.yml, tests/bootstrap/\*, bootstrap-matrix.yml | `python3 -m http.server 80` → preflight names the PID (TC-002); `DOCTOR_SIMULATE=…` (TC-026); `make scale-workers N=4` → 4 workers + 4 runners healthy, back to 2 (TC-007); `make bootstrap-test` green (`ubuntu:24.04`, `ubuntu:26.04`, `rockylinux:9`); the real RHEL run (SELinux/firewalld) on the host chosen in HANDOFF §7 | CHANGELOG; docs/operations/rhel-hosts.md (SELinux `:z`, firewalld, "verify on a real Rocky/Alma VPS" open item) |
| **S4** (4 h) | Smoke + CI | tests/smoke/\*, fixtures, ci.yml smoke job, weekly-latest-n8n.yml | `make smoke` green (TC-003–006 automated); CI green; worker log string + counter names captured into lib.sh | docs/compat.md first row (0.1.0-dev × 2.42.3 × date) |
| **S5** (4 h) | Backups | backup/\*, Makefile targets, smoke 07/08, CI restore step; Cloudflare R2 bucket + token (and an S3 bucket if the AWS account exists) | `BACKUP_REMOTES="/backups/local r2:…"` → `make backup-now` lands on both (TC-011); `make restore-test` (TC-012; verify openssl credential decrypt); delete a workflow → `make restore BACKUP=latest` → back, credential works; external-disk path test with a USB mount (`BACKUP_LOCAL_PATH`); CI restore job green; break a remote → Telegram failure (TC-013) | CHANGELOG; decision: two age recipients |
| **S6** (4 h) | Monitoring | monitoring/\*\*, profile services, Caddy routes, cert-check.sh, dashboards JSON | `COMPOSE_PROFILES=monitoring make up`; targets up, 3 dashboards render (TC-017); stop both webhook processors → Telegram < 3 min (TC-018); Loki shows n8n JSON logs by service | Deviation: Alloy; p95 note |
| **S7** (3 h) | Upgrade / rollback | scripts/{upgrade,rollback}.sh | Test stack pinned at previous patch (2.41.x) → `make upgrade N8N_VERSION=2.42.3`: pre-upgrade backup exists, migrations, smoke (TC-014); `SMOKE_FAIL=1` → `make rollback` → previous image + DB (TC-015) | docs/operations/upgrade-rollback.md |
| **S8** (3 h) | Chaos + loadtest | scripts/{loadtest,chaos}.sh, wf-schedule-tick.json | `make loadtest N=200` drains; `chaos SCENARIO=worker` (kill worker-1 mid-load: all N succeed exactly once, auto-restart; TC-008); `redis` (stop valkey 60 s: 5xx, then drains; TC-009); `main` (restart under load: webhooks 200 throughout, schedule resumes; TC-010) | docs/operations/chaos-drills.md |
| **S9** (4 h) | Docs site + dry run | docs/\*\*, mkdocs.yml, docs.yml, README polish, mermaid diagram | `mkdocs build --strict`; Pages live; fresh-VPS (Ubuntu 24.04, then Rocky/Alma 9) quickstart timed ≤ 15 min; recruit 3 testers (TC-025, async) | HANDOFF "Demo VPS" |
| **S10** (2 h) | M0 / M1-slice gate | CHANGELOG 0.1.0, compat.md, tag v0.1.0, GitHub Release | CI green on tag; `gh release create v0.1.0`; TC-001–018, 026 recorded | HANDOFF §1 M0 ✅ |

### Later milestones (outline only; detailed when reached)

- **M1 rest** — 5 templates with README / test payload / template tests (TC-021/022).
- **M2** — `terraform/aws` modules (network, ecs, rds-postgres-18, elasticache-valkey, efs, alb, s3, iam, monitoring), plan-snapshot tests, weekly sandbox apply/destroy, cost table (TC-023/024).
- **M2.5** — `k8s/helm/n8n-kit`: Deployments main/webhook/worker with runners as in-pod sidecar containers (`N8N_RUNNERS_TASK_BROKER_URI=http://localhost:5679`), Valkey StatefulSet (`valkey/valkey` image, no Bitnami), CloudNativePG Cluster or external DB, Ingress + cert-manager, KEDA scaler on the Bull wait list, `helm lint` / `helm template` snapshots + kind install in CI, kind on the VM `server1` for dev (stop the neighbouring projects first — RAM).
- **M3** — launch posts, "need help?" section.

## 16. Verification summary

| Layer | What runs | When |
| --- | --- | --- |
| Static | shellcheck, hadolint, yamllint, `compose config`, `caddy validate`, `mkdocs --strict` (later `terraform fmt/validate`, `helm lint`) | Every PR |
| Compose smoke | GitHub Actions, `n8n.localtest.me`, `tls internal`: TC-001, 003–006, 011–012 (+ full restore round-trip) | Every PR |
| Bootstrap matrix | `ubuntu:24.04` + `ubuntu:26.04` + `rockylinux:9` containers; one real AlmaLinux 9 VM / Rocky VPS run before claiming RHEL support | Weekly / on change / before tags |
| Latest-n8n smoke | Auto-issue on failure | Weekly |
| Manual drills (this desktop) | `make chaos` (TC-008–010), `make upgrade`/`rollback` (TC-014/015), `make restore-test` (TC-013), `make doctor` simulations (TC-026) | Per session |
| M0 gate | 3 people complete `docs/quickstart.md` on a fresh VPS in ≤ 15 min without questions (TC-025) | Once |

## 17. Risks and gotchas

| Area | Gotcha | Handling |
| --- | --- | --- |
| Runners version lock | Both images read `${N8N_VERSION}` | pin/upgrade update both digests; doctor fails on mismatch; weekly job resolves the version from GitHub Releases, never the `latest` tag |
| Explicit services vs `deploy.replicas` | Runners pair 1:1; Caddy dynamic `a` lacks active health checks | `scale-workers` renders a file; documented |
| Valkey + Bull | Eviction = lost jobs | `noeviction` mandatory; AOF `everysec` → ≤ 1 s loss; watch first-run logs for unsupported-command errors (none expected) |
| Postgres 18 volume path | `/var/lib/postgresql` (not `…/data`); wrong path silently loses data on recreate | Pinned in compose; `pg_dump` client ≥ server → backup image from the same base |
| uid 1000 + volumes | Named volumes fine; bind mounts need `chown 1000`; `read_only: true` on n8n may need extra tmpfs (`/home/node/.cache`) | Test in S2, fall back per service. Postgres runs uid 70 |
| RHEL hosts | SELinux enforcing needs `:z` on bind mounts; firewalld must allow http/https; Docker's centos repo serves Rocky/Alma; age/shellcheck from EPEL only for dev boxes (servers need only docker/make/jq/curl/git) | SELinux cannot be exercised in containers or on the Ubuntu VM → one real AlmaLinux 9 VM / Rocky VPS run (HANDOFF §7) |
| Shared dev VM: ports 80/443 | Host nginx and nginx-proxy-manager own them on `server1` | `HTTP_PORT=8080 HTTPS_PORT=8443`; preflight names the PID; 80/443 + ACME are exercised on the demo VPS only |
| `localtest.me` inside containers / from Windows | Resolves to the container itself; router DNS-rebind protection; the Windows browser must reach the VM IP; the VM's `/etc/hosts` currently maps it to `::1` | `compose.dev.yml` `extra_hosts` host-gateway + `NODE_EXTRA_CA_CERTS`; Windows hosts entry `<vm-ip> n8n.localtest.me kuma.n8n.localtest.me`; VM `/etc/hosts` → `127.0.0.1`; CI writes `/etc/hosts` |
| CI RAM/CPU | Core ≈ 3.5 GB, with monitoring ≈ 5 GB on a 16 GB / 4 vCPU runner | `--wait-timeout 300`; monitoring smoke in its own job |
| Routing correctness | With `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` main serves only `*-test/*` | Pool match must include `/form/*`, `/mcp/*`, `/*-waiting/*` and must not include `*-test/*`; `N8N_ENDPOINT_*` overrides break the Caddyfile → doctor check + docs |
| Migration race | Webhooks/workers start before migrations finish | `depends_on` main healthy; upgrade starts main alone first |
| Let's Encrypt rate limits | Mis-pointed DNS burns attempts | preflight DNS/IP check; `TLS_MODE=acme-staging` for the first prod run |
| Credential decrypt check | Relies on n8n's OpenSSL-compatible cipher | Fallback is a scratch n8n container |
| 2.x Save/Publish | Workflows must be published to receive webhooks | Smoke activates via public API; API keys need explicit scopes |
| Grafana sub-path | `GF_SERVER_SERVE_FROM_SUB_PATH=true` | Caddy `handle` must not strip the prefix |
| Docker socket | Only Alloy (ro) | Prometheus uses `file_sd` |
| CRLF | Windows line endings break scripts | `.gitattributes` forces LF; `core.autocrlf=false`; always clone and edit inside the VM (Remote-SSH), the Windows folder is read-only |
| Caddy as root | `cap_drop ALL` + `NET_BIND_SERVICE` | The one documented non-root exception |
| Multi-target backup semantics | Success = all remotes OK | Partial = WARN + alert, not silent; a missing external disk (`BACKUP_LOCAL_PATH` unmounted) is caught by preflight/doctor, not at 02:00 |
| Two-recipient age | Recovery key left on the host | > 7 days → doctor warning; `detach-recovery-key` prints it once and shreds it |
| `compose up --wait` | Fails on exited one-shots | Backup is a long-running cron service |
| Caddy PKI permissions | Caddy writes `pki/authorities/local/` as root 0700/0600; the n8n containers (uid 1000) and backup (uid 70) cannot read `root.crt` from the `caddy_data` mount → `NODE_EXTRA_CA_CERTS` silently fails, self-calls to `https://n8n.localtest.me` break | `make init`/`make trust-ca` export `root.crt` (0644) into `secrets/` and mount only that file; verify in S2 |
| `kuma.{$DOMAIN}` site block | Present even without the monitoring profile → on a real host Caddy requests an ACME cert for a name that may have no DNS record (rate-limit burn, log noise) | Include the block only via `import /etc/caddy/kuma-{$KUMA_ENABLED:off}.caddy` set by the profile, and preflight resolves `kuma.DOMAIN` when it is on |
| Ubuntu 26.04 hosts | Docker's apt repo has `resolute` (Engine 29.8, Compose 5.6 on 2026-10-07), but the kit was drafted for 24.04 | `bootstrap-host.sh` accepts both; CI matrix runs both; quickstart names 24.04 LTS as the reference VPS image |
| VM disk growth | `server1.vmdk` is growable to 80 GB on a D: with 18 GB free | Keep D: ≥ 10 GB free (prune Docker in the VM first); move the VM folder to K: if needed |

## 18. First actions after approval

1. **S0 docs** [done 2026-10-07]: PLAN.md / HANDOFF.md / CHANGELOG.md carry the §3 decisions, Target C scope, the laptop + VM in the machines table, and HANDOFF §7 answered.
2. **S0 machine** [done 2026-10-07 except two manual items]: VM at 7 GB, Docker pruned, dev tools installed, git defaults set, Remote-SSH installed. An: `gh auth login` + `gh auth setup-git` in the VM, and the Windows hosts entry from §6 step 7 (admin).
3. **S1:** in the VM, `mkdir -p ~/src/n8n-prod-kit && git init`, copy the 4 bundle files in, first Conventional Commit, `gh repo create nhhandevops/n8n-prod-kit --public --source . --push`, CI lint green. Ask An before the repo goes public.
