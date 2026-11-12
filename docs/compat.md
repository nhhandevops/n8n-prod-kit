# Compatibility

Which n8n versions each kit version was tested with, where, and how. A row is added whenever the n8n pin in
`compose/versions.env` changes or a kit release is tagged. "Smoke" means the full `make smoke` suite (TC-003…006,
TC-017 part) passed; "chaos" means all three `make chaos` drills passed (TC-008/009/010); "bootstrap" means
`make bootstrap-test` passed for the listed distributions. A real public host with Let's Encrypt is **not** yet
in this table — every row so far used an internal CA.

| Kit | n8n (+ runners) | Caddy | Postgres | Valkey | Tested on | Date | Result |
|---|---|---|---|---|---|---|---|
| 0.1.1-dev | 2.46.7 | 2.11.7 | 18.6 | 9.1.2 | Ubuntu 24.04.4 VM `n8nvm` (Docker 29.9.0, Compose 5.6.0; ports 80/443, internal CA, 2 vCPU / 7.7 GB, core stack only) | 2026-11-12 | smoke `03`+`11` ✅ (44 s): the shipped `templates/idempotent-webhook/` did the work **once** for **20 simultaneous deliveries** of one idempotency key (16 answered from the ledger, 4 refused as in-flight), and all four routes plus the ledger role's grants asserted. Also measured here, by hand: n8n's built-in *Remove Duplicates* dedupe node did the work **twice in 1 of 5** such bursts, and with `historySize: 2` failed every delivery past the cap (D-15, bug log 2026-11-12) |
| 0.1.1-dev | 2.46.7 | 2.11.7 | 18.6 | 9.1.2 | Two guests measured one at a time on one desktop hypervisor: `n8nvm` (2 vCPU / 7.7 GB, Ubuntu 24.04.4) and `server2` (**4 vCPU** / 7.8 GB, Ubuntu 24.04.5 cloud image), core stack and `COMPOSE_PROFILES=monitoring` | 2026-11-10/11 | **Sizing measured ✅** (PROD-PLAN D-16, `docs/sizing.md`): 2 → 4 vCPU roughly doubles intake, throughput and drain · the worker curve peaks at **2 workers** on 4 cores (4 workers cost ~15 % and returned an HTTP 502) · the monitoring profile costs 0–20 % and **~440 MiB**, not the ~1 GB previously documented · the core stack runs in **~2.0 GB** against ~6.6 GB of limits |
| 0.1.1-dev | 2.46.7 | 2.11.7 | 18.6 | 9.1.2 | Ubuntu **24.04.5 cloud image** VM `server2`, a second machine built for the drill (Docker 29.9.3, Compose 5.7.0; ports 80/443, internal CA, 2 vCPU / 7.8 GB, core stack only) | 2026-11-10 | **DR drill on a host that never held the stack's keys ✅** (PROD-PLAN D-7): `bootstrap-host.sh` on a bare cloud image ✅ · `make init` + `make up` 11/11 healthy ✅ · restore refused without `AGE_KEY` (exit 4) and without `ADOPT_KEY` (exit 3), nothing changed ✅ · `make restore … AGE_KEY ADOPT_KEY=1` ✅ (old key adopted, fingerprints equal) · smoke **10/10** ✅ · doctor ✅ 0 problems, 0 warnings |
| 0.1.1-dev | 2.46.7 | 2.11.7 | 18.6 | 9.1.2 | Ubuntu 24.04.4 VM `n8nvm` (Docker 29.9.0, Compose 5.6.0; ports 80/443, internal CA, 2 vCPU / 7.7 GB, core stack only) | 2026-11-09 | `make upgrade` 2.44.6 → 2.46.7 ✅ (**22 migrations**; its verify step failed first on an expired internal leaf cert after 14 days powered off — `make restart SERVICE=caddy`, then `RESUME=1`) · 11/11 healthy · smoke ✅ · doctor ✅ no problems · version lock ✅ · restore test ✅ (3 s) |
| 0.1.1-dev | 2.46.7 | 2.11.7 | 18.6 | 9.1.2 | GitHub Actions ubuntu-24.04 (ports 80/443, internal CA, mirrored images) | 2026-11-09 | lint ✅ · smoke ✅ ×2 + restore · upgrade drill ✅ (2.45.7 → pin: **17 migrations**, forced failure, restore-path rollback) · docs build ✅ · **no public-host (ACME) run yet** |
| 0.1.1-dev | 2.44.6 | 2.11.7 | 18.6 | 9.1.2 | Ubuntu 24.04.4 VM `n8nvm` (Docker 29.9.0, Compose 5.6.0; ports 80/443, internal CA, 2 vCPU / 7.7 GB, core stack only) | 2026-10-25/26 | `make upgrade` 2.42.4 → 2.44.6 ✅ (**24 migrations**) · smoke ✅ 9/9 (10-25) and **10/10 in 94 s** (10-26, with `10-error-workflow`) · doctor ✅ · backups and restore test to `/backups/local` ✅ · bundle format 2 round trip ✅ (files included, restored, uid 1000 kept) · `rotate-recovery-key` ✅ |
| 0.1.1-dev | 2.44.6 | 2.11.7 | 18.6 | 9.1.2 | GitHub Actions ubuntu-24.04 (ports 80/443, internal CA, mirrored images) | 2026-10-25 | lint ✅ · smoke ✅ ×2 + restore · upgrade drill ✅ (2.43.8 → pin: 10 migrations, forced failure, restore-path rollback) · docs build ✅ · **no public-host (ACME) run yet** |
| 0.1.0 | 2.42.4 | 2.11.7 | 18.6 | 9.1.2 | Ubuntu 24.04.4 VM (Docker 29.9.0, Compose 5.6.0; ports 80/443, internal CA, 2 vCPU / 7.7 GB) | 2026-10-10 | smoke ✅ 9/9 · chaos ✅ worker/redis/main · loadtest ✅ (200-job burst in 14 s, ~850 exec/min) · bootstrap ✅ |
| 0.1.0 | 2.42.4 | 2.11.7 | 18.6 | 9.1.2 | GitHub Actions ubuntu-24.04 (ports 80/443, internal CA, mirrored images) | 2026-10-10 | lint ✅ · smoke ✅ ×2 + restore · upgrade drill ✅ (2.41.7 → pin, forced failure, rollback) · docs build ✅ |
| 0.1.0-dev | 2.42.4 | 2.11.7 | 18.6 | 9.1.2 | Ubuntu 26.04 VM (Docker 29.5, Compose 5.1; ports 8080/8443, internal CA) | 2026-10-08 | smoke ✅ · bootstrap ✅ (Ubuntu 24.04/26.04, Debian 13, Rocky 9/10, Alma 9) |
| 0.1.0-dev | 2.42.4 | 2.11.7 | 18.6 | 9.1.2 | GitHub Actions ubuntu-24.04 (Docker 28.0, Compose 2.38; ports 80/443, internal CA, images from ghcr.io / public.ecr.aws mirrors) | 2026-10-08 | smoke ✅ ×2 (run 37724038543, 171 s incl. init + up + doctor) |

