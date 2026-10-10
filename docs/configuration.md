# Configuration

Two files hold everything you configure:

| File | Holds | Written by |
|---|---|---|
| `compose/.env` | site settings and secrets | `make init`, then you |
| `compose/versions.env` | the pinned image tags and digests | `make pin`, `make upgrade` |

Compose is given both on every call, `versions.env` first and `.env` second, so a key in `.env` **overrides** the same
key in `versions.env`. `compose/.env.example` is the annotated reference copy; a key that is not in it, and not passed
to a service in `docker-compose.yml`, does nothing however plausible its name looks. `.env` is mode 600 and
git-ignored: never commit it, and use `make env-keys` (key **names** only) in bug reports.

## Editing .env

The file is parsed by Compose *and* sourced by the kit's scripts, so it has to stay valid for both:

| Form | Use it for |
|---|---|
| `KEY=value` | plain tokens: no spaces, quotes, `$` or `#` |
| `KEY='va lue $x'` | literal — anything with a space, `$` or `#` |
| `KEY="javascript python"` | spaces, no `$` |

Comments go on lines of their own. `make config` prints the resolved configuration, and `make up` runs preflight
first, so a bad value fails there rather than at 02:00.

## Applying a change

| Change | What applies it |
|---|---|
| any `.env` key a container reads | `make up` — it recreates the containers whose configuration changed |
| `WORKER_REPLICAS` | `make scale-workers N=4`: it also removes the containers above the new count and verifies the result |
| the n8n version | `make upgrade`, never `make up` (last section) |
| `caddy/Caddyfile` or a snippet | `make up`, which runs `caddy reload`; the files are bind-mounted, so an edit alone does not recreate the container |
| `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` | nothing — they apply only when Grafana first creates its database. Later: `grafana cli admin reset-admin-password` |
| `GRAFANA_SECRET_KEY` | `make up` — it recreates Grafana with the new key, which is why it is safe only on a *new* Grafana: everything Grafana already stored (the Telegram token) becomes unreadable |
| Grafana rules, contact point, data sources | `make up` reloads its provisioning (rules load only at start) |
| `KUMA_ADMIN_USER` / `KUMA_ADMIN_PASSWORD` | `make up`, which creates Kuma's admin account — but only while Kuma has none; an instance that already has an admin is left alone, so change that password in Kuma's own UI |

`make restart SERVICE=n8n-worker-1` bounces a service; it is not how a setting is applied.

## 1 Identity and edge

| Setting | Default | What it does | Change it when |
|---|---|---|---|
| `DOMAIN` | `n8n.example.com` | public host name for users, webhooks and the certificate; Caddy's site block, `N8N_HOST` and `PUBLIC_URL` all derive from it | `init` sets it |
| `TLS_MODE` | `acme` | where the certificate comes from | see below |
| `ACME_EMAIL` | `admin@example.com` | ACME account contact; Caddy will not start with it empty, even in `internal` mode | always, for a public domain |
| `HTTP_PORT` | `80` | host port for plain HTTP: ACME HTTP-01 and the redirect. Caddy listens on the same number inside, so the redirect carries a reachable port | port 80 is taken (dev: `8080`) |
| `HTTPS_PORT` | `443` | host port for HTTPS (tcp) and HTTP/3 (udp) | as above; `init` appends a non-443 value to `PUBLIC_URL` |
| `PUBLIC_URL` | `https://n8n.example.com/` | base URL, trailing slash; feeds `N8N_WEBHOOK_URL` (what webhook nodes print) and `N8N_EDITOR_BASE_URL` (mail links, OAuth callbacks, SAML) | `DOMAIN` or `HTTPS_PORT` changed |
| `UI_PROTECT` | `off` | protection in front of the editor and API only | see below |
| `UI_ALLOW_CIDR` | empty = `0.0.0.0/0 ::/0` | space-separated CIDRs that may reach the UI | you have a VPN or office range |
| `UI_BASIC_AUTH_USER`, `UI_BASIC_AUTH_HASH` | empty | basic-auth user and the bcrypt hash of its password | required with `UI_PROTECT=on` |
| `KUMA_ENABLED` | `off` | publishes Uptime Kuma at `kuma.DOMAIN` | with the `kuma` profile |
| `GENERIC_TIMEZONE` | `Asia/Ho_Chi_Minh` | timezone for Schedule/Cron triggers and date expressions; n8n would otherwise assume `America/New_York`. Runner sidecars get the same value, so Code nodes agree with the workflow | always: set your own |
| `TZ` | `Asia/Ho_Chi_Minh` | container OS timezone (log timestamps) | keep it equal to `GENERIC_TIMEZONE` |

