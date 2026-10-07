# n8n Production Kit

[![ci](https://github.com/nhhandevops/n8n-prod-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/nhhandevops/n8n-prod-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Production-grade self-hosted **n8n** in 15 minutes: queue mode (main + webhook processors + workers + task runners), Postgres, Valkey, automatic TLS, encrypted off-host backups with weekly restore tests, Prometheus / Grafana / Loki monitoring, and safe upgrade / rollback — as **Docker Compose** for a VPS, **Terraform** for AWS, and a **Helm chart** for Kubernetes. Plus ready-to-import workflow templates for Vietnamese businesses (Zalo, VietQR, Google Sheets, Google Chat, AI FAQ bot).

> **Status: building in public.** The Compose core runs (queue mode, TLS, `make init / up / status / doctor / scale-workers`) — see [`compose/README.md`](compose/README.md). Backups, monitoring, upgrades and the docs site are still being built; progress lives in [`n8n-kit-HANDOFF.md`](n8n-kit-HANDOFF.md). Not production-ready until v0.1.0.

## Why this exists

Most self-hosting guides stop at `docker run n8n`. That single container has no TLS, no queue, no backups, loses every credential if the encryption key is lost, and falls over at the first webhook burst. Doing it properly takes days the first time. This kit packages a setup that already runs in production, with every opinionated default explained.

## Quickstart (target — Compose on a fresh VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash   # Docker + tools
git clone https://github.com/nhhandevops/n8n-prod-kit && cd n8n-prod-kit/compose
make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com   # generates secrets and age keys
make preflight && make up && make status                        # DNS, ports, disk → stack up → login URL
```

## Topology

```text
                      Internet
                         │
                       Caddy (TLS, HTTP→HTTPS, security headers)
          ┌──────────────┴───────────────┐
  /webhook/* /form/* /mcp/* …      everything else (UI, API, *-test/*)
          │                              │
  n8n-webhook ×2                    n8n-main ×1 ── runners sidecar
          └──────── Valkey (queue) ──────┘
                         │
                 n8n-worker ×N ── runners sidecar each
                         │
                    Postgres 18
   backups: pg_dump + key bundle → age → R2 / S3 / local disk, restore-tested weekly
   monitoring (optional profile): Prometheus · Grafana · Loki + Alloy · Uptime Kuma → Telegram
```

## What you get

| | |
|---|---|
| **Queue mode done right** | main, 2 webhook processors, N workers, 1:1 task-runner sidecars, pinned image digests |
| **Nothing precious on one disk** | nightly encrypted backups (two `age` recipients) to any mix of Cloudflare R2, AWS S3 or a local disk; automatic weekly restore test |
| **Day-2 operations** | `make upgrade` / `rollback` / `scale-workers` / `backup-now` / `restore` / `doctor` / `chaos` |
| **Observability** | provisioned Grafana dashboards, alert rules, Uptime Kuma |
| **Security defaults** | non-root containers, `cap_drop ALL`, read-only filesystems, `.env` 600, UI allow-list / basic auth, webhooks stay open |
| **Docs as a product** | quickstart (EN + VI), architecture, runbooks, security checklist, compatibility table |

## Roadmap

| Milestone | Scope |
|---|---|
| **M0** | Compose kit: fresh VPS → HTTPS n8n in queue mode in ≤ 15 min |
| **M1** | Backups + restore tests, monitoring, runbooks, 5 Vietnamese-business templates |
| **M2** | Terraform for AWS (ECS Fargate, RDS, ElastiCache Valkey, ALB, EFS, S3) |
| **M2.5** | Helm chart (runners as sidecars, CloudNativePG, KEDA on queue depth) |
| **M3** | Docs site + public launch |

## Repository map

```text
compose/      Docker Compose kit (Target A)        docs/        MkDocs site
terraform/    AWS (Target B)                       templates/   importable n8n workflows
k8s/          Helm chart (Target C)                tests/       smoke + bootstrap tests
scripts/      bootstrap-host.sh (apt + dnf)        n8n-kit-*.md plan, build plan, handoff, changelog
```

## Need help?

Issues and PRs are welcome — see the issue templates. For paid setup, migration from n8n Cloud, or managed hosting, open a *question* issue or contact [@nhhandevops](https://github.com/nhhandevops).

## License

[MIT](LICENSE). The kit is deployment configuration; n8n itself is licensed under the [Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md).
