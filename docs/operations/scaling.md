# Scaling

Two knobs decide how much work this stack executes: **`WORKER_REPLICAS`** (how many worker processes) and
**`WORKER_CONCURRENCY`** (how many executions each one runs at a time). Both live in `compose/.env`. This page is
about which of the two to turn, and when turning either stops helping.

## The two knobs

| Knob | Default | Range | How to change it |
|---|---|---|---|
| `WORKER_REPLICAS` | 2 | 1–16 | `make scale-workers N=4` |
| `WORKER_CONCURRENCY` | 10 | n8n recommends ≥ 5 | edit `compose/.env`, then `make up` |

`make scale-workers N=4` writes `WORKER_REPLICAS=4` into `.env`, runs `render.sh`, converges the stack with
`docker compose up -d --wait --remove-orphans`, then checks the result: every expected worker **and** its sidecar must
be healthy, and no `n8n-worker-5..16` may still exist. It ends with one line either way.

```text
[ OK ] scale-workers: 4 worker(s) + 4 runner sidecar(s) healthy (WORKER_REPLICAS=4 saved in .env)
```

Workers come in pairs — `n8n-worker-N` plus a 1:1 `n8n-worker-N-runners` sidecar that sandboxes Code-node tasks — so
the kit does not use `docker compose up --scale`. `render.sh` writes `compose.scale.yml` with workers 3..N expanded in
full (a generated file cannot reference another document's YAML anchors), and the Makefile includes that file whenever
it exists. The same run rewrites `monitoring/prometheus/targets/n8n.json`, which Prometheus re-reads through `file_sd`
within a minute, so a new worker reaches the dashboards without a restart.

`make scale-workers` runs the version guard: it refuses while a `make upgrade` or `make rollback` is unfinished, and
when `versions.env` pins a different n8n than the one running — resolve the version mismatch first — a newer pin with `make upgrade`, an older one with `make rollback` or by pinning forward ([upgrade-rollback.md](upgrade-rollback.md)) — not by scaling.

### What happens at N=1

`n8n-worker-2` is a static service in `docker-compose.yml`, so it cannot simply be omitted. At `N=1`, `render.sh`
assigns the worker-2 pair the Compose profile `parked` — Compose then ignores it — and `scale-workers` removes the two
containers with `docker compose --profile parked rm -sf`; without that they would keep running as orphans.

Keep one worker for a dev box. Bull's stalled-job sweep only runs inside a process consuming the queue, so a
single-worker instance has **nobody to sweep its own orphans** ([chaos-drills.md](chaos-drills.md)), and
`WorkerPoolDown` then means nothing executes at all.

### What `WORKER_CONCURRENCY` sets

It is the `--concurrency` flag on the worker's command line, so changing it changes the container's command and
`make up` recreates the workers. That is a graceful stop: n8n drains for up to `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` (30 s)
and `stop_grace_period` is 40 s, so Docker never kills an execution n8n would have finished. Leave
`N8N_CONCURRENCY_PRODUCTION_LIMIT` at `-1`: any other value overrides `--concurrency` on every worker.

Three things bound it:

- **Memory.** Every parallel execution holds its data in that worker's heap. `MEM_LIMIT_WORKER` (1g) is the first
  thing to raise when executions carry big binaries.
- **Database connections.** Each n8n process keeps a pool of 4 (`DB_POSTGRESDB_POOL_SIZE`; n8n's own default is 2).
  Main + 2 webhook processors + 2 workers is 20 connections; at 16 workers it is 76, against `max_connections=150`.
  `make doctor` warns at 80 % of that.
- **Code nodes.** Those run in the sidecar. `RUNNERS_MAX_CONCURRENCY` (5) should stay at or below
  `WORKER_CONCURRENCY`, and `MEM_LIMIT_RUNNERS` (512m) wants ~200 MiB per concurrent JS task (+75 MiB for Python when
  `RUNNERS_LANGS="javascript python"`).

**Replicas or concurrency?** Concurrency is cheaper — no extra container, no extra sidecar. Replicas buy isolation:
one worker's limit cannot starve another, and a worker that dies takes only *its* in-flight executions with it. In the
kit's own drill, killing one worker at concurrency 10 cost exactly 10 of 120 executions, and those are lost rather
than retried ([chaos-drills.md](chaos-drills.md)).

## What each worker costs

The kit sets **memory limits only** — no service has a CPU limit, so workers compete for cores through the scheduler.

| Service | `MEM_LIMIT_*` default |
|---|---|
| `n8n-main` | 1g |
| each `n8n-webhook-N` | 512m |
| each `n8n-worker-N` | 1g |
| each `n8n-worker-N-runners` | 512m |
| `postgres` | 1g |
| `valkey` | 384m |
| `caddy` | 256m |
| `backup` | 1536m |

**Every worker you add costs 1.5 GiB of limit** (1g worker + 512m sidecar). At the defaults with `WORKER_REPLICAS=2`,
the n8n processes, Postgres, Valkey and Caddy come to about 6.6 GB of limits, with the backup sidecar on top. A limit
is a ceiling, not a reservation: real use is far lower, and its job is to cap a runaway execution. A container that
exceeds its limit is OOM-killed and restarted, and Docker allows the same amount again in swap when the host has swap.

The floor is what `make preflight` enforces: at least 3.5 GB RAM, 2 CPUs and 10 GB free on the Docker root. With
`COMPOSE_PROFILES=monitoring` it warns below 5 GB, because that profile adds roughly 1 GB in practice (2.9 GB of
limits). `ContainerMemoryPressure` and `ContainerOOMKilled` in [monitoring.md](monitoring.md) tell you a limit is too
tight before a user does.

## Sizing: one data point, honestly

Everything below was measured on **one** host with **one** workflow shape: a 2 vCPU / 7.7 GB Ubuntu 24.04 VM running
the core stack only, `WORKER_REPLICAS=2`, `WORKER_CONCURRENCY=10`, driven by `make loadtest`. Its async fixture is a
webhook that answers on receipt feeding one Code node, so every execution includes a round trip to the runner sidecar.

| Measurement | Result |
|---|---|
| 200-job burst | absorbed in 14 s |
| peak backlog during the burst | 161 jobs waiting |
| webhook intake | 40 req/s |
| end-to-end throughput | ~850 executions/min |

What it does not tell you is how *your* workflows behave. Executions per minute is mostly a function of how long one
execution takes: an HTTP Request node waiting 2 s on a third-party API, or a node moving a 20 MB binary through
Postgres, changes it by an order of magnitude. The kit's planning table (`n8n-kit-PLAN.md` §2.6) is design intent
rather than measurement — 2 vCPU / 4 GB / 40 GB for ~20 workflows under 10k executions/day, 4 vCPU / 8 GB / 80 GB for
~100 workflows under 100k/day. Use it to pick a VPS, then measure.

## Measure your own with `make loadtest`

```bash
cd compose
make loadtest                     # N=200 requests, P=20 in flight, MODE=async
make loadtest N=1000 P=40         # a bigger burst
make loadtest MODE=sync N=100     # per-request latency instead of throughput
```

It publishes its own `kit-smoke-load-<nonce>` workflow, fires `N` POSTs through Caddy with `P` in flight, samples the
queue, waits for every execution to reach a terminal state, then deletes the workflow (`KEEP=1` keeps it) — and
refuses to run unless every service is healthy. Exit 0 when every request produced a successful execution, 1 on a
setup failure, 2 when the queue did not drain within `DRAIN_TIMEOUT` (default `120 + N × 3` s).

**`MODE=async` versus `MODE=sync` matters.** Async answers each request as soon as the job is queued, so senders race
ahead of the workers, a backlog builds, then it drains — the only shape that measures capacity. Sync holds each
response until its workflow has finished, so at most `P` jobs exist at once; with `P` at or below
`WORKER_REPLICAS × WORKER_CONCURRENCY` no job ever waits and **the peak queue depth is 0 by construction**. The run
says so itself when it sees that.

| Line it reports | What it tells you |
|---|---|
| HTTP code histogram | intake health — anything but 200 (`000` is a dropped connection) means the edge or the pool could not keep up |
| `send phase … (N req/s)` | how fast the pool accepted work |
| `peak queue depth N waiting` | the backlog, from Valkey's `n8n:jobs:wait` list rather than n8n's gauge, which refreshes only every 20 s |
| `drain after send` / `end to end` | how long the workers needed |
| `throughput … executions/min` | the headline number |
| per-worker job split | whether every worker took load |

Non-200s at send with a queue that drains fine means the **intake** is the limit. A clean histogram with a high peak
and a long drain means the **workers** are — add replicas or concurrency. A slow run on a small host is a measurement,
not a failure; only a queue that does not drain (exit 2) is, and the script then names the three things to try: raise
`DRAIN_TIMEOUT`, add workers, or read the first worker's logs.

Every request becomes a stored execution, and n8n prunes globally, oldest first. When `N × 4` exceeds
`EXECUTIONS_DATA_PRUNE_MAX_COUNT` (10000) the run stops and asks, because the run would push roughly `N` of the instance's existing executions out of
the database — use a staging stack for large runs.

## When to scale webhook processors instead

The webhook pool is **fixed at two** here. `n8n-webhook-1` and `n8n-webhook-2` are static services and Caddy's
`WEBHOOK_UPSTREAMS` is set in `docker-compose.yml`, not `.env`. The Caddyfile accepts a longer space-separated list,
so a third processor is possible, but there is no `make` target and no `.env` knob for it — you would edit
`docker-compose.yml` and `WEBHOOK_UPSTREAMS` by hand, and that path is not tested in this kit.

It is rarely the bottleneck. Processors only enqueue jobs and never execute workflow code, which is why their limit is
512m against a worker's 1g, and the measured 40 req/s was through Caddy, TLS and the pool. If the histogram is clean,
add workers instead. Production webhooks also never touch `n8n-main`: `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true` stops
it mounting `/webhook`, `/form`, `/webhook-waiting` and `/mcp`, so restarting main does not interrupt intake — the
`main` drill measured 40/40 webhooks at 200. Every response carries `X-Kit-Upstream: <service>:5678`, so you can see
which processor answered.

## Execution data is a capacity concern

`execution_entity` is the fastest-growing table, and binary data lives in Postgres
(`N8N_DEFAULT_BINARY_DATA_MODE=database`; filesystem mode is unsupported in queue mode), so payloads land in the
database and in every backup bundle. Growth costs disk, dump size, and migration time at the next `make upgrade`.

| Setting | Default | Note |
|---|---|---|
| `EXECUTIONS_DATA_PRUNE` | `true` | leave it on |
| `EXECUTIONS_DATA_MAX_AGE` | `336` | hours (14 days) of finished executions |
| `EXECUTIONS_DATA_PRUNE_MAX_COUNT` | `10000` | hard cap, oldest pruned first |
| `EXECUTIONS_DATA_SAVE_ON_SUCCESS` | `all` | `none` on very high-volume instances — the single biggest saving |
| `EXECUTIONS_DATA_SAVE_ON_ERROR` | `all` | keep this one |
| `EXECUTIONS_DATA_SAVE_ON_PROGRESS` | `false` | persists after every node: survives crashes, costs DB writes |

`n8n-main` prunes hourly. `make doctor` reports the row count, the age of the oldest execution (warning above twice
`EXECUTIONS_DATA_MAX_AGE`, which is how a stalled pruner shows up), the database size, connection use, and disk —
warning at 80 % of the Docker root, failure at 90 %, because Postgres and Valkey stop writing at 100 %. A bigger
database also needs a bigger `BACKUP_TMPFS_SIZE` (`.env.example`: about three times the dump) with `MEM_LIMIT_BACKUP` at least 256 MiB
above it ([backup-restore.md](backup-restore.md)).

The queue has its own ceiling: Valkey runs `maxmemory 256mb` with `noeviction`, deliberately, so a full queue
**errors** instead of silently dropping jobs Bull cannot survive losing. `QueueBacklog` fires above 500 waiting jobs
for 5 minutes.

## The documented ceiling

Some limits cannot be scaled away on this target:

- **One main.** n8n's community edition supports a single main process and the kit runs exactly one, so the UI and
  the scheduler are not highly available. They come back in seconds and webhooks keep flowing meanwhile.
- **One Postgres, one Valkey, one host.** Nightly encrypted backups and Valkey's AOF (`appendfsync everysec`, so at
  most a second of queue state) are the protection, not replication. The design target for this topology is 99.5 %.
- **Sixteen workers.** `WORKER_REPLICAS` is capped at 16, and `make scale-workers` refuses anything outside 1–16.

Move to the AWS target (**Target B**) when sustained volume passes roughly **100k executions/day**, or when you need
an availability SLA rather than a 99.5 % single host. Target B is the same topology on ECS Fargate with RDS Postgres
Multi-AZ, ElastiCache Valkey, an ALB, EFS and S3, worker autoscaling driven by queue depth, and a 99.9 % target. It is
milestone **M2** on the roadmap and is not shipped yet — see `terraform/README.md`.

First work through the cheap things: more RAM and vCPU, the two knobs, `MEM_LIMIT_WORKER`, then
`EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` — re-running `make loadtest` with the same `N` and `P` after each change, so
you can see whether it helped.
