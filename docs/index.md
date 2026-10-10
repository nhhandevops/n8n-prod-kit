# n8n Production Kit

Self-hosted [n8n](https://n8n.io) in queue mode on one Docker host, with the parts that a single
`docker run n8n` leaves out: TLS, a pool of webhook processors, workers with sandboxed Code nodes,
Postgres, a durable queue, encrypted off-host backups that are restore-tested every week, monitoring
with alerts, and an upgrade that takes a backup first and can be rolled back. Every image is pinned by
digest, every core container runs non-root with a read-only root filesystem and all capabilities dropped, and every opinionated default is
explained where it is set.

The kit is a repository you clone onto a VPS, not a product you install. `compose/.env` holds your
settings and secrets, `make` is the operator interface, and the scripts behind each target do only what
a person could type by hand. The current version pins **n8n 2.42.4** with matching task runners,
**Postgres 18**, **Valkey 9.1** and **Caddy 2.11** — [Compatibility](compat.md) records what was tested
where.

## Who it is for

- **Developers and agencies** who host automations for clients and want a known-good stack rather than a
  weekend of research.
- **Teams leaving n8n Cloud** who have real workflows and credentials to move and cannot afford to lose
  either.
- **Engineers evaluating n8n** who need a reference topology, failure-mode notes and numbers measured on
  a real host.

It is a single-host Compose deployment. n8n's enterprise features (multi-main, SSO) are out of scope.
Terraform for AWS and a Helm chart are planned milestones, not shipped code.

## What you get

```text
                      Internet
                         |
                    caddy  (the only published ports: HTTP_PORT, HTTPS_PORT + HTTPS_PORT/udp)
       +-----------------+------------------+
  /webhook/* /webhook-waiting/*             everything else: editor UI, /rest, /api,
  /form/* /form-waiting/* /mcp/*            /webhook-test/*, /form-test/*, /mcp-test/*
       |                                                 |
  n8n-webhook-1, n8n-webhook-2 (round robin)         n8n-main  (UI, API, triggers, migrations)
       +------------- valkey (Bull queue) --------------+
                         |
   n8n-worker-1 + n8n-worker-1-runners  ...  n8n-worker-N + n8n-worker-N-runners
                         |
                    postgres  (workflows, credentials, executions, binary data)

   backup sidecar: nightly pg_dump + encryption key -> age -> R2 / S3 / local disk, restore-tested weekly
```

| Service | Role |
|---|---|
| `caddy` | TLS (ACME, ACME staging or an internal CA), HTTP to HTTPS, security headers, routing, optional UI protection |
| `n8n-main` | editor UI, REST and public API, triggers and schedules, database migrations; runs no production webhooks |
| `n8n-webhook-1`, `n8n-webhook-2` | production webhooks, forms and MCP endpoints; they enqueue jobs and execute nothing |
| `n8n-worker-1`, `n8n-worker-2` | every queued execution; `make scale-workers N=1..16` adds or removes them |
| `n8n-worker-N-runners` | one task-runner sidecar per worker, where Code-node tasks run with no network of their own |
| `postgres` | PostgreSQL 18, shared by all five n8n processes |
| `valkey` | the Bull queue, AOF-persistent, `noeviction` so a full broker errors instead of dropping jobs |
| `backup` | nightly backup, weekly restore test, hourly certificate check, Telegram alerts |
| `monitoring` profile | Prometheus, Grafana at `/grafana/`, Loki, Alloy, node-exporter, cAdvisor |
| `kuma` profile | Uptime Kuma on `kuma.DOMAIN` for the outside view |

Behind those services:

- **Queue mode done properly.** Main does not answer production webhooks
  (`N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true`) and manual editor runs are offloaded to the workers, so
  restarting the UI does not interrupt inbound traffic. Caddy health-checks each upstream on
  `/healthz/readiness`, never `/healthz` — a starting n8n answers 200 on every path before it is
  connected and migrated. Every proxied response carries `X-Kit-Upstream`, so you can see which process
  served it.
- **Nothing precious on one disk.** A backup is a `pg_dump -Fc`, the `N8N_ENCRYPTION_KEY` and a
  manifest, encrypted with [age](https://age-encryption.org) to two recipients: the host key and an
  offline recovery key that belongs in your password manager. Every target listed in `BACKUP_REMOTES`
  must receive the bundle for the backup to count as successful, and the weekly restore test restores
  one into a scratch Postgres and decrypts a credential out of it.
- **Day-2 operations as `make` targets.** `init`, `preflight`, `up`, `status`, `doctor`,
  `scale-workers`, `backup-now`, `backups`, `restore`, `restore-test`, `upgrade`, `rollback`,
  `loadtest`, `chaos`, `pin`, `smoke`, `lint` — `make -C compose help` lists them all.
- **Hardening by default.** `cap_drop: ALL`, `no-new-privileges`, read-only root filesystems with a
  measured tmpfs write set, per-container memory limits, a backend network with no route out at all,
  `/metrics` answering 404 at the edge, and request headers dropped from Caddy's access log so API keys
  never reach the log store.
- **Measured, not assumed.** `make loadtest` and `make chaos` produce the numbers these docs quote. On a
  2 vCPU / 7.7 GB host with 2 workers at concurrency 10: a 200-job burst absorbed in 14 s, about 850
  executions per minute, 40 webhook requests/s at the edge, peak backlog 161. The drills also recorded
  what the kit cannot do — a killed worker's in-flight executions are lost rather than retried. That is
  on [Chaos drills](operations/chaos-drills.md), with the evidence.

## Quickstart

Four commands on a fresh Ubuntu 24.04/26.04, Debian 12/13, or Rocky / AlmaLinux / CentOS Stream /
Oracle Linux / RHEL 9 or 10 host:

```bash
curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash -s -- --yes
git clone https://github.com/nhhandevops/n8n-prod-kit && cd n8n-prod-kit/compose
make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com
make preflight && make up && make status
```

The bootstrap script installs Docker Engine and the Compose plugin from Docker's own repository plus
`make`, `jq` and `git`, and is idempotent. Log out and back in before the next command: membership of the `docker` group only applies to a new login session, and both `make init` (its age-key fallback runs a container) and `make preflight` need the Docker daemon. `make init` writes `.env` (mode 600) with generated secrets
and two age keys under `secrets/`. `make preflight` checks Docker, `.env`, the ports, DNS, disk, RAM and
the clock, and exits 1 on any failure. `make up` runs preflight again itself, pulls the pinned images,
starts everything with `--wait`, and ends with the health table and the login URL.

Read [Quickstart](quickstart.md) before running it: it covers DNS and ports, what to put in a password
manager before anything else, and the local variant that needs no public domain.

## Where to go next

| Page | What is on it |
|---|---|
| [Quickstart](quickstart.md) | fresh host to a working HTTPS instance, step by step |
| [Bắt đầu nhanh](quickstart.vi.md) | the same walkthrough in Vietnamese |
| [Runbook](runbook.md) | every feature tried on purpose on a host you can break, with a sign-off sheet |
| [Architecture](architecture.md) | the topology, the networks, and why each process exists |
| [Configuration](configuration.md) | the settings in `compose/.env` and what changing them does |
| [Security](security.md) | the hardening in place, what is exposed, and what you still own |
| [Backup and restore](operations/backup-restore.md) | what a bundle contains, restoring on the same host, disaster recovery on a new one |
| [Upgrade and rollback](operations/upgrade-rollback.md) | `make upgrade` step by step, and how to go back |
| [Monitoring and alerts](operations/monitoring.md) | the `monitoring` profile, dashboards, alert rules, Telegram |
| [Scaling](operations/scaling.md) | worker count, concurrency, and what to raise first |
| [Chaos drills](operations/chaos-drills.md) | `make chaos`, the measured failure behaviour, what a killed worker costs |
| [Rebuild a host](operations/rebuild-vps.md) | moving an instance to another host |
| [RHEL-family hosts](operations/rhel-hosts.md) | the dnf install path, SELinux `:z` labelling, firewalld |
| [Compatibility](compat.md) | which n8n, Postgres, Valkey, Caddy and host versions were tested |
| [FAQ](faq.md) | the recorded gotchas, each with what to do about it |
| [Contributing](contributing.md) | the contract for a pull request, and how to run the checks locally |

## Status

Tagged **v0.1.0** on 2026-10-10, as a pre-release. The Compose kit runs, is documented, and every
claim on these pages was checked against the code or measured on a real host — but the acceptance test
is still outstanding: nobody outside the project has followed the quickstart on a fresh host with a
stopwatch, and route A's real Let's Encrypt path has never been walked (every verified run so far used
an internal CA). Treat it as "runs, documented, not yet independently reproduced". Current status and
open items live in `n8n-kit-HANDOFF.md` in the repository.

Bug reports and questions go through the
[issue templates](https://github.com/nhhandevops/n8n-prod-kit/issues); questions about n8n itself belong
in the [n8n community forum](https://community.n8n.io/).

The kit is [MIT](https://github.com/nhhandevops/n8n-prod-kit/blob/main/LICENSE) licensed. It is
deployment configuration — n8n itself is licensed under the
[Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md).
