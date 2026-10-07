# n8n Production Kit — Project Plan

Version 0.1 · 2026-10-06 · Owner: An · Working name: `n8n-prod-kit` (public, open source)

Master plan. §1 what and why, §2 how it is built, §3 how it is demonstrated, tested, and tracked. §4 points to `n8n-kit-HANDOFF.md`.

---

## 1. Introduction

### 1.1 The problem

Most n8n self-hosting guides stop at `docker run n8n`. That single container has no TLS, no queue, no backups, loses every credential if the encryption key is lost, and falls over at the first webhook burst. Small businesses and agencies that want to escape n8n Cloud pricing end up either running a fragile toy setup or paying someone to do it properly. Doing it properly (queue mode, separate webhook processors and workers, Postgres, Redis, TLS, backups, monitoring, safe upgrades) takes a few days the first time. An has already done it in production at work; this kit packages that knowledge.

### 1.2 Target users

| Segment | Who | Why they care | Priority |
|---|---|---|---|
| Solo developers / agencies in Vietnam and SEA | Build automations for clients, want cheap reliable hosting | Need a known-good stack they can deploy in 15 minutes | Primary (GitHub users) |
| SMEs leaving n8n Cloud | Have 5–50 workflows, hit plan limits | Want self-hosting without hiring DevOps | Primary (paid setup customers) |
| DevOps engineers evaluating n8n | Need HA reference architecture | Terraform + docs save them a week | Secondary (stars, credibility) |

### 1.3 The product in one paragraph

A GitHub repository with two deployment targets and one set of batteries. **Target A**: Docker Compose for a single VPS, with n8n in queue mode (main + webhook processors + workers), Postgres, Redis, Caddy TLS, encrypted backups to S3-compatible storage, Prometheus/Grafana/Loki monitoring, and Uptime Kuma. **Target B**: Terraform for AWS (ECS Fargate, RDS Multi-AZ, ElastiCache, ALB, EFS, S3) with the same n8n topology. **Batteries**: a tested upgrade procedure, restore runbook, security checklist, and a library of ready-to-import workflow templates for Vietnamese businesses (Zalo notifications, VietQR, Google Sheets order logs, Google Chat approvals, AI FAQ bot). Free to use; An sells setup, migration, and managed hosting on top.

### 1.4 Usage

**Target A — VPS in 15 minutes**
```bash
git clone https://github.com/<user>/n8n-prod-kit && cd n8n-prod-kit/compose
cp .env.example .env            # domain, encryption key (generated), DB password, S3 backup creds
make preflight                  # checks DNS, ports 80/443, docker, disk
make up                         # caddy, n8n-main, n8n-webhook×2, n8n-worker×2, postgres, redis, backup, monitoring
make status                     # health of every service + first-login URL
```

**Target B — AWS**
```bash
cd terraform/aws && cp terraform.tfvars.example terraform.tfvars
terraform init && terraform plan && terraform apply     # ~15 min
terraform output n8n_url
```

**Day-2 operations** (`make` targets in both): `backup-now`, `restore BACKUP=…`, `upgrade N8N_VERSION=…`, `scale-workers N=4`, `logs SERVICE=…`, `export-workflows`, `rotate-db-password`, `doctor` (common-problem checker).

**Templates**: `templates/` folder, each with `workflow.json`, `n8n-kit-README.md` (what it does, credentials needed, how to test), and a screenshot. Import via n8n UI or `make import-template NAME=zalo-form-notify`.

### 1.5 Benefits

**For users**: production-grade n8n in minutes, not days; no lost credentials; upgrades that don't break; Vietnamese-context templates nobody else publishes.
**For An**: a public artifact that proves DevOps and architecture skills (IaC, HA, backups, observability, docs); inbound leads for paid setup/migration/managed hosting; the infrastructure base reused by SoBan and ChungTu; community feedback that reveals what people actually struggle with.

### 1.6 Scope

