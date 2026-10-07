# CLAUDE.md — n8n Production Kit

Instructions for AI coding agents (Claude Code, Cursor, …) and a cheat-sheet for humans.

## Rules

1. **Start:** `git pull`, read `n8n-kit-HANDOFF.md` fully (status, next steps, blockers, decisions, how to resume on each machine). `n8n-kit-PLAN.md` explains the project; do not ask the user to re-explain it. `n8n-kit-BUILD-PLAN.md` is the step-by-step source for every session (§15 lists S0–S10; where its §8–§11 differ from `compose/`, the code and HANDOFF §3 win). `warning_bug_and_solutions.md` lists every verified upstream gotcha — read it before touching n8n, Caddy, Compose or the bootstrap script.
2. **This repo is public.** Never include real domains, IPs, credentials, or anything resembling the owner's employer infrastructure. Placeholders only: `example.com`, `n8n.localtest.me`, `203.0.113.0/24`, generated secrets.
3. **Build against `n8n-kit-PLAN.md` §2.** Deviations go into `n8n-kit-HANDOFF.md` → Decisions log *before* coding.
4. **Every feature ships with a docs page and a test** (smoke / template / terraform / helm). The product is the docs as much as the config.
5. **Pin everything** — image digests (`make pin`), GitHub Actions by commit SHA, downloaded binaries by sha256 — and record tested n8n versions in `docs/compat.md`.
6. **End of session:** run tests → Conventional Commit → update `n8n-kit-CHANGELOG.md` (Unreleased) and `n8n-kit-HANDOFF.md` (status, next, blockers, "Last updated") → `git push`.
7. **If it is not in git, it does not exist.** Chat history is not storage.

## Safety

- Never run `make clean`, `make restore`, `make rollback` or anything that deletes volumes / overwrites a database on a user's stack unless they explicitly asked for that command.
- Never commit `compose/.env`, `compose/secrets/*`, `*.age`, `terraform.tfvars` or `*.tfstate*` (gitignored — keep it that way).
- Dry-run / `docker compose config -q` before `up`; verify versions before upgrading; one read-only inspection block before touching an external system.

## Conventions

- Bash: `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck clean with `enable=all`.
- YAML: 2-space indent, yamllint clean (line length 160). Dockerfiles: hadolint clean. Makefiles: real tabs.
- Conventional Commits (`feat(compose): …`, `fix(backup): …`, `docs: …`, `ci: …`). Kit versions `v0.x.y`, independent of the n8n version pinned.
- Docs in English; `docs/quickstart.vi.md` is the Vietnamese translation.
- Line endings LF everywhere (`.gitattributes`); edit inside Linux, never through a Windows share.

## `make` cheat-sheet (root)

| Target | What |
|---|---|
| `make help` | list targets |
| `make lint` | shellcheck + hadolint + yamllint over tracked files, then `compose/` lint (compose config, caddy validate x12) |
| `make bootstrap-test` | run `scripts/bootstrap-host.sh` inside Ubuntu/Debian/Rocky/Alma containers (~5–15 min) |

The Compose kit's targets live in `compose/Makefile` — `make -C compose help`. Available now: `init`, `pin`, `render`, `preflight`, `config`, `up`, `down`, `restart`, `pull`, `ps`, `logs`, `status`, `doctor`, `scale-workers`, `dev-ca`, `trust-ca`, `lint`, `version`, `env-keys`, `clean`. Coming: `smoke` (S4), `backup-now`/`restore` (S5), `upgrade`/`rollback` (S7), `loadtest`/`chaos` (S8).

Remote shell tip (learned the hard way): `docker compose up` and `make up` read stdin — never feed a multi-step script to a remote host through `ssh host 'bash -s' <<EOF`; copy it to a file and run `bash file </dev/null`.

## Definition of done

Code + tests on `main`, CI green · docs page updated · `make doctor` updated if a new failure mode is introduced · `n8n-kit-CHANGELOG.md` updated · `n8n-kit-HANDOFF.md` updated · `docs/compat.md` updated if the n8n pin changed.
