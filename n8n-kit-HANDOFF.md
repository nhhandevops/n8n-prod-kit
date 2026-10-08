# n8n-kit-HANDOFF.md — n8n Production Kit

> **Read this first on every machine, every session. Update it last, then `git push`.**
> If it is not in git, it does not exist. This file is the only shared memory between computers and between AI coding sessions.

**Last updated:** 2026-10-08 (S4 done) · **By:** Claude with An · **Machine:** laptop + VM `server1` · **Branch:** `main` · **Last commit:** see `git log -1` (the hand-off commit "docs(handoff): …") · **Project start date (T):** 2026-10-07 (day of the first public push)

> **Picking this up on another computer?** `git pull` → read §2 "Next up" (S5 is next) → §4 "How to resume" (generic steps for any Linux / WSL2 / VM host) → `n8n-kit-BUILD-PLAN.md` §13 + §15 for the S5 details. Nothing is in progress and nothing is uncommitted.

---

## 0. The protocol (do not skip)

**Start of session:** `git pull` → read this file → check Blockers and In progress → `make lint` and, on a machine with a dev stack, `make -C compose up && make -C compose status && make -C compose doctor && make -C compose smoke`.
**End of session:** run the relevant tests (`make -C compose smoke`, `terraform validate`) → commit (Conventional Commits) on a pushed branch → update `n8n-kit-CHANGELOG.md` Unreleased → update sections 1, 2, 3, 5 here + the "Last updated" line → `git push`.
**AI agents:** same protocol. This repo is **public**: never paste real domains, IPs, keys, or anything from An's work infrastructure into code, docs, examples, or this file. Use `example.com` and generated values.

---

## 1. Current status (one glance)

| Milestone | Target | State |
|---|---|---|
| M0 · Compose kit (fresh VPS ≤ 15 min) | T + 2 weeks | 🔄 S4 of S10 done (compose core, doctor/scale/read-only, smoke suite + CI smoke); S5–S10 pending |
| M1 · Batteries (backups, monitoring, runbooks, 5 templates) | T + 5 weeks | ⬜ |
| M2 · Terraform AWS | T + 8 weeks | ⬜ |
| M2.5 · Kubernetes Helm chart (Target C) | T + 10 weeks | ⬜ |
| M3 · Public launch (docs site, posts) | T + 3 months | ⬜ |
| M4 · Business (setups + retainers) | T + 6 months | ⬜ |

**Health:** S0–S4 complete 2026-10-08 — `make smoke` green on the VM and on GitHub Actions (every PR now boots the stack and runs the suite twice) — `compose/` runs: 10 services healthy on the build VM, webhook→worker→runner round-trip verified, `make lint` green · **Demo VPS:** _none_ · **Pinned n8n version:** 2.42.4 (+ `n8nio/runners:2.42.4`, digests in `compose/versions.env`) — check for a newer 2.x stable at the start of S4 (`gh api repos/n8n-io/n8n/releases/latest --jq .tag_name`; then `make -C compose pin N8N_VERSION=x`)

**Hand-off test run (2026-10-07, HEAD cf388ca, build VM): 18/18 PASS** — `make lint`; `make up` (96 s, 10/10 healthy); `make status`; `make doctor` (0 FAIL, 1 expected warn: backups not configured yet); `DOCTOR_SIMULATE` exits non-zero with injected FAILs; http→https redirect keeps the dev port; UI/API/`*-test` paths → n8n-main and production paths → webhook pool (`X-Kit-Upstream`); security headers present, `Server` removed; webhook → queue → worker → runner Code-node round trip; `scale-workers N=3` (generated worker-3 read-only) and back to 2; every container read-only, zero EROFS/EACCES in logs; `make down`; GitHub `ci` and `bootstrap-matrix` (6/6 distros) green.

---

## 2. Work log

