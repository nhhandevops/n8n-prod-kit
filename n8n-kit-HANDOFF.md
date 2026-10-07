# n8n-kit-HANDOFF.md — n8n Production Kit

> **Read this first on every machine, every session. Update it last, then `git push`.**
> If it is not in git, it does not exist. This file is the only shared memory between computers and between AI coding sessions.

**Last updated:** 2026-10-07 (S1 done) · **By:** Claude with An · **Machine:** laptop + VM `server1` · **Branch:** `main` · **Last commit:** 7964709 (chore: repo skeleton) · **Project start date (T):** 2026-10-07 (day of the first public push)

---

## 0. The protocol (do not skip)

**Start of session:** `git pull` → read this file → check Blockers and In progress → `make -C compose smoke` (once it exists).
**End of session:** run the relevant tests (`make -C compose smoke`, `terraform validate`) → commit (Conventional Commits) on a pushed branch → update `n8n-kit-CHANGELOG.md` Unreleased → update sections 1, 2, 3, 5 here + the "Last updated" line → `git push`.
**AI agents:** same protocol. This repo is **public**: never paste real domains, IPs, keys, or anything from An's work infrastructure into code, docs, examples, or this file. Use `example.com` and generated values.

---

## 1. Current status (one glance)

| Milestone | Target | State |
|---|---|---|
| M0 · Compose kit (fresh VPS ≤ 15 min) | T + 2 weeks | ⬜ not started |
| M1 · Batteries (backups, monitoring, runbooks, 5 templates) | T + 5 weeks | ⬜ |
| M2 · Terraform AWS | T + 8 weeks | ⬜ |
| M2.5 · Kubernetes Helm chart (Target C) | T + 10 weeks | ⬜ |
| M3 · Public launch (docs site, posts) | T + 3 months | ⬜ |
| M4 · Business (setups + retainers) | T + 6 months | ⬜ |

**Health:** S0 + S1 complete 2026-10-07 — repo public at https://github.com/nhhandevops/n8n-prod-kit, CI lint green · **Demo VPS:** _none_ · **Pinned n8n version:** 2.42.3 (+ `n8nio/runners:2.42.3`) — re-check latest stable on the day S2 starts

---

## 2. Work log

### ✅ Done
- 2026-10-07 · S1 repo bootstrap: public repo `nhhandevops/n8n-prod-kit` created, commit 7964709 pushed, CI lint green (run 37583413865), Dependabot alerts on, topics set. Personal details scrubbed from HANDOFF/bug log before the first push (`<vm-ip>`, `<vm-user>`).
- 2026-10-06 · Plan and docs bundle created.
- 2026-10-07 · Build host on the laptop = Ubuntu 26.04 VM `server1` in VMware (not WSL2); VM RAM raised 5 → 7 GB (`memsize = "7168"`) so the monitoring profile fits. Guest inspected: Docker 29.5.2 + Compose 5.1.4 already installed (containerd image store), `<vm-user>` in `docker` group, passwordless sudo, NTP synced, cgroup v2, AppArmor on; kubectl/helm/kind present. **Shared VM:** 5 other compose projects + host nginx run here: port 80 = host nginx, 443/81 = nginx-proxy-manager. Root disk 77 GB with 15 GB free; Docker build cache 12 GB reclaimable (0 active), unused images 6.7 GB, journal 1 GB. Missing tools: gh, age, rclone, shellcheck, yamllint, hadolint, mkdocs.
- 2026-10-07 · VM prepared for S0: Docker build cache + unused images pruned (15 → 32 GB free); installed age 1.2.1, shellcheck 0.11, hadolint 2.15.1, yamllint 1.37, rclone 1.75.1, gh 2.102, mkdocs-material (venv `~/.venvs/mkdocs`, symlink `~/.local/bin/mkdocs`); git `core.autocrlf=false`, `init.defaultBranch=main`. Decision: kit runs on **8080/8443** on this VM (80/443 belong to the other projects); 80/443 are exercised on the demo VPS. VS Code Remote-SSH installed on the laptop. Windows hosts entry added 2026-10-07 (`n8n.localtest.me` → <vm-ip> verified).
- 2026-10-07 · `gh auth login` + `gh auth setup-git` done in the VM: account `nhhandevops`, HTTPS, scopes `repo workflow read:org gist`.

