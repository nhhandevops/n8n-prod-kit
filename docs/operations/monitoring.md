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
| **n8n Overview** | main/webhook/worker up, queue waiting/active, executions per minute (completed/failed), execution duration p50/p95 and by status, edge requests by status code, RSS, event-loop lag and heap per process, error log lines (Loki) |
| **Host** | CPU, memory, disks, disk I/O, and per container (of the selected Compose project) CPU, memory, network, restarts |
| **Backups** | hours since the last backup per target, last attempt status, bundle size and duration, restore-test status/age/workflow count, TLS certificate days left, the backup service's log |

The dashboards are files (`compose/monitoring/grafana/dashboards/*.json`) and cannot be saved from the UI. To change
one, edit it in Grafana, *Export → Save to file*, and commit the JSON.

## Alerts (Grafana-managed, evaluated every 30 s)

| Alert | Fires when | For |
|---|---|---|
| N8nUIDown | n8n-main cannot be scraped | 2 m |
| WebhookPoolDown | no webhook processor can be scraped | 1 m |
| WorkerMissing | a worker in the target list is down | 5 m |
| QueueBacklog | more than 500 jobs waiting | 5 m |
| ExecutionFailureRate | more than 10 % of executions failed in 15 min (at least 5 ran) | 15 m |
| BackupMissing | the oldest last-success over all targets is older than 26 h, or no backup metric exists | 5 m |
| BackupLastAttemptFailed | the last backup attempt failed on a target | — |
| RestoreTestFailed | the last restore test failed | 5 m |
| RestoreTestStale | no passing restore test for 8 days | 30 m |
| DiskHigh | root filesystem more than 80 % full | 10 m |
| CertExpiring | the certificate Caddy serves expires within 14 days (ACME modes; hourly cert-check) | 1 h |
| ContainerRestarting | a container restarted more than twice in 15 min (one alert per Compose project on the host) | — |
| MonitoringTargetDown | Caddy metrics, node-exporter, cAdvisor, Loki or Alloy cannot be scraped | 5 m |

Notification policy: grouped per alert, first message after 30 s, repeated every 4 h while firing, plus a message when
it resolves. The rules live in `compose/monitoring/grafana/provisioning/alerting/rules.yml`.

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

Open `https://kuma.DOMAIN/` and create the admin account on the first visit. Suggested monitors (type HTTP(s)):

| Name | URL | Expect |
|---|---|---|
| n8n main | `https://DOMAIN/healthz` | 200 |
| webhook pool | `https://DOMAIN/healthz/webhook` | 200 |
| editor | `https://DOMAIN/` | 200, keyword `n8n` |

Kuma sends its own notifications (Settings → Notifications → Telegram, same bot). In dev (`TLS_MODE=internal`) it trusts
the kit's local CA like n8n does. It sees the stack from inside the host, so add an external check (any free uptime
service) for a view from outside.

## Security notes

- Loki, Alloy, node-exporter and cAdvisor are only on the `monitoring` network. The n8n workers execute user
  workflows that can call any address on their own networks, and Loki holds every log line without a login.
  Prometheus also joins `internal` to scrape n8n, so its read-only API is reachable from workflows: metrics only,
  no secrets.
- Alloy mounts the Docker socket read-only. A Docker socket is root-equivalent even when mounted read-only, so Alloy
  is the most privileged container of the profile. It only reads container logs, and it has no published port.
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
| BackupMissing right after enabling the profile | no backup has run yet: `make backup-now` |