**MVP (in)**: Compose target with queue mode, TLS, backups + restore, monitoring, upgrade procedure, security checklist, 5 templates, README + docs site (MkDocs on GitHub Pages).

**v1.x**: Terraform AWS target · **Target C: Kubernetes Helm chart** (M2.5, same topology; runners as in-pod sidecars, CloudNativePG or external DB, Valkey StatefulSet, Ingress + cert-manager, KEDA on queue depth) · 10+ templates · `doctor` tool · migration guide from n8n Cloud · Hetzner/DigitalOcean Terraform variants.

**Out**: n8n enterprise features (multi-main, SSO) · hosting the service ourselves as a SaaS (managed hosting is per-customer, not multi-tenant).

### 1.7 Forecast achievements

| Milestone | Target (relative to start) | Definition of success | Metric |
|---|---|---|---|
| M0 · Compose kit | T + 2 weeks | Fresh VPS → working HTTPS n8n in queue mode in ≤ 15 min, following only the README | 3 people reproduce it without asking An a question |
| M1 · Batteries | T + 5 weeks | Backups verified by restore test, monitoring dashboards, upgrade and restore runbooks, 5 templates | Restore drill passes; templates import clean |
| M2 · Terraform AWS | T + 8 weeks | `terraform apply` → HA n8n on ECS; `destroy` leaves nothing behind | Apply < 20 min; cost estimate documented |
| M3 · Public launch | T + 3 months | Docs site, launch posts (LinkedIn, Reddit r/n8n, Viblo, Vietnamese dev groups) | ≥ 100 GitHub stars, ≥ 5 inbound inquiries |
| M4 · Business | T + 6 months | Paid setups + retainers | ≥ 6 paid setups, ≥ 3 managed-hosting retainers |

**Revenue hypothesis**: setup/migration 2–5M đ per client (one-time); managed hosting retainer 1–2M đ/month per client (VPS cost passed through); larger AWS deployments 10–20M đ.

| Scenario (month 6) | Setups done | Retainers | Monthly revenue |
|---|---|---|---|
| Conservative | 4 | 2 | ~3M đ |
| Base | 8 | 4 | ~7M đ |
| Optimistic | 15 | 8 | ~15M đ |

**Portfolio outcomes**: the repo itself; an architecture page with diagram and failure-mode analysis; a blog post on queue-mode sizing with real numbers; a restore-drill video.

### 1.8 Risks and assumptions

| Risk | Mitigation |
|---|---|
| n8n changes env vars or topology between versions | Pin versions; CI tests the kit against latest stable weekly; upgrade notes per version |
| Users lose `N8N_ENCRYPTION_KEY` | Key generated once, stored in `.env` and in the encrypted backup bundle; README warns in red |
| "It works on my VPS" | CI spins up a throwaway VPS (or a Compose run in GitHub Actions) and runs the smoke suite |
| Support burden from a free tool | Issues template; `make doctor` catches 80% of problems; paid support option |
| Licensing confusion (n8n Sustainable Use License) | Kit is deployment config, not a hosted n8n service; document what the license allows for managed hosting per customer |

---

## 2. Architecture

### 2.1 Principles

1. **Opinionated defaults, every one explained.** Users should not need to understand queue mode to run it, but can read why each setting exists.
2. **Nothing precious on a single disk.** Database and encryption key are backed up off-host, encrypted, and restore-tested automatically.
3. **Separate the three roles** (UI/main, webhook intake, execution) so a burst or a heavy workflow never blocks the others.
4. **Same topology in Compose and AWS**, so a client can graduate from Target A to Target B without re-learning.
5. **Everything is code and tested in CI.**

### 2.2 System overview (identical topology, two targets)