### ✅ Done
- 2026-10-08 · **S4 smoke suite + CI shipped** (9f88b4c, 7b0bc5a): `tests/smoke/` (run.sh, lib.sh, 01-health, 02-tls, 03-owner, 04-webhook-routing, 05-execution-on-worker, 06-metrics, fixtures) → `make smoke [ONLY=04,05]`, ~30 s on the VM, idempotent; `ci.yml` smoke job (`tests/ci/up.sh`: init + up + doctor on the runner with quota-free registry mirrors, smoke ×2, `tests/ci/collect-logs.sh` artifact on failure) — first run green: lint 32 s, smoke 171 s on ubuntu-24.04 with ports 80/443 and Docker 28 / Compose 2.38 (run 37724038543); `weekly-latest-n8n.yml` (manual run: green — resolved n8n 2.42.4, pinned, smoke 6/6, no issue opened (run 37724372755)); `docs/compat.md`. **Security fix:** n8n-main's Prometheus endpoint was public at `https://DOMAIN/metrics` through Caddy's catch-all → now 404 (smoke 06 asserts it). TC-003…006 automated.
- 2026-10-07 · **S3 operability + RHEL path shipped**: `make doctor` (TC-026 with `DOCTOR_SIMULATE`), `make scale-workers N=` (TC-007: 2→4→1→2 verified, `N=1` parks the static worker-2 pair behind a Compose profile), every n8n container now `read_only` with a measured tmpfs set (/tmp, ~/.cache, ~/.npm — `docker diff` after a real workload), `docs/operations/rhel-hosts.md`, weekly `bootstrap-matrix.yml`. Hand-authored in the main loop (no agent fan-out) within one session window. `bootstrap-matrix` on GitHub Actions: 6/6 PASS (run 37643339809) after adding pull retries.
- 2026-10-07 · **S2 compose core shipped**: `compose/` (docker-compose.yml, compose.dev.yml, versions.env, Caddyfile + snippets, .env.example, scripts: lib/init/render/pin/preflight/status/dev-ca/trust-ca/lint, Makefile, README), `scripts/bootstrap-host.sh`, `tests/bootstrap/test-in-container.sh`, root `make bootstrap-test`. Verified on the VM: `make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443` → `make up` → 10/10 healthy in 2m28s; 308 redirect keeps the port; every path routes to the right upstream (`X-Kit-Upstream`); owner setup + API key + workflow publish via REST/public API; 3 webhook POSTs → 200 via the pool, executions success on workers, Code node ran in the runners sidecar; dev CA trusted by curl via `make trust-ca`. TC-001, TC-003, TC-004, TC-005 (manual) pass. Bootstrap matrix (`make bootstrap-test`): 6/6 PASS — Ubuntu 24.04/26.04, Debian 13, Rocky 9/10, Alma 9 → docker-ce 29.8.2 + compose 5.6.0, second run idempotent ≤ 1 s. Method: fact sweep (6 agents) → contract → files written by agents and by hand; the two agent authoring runs died on the 5-hour session limit, the main loop finished the make-ops group.
- 2026-10-07 · S1 repo bootstrap: public repo `nhhandevops/n8n-prod-kit` created, commit 7964709 pushed, CI lint green (run 37583413865), Dependabot alerts on, topics set. Personal details scrubbed from HANDOFF/bug log before the first push (`<vm-ip>`, `<vm-user>`).
- 2026-10-06 · Plan and docs bundle created.
- 2026-10-07 · Build host on the laptop = Ubuntu 26.04 VM `server1` in VMware (not WSL2); VM RAM raised 5 → 7 GB (`memsize = "7168"`) so the monitoring profile fits. Guest inspected: Docker 29.5.2 + Compose 5.1.4 already installed (containerd image store), `<vm-user>` in `docker` group, passwordless sudo, NTP synced, cgroup v2, AppArmor on; kubectl/helm/kind present. **Shared VM:** 5 other compose projects + host nginx run here: port 80 = host nginx, 443/81 = nginx-proxy-manager. Root disk 77 GB with 15 GB free; Docker build cache 12 GB reclaimable (0 active), unused images 6.7 GB, journal 1 GB. Missing tools: gh, age, rclone, shellcheck, yamllint, hadolint, mkdocs.
- 2026-10-07 · VM prepared for S0: Docker build cache + unused images pruned (15 → 32 GB free); installed age 1.2.1, shellcheck 0.11, hadolint 2.15.1, yamllint 1.37, rclone 1.75.1, gh 2.102, mkdocs-material (venv `~/.venvs/mkdocs`, symlink `~/.local/bin/mkdocs`); git `core.autocrlf=false`, `init.defaultBranch=main`. Decision: kit runs on **8080/8443** on this VM (80/443 belong to the other projects); 80/443 are exercised on the demo VPS. VS Code Remote-SSH installed on the laptop. Windows hosts entry added 2026-10-07 (`n8n.localtest.me` → <vm-ip> verified).
- 2026-10-07 · `gh auth login` + `gh auth setup-git` done in the VM: account `nhhandevops`, HTTPS, scopes `repo workflow read:org gist`.

