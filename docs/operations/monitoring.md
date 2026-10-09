# Monitoring and alerts

The `monitoring` Compose profile adds metrics, logs, dashboards and alerts to the stack. Nothing in it is published
except through Caddy: Grafana under `https://DOMAIN/grafana/`, Uptime Kuma (optional) on `https://kuma.DOMAIN/`.

| Component | Image (pinned in `versions.env`) | Role |
|---|---|---|
| Prometheus | `quay.io/prometheus/prometheus` 3.13 (LTS) | scrapes every n8n process, Caddy, the host, the containers, the backup metrics |
| Grafana | `grafana/grafana` 13 | dashboards, alert rules, Telegram notifications |
| Loki | `grafana/loki` 3.7 | stores the stack's container logs (`LOKI_RETENTION`, default 14 days) |
| Alloy | `grafana/alloy` 1.20 | reads the logs of THIS Compose project from Docker and ships them to Loki |
| node-exporter | `quay.io/prometheus/node-exporter` | host CPU/RAM/disk + the backup sidecar's textfile metrics |
| cAdvisor | `ghcr.io/google/cadvisor` | CPU/memory/network/restarts per container |
| Uptime Kuma (profile `kuma`) | `ghcr.io/louislam/uptime-kuma` 2 | the outside view: is `https://DOMAIN/healthz` answering? |

## Turn it on

In `compose/.env`:

```ini
COMPOSE_PROFILES=monitoring          # or monitoring,kuma together with KUMA_ENABLED=on
ALERT_TELEGRAM_BOT_TOKEN=123456789:AAH...
ALERT_TELEGRAM_CHAT_ID=-1001234567890
```

Then `make up`. `make status` prints the URLs. Log in to Grafana as `GRAFANA_ADMIN_USER` with
`GRAFANA_ADMIN_PASSWORD` from `.env`. Both are applied when Grafana first creates its database; to change the password
later: `docker compose … exec grafana grafana cli admin reset-admin-password <new>`.

The profile needs about 1 GB of RAM on a small stack (memory ceilings: `MEM_LIMIT_PROMETHEUS`, `_GRAFANA`, `_LOKI`,
`_ALLOY`, `_NODE_EXPORTER`, `_CADVISOR`, `_KUMA`). With `kuma` in acme mode, `kuma.DOMAIN` needs its own DNS record
pointing at the host (preflight checks it).

### Telegram