```
                      Internet
                         │
              Caddy (A) / ALB + ACM (B)      TLS, HTTP→HTTPS, websockets
                    │             │
   /webhook/* /webhook-waiting/* /form/*   └────── everything else (UI, /rest, /api, *-test/*)
   /form-waiting/* /mcp/*                          │
        │                                      │
  n8n-webhook ×2 (webhook processors)     n8n-main ×1 (UI, API, triggers, scheduler) ── runners sidecar
        │                                      │
        └──────────── Valkey (Bull queue) ─────┘
                           │
                    n8n-worker ×N (executions, concurrency 10 each) ── runners sidecar each (1:1, port 5679)
                           │
                    Postgres 18 (workflows, credentials, executions)
                           │
        Binary data: shared volume (A) / EFS (B)       Backups: pg_dump + key bundle → age (2 recipients) → R2 / S3 / local disk
 Monitoring: n8n /metrics → Prometheus → Grafana · logs → Alloy → Loki · Uptime Kuma → alerts (Telegram/Google Chat)
```

### 2.3 Components

| Component | Target A (Compose) | Target B (AWS Terraform) | Responsibility |
|---|---|---|---|
| Edge | Caddy with automatic Let's Encrypt | ALB + ACM cert, WAF optional | TLS, routing `/webhook/*`, `/webhook-waiting/*`, `/form/*`, `/form-waiting/*`, `/mcp/*` to webhook processors; everything else (incl. `*-test/*`) to main |
| n8n main | 1 container | 1 Fargate task | UI, REST API, cron/trigger scheduling, pushes jobs to queue |
| n8n webhook | 2 containers (`n8n webhook`) | 2 tasks, 2 AZs | Accept webhooks, enqueue, respond fast |
| n8n worker | 2 containers (`n8n worker --concurrency=10`) | 2+ tasks, autoscale on queue depth | Execute workflows |
| Task runners | `n8nio/runners` sidecar per main and per worker (1:1, external mode, same `${N8N_VERSION}`) | Sidecar container in each task definition | Run Code-node JS/Python outside the n8n process (required since n8n 2.0) |
| Queue | Valkey 9.1, AOF persistence, `noeviction` (Redis is a documented drop-in) | ElastiCache Valkey (replica) | Bull queue for executions |
| Database | Postgres 18 container, volume at `/var/lib/postgresql` | RDS Postgres 18 Multi-AZ, PITR | Everything n8n persists |
| Binary data | `N8N_DEFAULT_BINARY_DATA_MODE=filesystem` on a shared volume | EFS mounted on all tasks (S3 mode where the n8n edition supports it) | Files passing through workflows |
| Backups | `backup` sidecar (`FROM postgres:18-alpine` + age + rclone + supercronic): nightly `pg_dump` + key bundle → `age` to two recipients (host key + offline recovery key) → every remote in `BACKUP_REMOTES` (R2, S3, local/external disk, any rclone remote); weekly restore test | AWS Backup for RDS/EFS + same encrypted key bundle to S3 | Recovery |
| Host bootstrap | `scripts/bootstrap-host.sh`: Docker Engine + compose plugin + make/jq/curl/git on Ubuntu 24.04/26.04, Debian (apt) and Rocky/Alma/CentOS Stream/RHEL 9–10 (dnf; EPEL, firewalld, SELinux enforcing with `:z` mounts) | — | Fresh VPS → ready for `make up` |
| Monitoring | Prometheus, Grafana (dashboards provisioned), Loki + Alloy, Uptime Kuma | CloudWatch metrics/logs + same Grafana dashboards via managed Grafana or self-hosted | Visibility and alerts |
| Secrets | `.env` (chmod 600), generated by `make init` | Secrets Manager, injected into task definitions | |
| Docs | MkDocs Material → GitHub Pages | | |
| CI | GitHub Actions: lint (`hadolint`, `tflint`, `shellcheck`), Compose smoke test, Terraform `validate`/`plan`, weekly latest-n8n test | | |

### 2.4 Configuration model (the "data model" of an infra kit)

