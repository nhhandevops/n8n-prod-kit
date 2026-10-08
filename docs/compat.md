# Compatibility

Which n8n versions each kit version was tested with, where, and how. A row is added whenever the n8n pin in
`compose/versions.env` changes or a kit release is tagged. "Smoke" means the full `make smoke` suite (TC-003…006,
TC-017 part) passed; "bootstrap" means `make bootstrap-test` passed for the listed distributions.

| Kit | n8n (+ runners) | Caddy | Postgres | Valkey | Tested on | Date | Result |
|---|---|---|---|---|---|---|---|
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