**TLS_MODE** has three values. `acme` is Let's Encrypt production and needs `DOMAIN` to resolve to this host on ports
80 and 443; preflight compares the record with the host's public IP. `acme-staging` is the same flow against the
staging CA — untrusted certificates, no production rate limits — so it is the mode for rehearsing DNS and firewall on
a new host. `internal` uses Caddy's own CA, adds `compose.dev.yml` so n8n trusts that CA when it calls its own
`PUBLIC_URL`, and wants `make trust-ca` for the browser. `make init` picks it for dev names (`*.localtest.me`,
`*.local`, `*.test`, `*.internal`, `*.home.arpa`, `localhost`, an IPv4 address), because no public CA can issue
for them.

### UI protection

`UI_PROTECT=on` puts two layers in front of the editor, the API and `/grafana/`, in this order: a client outside
`UI_ALLOW_CIDR` gets a bare 403 and is never offered a password prompt, and everyone else passes HTTP basic auth
before reaching n8n's own login. Production webhooks, forms, MCP endpoints and the health paths are matched by earlier
routes and never go through it, so integrations keep working. Two details bite:

- **Quote the hash.** It looks like `$2a$14$F5Ch…`, and Compose interpolates every `$name` segment of an unquoted or
  double-quoted value away — silently, after which no password matches. Single-quote it, or double every `$`. Generate
  it with `docker compose --env-file versions.env --env-file .env run --rm caddy caddy hash-password --plaintext 'your-password'`.
- **Mind Docker NAT.** The allow-list matches the TCP peer, so a request made on the host itself arrives from the
  bridge gateway (172.x.0.1), not 127.0.0.1.

An empty `UI_ALLOW_CIDR` means everyone; an empty user or hash with `UI_PROTECT=on` makes Caddy refuse to start.

## 2 Secrets

`make init` generates all of these. `FORCE=1` regenerates them, which is destructive: a fresh `N8N_ENCRYPTION_KEY`
makes every credential already in Postgres unreadable.

| Setting | Default | What it does |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | 64 chars | encrypts every credential in Postgres |
| `POSTGRES_PASSWORD` | 48 hex chars | password of the Postgres role `n8n`; used at initdb **and** by every n8n process, so changing it later means changing it inside Postgres too |
| `VALKEY_PASSWORD` | 48 hex chars | `requirepass` of the queue, which carries execution payloads |
| `N8N_RUNNERS_AUTH_TOKEN` | 64 hex chars | shared secret between a worker's task broker (port 5679) and its runner sidecar; a sidecar with the wrong token stays silent for 60 s and exits 0 |
| `GRAFANA_ADMIN_PASSWORD` | 24 hex chars | Grafana's initial admin password |
| `GRAFANA_SECRET_KEY` | 40 hex chars | encrypts what Grafana stores, such as the Telegram token. Set it only for a *new* Grafana |
| `KUMA_ADMIN_USER` / `KUMA_ADMIN_PASSWORD` | `admin` / 32 hex chars | Uptime Kuma's admin, created by `make up` so its first-run page is never left open |
| `DB_POSTGRESDB_STATEMENT_TIMEOUT` | `300000` | ms one SQL statement may take, migrations included (not a secret, but it sits in this block). All pending migrations run in one transaction, so one statement over the limit rolls back the lot — raise it (e.g. `1800000`) after an upgrade failed on a statement timeout, then `make upgrade RESUME=1` |

### N8N_ENCRYPTION_KEY

This is the one value no backup can replace. Main, the webhook processors and the workers must share it: a worker
without it refuses to start, and main would silently generate a different one. **Losing it means every stored
credential is unreadable**, so it belongs in a password manager from day one.