### 🔄 In progress
Format: `- [machine] [branch] what · started date · where it stopped · how to verify`
_(nothing — everything is committed and pushed. The dev stack on the build VM is DOWN with its volumes and `.env` kept; `make -C compose up` restores it in ~2 min.)_

### ⏭️ Next up (ordered — details per session in `n8n-kit-BUILD-PLAN.md` §15; S0–S3 are done)
1. ~~**S4**~~ done 2026-10-08 (see Done). Original S4 notes kept below for reference:
   - `tests/smoke/run.sh` + `lib.sh` (`req`, `wait_for`, `assert_eq`; state in `compose/.smoke/`, gitignored) and `01-health.sh` … `06-metrics.sh`; `make -C compose smoke [ONLY=04,05]`.
   - Recipe already proven by hand on 2026-10-07 (S2 entry in Done): `POST /rest/owner/setup` → `POST /rest/login` (cookie) → `GET /rest/api-keys/scopes` → `POST /rest/api-keys {label, scopes, expiresAt:null}` → `data.rawApiKey` → `POST /api/v1/workflows` (Webhook + Code node) → `POST /api/v1/workflows/{id}/activate` → `POST /webhook/<path>` must answer 200 with `X-Kit-Upstream: n8n-webhook-N:5678` → `GET /api/v1/executions?workflowId=` status success. The Code node must stay pure JS (`process` is blocked in the runner sandbox).
   - `ci.yml` smoke job on ubuntu-24.04: `/etc/hosts` entry for `n8n.localtest.me` + `kuma.`, `make -C compose init DOMAIN=n8n.localtest.me CI=1`, `make up`, `make smoke`, logs artifact on failure. Docker Hub pull quota: `docker login` (repo secret) or switch `N8N_IMAGE`/`RUNNERS_IMAGE` to `ghcr.io/n8n-io/*` in CI.
   - `weekly-latest-n8n.yml` (latest stable from the GitHub Releases API → `make pin N8N_VERSION=` → smoke → `gh issue create --label n8n-upstream` on failure); `docs/compat.md` first row (0.1.0-dev × n8n 2.42.4 × 2026-10-07).
   - Watch for: the Postgres `NaN` error (§5) — does the smoke reproduce it?
2. **S5 (≈ 4 h) — backups**: `compose/backup/` sidecar (`FROM postgres:18-alpine` + age + rclone + supercronic), `backup.sh` / `restore.sh` / `restore-test.sh`, `make backup-now / restore / restore-test`, smoke 07/08, R2 bucket + token (and S3 if the AWS account exists). TC-011…013. Needs from An: Cloudflare R2 bucket + API token, Telegram bot token + chat id.
3. **S6 (≈ 4 h) — monitoring profile**: Prometheus 3.5, Grafana 13 at `/grafana/`, Loki 3.7 + Alloy, node-exporter, cAdvisor, Uptime Kuma (`KUMA_ENABLED=on`), 3 dashboards, alert rules → Telegram. TC-017/018. On the build VM stop heavy neighbour containers first (RAM).
4. **S7 (≈ 3 h)** `make upgrade` / `make rollback` (TC-014/015). **S8 (≈ 3 h)** `make loadtest` + `make chaos` (TC-008…010). **S9 (≈ 4 h)** MkDocs site + Pages + timed fresh-VPS quickstart, recruit 3 testers (TC-025). **S10 (≈ 2 h)** M0 gate: CHANGELOG 0.1.0, `docs/compat.md`, tag `v0.1.0`, GitHub Release.
5. Later milestones: M1 rest (5 templates, TC-021/022) → M2 Terraform AWS (TC-023/024) → M2.5 Helm chart → M3 launch posts → M4 business.

### 🚫 Blockers
_(none)_

---

## 3. Decisions log (newest first)

