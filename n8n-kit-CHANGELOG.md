# Changelog — n8n Production Kit

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org/) for the **kit** (independent of n8n's version).
Sections: **Added · Changed · Fixed · Removed · Security · Infra · Templates · Docs**. Each release states the n8n versions it was tested with. Reference issues as `(#12)`.

## [Unreleased]

### Added

### Changed

### Fixed

### Security

### Templates

### Docs
- `docs/runbook.md` — a hands-on runbook for a dev/test host: every shipped feature in the order it makes sense to learn it, written for someone new to Docker, queue mode, certificates and backups-as-a-practice. Six parts (inspection tools · the edge, the editor and a first webhook · backups and restore · upgrades, scaling and the chaos drills · monitoring and alerts · a sign-off sheet), each feature presented as *what it is · why you care · do this · what you should see · what it proves · if it goes wrong*, and each part mapped to the acceptance tests it verifies (TC-002…TC-018, TC-026). Written by five agents reading the scripts, then each part attacked by a verifier whose only job was to find commands, flags and output the repo does not support.
- `n8n-kit-PROD-PLAN.md` (repository root) — the production rollout, **parked** on purpose: the project stays on a disposable dev host until §1's three conditions are met. Holds the production-versus-dev configuration diff (every key that must change, every key to decide consciously, and the ones not to touch), an eight-phase rollout where each phase ends in a gate, the go-live checklist, the go-live risk register, and an **improvement ledger** that scores every open item as `(harm × likelihood × reach) ÷ effort` so "what should I fix first" is answered by the table rather than by memory. §6 lists what triggers an update to it.

---

## [0.1.0] — 2026-10-10

First tagged release: the Compose target (M0) complete except its acceptance test. Everything below was built
and verified between 2026-10-07 and 2026-10-10.

**Tested with n8n:** 2.42.4 (with `n8nio/runners:2.42.4`), alongside Caddy 2.11.7, Postgres 18.6, Valkey 9.1.2.
Verified on Ubuntu 24.04 (Docker 29.9.0 / Compose 5.6.0) and on GitHub Actions `ubuntu-24.04`; the bootstrap
matrix covers Ubuntu 24.04/26.04, Debian 13 and Rocky/AlmaLinux 9/10.

**Not yet verified:** TC-025 — the timed fresh-host quickstart followed by three outside testers — and with it
route A's real ACME path on a public host. That is why this release is marked pre-release.


### Added
- Documentation site (S9, 2026-10-10): MkDocs Material at `mkdocs.yml`, published to GitHub Pages by `.github/workflows/docs.yml` (builds with `--strict` on every docs PR, deploys on `main`; `mkdocs-material` pinned in `requirements-docs.txt`). New pages: `index`, `quickstart` and its Vietnamese translation `quickstart.vi`, `architecture` (with a mermaid topology diagram), `configuration` (every `.env` setting, grouped, with what it costs to get wrong), `security` (what is hardened by default plus a pre-handover checklist), `operations/scaling`, `operations/rebuild-vps`, `faq` (built from the verified entries in the bug log) and `contributing`. Root `make lint` now runs `mkdocs build --strict` when mkdocs is installed, so a dead internal link fails the lint rather than the site.
- Load test and chaos drills (S8, 2026-10-10): `make loadtest [N=200] [P=20] [MODE=async|sync]` bursts webhooks through the pool and reports the HTTP histogram, send/drain/end-to-end timing, executions per minute, the peak queue depth (read live from Valkey, because n8n's Prometheus gauge only refreshes every 20 s) and the per-worker split. `make chaos SCENARIO=worker|redis|main [N=] [OUTAGE=] [YES=1]` breaks one part of a running stack and asserts the documented behaviour (TC-008/009/010), restoring every service through its exit trap and keeping the evidence — deactivated, never left published — when an assertion fails. New fixtures `wf-webhook-async.json` (answers when queued, so a backlog can build), `wf-chaos-idempotent.json` (one file per input id, so a retry overwrites instead of duplicating) and `wf-schedule-tick.json`. `docs/operations/chaos-drills.md`. Measured on a 2 vCPU / 7.7 GB host with 2 workers at concurrency 10: ~850 executions/min, a 200-job burst absorbed in 14 s, peak backlog 161. Tested with n8n: 2.42.4.
- Upgrades (S7, 2026-10-09): `make upgrade [N8N_VERSION=x]` — checks with nothing changed (running version from the container label and n8n's own version record, stable release, no downgrade, majors only with ALLOW_MAJOR=1), pull + label check while n8n serves, stop + drain, pre-upgrade backup (failure → old version back), n8n-main alone for the migrations, then the rest, verification (versions + smoke on the core services); `RESUME=1`; without N8N_VERSION it applies the pin a `git pull` brought. `make rollback` — images only when no migration ran (no data lost), else the pre-upgrade backup is fetched and verified while n8n serves, then restored; `ROLLBACK_CONFIRM` whenever data would be lost, `ABORT=1`, `FROM=`. Version guard on make up / restart / scale-workers / restore. State in `compose/.upgrade/` (state, history, run logs). CI `upgrade` job (2.41.7 → pin: forced failure, rollback, upgrade); the weekly job upgrades from the pin to the latest stable n8n. `docs/operations/upgrade-rollback.md`.
- Monitoring (S6, 2026-10-08): Compose profile `monitoring` — Prometheus 3.13 LTS, Grafana 13 at `/grafana/` (provisioned data sources, dashboards n8n Overview / Host / Backups, 13 alert rules: n8n-main/webhook pool/workers down, queue backlog, execution failure rate, backup missing/failed, restore test failed/stale, disk, certificate, restart loops, monitoring targets; Telegram contact point from `ALERT_TELEGRAM_*`), Loki 3.7 + Grafana Alloy 1.20 (container logs of this project with a `level` label), node-exporter (incl. the backup metrics), cAdvisor; profile `kuma` adds Uptime Kuma 2 at `kuma.DOMAIN`; hourly certificate check; `docs/operations/monitoring.md`; smoke 09; CI runs the full kit with monitoring and an alert drill (TC-018). Tested with n8n: 2.42.4.
- Backups (S5, 2026-10-08): `backup` service — nightly `pg_dump` + encryption-key bundle, age-encrypted to a host key and an offline recovery key, copied to every `BACKUP_REMOTES` target (local, external disk, Cloudflare R2, AWS S3) with daily/monthly retention and Telegram alerts; weekly automatic restore test into a scratch Postgres (counts + credential decrypt + key check); `make backup-now`, `backups`, `restore` (safety backup, key check before the drop, `ADOPT_KEY`/`AGE_KEY` for disaster recovery), `restore-test`, `detach-recovery-key`; doctor/preflight backup checks; smoke 07/08; CI restores the newest backup into the live database; `docs/operations/backup-restore.md`. Tested with n8n: 2.42.4.
- Smoke suite + CI (S4, 2026-10-08): `make smoke [ONLY=…]` (`tests/smoke/01-06`: health, TLS/headers/redirect, owner/login/API key, webhook routing + round robin, execution on a worker incl. a Code node HTTP call, metrics), CI smoke job on every PR (fresh runner, ports 80/443, smoke twice, logs artifact on failure), weekly smoke against the latest stable n8n (`weekly-latest-n8n.yml`, opens an `n8n-upstream` issue on failure), `docs/compat.md`. Root `make lint` now also lints new, not yet tracked files. Tested with n8n: 2.42.4.
- Operability (S3, 2026-10-07): `make doctor` (versions, health + logs of unhealthy services, ports, DNS/certificate, disk, clock, Postgres connections/size/pruning, Valkey eviction/AOF/memory, dangerous `N8N_ENDPOINT_*` overrides, recovery-key-on-host, SELinux/firewalld on RHEL; `DOCTOR_SIMULATE=` for tests), `make scale-workers N=1..16` (worker 2 parked via a Compose profile for `N=1`), read-only root filesystem for all n8n containers (measured tmpfs set), `docs/operations/rhel-hosts.md`, weekly `bootstrap-matrix` workflow.
- Compose core (S2, 2026-10-07): n8n 2.42.4 queue mode — Caddy edge (TLS acme/acme-staging/internal, routing by n8n's production path list, security headers incl. error responses, optional UI allow-list + basic auth, `X-Kit-Upstream` on every response), n8n-main + 2 webhook processors + 2 workers with 1:1 `n8nio/runners` sidecars, Postgres 18, Valkey 9.1 (AOF, noeviction), hardened containers (non-root, cap_drop ALL, read-only where verified, memory limits, healthchecks with readiness), `make init/preflight/up/status/lint/pin/render/dev-ca/trust-ca/...`, `.env.example` with every key explained, `scripts/bootstrap-host.sh` (Ubuntu 24.04/26.04, Debian 12/13, Rocky/Alma/CentOS Stream/Oracle/RHEL 9–10) + container test matrix. Tested with n8n: 2.42.4.
- Repo skeleton (S1, 2026-10-07): public `README.md`, `CLAUDE.md`, MIT `LICENSE`, `.gitignore` / `.gitattributes` / `.editorconfig`, lint configs (`.yamllint`, `.hadolint.yaml`, `.shellcheckrc`), root `Makefile` with empty-safe `lint`, issue forms (bug / template request / question), PR template, `CODEOWNERS`, Dependabot (actions + backup Dockerfile), lint-only CI (`ci.yml`; actions pinned by commit SHA, hadolint sha256-pinned), placeholder READMEs for `templates/`, `terraform/`, `k8s/`. Repo public + CI green the same day.
- Build plan (`n8n Production Kit — Build Plan (readable).md`, 2026-10-06): compose services, Caddyfile, `.env.example`, Makefile targets, smoke suite + CI, backups, monitoring, 11 build sessions S0–S10.
- Target C: Kubernetes Helm chart (`k8s/helm/n8n-kit`) scheduled as milestone M2.5.

### Changed
- S7 (2026-10-09): Caddy health-checks n8n with `/healthz/readiness` (a starting n8n answers 200 "starting up" on every path); n8n start windows 600 s / 300 s with `start_interval: 5s`, `make up --wait-timeout 900`; `DB_POSTGRESDB_STATEMENT_TIMEOUT` passed to n8n (.env); backups record the n8n version of the database they dump; `make pin` takes `PIN_FILE` / `PIN_ONLY`; only a command-line `N8N_VERSION` reaches pin/upgrade; `make up` and `make upgrade` reload a changed Caddyfile into the running Caddy (`scripts/caddy-reload.sh`).
- Stack (vs PLAN 0.1): n8n pinned to 2.42.3 with 1:1 `n8nio/runners` sidecars · Valkey 9.1 replaces Redis · Grafana Alloy replaces Promtail · Postgres 18 · backups multi-target via rclone (`BACKUP_REMOTES`) with two age recipients · `scripts/bootstrap-host.sh` for apt and dnf hosts · Caddy routes n8n's real production path list to the webhook pool.
- Dev/build host on the laptop: Ubuntu 26.04 VM `server1` (VMware, kit on ports 8080/8443) instead of WSL2; Ubuntu 26.04 added next to 24.04 in bootstrap + CI matrix.

### Fixed
- The Read/Write Files node could not write anything (2026-10-10): `/home/node/.n8n-files` does not exist in the n8n image, so Docker created the `n8n_files` mount point as root:root while n8n runs as uid 1000, and every write failed with EACCES on a fresh install. `make up` now runs `scripts/files-perms.sh`, which chowns the volume to 1000 once, after `compose up`, from a throw-away root container.
- `make preflight` / `make doctor` (2026-10-10): the disk check no longer invents a "0 GB free" failure when the docker daemon is unreachable — seen on a host with 83 GB free, where it fired underneath the real docker error. `$(docker info … || echo /var/lib/docker)` captured docker info's empty line *and* the fallback, leaving `df` an unusable path; under `pipefail` the trailing `|| echo 0` then appended a literal `0`, turning "unreadable" into a confident wrong number. The default now applies to the captured value, an unreadable path is reported as such with the `df -h` command to run by hand, and a path assumed because the daemon is down says so.
- S7 review (2026-10-09, 41 confirmed findings): a closed SSH session no longer stops make upgrade/rollback half-way (EIO under `set -e`); an aborted attempt keeps the last rollback point; make rollback can no longer strand the stack (fetch before stop, fallback targets, ABORT=1, decision recorded only when committed); autovacuum no longer counts as an n8n session; restore's safety bundle carries the right version; pin.sh resolves ghcr.io through its registry fallback (GET for the auth challenge).
- Monitoring review (2026-10-09, 41 confirmed findings): Telegram alerts are plain text (Grafana's default HTML mode made Telegram reject any alert text with "<…>"); Grafana memory (its own gzip ballooned the heap to ~1 GiB: `GF_SERVER_ENABLE_GZIP=false` behind Caddy's compression, `GOMEMLIMIT`, unused data-source plugins off); cAdvisor `disk`/`diskIO` metrics off (60 % CPU on a busy host); Grafana first-start window 5 min; 17 alert rules (new: KitServiceUnhealthy for Postgres/Valkey/any kit container, WebhookProcessorMissing, WorkerPoolDown, CertCheckFailing; BackupMissing/RestoreTestStale count from when backups were switched on; ExecutionFailureRate counts first observations; DiskHigh watches every filesystem); dashboard fixes (TLS panel, CPU stack, load per CPU, pool up/down, disk I/O, sparse series, CPU by project, memory % of limit); `make kuma-setup`; smoke 09 checks isolation, Loki redaction, Telegram mode and the Kuma admin; the alert drill also tests WorkerPoolDown; ContainerMemoryPressure + ContainerOOMKilled alerts (19 rules); `make up` reloads Grafana's provisioning (rule changes no longer need a Grafana restart).
- Backup/restore review (2026-10-08, 28 findings): `make restore` restores into a staging database and swaps it in atomically (a failed pg_restore no longer leaves an empty database), checks the encryption key before the safety backup and stops n8n before it, resets n8n's cached key file after a restore (the new-host `ADOPT_KEY` procedure left n8n unstartable), and empties the decrypted work volume on every exit; `latest` ignores safety copies and future-dated names and refuses when a remote cannot be listed; every bundle name is bound to its manifest; backups alert and set `backup_last_status 0` on ANY failure; retention validates its values, never deletes the newest 7 per directory and prunes by the UTC name; monthly copies are self-healing; one lock across all backup containers; manifest counts come from the dump itself; `BACKUP_REMOTES` / `BACKUP_LOCAL_PATH` / retention / memory-vs-tmpfs are validated by preflight; doctor FAILs on a failed last attempt and checks the recovery key; the restore test verifies every remote's newest bundle and its age; `N8N_REINSTALL_MISSING_PACKAGES=true`. New defaults: `BACKUP_TMPFS_SIZE=1g`, `MEM_LIMIT_BACKUP=1536m`. New: `BACKUP_RETENTION_MIN_KEEP`, `BACKUP_ALLOW_SINGLE_RECIPIENT`, `RESTORE_TEST_MAX_AGE_HOURS`, `make restore-clean`, CI disaster-recovery drill (`tests/ci/dr-drill.sh`).
- n8n-main crashed with `EACCES mkdir /home/node/.cache/n8n` after any container restart (Docker mounts a tmpfs on a directory missing from the image as root 0755 after a restart); the tmpfs mounts now carry uid/gid/mode (S5).

### Security
- Monitoring review (2026-10-09): Caddy's access logs drop request headers (n8n API keys and webhook auth headers no longer reach Loki); Grafana and Uptime Kuma moved off the workers' network (`edge-grafana`, `edge-kuma`); Uptime Kuma's admin is created by `make up` (`KUMA_ADMIN_USER`/`KUMA_ADMIN_PASSWORD`), so its first-run page is never open; Grafana: plugin catalogue, external snapshots and public dashboards off, generated `GRAFANA_SECRET_KEY`; `UI_PROTECT=on` no longer forwards the edge password upstream; dev containers trust only the CA certificate (`secrets/dev-root.crt`), not Caddy's data volume with the CA key; doctor passes Grafana credentials on stdin.
- Backups (review 2026-10-08): the weekly restore test checks the bundle's key and recipients BEFORE restoring and restores as an unprivileged role (a bundle planted on a writable target could run `COPY … PROGRAM` as superuser); `ADOPT_KEY=1` asks for a human comparison of the key; the encryption key and the Telegram token no longer appear on process command lines; `backup-perms.sh` refuses system directories, `$HOME` and non-empty foreign directories as `BACKUP_LOCAL_PATH`; `make detach-recovery-key` is always interactive and verifies the pasted-back key; `compose/.env.*` (backups of .env) is git-ignored.
- n8n-main's Prometheus metrics were reachable from the Internet at `https://DOMAIN/metrics` (Caddy catch-all); Caddy now answers 404 on `/metrics*` (S4).

### Templates

### Docs
- `docs/operations/chaos-drills.md` (2026-10-10): what each drill proves, with the measured numbers, and the two upstream facts the drills disproved — a killed worker's in-flight executions are lost rather than retried (n8n 2.0 removed Bull's stalled retry), and `docker kill` never exercises `restart: unless-stopped`. PLAN §2.9, demo step 7 and TC-008 corrected to match measurement.
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