It is written into every backup bundle, and a restore stops when the bundle's key differs from the running one unless
you pass `ADOPT_KEY=1` ([Backup and restore](operations/backup-restore.md)). n8n also caches it in
`/home/node/.n8n/config` in the `n8n_data` volume, so after a manual change main dies with "Mismatching encryption
keys" until that file is deleted — `make restore` does this itself. `make doctor` checks it is present and at least 32
characters. Never generate a new one over an existing database.

## 3 Topology and sizing

| Setting | Default | What it does | Change it when |
|---|---|---|---|
| `WORKER_REPLICAS` | `2` | worker processes, 1–16, each with its own runner sidecar | the backlog does not drain |
| `WORKER_CONCURRENCY` | `10` | parallel executions per worker (`--concurrency`) | see below |
| `RUNNERS_LANGS` | `javascript` | languages each sidecar starts — this is its command line, and there is no environment variable for it. `'javascript python'` (quoted) adds native Python at ~75 MiB extra per task | you need Python Code nodes |
| `RUNNERS_MAX_CONCURRENCY` | `5` | tasks one runner runs in parallel (documented value; the code default is 10) | keep it ≤ `WORKER_CONCURRENCY` |
| `RUNNERS_TASK_TIMEOUT` | `300` | seconds a Code-node task may run, broker *and* sidecar; without it the launcher forces 60 s into the runners | long-running Code nodes |

Memory limits are cgroup caps, not reservations: they stop a runaway execution, and a container over its limit is
OOM-killed and restarted. The defaults fit a 4 GB host with two workers.

| Setting | Default | Notes |
|---|---|---|
| `MEM_LIMIT_MAIN` | `1g` | UI, API, triggers; migrations are its peak |
| `MEM_LIMIT_WEBHOOK` | `512m` | per processor — they only enqueue jobs |
| `MEM_LIMIT_WORKER` | `1g` | raise first for big binaries or high concurrency |
| `MEM_LIMIT_RUNNERS` | `512m` | ~200 MiB per concurrent JS task |
| `MEM_LIMIT_POSTGRES` | `1g` | `shared_buffers` is 256 MB |
| `MEM_LIMIT_VALKEY` | `384m` | `maxmemory` 256 MB with `noeviction` |
| `MEM_LIMIT_CADDY` | `256m` | idles low, peaks on TLS and HTTP/3 |
| `MEM_LIMIT_BACKUP` | `1536m` | must be ≥ `BACKUP_TMPFS_SIZE` + 256m; preflight fails otherwise |
| `MEM_LIMIT_PROMETHEUS`, `_GRAFANA`, `_LOKI`, `_ALLOY`, `_NODE_EXPORTER`, `_CADVISOR`, `_KUMA` | `512m`, `768m`, `512m`, `384m`, `128m`, `256m`, `384m` | monitoring profile only |

### WORKER_REPLICAS and WORKER_CONCURRENCY

Workers 1 and 2 are static services. Above 2, `make render` writes `compose.scale.yml` with `n8n-worker-3..N` and a
sidecar each; at 1 it parks the second pair behind a Compose profile. Use `make scale-workers N=…` rather than editing
the value by hand — it does all of that, clears up what is no longer wanted, and checks the result.

Concurrency 10 is n8n's own default and n8n recommends at least 5. The ceiling is the database: each n8n process holds
`DB_POSTGRESDB_POOL_SIZE` (4) connections, so the five static processes use 20 and sixteen workers would use 76,
comfortably under Postgres' `max_connections=150`; `make doctor` warns past 80 % of it. For scale: on a 2 vCPU /
7.7 GB host with 2 workers at concurrency 10, the drills absorbed a 200-job burst in 14 s at 40 requests/s intake,
ran about 850 executions/min and peaked at a backlog of 161. Run **at least two workers** — Bull's stalled-job sweep
only runs inside a process that consumes the queue, so a single-worker instance has nobody to notice when its one
worker dies ([Chaos drills](operations/chaos-drills.md)).

## 4 Executions