## How the matrix is kept honest

- Every pull request runs lint + `make smoke` on a fresh runner (`.github/workflows/ci.yml`).
- Every Monday `weekly-latest-n8n.yml` pins the newest stable n8n release and runs the smoke suite; a failure opens an
  issue labelled `n8n-upstream` before anyone upgrades.
- Every Monday `bootstrap-matrix.yml` installs Docker with `scripts/bootstrap-host.sh` on each supported distribution.
- Image digests are pinned; `make pin N8N_VERSION=x` moves n8n and its runners image together.

## Supported ranges (from upstream)

- **n8n**: 2.x stable releases. n8n 3.0 is scheduled for October 2026 and removes settings the kit already avoids
  (`OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS` becomes the only behaviour, in-memory binary mode goes away); it will get its
  own row after a weekly run against it.
- **Postgres**: 16, 17, 18 are supported by n8n 2.x; 16 logs "compatibility support only". The kit ships 18.
- **Docker**: Engine ≥ 27 and Compose ≥ 2.30 (checked by `make preflight`).
- **Hosts**: Ubuntu 24.04/26.04, Debian 12/13, Rocky/AlmaLinux/CentOS Stream/Oracle/RHEL 9–10 (install path); a real
  SELinux-enforcing + firewalld host run is still pending (see `docs/operations/rhel-hosts.md`).
