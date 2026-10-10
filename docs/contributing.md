# Contributing

Pull requests and issues are welcome. This page is the real contract: what a change has to carry before
it can be merged, and how to run the same checks locally that CI will run on it.

The short version, which is also the pull-request template's checklist:

- `make lint` is green locally.
- Smoke output is pasted into the PR, or the PR says "docs only".
- A docs page is added or updated for every behaviour change.
- `n8n-kit-CHANGELOG.md` → **Unreleased** is updated.
- No real domains, IPs, keys or employer infrastructure anywhere.
- Image digests, action SHAs and binary checksums are pinned for anything new.

## The two rules that are not negotiable

**Every feature ships with a docs page and a test.** The documentation is as much the product as the
configuration is, and a setting nobody can find is not a feature. A new failure mode also belongs in
`make doctor`, so the next person to hit it gets told what to do.

**This repository is public.** Never commit a real domain, IP address, hostname, user name, key or
anything that resembles production infrastructure. The placeholders are `example.com`,
`n8n.localtest.me` and `203.0.113.0/24`, plus generated secrets. The same applies to issues and pull
requests: `make -C compose env-keys` prints the key *names* in `.env` for bug reports — never the
values.

These files are git-ignored and must stay that way: `compose/.env`, `compose/.env.*`,
`compose/secrets/*`, `compose/backups/*`, `*.age`, `terraform.tfvars`, `*.tfstate*`, `compose/.smoke/`
and `compose/.upgrade/`.

## A development host

The kit is Linux software: build and test it on a Linux host or VM, never through a Windows share
(line endings). `scripts/bootstrap-host.sh` prepares the host itself — Docker Engine, the Compose
plugin, `make`, `jq`, `git`, `vm.overcommit_memory=1`, and your user in the `docker` group.

`make lint` additionally needs `shellcheck`, `hadolint`, `yamllint` and `jq` on the host. CI pins
ShellCheck **v0.11.0** and hadolint **v2.15.1** and verifies both downloads against a sha256; use those
versions locally, because an older distribution build of ShellCheck reports different codes and will
disagree with CI.

## Run the checks

```bash
make lint                 # shellcheck + hadolint + yamllint, then the Compose kit's own lint
make -C compose help      # every target of the Compose kit
```

The root `make lint` covers tracked files **and** new files that are not git-ignored, so a script you
have not committed yet is still linted. It then calls `compose/scripts/lint.sh`, which runs
`shellcheck -x` over every script, `yamllint`, `docker compose config -q` (against your real `.env`, or
a throw-away one built from `.env.example` on a fresh clone), `caddy validate` inside the pinned Caddy
image for every `TLS_MODE` × `UI_PROTECT` × `KUMA_ENABLED` combination, and the monitoring configs
through `promtool`, `loki -verify-config` and `alloy fmt`.

## Run the smoke suite

The suite tests a *running* stack, so bring one up first. A dev stack on non-standard ports with the
internal CA needs no public DNS:

```bash
cd compose
make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443
make up
make smoke
```

`tests/smoke/01-09` check, in order: every service healthy with its runner sidecars; the edge
(redirect, certificate chain, security headers, no `Server` banner); owner, login and API key; webhook
routing through the pool with round robin; the execution landing on a worker including a Code-node HTTP
call; metrics inside the stack and a 404 for `/metrics` at the edge; `make backup-now` to every remote;
`make restore-test`; and the monitoring profile. Test 09 passes as skipped when `COMPOSE_PROFILES` does
not list `monitoring`.

Useful knobs: `make smoke ONLY=04,05` runs two scripts, `SMOKE_KEEP=1` keeps the workflows it created
for debugging, and shared state lives in `compose/.smoke/`. Run it twice before you open the PR — CI
does, because the suite must be idempotent.

Two rules when writing or changing a smoke test:

- Never pipe into an early-exiting reader (`| grep -q`, `| head`) under `pipefail`: the producer gets
  SIGPIPE and the pipeline reports failure. Capture the output first, then match on the variable.
- n8n allows only five logins per window, so reuse the session and API key in `compose/.smoke/` instead
  of logging in again.

`make loadtest` and `make chaos` are drills, not tests: they fire real executions (which pushes real
history out of the database through pruning) and `chaos` kills and stops containers on purpose. Read
[Chaos drills](operations/chaos-drills.md) first and run them only against a stack you created for
testing. The same goes for `make clean`, `make restore` and `make rollback`.