| Date | Decision | Why | Alternatives rejected |
|---|---|---|---|
| 2026-10-07 | **S2 design (after the fact sweep):** pin **n8n 2.42.4** (stable since 07:22 UTC today) + `n8nio/runners:2.42.4` (docker.n8n.io has no runners image); runners sidecars on **workers only** (main runs no broker with `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`, webhooks never need one); `N8N_DEFAULT_BINARY_DATA_MODE=database` (filesystem is unsupported in queue mode); `N8N_WEBHOOK_URL` not `WEBHOOK_URL`; Caddy runs as uid 1000 (PKI readable by n8n), `cap_add NET_BIND_SERVICE`, multi-line Caddyfile, `handle_errors` headers, container listens on the published port numbers; Valkey `user 999:1000` + shell-form command; Postgres TCP healthcheck; two-anchor YAML env merge; EL bootstrap copies the centos `.repo` file and never lists `curl` on EL9 | Every item was refuted or corrected by running the real images (see `warning_bug_and_solutions.md`, 2026-10-07 S2 entry) | The plan's literal §8–§10 values |
| 2026-10-07 | Dev/build host = Ubuntu 26.04 VM `server1` (VMware, `ssh k8svm`), kit on ports **8080/8443**; `bootstrap-host.sh` and CI matrix cover Ubuntu 24.04 **and 26.04** | Only Linux on this laptop; VM is shared with other projects that own 80/443; 26.04 is what runs here and Docker's apt repo already serves `resolute` | WSL2 + Docker Engine (plan's original), Docker Desktop, reinstalling the VM as 24.04 |
| 2026-10-06 | Pin **n8n 2.42.3** + `n8nio/runners:2.42.3`, one `${N8N_VERSION}` in `compose/versions.env` (tag + digest); every main/worker gets a 1:1 runners sidecar | 2.x requires external task runners; version lock by construction | `latest` tag; one shared runners service; `deploy.replicas` |
| 2026-10-06 | **Valkey 9.1** (`noeviction`, AOF everysec) as queue backend; Redis documented as drop-in | BSD licence, ElastiCache engine, ioredis-compatible | Redis 7/8 (tri-licensed) |
| 2026-10-06 | **Grafana Alloy** ships logs to Loki | Promtail EOL 2026-03-02 | Promtail |
| 2026-10-06 | **Postgres 18** (`postgres:18-alpine`, volume `/var/lib/postgresql`); backup image `FROM postgres:18-alpine` | n8n supports 16–18; `pg_dump` always matches server | 16 / 17 |
| 2026-10-06 | Caddy routes `/webhook/*`, `/webhook-waiting/*`, `/form/*`, `/form-waiting/*`, `/mcp/*` → webhook pool; everything else (incl. `*-test/*`) → main; `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` | Matches n8n's router | All `/webhook*` to the pool |
| 2026-10-06 | **Backups multi-target via rclone** (`BACKUP_REMOTES`: R2 / S3 / local or external disk); R2 is the demo default, S3 for Target B | 3-2-1 as a config line; R2 has free egress | Single-target script |
| 2026-10-06 | **Two age recipients**: host automation key + offline recovery key (`make detach-recovery-key`) | Unattended weekly restore test + bucket useless on its own | Single key; GPG |
| 2026-10-06 | `scripts/bootstrap-host.sh` supports apt (Ubuntu/Debian) **and** dnf (Rocky/Alma/CentOS Stream/RHEL 9–10) | User wants CentOS-family support; Rocky/Alma are the prod-grade rebuilds | CentOS-Stream-only |
| 2026-10-06 | **Target C = Kubernetes Helm chart** as milestone M2.5 (after Terraform) | User asked for Kubernetes; same topology, runners as in-pod sidecars, KEDA on queue depth | Out of scope (PLAN §1.6 original) |
| 2026-10-06 | Repo **public from day one**; Grafana at `/grafana/`, Uptime Kuma at `kuma.DOMAIN` | No-secrets discipline from commit 1; one cert/domain | Private until M0; extra ports |
| 2026-10-06 | Caddy instead of Traefik/nginx | Automatic TLS with 10-line config; fewer support questions | Traefik (more powerful, steeper learning curve) |
| 2026-10-06 | `age` for backup encryption | Simple, modern, one public key in `.env`, private key off-host | GPG (heavier), unencrypted backups (unacceptable) |
| 2026-10-06 | Terraform only for AWS in v1; Hetzner/DO variants later | Portfolio value + An's AWS SAA; VPS users have Compose already | Multi-cloud from day one |
| 2026-10-06 | MIT license, public repo | Maximum adoption and portfolio visibility; business is services, not the code | Source-available license |
| 2026-10-06 | Single-main topology documented as the limit | Multi-main is n8n enterprise; HA for webhooks/workers is enough for the target users | Pretending to support multi-main |
| 2026-10-06 | Binary data on shared volume / EFS | Works on community edition in every version | S3 mode (edition-dependent; documented as optional) |