```
compose/.env                 # DOMAIN, N8N_VERSION, N8N_ENCRYPTION_KEY, DB_PASSWORD, REDIS_PASSWORD,
                             # WEBHOOK_REPLICAS, WORKER_REPLICAS, WORKER_CONCURRENCY,
                             # BACKUP_S3_*, BACKUP_AGE_PUBLIC_KEY, ALERT_TELEGRAM_*, TZ=Asia/Ho_Chi_Minh,
                             # EXECUTIONS_DATA_PRUNE=true, EXECUTIONS_DATA_MAX_AGE=336
compose/docker-compose.yml   # services with healthchecks, restart policies, resource limits
compose/Caddyfile            # TLS, websocket, routing, security headers
compose/monitoring/          # prometheus.yml, grafana/provisioning/, loki.yml, alerts.yml
compose/backup/              # backup.sh, restore.sh, restore-test.sh
terraform/aws/               # modules: network, ecs, rds, redis, efs, alb, s3, iam, monitoring
templates/<name>/            # workflow.json, n8n-kit-README.md, screenshot.png, test-payload.json
docs/                        # mkdocs site: quickstart, architecture, operations, security, templates, faq
```

### 2.5 Request / execution flow

1. External system calls `https://n8n.example.com/webhook/abc`. Caddy/ALB routes the production paths (`/webhook/*`, `/webhook-waiting/*`, `/form/*`, `/form-waiting/*`, `/mcp/*`) to a webhook processor; `*-test/*` and everything else go to main (`N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true`).
2. Webhook processor validates the workflow, pushes an execution job to Redis, and responds (immediately, or waits for the result if the workflow uses "Respond to Webhook").
3. A worker pulls the job, runs the workflow, writes execution data to Postgres.
4. Main instance handles UI, manual runs (offloaded to workers), and schedule/polling triggers, which also enqueue jobs.
5. Prometheus scrapes `/metrics` from main, webhooks and workers (queue depth, executions, cache hits); Alloy ships container logs to Loki.
6. 02:00 nightly: backup sidecar dumps Postgres + bundles `.env` key → encrypts → uploads; Sunday 03:00: restore test spins up a scratch Postgres, restores, counts workflows, reports to the alert channel.

### 2.6 Resources required

**Target A**

| Size | VPS | Fits | Est. cost / month |
|---|---|---|---|
| Small | 2 vCPU, 4 GB, 40 GB | ~20 workflows, < 10k executions/day | 150.000–300.000đ |
| Medium | 4 vCPU, 8 GB, 80 GB | ~100 workflows, < 100k executions/day | 400.000–700.000đ |
| Plus | S3/R2 backups (< 10 GB) | | ~0–30.000đ |

**Target B (AWS, ap-southeast-1)**

| Resource | Spec | Est. cost / month |
|---|---|---|
| ECS Fargate | main 0.5 vCPU/1 GB; webhook 2 × 0.25/0.5; worker 2 × 0.5/1 | ~$55 |
| ALB | | ~$20 |
| RDS Postgres | db.t4g.small Multi-AZ, 20 GB | ~$50 |
| ElastiCache Redis | cache.t4g.micro + replica | ~$25 |
| EFS, S3, CloudWatch, Secrets, Route 53 | | ~$15 |
| **Total** | | **≈ $160–180 (~4–4.5M đ)**; single-AZ dev variant ≈ $70 |

**Accounts/tooling**: GitHub (Actions, Pages), a test VPS for CI/demos, S3/R2 bucket, AWS account, Terraform ≥ 1.9, Docker, `age`, `mkdocs-material`.
**Time**: ~50–70 hours to M2 (most of the Compose knowledge already exists from the prod-at-02 setup; the work is cleaning, parameterising, documenting, and testing).

### 2.7 High availability