1. Talk to [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
2. Add the bot to the group or channel that should get the alerts, send it any message, then open
   `https://api.telegram.org/bot<token>/getUpdates` and copy `chat.id` (groups and channels are negative numbers).
3. Put both into `.env`, `make up`. Both the backup sidecar and Grafana use them. `make doctor` says
   whether alerts are delivered anywhere.

## Dashboards (folder "n8n-kit")

| Dashboard | Shows |
|---|---|
| **n8n Overview** | n8n-main up; webhook processors and workers as "up / down" (one member down shows red); queue waiting/active; executions per minute (completed/failed); execution duration p50/p95 and by status (empty when nothing ran in the last 5 min); edge requests by status code (without Prometheus' own scrapes); RSS, event-loop lag and heap per process; error lines of n8n, the task runners and Caddy (Loki) |
| **Host** | CPU busy (the stack includes "not accounted by the guest kernel" — on a VM, time the hypervisor took), memory, load per CPU, disks, disk I/O (physical disks only), CPU by Compose project (which project uses the host), and for this kit's containers: CPU, memory, memory as % of its MEM_LIMIT, network, restarts |
| **Backups** | hours since the last backup per target, last attempt status, bundle size and duration, restore-test status/age/workflow count, TLS certificate days left ("not checked" in internal TLS, "cert-check failing" when the hourly check fails), the backup service's log |

The dashboards are files (`compose/monitoring/grafana/dashboards/*.json`) and cannot be saved from the UI. To change
one, edit it in Grafana, *Export → Save to file*, and commit the JSON.

## Alerts (Grafana-managed, evaluated every 30 s)

| Alert | Severity | Fires when | For |
|---|---|---|---|
| N8nUIDown | critical | n8n-main cannot be scraped | 2 m |
| WebhookPoolDown | critical | no webhook processor can be scraped | 1 m |
| WebhookProcessorMissing | warning | some, but not all, webhook processors are down | 5 m |
| WorkerPoolDown | critical | no worker can be scraped — nothing executes (the only worker with `WORKER_REPLICAS=1`) | 2 m |
| WorkerMissing | warning | some, but not all, workers are down | 5 m |
| KitServiceUnhealthy | critical | a kit container (Postgres, Valkey, Caddy, backup, any n8n process or runner) fails its Docker healthcheck — Postgres or Valkey down shows up here, because n8n keeps answering /metrics without them | 5 m |
| QueueBacklog | warning | more than 500 jobs waiting | 5 m |
| ExecutionFailureRate | warning | more than 10 % of production executions failed over 15 min (at least 5 ran; editor test runs not counted) | 5 m |
| BackupMissing | critical | the oldest last-success over all targets is older than 26 h (a target that never succeeded counts as never); the clock starts when backups were switched on, and the alert is quiet while `BACKUP_ENABLED=false` | 5 m |
| BackupLastAttemptFailed | warning | the last backup attempt failed on a target | — |
| RestoreTestFailed | critical | the last restore test failed | 5 m |
| RestoreTestStale | warning | no passing restore test for 8 days since backups were switched on | 30 m |
| DiskHigh | warning | any real filesystem of the host more than 80 % full (one alert per mount point) | 10 m |
| CertExpiring | warning | the certificate Caddy serves expires within 14 days (ACME modes) | 1 h |
| CertCheckFailing | warning | the hourly certificate check failed three times in a row (CertExpiring would be blind) | 2 h 30 m |
| ContainerMemoryPressure | warning | a kit container spends more than 10 % of its time waiting for memory (Linux PSI: it presses against its MEM_LIMIT_* and reclaims or swaps) | 10 m |
| ContainerOOMKilled | warning | the kernel OOM-killed a process of a kit container | — |
| ContainerRestarting | warning | a container of this kit restarted more than twice in 15 min | — |
| MonitoringTargetDown | warning | Caddy metrics, node-exporter, cAdvisor, Loki, Alloy or Grafana cannot be scraped | 5 m |

Notification policy: grouped per alert, first message after 30 s, repeated every 4 h while firing, plus a message when
it resolves. Messages are plain text in the kit's own short format (`🔴 FIRING: …` / `✅ RESOLVED: …`, summary,
description, link). Plain text on purpose: Grafana's default Telegram mode is HTML, in which Telegram rejects any alert
text containing `<…>` — that alert would silently never arrive. The rules live in
`compose/monitoring/grafana/provisioning/alerting/rules.yml`; rule files get no environment variables, so "this kit" is
found as "the Compose project that has an n8n-main container".

**Test the path end to end** (TC-018): stop both webhook processors and wait for the Telegram message, which should
arrive within 3 minutes:

```bash
docker compose … stop n8n-webhook-1 n8n-webhook-2     # WebhookPoolDown: scrape 15 s + eval 30 s + for 1 m + wait 30 s
make up                                               # starts them again; a "resolved" message follows
```

## Logs (Loki)

Grafana → Explore → Loki. Every line carries `service`, `container` and `project`, and n8n and Caddy lines also carry
`level`:

```logql
{service="n8n-main"}                                  # one service
{service=~"n8n-.*", level="error"}                    # every n8n error
{service="caddy"} | json | status >= 500              # 5xx at the edge
{service=~"n8n-worker-.*"} |= "Worker finished execution"
```

Only containers of this Compose project are collected (`COMPOSE_PROJECT_NAME`); other projects on the same host stay
out.

## Uptime Kuma

`make up` creates Kuma's admin account itself, right after Kuma starts (`scripts/kuma-setup.sh`; user
`KUMA_ADMIN_USER`, password `KUMA_ADMIN_PASSWORD` in `.env`, generated by `make init`). Kuma's first-run page would
otherwise let whoever reaches `kuma.DOMAIN` first create the only admin. `make doctor` fails while no admin exists; the
manual repair is `make kuma-setup`. Log in at `https://kuma.DOMAIN/` and add the monitors (type HTTP(s)):