---

## 4. How to resume on a new machine

**Any machine** (Linux host, WSL2 distro or Linux VM; always work on a Linux filesystem, never a Windows share — chmod 600 and LF line endings matter):

```bash
# 0. Docker missing? On Ubuntu 24.04/26.04, Debian 12/13, Rocky/Alma/CentOS Stream/Oracle/RHEL 9–10:
#    sudo scripts/bootstrap-host.sh            (after cloning; or: curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash)
git clone https://github.com/nhhandevops/n8n-prod-kit && cd n8n-prod-kit      # existing clone: git pull
# Dev tools for `make lint` (CI pins the same versions): shellcheck 0.11.0, yamllint, hadolint 2.15.1, jq, make; gh for CI/releases.
make lint                                     # repo + compose: shellcheck, yamllint, compose config, caddy validate x12
cd compose
make init DOMAIN=n8n.localtest.me             # add HTTP_PORT=8080 HTTPS_PORT=8443 if 80/443 are taken on this machine
make up && make status && make doctor         # ~2–3 min on first pull; expect 10 services healthy and doctor "no problems"
make trust-ca                                 # trust the dev CA on this host; prints the Windows certutil line for a browser
# Terraform (from M2): cd terraform/aws && cp terraform.tfvars.example terraform.tfvars && terraform init
```

Each machine gets its OWN `.env`, `secrets/` and volumes from `make init` — dev data is disposable, never copy a dev `.env` between machines (a production `.env`/encryption key lives only in the password manager). If 127.0.0.1 is not where the stack runs (VM, remote host), add `<host-ip> n8n.localtest.me kuma.n8n.localtest.me` to the browser machine's hosts file.

**This laptop (Windows 10 + VMware VM `server1`):** everything runs in the VM — `ssh k8svm` or VS Code → Remote-SSH → k8svm. Repo at `~/src/n8n-prod-kit`; `.env` exists (stack down, volumes kept, test owner `owner@example.com` / `KitSmoke123!`): `cd ~/src/n8n-prod-kit/compose && make up`. Ports 8080/8443 (80/443 belong to other projects on the VM); the Windows hosts entry is in place. If containers on the default bridge ever get "No route to host": `sudo ip addr add 172.17.0.1/16 dev docker0 && sudo ip link set docker0 up` (see `warning_bug_and_solutions.md`).

**Secrets (password manager only):** `n8nkit/demo-vps-ssh`, `n8nkit/backup-bucket`, `n8nkit/age-private-key`, `n8nkit/aws-sandbox`, `n8nkit/alert-telegram`. None of these ever go in the repo.

**Machines**

| Machine | OS | Role | Notes |
|---|---|---|---|
| Laptop (4c/8t, 16 GB) | Win 10 Pro + VMware Workstation 25 → VM `server1`: Ubuntu 26.04 LTS, 4 vCPU, 7 GB, NAT `<vm-ip>`, ssh alias `k8svm` | Dev / build host (replaces the WSL2 plan on this machine) | VM disk is a growable vmdk capped at 80 GB (72 GB already allocated, on D:, which has 18 GB free); K: is a USB SSD with 202 GB free. Windows browser needs a hosts entry `<vm-ip> n8n.localtest.me kuma.n8n.localtest.me`. Docker apt repo has `resolute` (Engine 29.8.2, Compose 5.6.0 on 2026-10-07) |
| Work laptop | Windows (WSL2) | Dev | Existing local n8n stack uses default ports → run the kit with `COMPOSE_PROJECT_NAME=n8nkit` and the port overrides in `.env.example` |
| ThinkPad T440 | Linux | Dev / long-running test host | Good for soak tests and chaos drills |
| Demo VPS | Ubuntu 24.04 | Fresh-install demos, quickstart testing | Rebuild from scratch regularly; it is a test subject, not prod |
| AWS sandbox | — | Terraform apply/destroy | Budget alarm at $20/month; always `destroy` after tests |