| Layer | Target A | Target B |
|---|---|---|
| Webhook intake | 2 processors; Caddy load-balances; a crash of one loses nothing | 2 tasks across AZs behind ALB |
| Execution | 2+ workers; a worker crash leaves jobs in Redis to be picked up | Autoscaled tasks across AZs |
| Main (UI/triggers) | Single instance (n8n community edition supports one main); restarts in seconds; webhooks keep flowing while it is down | Same; ECS restarts the task; multi-main is an n8n enterprise feature and is documented as out of scope |
| Redis | Single with AOF; restart loses nothing durable | Replica with automatic failover |
| Postgres | Single container; nightly backup; WAL archiving optional | Multi-AZ, PITR |
| Target | 99.5% | 99.9% |

### 2.8 Scalability

- Horizontal: `WORKER_REPLICAS` and `WORKER_CONCURRENCY` are the two knobs; documented sizing table (executions/day vs workers × concurrency vs RAM).
- Webhook processors scale independently of workers for inbound-heavy use.
- Execution data pruning keeps Postgres small (`EXECUTIONS_DATA_MAX_AGE`); guidance on saving only failed executions for high-volume workflows.
- Target B: worker autoscaling policy on the queue-depth metric; RDS instance class upgrade path; read replica not needed at this scale.
- Documented ceiling: when to move from A to B (sustained > 100k executions/day, or an SLA requirement).

### 2.9 Fault tolerance

| Failure | Behaviour |
|---|---|
| Worker dies mid-execution | Bull marks the job stalled and re-queues it; execution retried; documented that workflows should be idempotent |
| Webhook processor dies | Caddy/ALB health check removes it; the other handles traffic; Compose/ECS restarts it |
| Main dies | Webhooks and queued executions continue; schedule triggers pause until restart (seconds) |
| Redis restart | AOF restores queue; in-flight jobs re-run |
| Postgres down | Everything pauses; nothing corrupts; alert fires; `make restore` runbook |
| Disk full | Execution pruning + log rotation; disk alert at 80%; `make doctor` shows top consumers |
| Bad upgrade | `make upgrade` takes a backup first, pulls the new image, runs migrations, checks health; `make rollback` restores the previous image and the pre-upgrade DB dump |
| Lost encryption key | Only recoverable from the backup bundle; README and `make doctor` warn; restore test verifies the bundle contains the key |

### 2.10 Resilience and recovery

- **Backups**: nightly DB dump + key bundle, encrypted with `age` to a public key whose private key is kept off-host; 30 daily + 12 monthly retention; weekly automated restore test with a report.
- **RPO/RTO**: A — 24 h / 30 min (1 h RPO with optional WAL archiving to S3). B — 5 min / 30 min.
- **Runbooks** in `docs/operations/`: restore from backup · rebuild VPS from scratch · upgrade and rollback · rotate DB/Redis passwords · migrate from n8n Cloud (export → import → credentials re-entry checklist) · move from Target A to Target B.
- **Chaos checks** (documented and scripted, `make chaos`): kill a worker during a running workflow; stop Redis for 60 s; fill disk; expire the TLS cert in a staging run and confirm renewal.

### 2.11 Security

- TLS everywhere; HSTS and security headers in Caddy; webhook path isolation.
- n8n owner account + optional basic-auth/IP allow-list in front of the UI; `/webhook/*` exempt.
- Secrets never in images or git; `.env` 600; `make init` generates strong random values.
- Containers non-root, pinned image digests, resource limits; `hadolint` in CI.
- Backups encrypted at rest with `age`; bucket private; lifecycle rules.
- Security checklist page in docs (what to do before giving clients the URL).
- Weekly CI run against the latest n8n release flags breaking changes early.

### 2.12 Observability

- Grafana dashboards provisioned: **n8n Overview** (executions/min, success/failure, queue depth, worker count, p95 duration), **Host** (CPU, RAM, disk, container restarts), **Backups** (last success, size, restore-test status).
- Alerts: n8n UI down 2 min · webhook endpoint down 2 min · queue depth > 500 for 5 min · failed executions > 10% over 15 min · backup missing 26 h · restore test failed · disk > 80% · cert expiring < 14 days.
- Uptime Kuma public status page optional.