### 🔄 In progress
Format: `- [machine] [branch] what · started date · where it stopped · how to verify`
_(nothing)_

### ⏭️ Next up (ordered)
1. ~~S1 finish~~ done 2026-10-07. GitHub Pages gets enabled in S9 together with `docs.yml`.
2. S2 — `compose/`: `versions.env` + `scripts/pin.sh`, `docker-compose.yml` (caddy, n8n-main + runners, n8n-webhook-1/2, n8n-worker-1/2 + runners, postgres 18, valkey, backup placeholder), `caddy/*`, `.env.example`, `scripts/{lib,init,render}.sh`, minimal Makefile, `scripts/bootstrap-host.sh` (apt/dnf). Re-typed with generic values, never copied from real config. On this VM: `HTTP_PORT=8080 HTTPS_PORT=8443`.
3. `compose/.env.example` + `make init` (generates key/passwords, 600 perms) + `make preflight` + `make status`. TC-001…TC-004.
4. Smoke suite `tests/smoke/*.sh` (login, webhook roundtrip, execution on worker, metrics). TC-005/006. GitHub Actions runs it on every PR.
5. Backups: `backup/backup.sh` (pg_dump + key bundle → age → S3/R2), `restore.sh`, `restore-test.sh`, cron sidecar. TC-011…TC-013.
6. Monitoring: Prometheus, Grafana provisioning (3 dashboards), Loki/Promtail, Uptime Kuma, alert rules → Telegram. TC-017/018.
7. `make upgrade` / `make rollback` / `make scale-workers` / `make doctor`. TC-014/015/026.
8. Chaos script `make chaos` + TC-008/009/010.
9. Docs site (MkDocs Material): quickstart, architecture (diagram), operations runbooks, security checklist, sizing table. Have 3 people run the quickstart (TC-025) → **M0/M1**.
10. First 5 templates with README + test payload + template tests: `zalo-form-notify`, `vietqr-payment-link`, `sheets-order-log`, `gchat-approval`, `ai-faq-bot`. TC-021/022.
11. Terraform AWS modules; `plan` snapshot tests; weekly sandbox `apply`/`destroy`; cost table. TC-023/024 → **M2**.
12. Weekly `latest-n8n` workflow + `docs/compat.md`.
13. Launch: LinkedIn post, r/n8n, Viblo article (Vietnamese), dev community groups; add "Need help deploying? → contact" section → **M3**.

### 🚫 Blockers
_(none)_

---

## 3. Decisions log (newest first)

| Date | Decision | Why | Alternatives rejected |
|---|---|---|---|
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

```bash
# On this laptop: everything runs inside the VM — `ssh k8svm` (or VS Code → Remote-SSH → k8svm). Clone on the VM's ext4, never on a Windows share.
ssh k8svm
mkdir -p ~/src && cd ~/src && gh repo clone nhhandevops/n8n-prod-kit && cd n8n-prod-kit/compose
make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443   # internal TLS; 80/443 belong to the other projects on this VM
make preflight && make up && make status && make smoke
# Windows hosts file (admin): <vm-ip> n8n.localtest.me kuma.n8n.localtest.me → https://n8n.localtest.me:8443
# Terraform: cd terraform/aws && cp terraform.tfvars.example terraform.tfvars && terraform init
```

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
_(none yet)_

## 6. Weekly notes (3 lines max per week)
- **Week of 2026-10-06:** Plan done. Decide start date relative to SoBan progress; the kit's Compose base can be built alongside SoBan's Phase A infra.

## 7. Questions for An (AI agents: add here instead of guessing)
- ~~Pin which n8n version at start?~~ → **2.42.3** (decided 2026-10-06; re-verify latest stable when S2 starts).
- ~~Which S3-compatible backup target for the demo?~~ → **Cloudflare R2** default, AWS S3 for Target B, both supported via `BACKUP_REMOTES`.
- Where to verify the RHEL path with real SELinux/firewalld (not possible in containers)? Options: small AlmaLinux 9 VM on the K: USB SSD, or a one-off Rocky 9 VPS. Decide in S3.
- ~~Set **T**~~ → T = 2026-10-07 (first public push). Planned M0 = 2026-10-21; realistic M0 ≈ early November 2026 (35 h of evenings + 3 outside testers).