**Conventions:** bash scripts `set -euo pipefail` + `shellcheck` clean; YAML 2-space; Terraform fmt; docs in English with a Vietnamese quickstart translation; Conventional Commits; kit versions `v0.x.y`.

---

## 5. Known issues / tech debt
- Shared `/home/node/.n8n` volume: `crash.journal` is shared too, so a process starting while another runs logs "Last session crashed" once; evaluate per-role volumes vs community-node sharing (open; harmless so far).
- Postgres logs `invalid input syntax for type integer: "NaN"` twice per smoke run (VM and GitHub runner alike) from an n8n-internal paginated executions query around webhook executions; NOT from any public API call (bisected). Harmless — smoke 04 warns; report upstream with the statement (bug log 2026-10-08).
- Code nodes run in a network-less sandbox without `fetch`; `this.helpers.httpRequest` works (executed by the worker) — verified by smoke 05. Template authors must use the helper or an HTTP Request node (S5+ templates).
- Docker Hub anonymous pull quota (100/h per IP) bites shared hosts: `pin.sh` has a Hub-API fallback; CI pulls from ghcr.io / public.ecr.aws mirrors with the same digests (`tests/ci/up.sh`). Users on shared IPs may need `docker login`.
- `make lint` runs `caddy validate` 12× in a container (~15 s); fine locally, keep an eye on CI time.
- `make doctor` cannot check certificate expiry in `TLS_MODE=internal` (12 h leaf certs are normal there) — it reports the mode instead; ACME modes are checked.
- n8n allows 5 `/rest/login` attempts per window per IP (429 + Retry-After, not configurable); scripts must reuse sessions/API keys (the smoke suite does).
- Build-process lesson: a 20-agent workflow cannot survive the 5-hour session limit; author with ≤ 6 agents per run or by hand, and keep each run resumable.

## 6. Weekly notes (3 lines max per week)
- **Week of 2026-10-06:** Plan done. Decide start date relative to SoBan progress; the kit's Compose base can be built alongside SoBan's Phase A infra.
- **2026-10-08:** S4 shipped: smoke suite + CI smoke job green on GitHub; found and closed a public `/metrics` exposure. Next: S5 backups (needs R2 + Telegram from An).
- **2026-10-07:** S0–S3 shipped in one day (repo public, compose core running, doctor/scale/read-only, bootstrap matrix green on GitHub). Lesson: hand-author in the main loop; big agent fan-outs die on the 5-hour session limit. Next: S4 smoke suite + CI.

## 7. Questions for An (AI agents: add here instead of guessing)
- Browser check wanted when convenient (this laptop): in the VM `make -C ~/src/n8n-prod-kit/compose up`; on Windows `scp k8svm:~/n8nkit-root.crt $env:USERPROFILE\Downloads\` then (admin) `certutil -addstore -f ROOT $env:USERPROFILE\Downloads\n8nkit-root.crt`, open https://n8n.localtest.me:8443/ and log in as owner@example.com / KitSmoke123! (test owner created by the S2 verification; `make clean` wipes it).
- For S5: create the Cloudflare R2 bucket `n8n-backups` + an S3-API token scoped to it, and a Telegram bot (@BotFather) + chat id — store all in the password manager.
- ~~Pin which n8n version at start?~~ → **2.42.4** (2.42.3 decided 2026-10-06; 2.42.4 became stable on 2026-10-07 and is pinned).
- ~~Which S3-compatible backup target for the demo?~~ → **Cloudflare R2** default, AWS S3 for Target B, both supported via `BACKUP_REMOTES`.
- Where to verify the RHEL path with real SELinux/firewalld (not possible in containers)? Options: small AlmaLinux 9 VM on the laptop's external SSD, or a one-off Rocky 9 VPS. Still open — decide before S9 (the install path is already verified in containers).
- ~~Set **T**~~ → T = 2026-10-07 (first public push). Planned M0 = 2026-10-21; realistic M0 ≈ early November 2026 (35 h of evenings + 3 outside testers).