| Name | URL | Expect |
|---|---|---|
| n8n main | `https://DOMAIN/healthz` | 200 |
| webhook pool | `https://DOMAIN/healthz/webhook` | 200 |
| editor | `https://DOMAIN/` | 200, keyword `n8n` |

Kuma sends its own notifications (Settings → Notifications → Telegram, same bot). In dev (`TLS_MODE=internal`) it trusts
the kit's local CA like n8n does. It sees the stack from inside the host, so add an external check (any free uptime
service) for a view from outside.

## Security notes

The n8n workers execute user workflows, and a workflow can call any address on the worker's networks. The profile is
laid out so that nothing sensitive is on those networks (smoke 09 checks it from inside a worker on every CI run):

- Loki (every log line, no login), Alloy, node-exporter and cAdvisor are only on the internal `monitoring` network.
- Grafana and Uptime Kuma each have a private network with Caddy (`edge-grafana`, `edge-kuma`) instead of sharing
  `proxy` with the workers — workflows cannot reach them past Caddy's `/grafana/metrics` block and `UI_PROTECT`.
- Prometheus joins `internal` to scrape n8n, so its read-only API is reachable from workflows: metrics of this kit and
  the container inventory (names, images, memory) of every Compose project on the host — no secrets, but not private
  either. Admin, lifecycle and remote-write endpoints are off.
- Caddy's access logs drop all request headers (n8n's `X-N8n-Api-Key` and any header a webhook uses for auth would
  otherwise land in Loki in clear text; Caddy itself only redacts `Authorization` and `Cookie`). Query strings are still
  logged — do not put secrets into webhook URLs.
- Grafana is served from the n8n origin (`/grafana/`): the plugin catalogue, external snapshots and public dashboards are
  off, and with `UI_PROTECT=on` the edge password is not forwarded to Grafana, n8n or Kuma. A separate
  `grafana.DOMAIN` would isolate it completely (open decision in the hand-off).
- Grafana's secret key (`GRAFANA_SECRET_KEY`, generated by `make init`) encrypts what Grafana stores, such as the
  Telegram token of the contact point.
- Alloy (Docker socket) and cAdvisor (Docker and containerd sockets through `/var/run`, the whole host filesystem
  read-only) are both root-equivalent: read-only mounts, `cap_drop: ALL`, no published port, but a compromise of either
  is a compromise of the host.
- In dev (`TLS_MODE=internal`) the n8n services and Kuma get only the local CA's certificate (`secrets/dev-root.crt`),
  never Caddy's data volume with the CA's private key.
- `/metrics` of n8n and of Grafana answer 404 at the edge; Caddy's metrics are on an internal-only listener (`:2020`).
- On SELinux hosts the three host-reading services run with `label:disable` (see [rhel-hosts.md](rhel-hosts.md)).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `https://DOMAIN/grafana/` → 502 | the profile is off or Grafana is starting: `make status`, `make logs SERVICE=grafana` |
| `make doctor`: scrape target down | the named service is down or not on the expected network — `make status` |
| Host dashboard shows no containers | cAdvisor cannot read `/var/lib/docker` or the cgroups — `make logs SERVICE=cadvisor` (SELinux: see above) |
| no logs in Loki | `make logs SERVICE=alloy` (socket permission? project label filter = `COMPOSE_PROJECT_NAME`?) |
| alerts show in Grafana but no Telegram message | `ALERT_TELEGRAM_*` empty or wrong (`make doctor`); Grafana → Alerting → Contact points → *Test* |
| BackupMissing | `make logs SERVICE=backup SINCE=48h`; `make backup-now`. It starts counting when backups were switched on, so a fresh install has 26 h before the first nightly backup is due |
| `make doctor`: Uptime Kuma has no admin account yet | `make kuma-setup` (uses `KUMA_ADMIN_USER` / `KUMA_ADMIN_PASSWORD` from `.env`) |
| ContainerMemoryPressure, or a container near 100 % on "Memory per container (% of its limit)" | raise its `MEM_LIMIT_*` in `.env`, then `make up` — but first look for what grows: Grafana once sat at its limit because it gzipped every response itself (fixed: Caddy compresses, `GOMEMLIMIT=400MiB` in Go units, unused plugins off) |