| Setting | Default | What it does | Change it when |
|---|---|---|---|
| `EXECUTIONS_DATA_PRUNE` | `true` | delete old execution data automatically | practically never |
| `EXECUTIONS_DATA_MAX_AGE` | `336` | hours finished executions are kept (14 days) | you need longer history |
| `EXECUTIONS_DATA_PRUNE_MAX_COUNT` | `10000` | hard cap on stored executions, oldest pruned first | a trigger fires thousands of times an hour |
| `EXECUTIONS_DATA_SAVE_ON_SUCCESS` | `all` | store data of successful runs: `all` or `none` | `none` at very high volume |
| `EXECUTIONS_DATA_SAVE_ON_ERROR` | `all` | the same for failed runs | rarely: this is your evidence |
| `EXECUTIONS_DATA_SAVE_ON_PROGRESS` | `false` | persist after every node — survives a crash mid-run, costs writes | partial progress matters |
| `EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS` | `true` | keep editor test runs | heavy editor use, small disk |
| `EXECUTIONS_TIMEOUT` | `-1` | default per-workflow timeout in seconds, `-1` = none | you want a floor under runaways |
| `EXECUTIONS_TIMEOUT_MAX` | `3600` | highest timeout a workflow may set itself | a workflow needs longer |
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | `-1` | global production cap | leave it: any other value overrides `--concurrency` on **every** worker |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `30` | seconds n8n waits for running executions on SIGTERM | see below |

**Pruning is global and oldest-first**, which surprises people: there is no per-workflow equivalent, so when the count
cap is reached the oldest rows go, whichever workflow they belong to. A burst of test traffic therefore pushes real
history out of the database — which is why `make loadtest` warns and asks for confirmation once `N × 4` would exceed `EXECUTIONS_DATA_PRUNE_MAX_COUNT`. n8n-main
prunes hourly, and `make doctor` warns when the oldest execution is older than twice `EXECUTIONS_DATA_MAX_AGE`, which
means pruning has stalled.

### The graceful-shutdown timeout is what makes a drain work

On SIGTERM n8n pauses its queues, waits for in-flight executions for 80 % of this timeout, then cancels the stragglers
deterministically. That matters more than it looks, because **a worker that dies without a graceful shutdown loses the
executions it had in flight — they are not retried and not re-queued.** n8n hard-codes Bull's `maxStalledCount` to
`0`, so the first stall fails the job instead of returning it to the wait list; n8n 2.0 removed that retry
deliberately. Queued work is safe. `docker kill` does not even trigger `restart: unless-stopped`, because Docker
treats it as an operator stop.

So drain rather than kill: `docker stop`, or `make upgrade`, which waits out running executions for
`UPGRADE_DRAIN_TIMEOUT` (300 s) and then hands the stragglers this grace period. Set the timeout above your p99
execution time and give critical workflows an Error Workflow. The n8n services' compose `stop_grace_period` is 40 s —
deliberately above the 30 s default, so Docker never SIGKILLs an execution n8n would have finished — and it lives in
`docker-compose.yml`, so raise it whenever you raise this knob. A `crashed` execution may already have done its side
effect, so keep replays idempotent; [Chaos drills](operations/chaos-drills.md) measures all of this.

## 5 Security

Names were checked against the 2.42 image, and the ones that match n8n's own default are set explicitly so a future
default change cannot quietly loosen the kit.

| Setting | Default | What it does |
|---|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `true` | Code and expression nodes cannot read `process.env` |
| `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES` | `true` | nodes cannot read `/home/node/.n8n` — config, key file, event logs |
| `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` | `true` | keeps `/home/node/.n8n/config` at 0600 on the shared volume |
| `N8N_GIT_NODE_DISABLE_BARE_REPOS` | `true` | the Git node refuses bare repositories, an RCE vector |
| `N8N_DIAGNOSTICS_ENABLED` | `false` | no anonymous telemetry to n8n.io |
| `N8N_PERSONALIZATION_ENABLED` | `false` | no onboarding questionnaire |
| `N8N_HIRING_BANNER_ENABLED` | `false` | no hiring banner in the console |
| `N8N_TEMPLATES_ENABLED` | `true` | the template gallery, fetched from n8n.io |
| `N8N_VERSION_NOTIFICATIONS_ENABLED` | `true` | the "new version available" hint; it only compares version numbers |
| `N8N_PUBLIC_API_DISABLED` | `false` | `/api/v1` stays on, behind API keys and `UI_PROTECT` |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | `false` | unverified community packages stay blocked (2.42 warns when unset) |
| `NODES_EXCLUDE` | the two shell/filesystem nodes | node types that may not be used |

