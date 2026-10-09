# Compose kit (Target A) — operator notes

Self-hosted n8n in queue mode on one Docker host. Everything is driven by `make` from this directory (or `make -C compose …` from the repo root). The full documentation site arrives in a later milestone; this page is the minimum an operator needs today.

## Topology

```text
caddy  (the only published ports: HTTP_PORT → redirect, HTTPS_PORT → TLS)
 ├─ /webhook/* /webhook-waiting/* /form/* /form-waiting/* /mcp/*  → n8n-webhook-1, n8n-webhook-2  (round robin, health-checked)
 └─ everything else (UI, /rest, /api, *-test/*)                     → n8n-main
n8n-main ── Valkey (Bull queue) ── n8n-worker-1 ── n8n-worker-1-runners   (Code nodes run in the sidecar sandbox)
                                └─ n8n-worker-2 ── n8n-worker-2-runners
Postgres 18 (workflows, credentials, executions, binary data)
```

Every response from Caddy carries `X-Kit-Upstream: <service>:5678`, so you can always see which process answered.

## First run

```bash
# production VPS (DNS for DOMAIN must already point here)
make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com
make preflight && make up            # ≈ 2–3 minutes; ends with the status table and the login URL

# local development (any name that cannot get a public certificate switches to the internal CA)
make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443
make up && make trust-ca             # trust-ca prints the certutil line for a Windows browser
```

`make init` writes `.env` (mode 600) with generated secrets and two `age` keys under `secrets/`. **Store `N8N_ENCRYPTION_KEY` and `secrets/age-recovery-key.txt` in a password manager now** — without the key every stored credential is lost, without the recovery key encrypted backups cannot be restored elsewhere.

## Day to day

| Command | What it does |
|---|---|
| `make status` | health table of all services + login URL; exit 1 if anything is unhealthy |
| `make logs SERVICE=n8n-worker-1 SINCE=30m` | follow logs of one service |
| `make restart SERVICE=n8n-main` | restart one service |
| `make down` / `make up` | stop / start (volumes and `.env` are kept) |
| `make preflight` | re-check host, ports, DNS, disk, clock |
| `make smoke [ONLY=04,05]` | end-to-end check of the running stack: health, TLS and headers, owner/login/API key, webhook routing through the pool, execution on a worker (incl. a Code node), metrics — ~30 s, idempotent; state in `compose/.smoke/` |
| `make doctor` | diagnose: versions, health + last logs of unhealthy services, certificate, disk, Postgres/Valkey state, dangerous settings — every FAIL comes with its fix |
| `make scale-workers N=4` | 1–16 workers (each with its runner sidecar); `N=1` parks worker 2 |
| `make backup-now [NAME=x]` | encrypted backup (DB + encryption key) to every `BACKUP_REMOTES` target now; nightly from cron |
| `make backups` | list the backups on every target |
| `make restore BACKUP=latest` | replace the database with a backup (key check, safety backup, staging DB + atomic swap, queue flush) |
| `make restore-clean` | empty the work volume after an interrupted restore (never needed normally) |
| `make restore-test` | verify every target's newest backup, restore the newest into a scratch Postgres; weekly from cron |
| `make detach-recovery-key` | move the offline recovery key into your password manager (paste it back to prove the copy, then shreds) |
| `make upgrade [N8N_VERSION=2.42.6]` | upgrade n8n + runners: pull first, stop and drain, pre-upgrade backup, migrations by n8n-main alone, verify; without a version it applies the pin a `git pull` brought (`make up` refuses to) — see `docs/operations/upgrade-rollback.md` |
| `make rollback` | undo the last upgrade: images only when no migration ran (no data lost), else the pre-upgrade backup is restored first |
| `make pin [N8N_VERSION=x]` | resolve image digests into `versions.env` (on a running install, change n8n's version with `make upgrade`) |
| `make lint` | shellcheck + yamllint + compose config + `caddy validate` for every mode |
| `make env-keys` | key names of `.env` for bug reports (never paste values) |
| `make clean` | destroys containers **and volumes**; asks for the word `destroy` |

Scaling: `make scale-workers N=<1..16>` writes `WORKER_REPLICAS`, regenerates `compose.scale.yml` (extra workers + sidecars, or a parked worker 2 for `N=1`) and converges the stack. `WORKER_CONCURRENCY` is jobs per worker.

## Modes and knobs (all in `.env`, every key is commented in `.env.example`)

- `TLS_MODE`: `acme` (Let's Encrypt, default) · `acme-staging` (rehearsals, no rate limits) · `internal` (local CA, set automatically for dev domains).
- `UI_PROTECT=on` + `UI_ALLOW_CIDR` / `UI_BASIC_AUTH_USER` / `UI_BASIC_AUTH_HASH`: IP allow-list and basic auth in front of the editor only; webhooks, forms and MCP stay open. The hash comes from `caddy hash-password` and **must be single-quoted** in `.env`.
- `RUNNERS_LANGS="javascript python"` enables the Python Code node in the sidecars.
- Code nodes run in a network-less sandbox: make HTTP calls with `this.helpers.httpRequest(...)` (executed by the worker) or an HTTP Request node — `fetch` is not available inside the sandbox.
- `/metrics` is never served through Caddy (404); Prometheus scrapes the processes over the internal network.
- Binary data is stored in Postgres (`N8N_DEFAULT_BINARY_DATA_MODE=database`): filesystem mode is unsupported in queue mode; S3/Azure need an n8n licence.

## Known limits in this version

- Backups: see `docs/operations/backup-restore.md` (targets, restore, disaster recovery with the recovery key). Set an off-host target (`BACKUP_REMOTES="r2:…"`) before going live — dev hosts back up to `compose/backups` only.
- Monitoring: `docs/operations/monitoring.md`. Upgrades: `docs/operations/upgrade-rollback.md`. `make chaos` / `loadtest` arrive in the next session (see `n8n-kit-HANDOFF.md`).
- RHEL-family hosts: see `docs/operations/rhel-hosts.md` (install path verified in containers; a real SELinux + firewalld host run is still pending).
- All n8n processes share one `/home/node/.n8n` volume (community nodes must be visible to every worker); a worker starting while another process was writing may log "Last session crashed" once — harmless.