### 2.13 Repository structure

```
n8n-prod-kit/
├── n8n-kit-README.md n8n-kit-PLAN.md n8n-kit-HANDOFF.md n8n-kit-CHANGELOG.md CLAUDE.md LICENSE (MIT)
├── scripts/        # bootstrap-host.sh (apt + dnf host prep)
├── compose/        # docker-compose.yml, compose.dev.yml, versions.env, .env.example, caddy/, Makefile, scripts/, backup/, monitoring/
├── terraform/aws/  # main.tf, variables.tf, outputs.tf, modules/{network,ecs,rds-postgres,elasticache-valkey,efs,alb,s3,iam,monitoring}
├── k8s/helm/n8n-kit/  # Target C Helm chart (M2.5)
├── templates/      # zalo-form-notify/, vietqr-payment-link/, sheets-order-log/, gchat-approval/, ai-faq-bot/, ...
├── docs/           # mkdocs.yml, quickstart.md, architecture.md, operations/*.md, security.md, compat.md, templates.md, faq.md
├── tests/          # smoke/ (bash + curl), bootstrap/ (ubuntu:24.04, ubuntu:26.04, rockylinux:9 containers), terraform/, templates/
└── .github/workflows/ ci.yml, bootstrap-matrix.yml, weekly-latest-n8n.yml, docs.yml
```

---

## 3. Demo, Test Cases, and Change Logging

### 3.1 Demo script (15 minutes, the "fresh VPS" demo)

| Step | Action | Expected |
|---|---|---|
| 1 | Create a new VPS, point `n8n.demo.example.com` at it | DNS resolves |
| 2 | `git clone … && make init` | `.env` generated with random key and passwords; prompt for domain + backup bucket |
| 3 | `make preflight` | All checks green (DNS, ports, docker, disk, memory) |
| 4 | `make up` | ~2 min; `make status` shows 9 healthy services; HTTPS login page loads |
| 5 | Create owner account; `make import-template NAME=zalo-form-notify` | Workflow appears, README explains credentials |
| 6 | Send 200 test webhooks (`make loadtest N=200`) | Queue depth rises then drains; Grafana shows executions on both workers |
| 7 | `docker kill n8n-worker-1` mid-run | Executions complete on worker-2; killed job re-queued; Compose restarts worker-1 |
| 8 | `make backup-now` | Encrypted bundle appears in bucket |
| 9 | Delete a workflow, `make restore BACKUP=latest` | Workflow is back; credentials still decrypt |
| 10 | `make upgrade N8N_VERSION=<next>` | Pre-upgrade backup, migration, health green; `make rollback` works |
| 11 | Open Grafana + Uptime Kuma | Dashboards and status green |
| 12 | (AWS demo) `terraform apply` in a prepared account | Outputs URL in < 20 min; same steps 5–7 work; `terraform destroy` clean |

### 3.2 Test strategy

- **Static**: `hadolint`, `shellcheck`, `yamllint`, `tflint`, `terraform validate`, `terraform fmt -check`.
- **Compose smoke (every PR)**: GitHub Actions brings up the stack with a self-signed/internal domain, waits for health, runs the smoke suite (login API, webhook roundtrip, execution on worker, metrics endpoint, backup script, restore script into scratch DB).
- **Template tests**: import each template via API, run with `test-payload.json` against mock endpoints, assert the expected nodes succeeded.
- **Terraform**: `plan` snapshot tests on PR; full `apply`/`destroy` in a sandbox account weekly (cost-capped).
- **Weekly latest-n8n run**: same smoke suite against `n8nio/n8n:latest`; opens an issue automatically on failure.
- **Manual drills**: quarterly full restore to a new VPS using only the docs.

### 3.3 Test cases