Handle `NODES_EXCLUDE` carefully: any value **replaces** n8n's built-in list, so keep both default entries
(`n8n-nodes-base.executeCommand`, `n8n-nodes-base.localFileTrigger`) when you add more, on one line inside single
quotes.

Two settings are left out on purpose. `N8N_RESTRICT_FILE_ACCESS_TO` stays at its 2.x default `/home/node/.n8n-files`,
which the kit mounts as the dedicated `n8n_files` volume — that directory is the Read/Write Files node's whole world,
and moving it inside `/home/node/.n8n` would collide with the block above. MFA enforcement needs
`N8N_MFA_ENFORCED_ENABLED=true` **and** `N8N_SECURITY_POLICY_MANAGED_BY_ENV=true`, which hands the whole security
policy to environment variables; enable MFA per user in the UI, or add both keys here and to the compose environment
map. Do not set `N8N_ENDPOINT_*` at all: the Caddyfile routes n8n's default paths, custom names would reach the wrong
process, and `make doctor` fails on it.

## 6 Backups

| Setting | Default | What it does | Change it when |
|---|---|---|---|
| `BACKUP_ENABLED` | `true` | schedules the nightly backup and weekly restore test; `false` schedules nothing (`make backup-now` still works) and `make doctor` warns | never on a live instance |
| `BACKUP_REMOTES` | empty | space-separated targets that **all** receive every backup | before going live — see below |
| `BACKUP_LOCAL_PATH` | empty | host directory that appears as `/backups/external` | you have an external disk or NAS; a dedicated sub-directory, never `$HOME` |
| `BACKUP_SCHEDULE` | `'0 2 * * *'` | cron expression, in `GENERIC_TIMEZONE` | your quiet hour is elsewhere |
| `RESTORE_TEST_SCHEDULE` | `'0 3 * * 0'` | the weekly restore test | as above |
| `BACKUP_RETENTION_DAILY_DAYS` | `30` | how long `daily/` bundles are kept, whole days ≥ 1 | your policy differs |
| `BACKUP_RETENTION_MONTHLY_DAYS` | `365` | the same for `monthly/` | as above |
| `BACKUP_RETENTION_MIN_KEEP` | `7` | newest bundles retention never deletes at any age, so a clock that jumps ahead cannot empty a remote | rarely |
| `BACKUP_NOTIFY_SUCCESS` | `false` | Telegram message for successful runs too; failures are always sent | you want daily confirmation |
| `BACKUP_TMPFS_SIZE` | `1g` | RAM scratch for the dump, the bundle and the restore-test database — about 3× the dump | the dump grows; raise `MEM_LIMIT_BACKUP` with it |
| `RESTORE_TEST_MAX_AGE_HOURS` | `26` | the restore test fails when a target's newest bundle is older | a non-daily schedule |
| `RCLONE_CONFIG_R2_*` | empty | R2 access key, secret, endpoint for an `r2:` target | you back up to R2 |
| `RCLONE_CONFIG_S3_*` | region `ap-southeast-1` | S3 credentials for an `s3:` target | you back up to S3 |
| `BACKUP_AGE_PUBLIC_KEY` | filled by `init` | the host recipient; its private half is `secrets/age-key.txt` | only to replace the pair |
| `BACKUP_AGE_RECOVERY_PUBLIC_KEY` | filled by `init` | the recovery recipient | as above |
| `BACKUP_ALLOW_SINGLE_RECIPIENT` | `false` | allows backups encrypted to the host key alone | almost never |

