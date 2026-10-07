# Changelog — n8n Production Kit

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/) for the **kit** (independent of n8n's version).
Sections: **Added · Changed · Fixed · Removed · Security · Infra · Templates · Docs**. Each release states the n8n versions it was tested with. Reference issues as `(#12)`.

## [Unreleased]

### Added
- Repo skeleton (S1, 2026-10-07): public `README.md`, `CLAUDE.md`, MIT `LICENSE`, `.gitignore` / `.gitattributes` / `.editorconfig`, lint configs (`.yamllint`, `.hadolint.yaml`, `.shellcheckrc`), root `Makefile` with empty-safe `lint`, issue forms (bug / template request / question), PR template, `CODEOWNERS`, Dependabot (actions + backup Dockerfile), lint-only CI (`ci.yml`; actions pinned by commit SHA, hadolint sha256-pinned), placeholder READMEs for `templates/`, `terraform/`, `k8s/`. Repo public + CI green the same day.
- Build plan (`n8n Production Kit — Build Plan (readable).md`, 2026-10-06): compose services, Caddyfile, `.env.example`, Makefile targets, smoke suite + CI, backups, monitoring, 11 build sessions S0–S10.
- Target C: Kubernetes Helm chart (`k8s/helm/n8n-kit`) scheduled as milestone M2.5.

### Changed
- Stack (vs PLAN 0.1): n8n pinned to 2.42.3 with 1:1 `n8nio/runners` sidecars · Valkey 9.1 replaces Redis · Grafana Alloy replaces Promtail · Postgres 18 · backups multi-target via rclone (`BACKUP_REMOTES`) with two age recipients · `scripts/bootstrap-host.sh` for apt and dnf hosts · Caddy routes n8n's real production path list to the webhook pool.
- Dev/build host on the laptop: Ubuntu 26.04 VM `server1` (VMware, kit on ports 8080/8443) instead of WSL2; Ubuntu 26.04 added next to 24.04 in bootstrap + CI matrix.

### Fixed

### Security

### Templates

### Docs
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
