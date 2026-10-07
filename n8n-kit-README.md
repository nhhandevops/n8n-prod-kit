# n8n Production Kit

Production-grade self-hosted n8n in 15 minutes: queue mode (main + webhook processors + workers), Postgres, Redis, automatic TLS, encrypted off-host backups with weekly restore tests, Prometheus/Grafana/Loki monitoring, safe upgrade/rollback — as Docker Compose for a VPS and as Terraform for AWS. Plus ready-to-import workflow templates for Vietnamese businesses (Zalo, VietQR, Google Sheets, Google Chat, AI FAQ bot).

Owner: An · Planned: 2026-10-06 · Status: planning (not started) · License: MIT (public repo)

## Documents in this bundle

| File | What it is | When to read it |
|---|---|---|
| `n8n-kit-PLAN.md` | Problem, users, usage, benefits, forecast · Architecture for both targets (HA / scalability / fault tolerance / resilience / security) · Demo script, 26 test cases, change-logging process | Before building anything |
| `n8n-kit-HANDOFF.md` | Living status: done / in progress / next / blockers / decisions / how to resume on any machine | **First read of every session, last update of every session** |
| `n8n-kit-CHANGELOG.md` | Kit releases and the n8n versions each was tested with | When shipping or looking something up |

```
n8n-prod-kit/
├── n8n-kit-README.md  n8n-kit-PLAN.md  n8n-kit-HANDOFF.md  n8n-kit-CHANGELOG.md  LICENSE
├── CLAUDE.md        ← copy the section below into it
└── compose/ terraform/ templates/ docs/ tests/   (see n8n-kit-PLAN.md §2.13)
```

## Instructions for AI coding agents (Claude Code, Cursor, etc.)

1. **Start:** `git pull`, read `n8n-kit-HANDOFF.md` fully. `n8n-kit-PLAN.md` explains the project; do not ask the user to re-explain it.
2. **This repo is public.** Never include real domains, IPs, credentials, or anything resembling An's employer's infrastructure. Use `example.com`, `n8n.localtest.me`, generated secrets.
3. **Build against `n8n-kit-PLAN.md` §2.** Deviations go in `n8n-kit-HANDOFF.md` → Decisions log *before* coding.
4. **Every feature ships with a docs page and a smoke/template/terraform test.** The product is the docs as much as the config.
5. **Pin everything** (image digests, Terraform providers) and record tested n8n versions in `docs/compat.md`.
6. **End of session:** run tests → Conventional Commit → update `n8n-kit-CHANGELOG.md` (Unreleased) and `n8n-kit-HANDOFF.md` (status, next, blockers, timestamp) → `git push`.
7. **If it is not in git, it does not exist.**

## Quick start (once the kit exists)

```bash
git clone https://github.com/<user>/n8n-prod-kit && cd n8n-prod-kit/compose
make init DOMAIN=n8n.example.com && make preflight && make up && make status
```