**BACKUP_REMOTES** accepts `/backups/local` (the `compose/backups` directory here), `/backups/external[/dir]`
(whatever `BACKUP_LOCAL_PATH` points at) and any rclone remote `name:bucket/path` — the kit configures `r2:` and
`s3:`, and another remote needs its own `RCLONE_CONFIG_<NAME>_*` variables in a `compose.override.yml`. Anything else is
`/backups/external` (whatever `BACKUP_LOCAL_PATH` points at), `r2:BUCKET/PATH` and `s3:BUCKET/PATH`. Anything else is
refused, because a typo such as `r2/bucket` would be written inside the container and vanish on restart. Every listed
target receives every backup, and a backup counts as successful only when all of them did. Give each stack its own
prefix: retention prunes every kit bundle under `<target>/daily`. `make init` sets `/backups/local` for dev domains
and leaves it empty for public ones — preflight warns while it is empty, and `make doctor` fails on it.

**The two age keys** are what make the bundles recoverable. The host key (`secrets/age-key.txt`) stays here and is
what the weekly restore test and `make restore` use; the recovery key belongs in your password manager, off the host,
which is what `make detach-recovery-key` is for — a lost host must not mean lost backups. A bundle with one recipient
is refused unless `BACKUP_ALLOW_SINGLE_RECIPIENT=true`, and `make init` never replaces existing age keys, because that
would orphan every backup already taken.

## 7 Monitoring

| Setting | Default | What it does |
|---|---|---|
| `COMPOSE_PROFILES` | empty | `monitoring` adds Prometheus, Grafana, Loki, Alloy, node-exporter and cAdvisor (~1 GB RAM more); `monitoring,kuma` adds Uptime Kuma. Profile-gated services are invisible to `make up` and `make status` until listed here |
| `GRAFANA_ADMIN_USER` | `admin` | Grafana's admin login, applied when it first creates its database |
| `PROM_RETENTION` | `15d` | how long Prometheus keeps data |
| `PROM_RETENTION_SIZE` | `2GB` | how much it keeps; whichever limit is hit first |
| `LOKI_RETENTION` | `336h` | how long Loki keeps the container logs (14 days) |
| `ALERT_TELEGRAM_BOT_TOKEN` | empty | bot token for every alert — backup failures and Grafana's rules. Empty means nothing is *sent*; Grafana still shows them |
| `ALERT_TELEGRAM_CHAT_ID` | empty | the chat or channel alerts go to (group ids are negative) |

`KUMA_ENABLED` (group 1) and the `kuma` profile must agree, and preflight fails when they do not.
[Monitoring and alerts](operations/monitoring.md) covers the dashboards and the rules.

## 8 Local

`COMPOSE_PROJECT_NAME` (default `n8nkit`) is the prefix of every container, network and volume name. It is fixed so
volumes are called `n8nkit_pg_data` whatever the checkout directory is called, and so a second copy of the kit on one
host needs nothing but a different `.env`.

## versions.env: the image pins

`versions.env` holds an image, a tag and a digest per service, so every `make up` starts the exact bytes that were
tested — a tag can be re-pushed, a digest cannot. `make pin` rewrites the `*_DIGEST` lines; do not edit them by hand.
The core pins are n8n 2.42.4 with runners 2.42.4, Postgres 18.6-alpine, Valkey 9.1.2-alpine and Caddy 2.11.7-alpine;
the monitoring images are pinned in the same file. n8n and its runners image **must** share `N8N_VERSION` — the kit's
version lock, which `make doctor` checks.

The n8n pin lives there rather than in `.env` for a mechanical reason: Compose reads `versions.env` first and `.env`
second, so an `N8N_VERSION`, `N8N_DIGEST` or `RUNNERS_DIGEST` in `.env` would override the pin for every service, and
`make upgrade` could never take effect. The version guard that `make up` runs therefore refuses to start anything
while `.env` sets one of those three keys, and also when:

- an upgrade or rollback is unfinished — it owns the stack until it is finished or undone;
- `versions.env` pins a **newer** n8n than this installation runs. That is an upgrade, and only `make upgrade` takes
  the backup and runs the migrations in order;
- `versions.env` pins an **older** n8n than the database was last used with. n8n would start on the newer schema
  without a word, because it ignores migrations it does not know.

The middle case is what a `git pull` of the kit produces: the pin moves, and `make up` stops and tells you to run
`make upgrade`. `FORCE_VERSION=1` skips the version comparison, never a pending upgrade. The procedure itself, and
what `make rollback` can and cannot undo, is in [Upgrade and rollback](operations/upgrade-rollback.md).