| ID | Area | Input / condition | Expected |
|---|---|---|---|
| TC-001 | Init | `make init` on a clean clone | `.env` created, key 32+ bytes, passwords random, file mode 600 |
| TC-002 | Preflight | Port 80 occupied | Clear error naming the process |
| TC-003 | Up | `make up` | All services healthy within 180 s |
| TC-004 | TLS | HTTPS request to domain | Valid cert, HSTS header, HTTP redirects |
| TC-005 | Routing | POST `/webhook/test` | Handled by a webhook processor (log shows service name), not main |
| TC-006 | Queue | Trigger execution | Job appears in Redis; executed by a worker; stored in Postgres |
| TC-007 | Scale | `make scale-workers N=4` | 4 workers registered; load spread |
| TC-008 | Resilience | Kill worker mid-execution | Job re-queued; execution finishes on another worker; no duplicate side effects in idempotent test workflow |
| TC-009 | Resilience | Stop Redis 60 s | Webhooks return 5xx during outage; after restart, queue intact |
| TC-010 | Resilience | Restart main | Webhooks still processed during restart; schedules resume |
| TC-011 | Backup | `make backup-now` | Encrypted bundle uploaded; contains DB dump + key |
| TC-012 | Restore | `make restore` into scratch | Workflow count matches; credential decrypts with restored key |
| TC-013 | Restore test | Weekly job | Report posted; failure opens alert |
| TC-014 | Upgrade | `make upgrade` to next minor | Backup taken first; migrations run; health green |
| TC-015 | Rollback | `make rollback` after failed upgrade | Previous image + DB state restored |
| TC-016 | Pruning | 1.000 executions older than max age | Pruned on schedule; DB size drops |
| TC-017 | Monitoring | Prometheus targets | All up; Grafana dashboards render with data |
| TC-018 | Alerts | Stop webhook processors | Alert in Telegram within 3 min |
| TC-019 | Security | UI without auth from non-allow-listed IP (if enabled) | 403; `/webhook/*` still open |
| TC-020 | Security | Image scan | No critical CVEs in pinned images; non-root user |
| TC-021 | Templates | Import each template | Imports without errors; README lists credentials |
| TC-022 | Templates | Run `zalo-form-notify` with test payload against mock Zalo endpoint | Expected nodes succeed; message body matches |
| TC-023 | Terraform | `terraform plan` | No drift on second plan; variables validated |
| TC-024 | Terraform | `apply` then `destroy` | No orphaned resources (checked with a tag query) |
| TC-025 | Docs | Quickstart followed by a tester | Completed in ≤ 15 min with no questions |
| TC-026 | Doctor | Low disk, missing key, wrong DNS (simulated) | `make doctor` names each problem and the fix |

### 3.4 Definition of done

Code + tests on `main`, CI green · docs page updated (every feature has a docs page or section) · `make doctor` updated if a new failure mode is introduced · `n8n-kit-CHANGELOG.md` updated · `n8n-kit-HANDOFF.md` updated · version compatibility table updated if n8n version pins changed.

### 3.5 Logging updates, bugs, fixes, and changes

- `n8n-kit-CHANGELOG.md` (Keep a Changelog, SemVer; kit version is independent of the n8n version it pins; each release lists the n8n versions tested).
- GitHub Issues with templates: **bug** (kit version, n8n version, target A/B, `make doctor` output, redacted `.env` keys list), **template request**, **question**. Labels: `compose`, `terraform`, `templates`, `docs`, `n8n-upstream`, `good first issue`, `P0–P3`.
- `docs/compat.md`: table of kit version × n8n version × tested date.
- Conventional Commits; release tags `v0.x.y`; GitHub Release notes generated from the changelog.
- Community changes: PR template requires a smoke-test run and a docs update.
- Monthly: review weekly-latest-n8n failures, open issues with `n8n-upstream`, and update the pin.

---

## 4. Handoff

See `n8n-kit-HANDOFF.md`. Start every session by reading it; end every session by updating it.
