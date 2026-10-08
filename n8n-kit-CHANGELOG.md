# Changelog — n8n Production Kit

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/) for the **kit** (independent of n8n's version).
Sections: **Added · Changed · Fixed · Removed · Security · Infra · Templates · Docs**. Each release states the n8n versions it was tested with. Reference issues as `(#12)`.

## [Unreleased]

### Added
- Smoke suite + CI (S4, 2026-10-08): `make smoke [ONLY=…]` (`tests/smoke/01-06`: health, TLS/headers/redirect, owner/login/API key, webhook routing + round robin, execution on a worker incl. a Code node HTTP call, metrics), CI smoke job on every PR (fresh runner, ports 80/443, smoke twice, logs artifact on failure), weekly smoke against the latest stable n8n (`weekly-latest-n8n.yml`, opens an `n8n-upstream` issue on failure), `docs/compat.md`. Root `make lint` now also lints new, not yet tracked files. Tested with n8n: 2.42.4.
- Operability (S3, 2026-10-07): `make doctor` (versions, health + logs of unhealthy services, ports, DNS/certificate, disk, clock, Postgres connections/size/pruning, Valkey eviction/AOF/memory, dangerous `N8N_ENDPOINT_*` overrides, recovery-key-on-host, SELinux/firewalld on RHEL; `DOCTOR_SIMULATE=` for tests), `make scale-workers N=1..16` (worker 2 parked via a Compose profile for `N=1`), read-only root filesystem for all n8n containers (measured tmpfs set), `docs/operations/rhel-hosts.md`, weekly `bootstrap-matrix` workflow.
- Compose core (S2, 2026-10-07): n8n 2.42.4 queue mode — Caddy edge (TLS acme/acme-staging/internal, routing by n8n's production path list, security headers incl. error responses, optional UI allow-list + basic auth, `X-Kit-Upstream` on every response), n8n-main + 2 webhook processors + 2 workers with 1:1 `n8nio/runners` sidecars, Postgres 18, Valkey 9.1 (AOF, noeviction), hardened containers (non-root, cap_drop ALL, read-only where verified, memory limits, healthchecks with readiness), `make init/preflight/up/status/lint/pin/render/dev-ca/trust-ca/...`, `.env.example` with every key explained, `scripts/bootstrap-host.sh` (Ubuntu 24.04/26.04, Debian 12/13, Rocky/Alma/CentOS Stream/Oracle/RHEL 9–10) + container test matrix. Tested with n8n: 2.42.4.
- Repo skeleton (S1, 2026-10-07): public `README.md`, `CLAUDE.md`, MIT `LICENSE`, `.gitignore` / `.gitattributes` / `.editorconfig`, lint configs (`.yamllint`, `.hadolint.yaml`, `.shellcheckrc`), root `Makefile` with empty-safe `lint`, issue forms (bug / template request / question), PR template, `CODEOWNERS`, Dependabot (actions + backup Dockerfile), lint-only CI (`ci.yml`; actions pinned by commit SHA, hadolint sha256-pinned), placeholder READMEs for `templates/`, `terraform/`, `k8s/`. Repo public + CI green the same day.
- Build plan (`n8n Production Kit — Build Plan (readable).md`, 2026-10-06): compose services, Caddyfile, `.env.example`, Makefile targets, smoke suite + CI, backups, monitoring, 11 build sessions S0–S10.
- Target C: Kubernetes Helm chart (`k8s/helm/n8n-kit`) scheduled as milestone M2.5.

### Changed
- Stack (vs PLAN 0.1): n8n pinned to 2.42.3 with 1:1 `n8nio/runners` sidecars · Valkey 9.1 replaces Redis · Grafana Alloy replaces Promtail · Postgres 18 · backups multi-target via rclone (`BACKUP_REMOTES`) with two age recipients · `scripts/bootstrap-host.sh` for apt and dnf hosts · Caddy routes n8n's real production path list to the webhook pool.
- Dev/build host on the laptop: Ubuntu 26.04 VM `server1` (VMware, kit on ports 8080/8443) instead of WSL2; Ubuntu 26.04 added next to 24.04 in bootstrap + CI matrix.

### Fixed

### Security
- n8n-main's Prometheus metrics were reachable from the Internet at `https://DOMAIN/metrics` (Caddy catch-all); Caddy now answers 404 on `/metrics*` (S4).

### Templates

### Docs
- `n8n-kit-BUILD-PLAN.md` committed (sanitized copy of the session plan) so any machine can continue; HANDOFF rewritten as a hand-off point (generic resume steps, S4 recipe, test results); CLAUDE.md points at the build plan and the gotcha list.
- HANDOFF: M2.5 row, decisions log 2026-10-06/07, machines table, §4 resume block for the VM, §7 questions answered.

---

## [0.0.1] — 2026-10-06

### Added
- Project plan (`n8n-kit-PLAN.md`): problem, users, usage, benefits, forecast M0–M4, service-revenue hypothesis, risks.
- Architecture: identical queue-mode topology for Docker Compose (VPS) and Terraform (AWS ECS/RDS/ElastiCache/EFS), encrypted backups with restore tests, monitoring, upgrade/rollback, security checklist; HA / scalability / fault-tolerance / resilience sections.
- Demo script (fresh-VPS in 15 minutes), 26 test cases (TC-001…TC-026), definition of done, community change process.
- `n8n-kit-HANDOFF.md` protocol, `n8n-kit-README.md` with agent instructions.

Tested with n8n: _none yet_

---

<!--
Entry examples:
- Added: `make doctor` detects missing N8N_ENCRYPTION_KEY and wrong DNS (#18)
- Fixed: webhook processors not receiving traffic when Caddy restarted before n8n was healthy (#27)
- Templates: added `vietqr-payment-link` (#33)
- Security: pinned all images by digest (#12)
Tested with n8n: 1.x.y, 1.x.z
-->