## Conventions

| Area | Rule |
|---|---|
| Bash | `#!/usr/bin/env bash`, `set -euo pipefail`, ShellCheck clean with `enable=all` (`.shellcheckrc`). A file-wide `# shellcheck disable=` directive must come before the first command. |
| YAML | 2-space indent, yamllint clean, 160-column limit (`.yamllint`). |
| Dockerfiles | hadolint clean (`.hadolint.yaml`). |
| Makefiles | real tabs. |
| Files | UTF-8, LF line endings everywhere (`.gitattributes`), final newline, no trailing whitespace outside Markdown (`.editorconfig`). |
| Pinning | image digests through `make pin`, GitHub Actions by commit SHA, downloaded binaries by sha256. Update `docs/compat.md` when the n8n pin changes. |
| Commits | [Conventional Commits](https://www.conventionalcommits.org/): `feat(compose): …`, `fix(backup): …`, `docs: …`, `ci: …`. Kit versions are `v0.x.y`, independent of the n8n version it pins. |

Committing from Windows: new scripts arrive without the executable bit. Set it with
`git update-index --chmod=+x <file>` and check with `git ls-files -s`.

## Changelog and handoff

`n8n-kit-CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) with the
sections **Added · Changed · Fixed · Removed · Security · Infra · Templates · Docs**. Put your entry
under `[Unreleased]`, reference issues as `(#12)`, and name the n8n version a change was tested with.

`n8n-kit-HANDOFF.md` carries the current status, what is next, blockers and the decisions log. A change
that deviates from `n8n-kit-PLAN.md` §2 is recorded there as a decision *before* the code is written,
and anything a reviewer or drill disproved belongs in `warning_bug_and_solutions.md` with its symptom,
root cause, how to verify it and the fix. That file is where this FAQ came from.

## Documentation changes

The site is MkDocs Material, built from `docs/` with `mkdocs.yml`. Install the pinned toolchain and
build it the way CI does:

```bash
pip install -r requirements-docs.txt     # mkdocs-material, pinned
mkdocs build --strict
```

`--strict` turns warnings into errors, so a broken internal link or a page missing from the `nav` fails
the build instead of shipping a dead link. Add every new page to the `nav` in `mkdocs.yml`. Pages are in
English; `docs/quickstart.vi.md` is the Vietnamese translation of the quickstart.

Match the voice of the existing pages: plain sentences, the reader's next action first, tables only where
they genuinely compress, short code blocks that can be pasted, and the reason a setting exists whenever
that reason is not obvious. Quote measured numbers rather than estimates, and say plainly when something
has not been verified.

## What CI does to your pull request

| Workflow | When | What runs |
|---|---|---|
| `ci.yml` → `lint` | every PR and push to `main` | pinned linters, then `make lint` |
| `ci.yml` → `smoke` | after `lint` | `make init` + `make up` + `make doctor` on a fresh runner, `make smoke` twice, an alert drill, a restore of the newest backup into the live database followed by smoke 01/04/05, and the full disaster-recovery drill; logs are uploaded on failure |
| `ci.yml` → `upgrade` | after `lint` | pins the previous n8n minor, brings the stack up on it, then the upgrade/rollback drill |
| `docs.yml` | changes under `docs/`, `mkdocs.yml`, `requirements-docs.txt` or the workflow | `mkdocs build --strict`; a push to `main` also deploys to GitHub Pages |
| `bootstrap-matrix.yml` | weekly | `scripts/bootstrap-host.sh` in Ubuntu, Debian, Rocky and Alma containers |
| `weekly-latest-n8n.yml` | weekly | pins the newest stable n8n and runs the smoke suite; a failure opens an issue labelled `n8n-upstream` |

Dependabot updates GitHub Actions weekly. Container images are deliberately **not** managed by it: every
image is pinned by digest in `compose/versions.env` and moved with `make pin`, and the weekly n8n job is
the early warning for n8n itself.

## Issues

Use the issue forms: a **bug report** asks for `make version`, the n8n version, the host OS and Docker
version, and the output of `make doctor`, `make status` and `make env-keys`; a **question** covers
usage, sizing and migration; a **template request** asks for a workflow template. Questions about n8n
nodes, workflows or the editor belong in the [n8n community forum](https://community.n8n.io/) rather
than here.
