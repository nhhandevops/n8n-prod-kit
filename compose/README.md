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
| `make pin N8N_VERSION=2.42.5` | move the n8n pin (and the runners sidecar with it); then `make up` |
| `make lint` | shellcheck + yamllint + compose config + `caddy validate` for every mode |
| `make env-keys` | key names of `.env` for bug reports (never paste values) |
| `make clean` | destroys containers **and volumes**; asks for the word `destroy` |

Scaling: set `WORKER_REPLICAS` (3–16) in `.env` and run `make up` — `render` generates `compose.scale.yml` with the extra workers and their runner sidecars. `WORKER_CONCURRENCY` is jobs per worker.

## Modes and knobs (all in `.env`, every key is commented in `.env.example`)

- `TLS_MODE`: `acme` (Let's Encrypt, default) · `acme-staging` (rehearsals, no rate limits) · `internal` (local CA, set automatically for dev domains).
- `UI_PROTECT=on` + `UI_ALLOW_CIDR` / `UI_BASIC_AUTH_USER` / `UI_BASIC_AUTH_HASH`: IP allow-list and basic auth in front of the editor only; webhooks, forms and MCP stay open. The hash comes from `caddy hash-password` and **must be single-quoted** in `.env`.
- `RUNNERS_LANGS="javascript python"` enables the Python Code node in the sidecars.
- Binary data is stored in Postgres (`N8N_DEFAULT_BINARY_DATA_MODE=database`): filesystem mode is unsupported in queue mode; S3/Azure need an n8n licence.

## Known limits in this version

- Backups (`make backup-now` / `restore`), monitoring (`--profile monitoring`), `make upgrade` / `rollback` / `doctor` / `chaos` arrive in the next sessions (see `n8n-kit-HANDOFF.md`).
- The n8n containers are not `read_only` yet (their write set is being verified); Caddy, Postgres, Valkey and the runners are.
- All n8n processes share one `/home/node/.n8n` volume (community nodes must be visible to every worker); a worker starting while another process was writing may log "Last session crashed" once — harmless.
