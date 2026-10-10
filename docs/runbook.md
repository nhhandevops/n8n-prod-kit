# Runbook: try every feature on purpose

[Quickstart](quickstart.md) gets the stack running in about fifteen minutes. This page is what comes
next: a guided tour of everything the kit can do, in the order that makes sense to learn it, with the
exact commands and the reason each one exists.

It is written for one person working alone on a dev or test machine, who is new to most of this — to
Docker, to job queues, to certificates, to treating backups as something you test rather than something
you have. No step assumes you know why it matters; each one says so. Work down the page with a terminal
open.

!!! info "This is the dev and test pass, deliberately"

    Every command here is meant for a machine you can throw away. That is not a limitation of the
    runbook — it is the point of it. Break things here, learn what the failure looks like, and arrive at
    a production host already knowing. The production sequence is a separate, deliberately parked
    document: `n8n-kit-PROD-PLAN.md` in the repository root. Do not work from it yet.

## What you need before you start

- A Linux host you can afford to break: a VM, a spare machine, or a cloud box you will delete. 2 vCPU
  and about 8 GB of RAM runs the core stack.
- The kit cloned onto it. Part A takes you from there: it installs Docker if you need it, writes the
  configuration, and starts the stack. If you already followed [Quickstart](quickstart.md) and
  `make -C compose status` prints a table of healthy services, Part A is a tour rather than a setup.
- A browser that can reach the host. If the browser is on a different machine, add a line to that
  machine's hosts file pointing `n8n.localtest.me` at the host's address.
- Two to five hours, in whatever pieces suit you. Each part below is self-contained and ends somewhere
  sensible to stop.

Part A opens with the exact setup this page was written against, and says where to deviate if your host
differs — different ports, a different address for the browser, a bigger VM for Part E.

## The session plan

| Part | What you come away with | Time | Test cases it covers |
|---|---|---|---|
| [A](#part-a) | What the eleven containers are, and how to look at a running system | 30 min | TC-001, TC-002, TC-003, TC-026 |
| [B](#part-b) | TLS, the editor, routing, and your first webhook that really runs | 60 min | TC-004, TC-005, TC-006 |
| [C](#part-c) | Backups you have actually restored from, and the key it all depends on | 60 min | TC-011, TC-012, TC-013 |
| [D](#part-d) | Upgrades, rollback, scaling, and breaking it on purpose | 60–90 min | TC-007, TC-008, TC-009, TC-010, TC-014, TC-015 |
| [E](#part-e) | Dashboards, alerts that have actually fired, and the outside view | 45 min | TC-017, TC-018 |
| [F](#part-f) | A sign-off sheet, and what to do when a step fails | 10 min | — |

The test-case numbers are the project's own acceptance tests, listed in `n8n-kit-PLAN.md`. They are here
so that when you finish a part you know exactly which promise you have verified yourself rather than
taken on trust.

Part E is the one part that asks something of you beyond time: a host with about 4 vCPU, because the
monitoring stack does not fit comfortably in 2, and a Telegram bot, which takes five minutes to create.
Parts A to D need neither. If you only have the smaller VM, do A to D now and come back to E.

## How each feature is presented

Every feature in this runbook is laid out the same way, so you can skim to the beat you need:

- **What it is** — in plain words, with any jargon defined where it first appears.
- **Why you care** — what goes wrong without it.
- **Do this** — the command, copy-pasteable.
- **What you should see** — how to tell it worked.
- **What it proves** — the claim you have just checked for yourself.
- **If it goes wrong** — the first thing to try.

Every command assumes one working directory: the repository root, the directory you cloned into. That is
why they read `make -C compose <target>` — `-C compose` is a path relative to where you are standing, so
the same line works for every part of this page. A handful of commands are not `make` targets; those are
written to run from the root too.

!!! danger "Three commands destroy data"

    `make clean` deletes the containers **and** the volumes: database, queue, certificates. `make
    restore` replaces the live database with a backup. `make chaos` kills or stops containers on
    purpose. All three are safe and useful on a throwaway host — that is why they are in this runbook —
    and all three are the wrong thing to type on a machine someone depends on. Each one is flagged again
    where it appears.

---

## Part A — The ground floor: what is running, and how you look at it { #part-a }

### What the kit is

A git repository you clone onto one Linux host. `compose/` holds a Docker Compose file, a Caddyfile, and a
`Makefile` whose targets are thin wrappers around scripts in `compose/scripts/` — each script does only what a
person could type by hand, so you can read it before you run it.

Two files hold your configuration. `compose/.env` is settings and secrets, and does not exist until you run
`make init`. `compose/versions.env` is image versions and digests; it ships pinned in the repository, and
`make pin` only rewrites it later. A digest is a content-fingerprint of a container image: a tag such as
`2.42.4` can be re-pushed to point at different bytes, a digest cannot.
[Configuration](configuration.md) is the key reference.

Examples read `make -C compose <target>` and assume your shell is in the repository root, the directory you
cloned into — `-C compose` is relative to where you are standing. Already inside `compose/`? Drop the
`-C compose`.

### The eleven containers, in the order a request meets them

A container is an isolated process, started from an image, with its own filesystem. The core stack is eleven
of them.

| Container | What it is for |
|---|---|
| `caddy` | The edge, and the only container that publishes a port: TLS (encryption), HTTP-to-HTTPS, security headers, routing. |
| `n8n-main` | Editor UI, `/rest` and public API, timers and triggers, database migrations. No production webhooks, and manual runs are handed to the workers. |
| `n8n-webhook-1`, `n8n-webhook-2` | Receive production webhooks (a URL an outside system calls to start your workflow), put a job on the queue, answer. They never run workflow code. |
| `n8n-worker-1`, `n8n-worker-2` | Take jobs off the queue and execute your workflows, 10 in parallel each by default (`WORKER_CONCURRENCY`). |
| `n8n-worker-1-runners`, `n8n-worker-2-runners` | One sandbox sidecar per worker for Code-node JavaScript. No volumes, no route out. |
| `postgres` | PostgreSQL 18: workflows, credentials, execution records, and binary execution data (`N8N_DEFAULT_BINARY_DATA_MODE=database`). |
| `valkey` | The queue broker (Redis-compatible): the list of jobs waiting for a worker. |
| `backup` | Its own cron schedule: nightly encrypted backup (02:00), weekly restore test (Sunday 03:00), hourly certificate check. |

!!! note

    The build plan also described an `n8n-main-runners` sidecar. It was dropped on purpose: with
    `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` main starts no task broker, so a sidecar there would retry
    forever. Eleven, not twelve. The optional `monitoring` and `kuma` profiles add more containers; both are
    off here, and a service behind a profile stays invisible to `make up` and `make status` until you list it
    in `COMPOSE_PROFILES`.

### Why the work is split: queue mode

**What it is.** A single `docker run n8nio/n8n` is one process doing everything. Queue mode
(`EXECUTIONS_MODE=queue`) splits it into producers and consumers: whoever receives work writes a job into a
queue (a list of jobs waiting for a worker), and separate workers pull jobs off and execute them. The queue is
Bull on Valkey; all five n8n processes share one Postgres database and one encryption key.

**Why you care.** On a single-process n8n, one heavy workflow starves the editor and a crash mid-execution
takes your webhook endpoint down with it. Here each job has one owner: a drill on a real stack measured 40 of
40 production webhooks answered 200 across a restart of `n8n-main`, because main is not in the webhook path.
What queue mode does not give you: an execution already *running* on a worker you kill is lost, not retried —
it ends as `crashed` and stays that way. See [Architecture](architecture.md) and
[Chaos drills](operations/chaos-drills.md).

### Your reference environment

| Setting | Value |
|---|---|
| Host | Ubuntu 24.04, 2 vCPU, ~7.7 GB RAM, kit cloned into your home directory |
| Ports | 80 and 443, free on this host |
| `DOMAIN` | `n8n.localtest.me` |
| `TLS_MODE` | `internal` — Caddy mints its own certificate authority, so no public DNS is needed |
| `ACME_EMAIL` | `dev@example.com` |
| `BACKUP_REMOTES` | `/backups/local` |
| `COMPOSE_PROFILES` | empty — monitoring and Uptime Kuma off, which is what keeps the stack at eleven |

`DOMAIN` is the only one you type. Because `*.localtest.me` is a name no public certificate authority can
issue for, `make init` fills in the next three by itself. Switching the monitoring profile on later costs
roughly 1 GB more RAM.

!!! note

    If something already owns 80 or 443, add `HTTP_PORT=8080 HTTPS_PORT=8443` to the init command below.
    Later commands are unchanged; your URLs gain the port.

### One-time prerequisites

- [ ] **Install Docker:** `sudo bash scripts/bootstrap-host.sh` from the clone. It asks before it changes
      anything, then installs Docker Engine, the Compose plugin, `make`, `jq` and `git`, sets
      `vm.overcommit_memory=1` (Valkey needs it), and adds you to the `docker` group. It ends with a
      `Done on this host:` list and a `Deliberately NOT done:` list — read both. A second run changes nothing
      and takes about a second. Details: [Quickstart](quickstart.md).

- [ ] **Log out and back in.** The trap that catches almost everyone: group membership applies only to a new
      login session. The script says so — `added <user> to the docker group — LOG OUT AND BACK IN (or run:
      newgrp docker) before using docker without sudo.` Skip it and `make preflight` reports `docker daemon
      not reachable`, `make init` dies at its key-generation step (its fallback runs a container), and
      `make trust-ca` fails on the Docker socket. All three happened on a fresh host on 2026-10-10.

- [ ] **Write the configuration file.** This creates `compose/.env`, and nothing else works without it:

      ```bash
      make -C compose init DOMAIN=n8n.localtest.me
      ```

      It copies `.env.example` to `.env`, sets its mode to 600 *before* writing anything secret, fills in the
      domain, ports, TLS mode and `PUBLIC_URL`, generates seven secrets, creates two `age` key pairs under
      `compose/secrets/` for the encrypted backups, checks itself (key length, file mode, digests pinned,
      `docker compose config` parses) and ends with a red banner. Do what the banner says before you type
      anything else. If `age-keygen` is missing — the bootstrap script does not install it — `init` builds the
      kit's backup image to borrow its copy, which costs one Docker build.

- [ ] **Install the dev tools if you want `make lint`.** The bootstrap script installs none of them, by
      design: the root lint target needs `shellcheck`, `hadolint` and `yamllint`, the `compose/` half also
      needs `jq`, and the strict docs build needs `mkdocs`. Per host.

- [ ] **Add a hosts-file entry on the machine with the browser.** `n8n.localtest.me` resolves to `127.0.0.1`,
      which is not your VM, so point the name at it: `<vm-ip> n8n.localtest.me`. Add
      `kuma.n8n.localtest.me` to that line only if you later switch the `kuma` profile on.

### Where your state lives

| Where | Holds | If you lose it |
|---|---|---|
| Named Docker volumes (`n8nkit_pg_data`, `n8nkit_valkey_data`, `n8nkit_n8n_data`, `n8nkit_n8n_files`, `n8nkit_caddy_data`, …) | database, queue, n8n's settings and community nodes, user files, TLS certificates | your workflows and executions, unless you have a backup |
| `compose/.env` | domain, ports, sizing knobs and every generated secret, at file mode 600 | the stack will not start; `make init` writes a new one with *new* secrets, which no longer match the database |
| `compose/secrets/` | the `age` keys that encrypt backups, and the exported dev CA certificate | backups you cannot decrypt |

`COMPOSE_PROJECT_NAME` (default `n8nkit`) is the prefix on every container, network and volume name, which is
why the volumes are `n8nkit_*` and not named after your directory. Check one the way the kit's version guard
does: `docker volume inspect n8nkit_pg_data`.

`N8N_ENCRYPTION_KEY` in `.env` is the value every stored credential depends on: all five n8n processes share
it, and every credential in Postgres is encrypted with it. Each backup bundle carries a copy of it in a
`key-bundle.env` file, and `make restore ... ADOPT_KEY=1` writes that copy back into `.env` — but only while
you can still *decrypt* a bundle, which needs the `age` keys in `compose/secrets/`. So treat the two as one
thing: lose the encryption key and every bundle you can still open, and a restored database is credentials
nobody can read. Both belong in a password manager from the minute `make init` prints its red banner,
`STORE THESE IN A PASSWORD MANAGER NOW — THEY CANNOT BE RECOVERED LATER`.

!!! danger

    The command below prints a secret to your terminal and into your shell history. Run it once, paste the
    value into your password manager, then clear the screen.

    ```bash
    grep '^N8N_ENCRYPTION_KEY=' compose/.env
    ```

### The read-only inspection tools

Learn them in this order. None of them changes anything.

#### `make help` and `make version`

**What it is · Why you care.** `help` prints every target with a one-line description generated from the
Makefile's own comments, so it cannot drift from the code, and then two ready-made first-run command lines.
`version` prints two lines, one starting `kit ` (the git tag) and one starting `n8n ` (the version pinned in
`versions.env`).

```bash
make -C compose help
```

```bash
make -C compose version
```

**What you should see · What it proves.** The target list, the two first-run lines, then the two version
lines: you are in the right checkout and you know which n8n it intends to run. These two are also the only
targets that work before `make init` has written `.env`. **If it goes wrong:** a missing directory or an
unknown target means your shell is not in the repository root.

#### `make ps` and `make status`

**What it is · Why you care.** `ps` is `docker compose ps` with the kit's file and env-file arguments filled
in; that table is Docker's own, so this page predicts no text for it. `status` runs
`compose/scripts/status.sh`, which adds the pass/fail verdict `ps` has no opinion about.

```bash
make -C compose ps
```

```bash
make -C compose status
```

**What you should see.** A header row of `SERVICE STATE HEALTH UP RESTARTS`, one line per service, then
`[ OK ] all 11 services running and healthy`, the URL (`  n8n:  https://n8n.localtest.me/` here), and a
reminder to run `make trust-ca` because `TLS_MODE=internal`. The count is the number of services in the
resolved configuration, so it rises if you switch a profile on.

| Column | What it means |
|---|---|
| `SERVICE` | the Compose service name — the value you pass as `SERVICE=` elsewhere |
| `STATE` | Docker's container state. `running` is the only good one; `missing` means no container exists yet |
| `HEALTH` | the container's own health check: `healthy`, `starting` or `unhealthy`. All eleven core services define one, so `none` — which the script counts as healthy while the container runs — would only show for a service added without a check |
| `UP` | time since this container started, printed as `5m`, `2h13m` or `3d04h` |
| `RESTARTS` | Docker's restart count. Above 0 means something crashed and came back |

**What it proves.** Every process Compose knows about exists, runs and passes its own readiness probe; for
`n8n-main`, healthy means the database is connected *and* migrated.

**If it goes wrong.** It exits 1, so it also works as a gate inside your own checklists, and it names the
fix: `make logs SERVICE=<name> SINCE=10m`. One thing that looks alarming but is not: `starting` during a
first boot, because `n8n-main`'s health check is given a 600-second start period for the initial migrations.

#### `make logs SERVICE= SINCE=`

**What it is · Why you care.** Follows one service's output. n8n logs JSON lines (`N8N_LOG_FORMAT=json`), so
this is where migration progress and workflow errors appear in the process's own words.

```bash
make -C compose logs SERVICE=n8n-main SINCE=10m
```

**What you should see · What it proves.** During a first start, `Starting migration` lines; Ctrl-C stops
following. `SINCE` defaults to `10m`, and omitting `SERVICE` follows every service at once. You learn which
process is complaining, and about what. **If it goes wrong:** an empty result usually means your window is
shorter than the silence, so try `SINCE=24h`. Logs are capped at 20 MB × 5 files per container, so older
history is gone.

#### `make config` and `make env-keys`

**What it is · Why you care.** `config` prints the fully resolved Compose configuration — every variable
substituted, exactly what Docker will be asked to create — so it answers "did my `.env` edit reach the
container?" without starting anything. `env-keys` prints the key *names* in `.env`, sorted, never the values,
so you can show the shape of your configuration in a bug report; `.env` itself holds the encryption key and
six more generated secrets and must never be pasted anywhere.

```bash
make -C compose config | head -40
```

```bash
make -C compose env-keys
```

**What you should see.** From `config`, YAML on standard output: the project `name`, then `services`, with
real values where the file has `${...}` placeholders. From `env-keys`, one capitalised key name per line, in
alphabetical order, and no values anywhere.

**What it proves.** Both env-files parse and the digests are pinned. **If it goes wrong:** `config` is where a
missing secret surfaces, failing with the message written beside that variable in `docker-compose.yml`, such
as `run make pin` or `set N8N_ENCRYPTION_KEY (make init)`. `env-keys` prints `.env not found (make init)` and
exits 1 when there is no `.env`.

#### `make doctor`

**What it is.** A read-only diagnosis in ten sections, printed as `── configuration`, `── version lock`,
`── upgrade`, `── services`, `── edge`, `── host`, `── database`, `── queue`, `── backups`,
`── monitoring`. Every line is `[ OK ]`, `[warn]` or `[FAIL] <what> — <how to fix>`. Warnings never fail the
command; one `[FAIL]` exits 1. For an unhealthy service it also prints that container's last 20 log lines.

**Why you care.** It is the command for "something is wrong and I do not know what", and its output is what a
bug report needs. It sees what `status` cannot: encryption-key length, n8n and its runners image being the
same version, disk usage, clock sync, Postgres connections and size, whether execution pruning keeps up,
Valkey still on `noeviction` with AOF, and how old your newest backup and restore test are.

```bash
make -C compose doctor
```

**What you should see.** On a fresh healthy dev stack the last line has the form
`[ OK ] doctor: no problems found (2 warning(s))`. Both warnings are legitimate on a new install and name
their own fix: `no successful backup to /backups/local yet — run make backup-now`, and `no restore test has
run yet — make restore-test (weekly from cron)`. That result was recorded on the reference VM on 2026-10-10.
Other hosts can honestly show more — an unsynchronised clock, a disk over 80 %, a recovery key still sitting
on the host after seven days — so read the lines rather than counting them.

**What it proves.** The stack is not merely running but correctly configured, and your backups are real rather
than theoretical.

**If it goes wrong.** Fix the `[FAIL]` lines in the order printed; each carries its own remedy. To see what
failure output looks like before you have a real failure, inject some on purpose:

```bash
DOCTOR_SIMULATE=lowdisk,nokey,baddns,unhealthy make -C compose doctor
```

It prints an `[info]` line saying some failures below are injected on purpose, and exits non-zero. On this
stack three of the four keys bite: `nokey` (a blank encryption key), `unhealthy` (`n8n-worker-2` reported
unhealthy, with its log lines) and `lowdisk` (93 % used). `baddns` feeds a wrong answer to the DNS comparison
that runs only in the ACME TLS modes, so under `TLS_MODE=internal` it changes nothing. Nothing on the host is
touched either way.

!!! note

    Write `DOCTOR_SIMULATE=` in front of `make`, as a shell environment variable, exactly as above. The
    script reads it from its own environment, so that form is certain to reach it.

#### `make preflight`

**What it is.** The "will `make up` work on this host?" check, in the same three-prefix shape: Docker ≥ 27
and Compose ≥ 2.30, `.env` mode and required keys, pinned digests, both ports free (naming the process and
PID holding one), the `age` backup key and the backup targets, disk, RAM, CPUs, clock sync,
`vm.overcommit_memory`, and DNS.

**Why you care.** `make up` runs it first and refuses to continue on any `[FAIL]`. The refusal is the feature:
a wrong DNS record is named before anything is pulled, and `make up` never gets halfway in on a host that is
out of disk.

```bash
make -C compose preflight
```

**What you should see · What it proves.** `[ OK ]` lines ending with `[ OK ] preflight: all checks passed`,
meaning nothing about this host will stop `make up`. With `TLS_MODE=internal`, DNS is informational: any
address is fine, and a name that does not resolve on the host is a warning, not a failure. It takes seconds
and is safe at any time.

**If it goes wrong.** It exits with `[FAIL] preflight: N problem(s) — fix them and re-run make preflight`. The
two you will probably meet are `docker daemon not reachable` (the re-login trap) and a port in use, reported
with the holding process and PID.

#### `make lint`

**What it is · Why you care.** Static checks from the repository root: `shellcheck` on the scripts, `hadolint`
on the Dockerfiles, `yamllint` on the YAML, then the `compose/` suite — `docker compose config -q`,
`caddy validate` twelve times (once per combination of three TLS modes, UI protection on or off, Kuma on or
off) and the monitoring profile's validators — and finally `mkdocs build --strict` when mkdocs is installed.
It touches no running stack, so it proves a config edit is still valid in modes you are not using. It does
need the Docker daemon: those validators run inside the pinned images.

```bash
make lint
```

**What you should see.** `shellcheck: OK`, `hadolint: OK` and `yamllint: OK` from the root target, then the
compose suite's `[ OK ]` lines group by group — twelve reading `caddy validate tls=… ui=… kuma=…` — ending in
`lint: all checks passed`; then `mkdocs: OK` or a line saying it was skipped, and the root target's last
line, `lint: OK`. Allow about half a minute; the twelve Caddy validations alone take around 15 seconds.

**What it proves.** Every config file in the repository is syntactically valid, in every TLS and UI
combination, before you ask a container to load it. **If it goes wrong:** a tool the root target needs is
simply absent, so make stops with `Error 127`; a tool the `compose/` suite needs is named for you instead, as
`missing required command(s): ... — install them (scripts/bootstrap-host.sh does) and retry`.

### How to start, stop and resume safely

`make up` converges everything, in this order: `preflight`, the version guard, `render` (regenerated Compose
fragments and Prometheus targets), a pull of every pinned image, a local build of the `backup` image, the
backup volume's permissions, the dev-CA export when `TLS_MODE=internal`, `docker compose up -d --wait` with a
900-second timeout, the `n8n_files` ownership fix, a Caddy reload, the Kuma and Grafana setup steps for those
profiles, and the status table. It is idempotent — run it again after a `.env` change and Compose recreates
only the containers whose configuration changed.

- [ ] Start the stack. Budget about five minutes the first time: roughly four minutes of image pulls, then
      around 50 seconds until all eleven containers are healthy, as measured on the reference VM. On a
      heavily loaded host a first start has taken 6.5 minutes, of which 2m41s was the 275 initial database
      migrations. Pulls are retried three times, 20 and 40 seconds apart, because public registries throttle
      anonymous clients: a `toomanyrequests` error on the first attempt is normal, not fatal.

```bash
make -C compose up
```

- [ ] Confirm it worked.

```bash
make -C compose status
```

- [ ] Trust the dev certificate authority once, so your browser and `curl` accept the kit's certificates. Read
      its output rather than assuming: it copies the certificate into your home directory, installs it into
      this host's trust store when the tools and the rights are there, and prints the one-liners for a browser
      on another machine. Then open the URL `status` printed; its first page asks you to create the instance
      owner ([Quickstart](quickstart.md) walks through that).

```bash
make -C compose trust-ca
```

- [ ] Stop the stack when you are done. `down` removes the containers but keeps every volume and keeps `.env`,
      so the database, queue, certificates and settings are all still there.

```bash
make -C compose down
```

Restart one wedged process with the line below. It is not how a `.env` change is applied — that is `make up`,
because a restart reuses the container exactly as it was created.

```bash
make -C compose restart SERVICE=n8n-worker-1
```

**After a VM reboot you do nothing.** Every container is declared `restart: unless-stopped`, so Docker starts
the stack again on boot; check with `make -C compose status`. The exception is a container you stopped or
killed yourself: `docker stop` and `docker kill` both cancel that container's restart manager, so it stays
down until the next `make up`. A drill measured such a container down for 14 minutes with a restart count of
0.

!!! danger

    `make clean` is not a stronger `make down`. It runs `docker compose down -v`, which **destroys the
    volumes**: database, queue, certificates and n8n's own data directory. `.env` and `secrets/` stay on disk,
    and the record of an unfinished upgrade is filed under `compose/.upgrade/history/`. It prints
    `This removes the containers AND the volumes: database, queue, certificates, n8n data.` and then makes you
    type the word `destroy` — a prompt it skips when `YES=1` or `CI=1` is set, so never put either of those on
    this command line.

    On this disposable dev VM that is fine, and it is how you get back to a first-run n8n with no owner
    account. On a real instance it ends your workflows, credentials and execution history, with only a backup
    between you and permanent loss. Take one first:
    [Backup and restore](operations/backup-restore.md).

```bash
make -C compose clean
```

### The version guard, and where it bites

**What it is · Why you care.** Early in `make up` — after `preflight`, before anything is pulled or started —
`compose/scripts/version-guard.sh` checks that no upgrade or rollback is unfinished, that `.env` is not
overriding the image pins, and that the n8n version in `versions.env` matches the version actually running
or, when the stack is down, the version the database was last used by. Changing n8n's version is not a
restart: moving forward runs database migrations, which is why `make upgrade` takes a backup first and lets
exactly one process migrate; moving backward is worse, because n8n ignores migrations it does not know and
starts on a schema it does not understand.

**Where it bites.** You `git pull` the kit, the pin moves, and your next `make up` stops with a message of the
form `versions.env pins n8n <new>, n8n-main runs <old> — apply the new version with 'make upgrade' (it takes a
backup, then runs the migrations in order), not make up`. That is the guard working: run
`make -C compose upgrade`. After an interrupted upgrade it refuses with `an upgrade is unfinished
(PHASE=...; make doctor shows it)` and tells you that `make upgrade RESUME=1` finishes it and `make rollback`
undoes it. The procedure and its limits are in [Upgrade and rollback](operations/upgrade-rollback.md).

---

## Part B — The edge, the UI, and your first real workflow { #part-b }

Part A left you with every container running and healthy. Part B is where you use the thing: you make your
browser trust the dev certificate, log in, prove which process answers which URL, build a workflow by hand,
and watch a worker run it.

Everything below assumes your shell is in the repository root on the dev VM from Part A
(`DOMAIN=n8n.localtest.me`, `TLS_MODE=internal`, ports 80 and 443, monitoring profile off), the same place
Part A worked from: `make -C compose <target>` and the relative paths below are all written from there.

!!! note
    If ports 80/443 were already taken on your host, Part A ran `make init` with `HTTP_PORT=8080
    HTTPS_PORT=8443`. Every URL below then needs the port — `https://n8n.localtest.me:8443/…`. `make init`
    writes that into `PUBLIC_URL`, and `make -C compose status` prints that URL back to you — but only once
    every service is healthy. If something is unhealthy, `status` names it and stops without printing the URL,
    so fix that first.

### 1. The edge: what Caddy is doing for you

**What it is.** Caddy is the reverse proxy — a program that accepts every request from outside and hands it
to the right internal container. It is the only container that publishes a port, so the database, the queue
and n8n itself are unreachable from your network except through it. Its four jobs are all in
`compose/caddy/Caddyfile` and the small snippet files it imports:

| Job | What it means in plain words |
|---|---|
| TLS termination | Serves `https://`, so passwords and webhook payloads are encrypted in transit. |
| HTTP to HTTPS | A request to `http://` gets a permanent redirect (308) to the `https://` address. |
| Security headers | On every response: HSTS (tells the browser to use HTTPS for this host for a year), `X-Content-Type-Options: nosniff` (do not guess a response's type), `X-Frame-Options: SAMEORIGIN` (no other site may put the editor in a frame), a strict referrer policy — and the `Server` banner removed, so the edge does not advertise what it is. |
| Routing | Splits traffic between `n8n-main` (editor, API) and the webhook pool. See step 3. |

**Why you care.** Every response Caddy proxies to an n8n process also carries `X-Kit-Upstream: <container>:5678`.
That header is the kit's routing contract: it names the container that actually answered, and it is how you prove a
request went where it should. Responses Caddy writes itself — a 502 when nothing upstream is reachable, or the
deliberate 404 on `/metrics` — carry no such header, which is a useful tell in its own right.

#### TLS_MODE: three ways to get a certificate

A certificate is signed by a **certificate authority** (an issuer browsers already trust). `TLS_MODE` in
`.env` picks which authority signs yours; Caddy imports one snippet file per mode.

| `TLS_MODE` | Who signs | Trusted? | Use it when |
|---|---|---|---|
| `internal` | Caddy's own local CA | Only after you install the root certificate | A dev VM, or any name no public CA can issue for (`*.localtest.me`, `localhost`, an IP) |
| `acme-staging` | Let's Encrypt **staging** | No, by design | Rehearsing DNS, firewall and ports on a public host without burning rate limits |
| `acme` | Let's Encrypt production | Yes, automatically | A public host whose DNS points at it, ports 80 and 443 reachable |

ACME is the protocol Let's Encrypt uses to check you control the domain before issuing. It needs public DNS
and inbound port 80, which a dev VM does not have — so `internal` is right here: Caddy mints its own
authority in its data volume and issues 12-hour certificates from it, renewing them itself
(`compose/caddy/tls-internal.caddy`). Switching to `acme` later changes where the certificate comes from, not how
you build workflows — but it normally also means a new, public `DOMAIN`, and `PUBLIC_URL` is derived from `DOMAIN`.
`PUBLIC_URL` is what n8n prints as a webhook address, so every caller of a production webhook has to be pointed at
the new host name when you move.

**Do this.** `make up` already ran the first command when `TLS_MODE=internal`; running it again is harmless.

- [ ] Export the dev CA's root certificate. Worst case it takes about two and a half minutes: up to 90 s waiting
      for Caddy to be healthy, then up to 60 s for the CA file to appear.

```bash
make -C compose dev-ca
```

- [ ] Install it where your tools can see it:

```bash
make -C compose trust-ca
```

**What you should see.** `dev-ca.sh` prints either `dev CA exported:` or `dev CA unchanged:` plus the path
`compose/secrets/dev-root.crt`. `trust-ca.sh` prints `copied to …/n8nkit-root.crt`, and — if it could become
root without a password prompt — `installed into the host trust store (update-ca-certificates)`. If not, it
says `not installed into the host trust store` and offers the `curl --cacert` form instead: a normal outcome,
not a failure. (If you run the kit inside WSL rather than a VM, it also copies the file straight into your Windows
Downloads folder and says so, which saves you the `scp` below.) It finishes by printing the two commands for a
Windows browser, the URL to open, and the macOS equivalent. Those two Windows commands are the point of this step
for you — run them in **PowerShell** on your laptop, not in the VM's shell:

```powershell
scp <vm-user>@<vm-ip>:~/n8n-prod-kit/compose/secrets/dev-root.crt $env:USERPROFILE\Downloads\n8nkit-root.crt
certutil -addstore -f ROOT $env:USERPROFILE\Downloads\n8nkit-root.crt
```

Take the source path from your own run rather than retyping this one: the script prints the absolute path to
`compose/secrets/dev-root.crt` inside your checkout, which is `~/n8n-prod-kit` on the reference host. Run the
`certutil` line in an **administrator** PowerShell, then restart the browser. That machine also needs
`n8n.localtest.me` in its own hosts file pointing at the VM — `localtest.me` resolves to `127.0.0.1`
everywhere, so without the entry the name points at your laptop.

**What it proves.** Only the root *certificate* leaves the stack, never the CA's private key. The same file is
mounted read-only into all five n8n processes as `NODE_EXTRA_CA_CERTS` (`compose/compose.dev.yml`), which is how
n8n can call its own `PUBLIC_URL` without a certificate error. The runners sidecars are deliberately left out:
they only talk to their own worker on the internal network and never see the public certificate.

**If it goes wrong.** A warning such as "your connection is not private" means the browser does not recognise
the signer. It does **not** mean the connection is unencrypted or the stack is broken. In `internal` mode you
get it until `certutil` has run; `make -C compose status` ends with a reminder of exactly that — `dev TLS: the
certificate is signed by the kit's local CA — run 'make trust-ca' once so browsers and curl trust it`. On a public
host in `acme` mode you should never see it — there it means DNS, port 80 or the ACME exchange failed, and the fix
is in [Quickstart](quickstart.md), not in your trust store.

!!! tip
    If you edit the Caddyfile, run `make -C compose up` again: among its steps it calls `caddy-reload.sh`, which
    reloads gracefully and prints `caddy: configuration reloaded`. An invalid file is refused and the running
    configuration kept, with a `caddy: the Caddyfile was not reloaded` warning. `make -C compose lint` checks the
    file for all twelve `TLS_MODE` x `UI_PROTECT` x `KUMA_ENABLED` combinations before you restart anything — it
    needs `shellcheck`, `yamllint` and `jq` installed on the host and names the missing one if it stops at once.

### 2. Logging in, and the editor screen

**What it is.** n8n has one **instance owner**: the first account, created once on a first-run setup page, with
full rights over the instance. Once it exists that page is gone for good, and every other user is invited from
inside the editor.

**Why you care.** Two things follow from "created once". You should create it yourself rather than leave the setup
page reachable, and whatever you type becomes the only way into this instance. It is also the one secret step 7
needs: the smoke suite can create the owner itself on an instance that has none (`smoke-owner@example.com`,
password written to `compose/.smoke/owner.env`), but it cannot guess a password you typed into a browser.

**Do this.**

- [ ] Open the URL `make -C compose status` printed. If you get the setup page, create the owner. The password
      needs at least eight characters including a digit and an uppercase letter.
- [ ] If you get a login page instead, the instance already has an owner, because something ran `make smoke` before
      you. Its email and password are in `compose/.smoke/owner.env` on the host.
- [ ] Put that email and password in your password manager now, and keep them to hand: step 7 asks for them.

**What you should see.** The editor, with an empty workflow list. Four places matter to you.

| Where | What it holds |
|---|---|
| Workflows | Your workflows. A workflow is a trigger plus the nodes it runs. |
| Executions | One row per run, with status and the data each node produced. Your audit trail. |
| Credentials | Saved logins for other services, encrypted in Postgres with `N8N_ENCRYPTION_KEY`. |
| Settings | Account settings and the personal API keys page (the editor calls `/rest/api-keys` behind it). |

**What it proves.** Reaching the editor means Caddy's catch-all route, TLS and `n8n-main` all work.

**If it goes wrong.** A login answered with **HTTP 429** is the rate limit, not a wrong password: n8n allows
five `/rest/login` attempts per window per client IP, and this is not configurable. The response's
`Retry-After` header says how many seconds to wait — wait them out, then try once, carefully. The smoke
suite's helper logs the same thing as `n8n login rate limit hit (5 per window) — waiting …s`. Because the kit
sets `N8N_PROXY_HOPS=1`, Caddy's forwarded client address is trusted, so the counter is on *your* address rather
than the proxy's. More in [FAQ](faq.md).

### 3. Routing: proving who answers what

**What it is.** Two kinds of n8n process serve HTTP here. `n8n-main` serves the editor, the `/rest` API and the
`*-test` URLs the editor uses while you build. The **webhook pool** — `n8n-webhook-1` and `n8n-webhook-2`, started
with the `webhook` command — serves production triggers only: it looks the workflow up, pushes a job into the queue
(a list of jobs waiting for a worker to pick them up) and answers. It never executes workflow code. Neither does
main: the kit sets `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`, so even a run you start from the editor is handed
to a worker.

| Path | Goes to |
|---|---|
| `/webhook/*`, `/webhook-waiting/*`, `/webhook-waiting-slack*`, `/webhook-waiting-telegram*`, `/form/*`, `/form-waiting/*`, `/mcp/*` (n8n's MCP server endpoints) | webhook pool |
| `/healthz/webhook` | webhook pool (rewritten to `/healthz`) |
| `/healthz` | `n8n-main` |
| `/metrics*` | `404`, never public |
| everything else — `/`, `/rest/*`, `/webhook-test/*`, `/form-test/*`, `/mcp-test/*`, `/chat`, `/push` | `n8n-main` |

**Why you care.** The split is why restarting the editor does not drop inbound webhooks, and why you can add
webhook processes without touching main. It is also the one thing that fails *silently* when it is wrong.

**Do this.**

- [ ] Ask four paths who answered them. The loop prints one line per path: the path, then the upstream that served
      it, and nothing else.

```bash
for p in /healthz /healthz/webhook /form/x /webhook-test/x; do
  printf '%-18s ' "$p"
  curl -sS --cacert compose/secrets/dev-root.crt -o /dev/null -D - "https://n8n.localtest.me$p" \
    | awk 'tolower($1) == "x-kit-upstream:" { sub(/\r$/, "", $2); print $2 }'
done
```

`--cacert compose/secrets/dev-root.crt` is how curl trusts the dev CA without installing it, exactly as the smoke suite
does it; `-o /dev/null -D -` throws the body away and prints the headers instead, and `awk` keeps the one header
that matters.

**What you should see.** `/healthz` and `/webhook-test/x` answered by `n8n-main:5678`; `/healthz/webhook` and
`/form/x` answered by `n8n-webhook-1:5678` or `n8n-webhook-2:5678`. Repeat the loop a few times and the pool member
alternates: Caddy balances round robin and admits only a member whose `/healthz/readiness` passed. A single extra
request is not a guarantee of alternation — the smoke suite keeps asking for up to 30 s before it concludes that
both members answered.

**What it proves.** That the routing contract holds for the four paths you just asked about. Smoke 02 asserts the
two health paths on every run, and smoke 04 does the rest path by path — `/form/x`, `/form-waiting/x`,
`/webhook-waiting/x`, `/mcp/x` to the pool, and `/form-test/x`, `/mcp-test/x`, `/rest/settings` to main.

!!! warning
    `n8n-main` also runs with `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true`, which stops it mounting the
    production webhook, form, waiting and MCP paths. Do not treat that flag as your safety net. The kit's bug
    log records the verified behaviour: **with the flag set**, a misrouted `/webhook/x` still falls through to
    the editor's single-page app and answers HTTP 200 with HTML. The caller sees success and the workflow
    never runs. The real safeguards are the explicit Caddy routes plus the `X-Kit-Upstream` assertions in the
    smoke suite — which is why you just read that header instead of trusting a 200.

**If it goes wrong.** A pool path answered by `n8n-main:5678`, or a 200 whose body is HTML, means the
Caddyfile in the container is not the one on disk: `make -C compose up` reloads it. A 502 means no pool member
is passing readiness yet — look with `make -C compose logs SERVICE=n8n-webhook-1` (it follows the log, so
Ctrl-C to stop). [Architecture](architecture.md) has the full table and the reasoning.

### 4. Your first workflow, by hand

**What it is.** A **webhook** is a URL that starts your workflow when something calls it. You will build the
smallest useful one: a Webhook trigger plus a Code node that answers with what it received.

**Why you care.** The test-URL versus production-URL distinction below is the most common beginner confusion
in n8n, and it is easier to learn on a workflow you built than on a broken integration.

**Do this.** In the editor:

- [ ] New workflow, named `hello-pool` (read the danger note below before naming anything `kit-smoke-…`).
- [ ] Add a trigger node, choose **Webhook**, set HTTP Method `POST` and Path `hello-pool`, and leave the response
      mode on the option that answers with the last node's output — the shipped fixture uses
      `responseMode: lastNode`, meaning "answer the caller with whatever the last node produced".
- [ ] Add a **Code** node after it and paste this, the body of `tests/smoke/fixtures/wf-webhook-echo.json`:

```javascript
const body = $input.first().json.body;
return [{ json: { pong: body.ping, exec: $execution.id } }];
```

- [ ] **Save**, then make the workflow live. This page cannot promise the exact word your build of the editor puts
      on that control, so look for the switch or button that takes a workflow from draft to live; the public API
      calls the same operation `/api/v1/workflows/{id}/activate`, and the kit's smoke output labels it
      `workflow published/activated`. Saving stores the workflow; making it live is what registers the production
      URL on the webhook pool.
- [ ] Copy the **production** URL the Webhook node shows: `https://n8n.localtest.me/webhook/hello-pool`,
      because the kit sets n8n's webhook base URL from `PUBLIC_URL`.

| | Test URL | Production URL |
|---|---|---|
| Path | `/webhook-test/<path>` | `/webhook/<path>` |
| Served by | `n8n-main` only | the webhook pool only |
| When it listens | After you start a test run in the editor, for one call | Always, once the workflow is live |
| What you see | The data appears live on the canvas | A row in Executions |

- [ ] Call the production URL:

```bash
curl -sS --cacert compose/secrets/dev-root.crt -D - \
  -H 'Content-Type: application/json' --data '{"ping":"hello"}' \
  https://n8n.localtest.me/webhook/hello-pool
```

**What you should see.** A JSON body with a `pong` field echoing `hello` and an `exec` field holding the
execution id — your Code node's return value — plus an `X-Kit-Upstream` header naming an `n8n-webhook-N`
container. Then a new row in **Executions**.

**What it proves.** Going live reached the pool; the pool enqueued the job; a worker ran your code; the
response came back through Caddy.

**If it goes wrong.** A **404** for the first few seconds is normal: activation reaches the webhook processes
asynchronously. The first execution after a (re)start waits on top of that for the runners sidecar to launch its
JavaScript runner process — the repo records over 60 s of that on the author's build VM while it was heavily
loaded (load average around 24), which is why smoke 04 gives the same step up to 180 s. Retry before you debug.
A 404 that never clears usually means saved but never made live, or a mismatched path. A **200 whose body is
HTML** is the misroute from step 3.

!!! danger
    `make smoke` deletes **every** workflow whose name starts with `kit-smoke-` when it finishes, plus the
    throw-away credential it created. On this disposable dev stack that is the point. Never name a workflow
    you want to keep `kit-smoke-anything`, here or on a real instance.

### 5. Where the execution actually ran

**What it is.** The pool only enqueued the job. A **worker** (`n8n-worker-1`, `n8n-worker-2`) took it off the
queue and executed it. Each worker has its own **runners sidecar** (`n8n-worker-N-runners`): a separate
container that runs Code-node JavaScript in a sandbox, on the internal network only, mounting no volumes.

**Why you care.** Two consequences hit every beginner, and both are the sandbox working as designed:

- `fetch` is not available in a Code node ("fetch is not defined"), because the sandbox has no network of its
  own. Use `this.helpers.httpRequest(...)`, which the worker executes for you, or an HTTP Request node.
- `process` and environment access are blocked ("process is not defined"), from
  `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`. Pass configuration in through the workflow instead of `process.env`.

**Do this.**

- [ ] Open the run in **Executions** and confirm it succeeded and shows your node data.
- [ ] Find the worker that ran it, using the id from the `exec` field. This command follows the log, so give it a
      moment to print the backlog, then press Ctrl-C:

```bash
make -C compose logs SERVICE=n8n-worker-1 SINCE=30m
```

**What you should see.** A JSON log line containing `Worker finished execution <id> (job <n>)`. If it is not
in worker 1, look in `n8n-worker-2`. Smoke 05 does this same search for you and additionally asserts that
`n8n-main`'s log does **not** contain that line.

**What it proves.** Queue mode is real: main is not in the execution path, so restarting the editor does not
interrupt work in flight. Smoke 05 also checks the execution is `success` both in the public API and in the
`execution_entity` table in Postgres, that the metric `n8n_scaling_mode_queue_jobs_completed` increased, and
that keys belonging to Bull — the job-queue library n8n uses, whose keys are prefixed `n8n:` here — exist in
Valkey, the queue store.

!!! warning
    Queue mode protects you from an editor restart, not from a dying worker. The kit measured this: a worker
    killed mid-execution **loses** the executions it was running. n8n builds the Bull queue with
    `maxStalledCount: 0`, so a stalled job is failed on its first stall instead of being put back on the queue;
    the execution ends as `crashed`, possibly after it already performed half its side effects, and nothing
    retries it for you. A node's own "Retry on Fail" does not survive a killed container either — only an Error
    Workflow sees it. Taking a worker out safely means draining it with `docker stop` (SIGTERM), which is what
    `make upgrade` does. [Chaos drills](operations/chaos-drills.md) has the measurements.

**If it goes wrong.** No worker log line and no execution row means the job never left the queue. Check that both
workers and both runner sidecars are healthy with `make -C compose status`, then run `make -C compose doctor` — it
is read-only and prints a fix with every failure it reports. A Code node failing on `fetch` or `process` is the
sandbox, not a bug; see [FAQ](faq.md). Worker counts and concurrency are in [Scaling](operations/scaling.md).

### 6. Files: the one volume that needed a fix

**What it is.** The Read/Write Files node may only touch `/home/node/.n8n-files` (n8n's
`N8N_RESTRICT_FILE_ACCESS_TO` default), and the kit gives that path a volume of its own, `n8n_files`, to keep user
files out of the config tree that holds the encryption key.

**Why you care.** That directory does not exist in the n8n image, so Docker created the mount point as `root:root`
while n8n runs as uid 1000 — every write failed with `EACCES`, and the node was broken on every fresh install until
this was fixed. `make up` now runs `compose/scripts/files-perms.sh` after `compose up`, which chowns the directory
to uid 1000 once, with no restart. You will meet the same bug the day you mount a volume of your own on a path the
image lacks.

**Do this.**

- [ ] Confirm the ownership. The parentheses run the command in a subshell, so your own shell stays in the
      repository root:

```bash
(cd compose && docker compose --env-file versions.env --env-file .env \n   exec -T n8n-worker-1 sh -c 'ls -ld /home/node/.n8n-files')
```

**What you should see.** One line whose owner column reads `node` — the image's uid-1000 user — and not `root`. If
you would rather see the number, ask for it directly; `1000` is exactly what `files-perms.sh` compares against:

```bash
(cd compose && docker compose --env-file versions.env --env-file .env \n   exec -T n8n-worker-1 sh -c 'stat -c %u /home/node/.n8n-files')
```

`files-perms.sh` itself stays quiet when there is nothing to fix, and prints
`n8n files volume …: owner <old> -> 1000 (the Read/Write Files node can write again)` when it fixes one.

**What it proves.** A Write File node will now succeed. The fixture the chaos drill ships,
`tests/smoke/fixtures/wf-chaos-idempotent.json`, writes into exactly this tree with the Read/Write Files node.

**If it goes wrong.** If the script cannot check or fix the ownership it warns and tells you to re-run
`make up`. Note that `n8n_files` is **not** in the kit's backups — back it up separately if workflows keep
files there ([Backup and restore](operations/backup-restore.md)).

### 7. `make smoke`: the automated version of everything you just did

**What it is.** Nine scripts in `tests/smoke/` that drive the running stack through Caddy the way you just
did by hand, and look inside containers only where the outside cannot see. They run in order and stop at the
first failure, because later ones build on earlier ones (04 creates the workflow 05 inspects).

| Script | What it asserts |
|---|---|
| `01-health` | Every service healthy within 180 s; worker count equals `WORKER_REPLICAS`; every worker has a runner sidecar; every n8n process runs the pinned version and digest. |
| `02-tls` | The HTTP→HTTPS redirect keeps a non-standard port; the chain validates; HSTS, `nosniff`, `SAMEORIGIN`, no `Server` banner; `/healthz` from main, `/healthz/webhook` from the pool. |
| `03-owner` | An owner exists; login works; a wrong password is rejected; an API key is accepted and a bogus one rejected. |
| `04-webhook-routing` | A published workflow answers on `/webhook/<path>` through the pool, never main; round robin reaches every webhook process; each test and production path lands on the right upstream. |
| `05-execution-on-worker` | The execution is `success` in the API and in Postgres; a worker's log names it, main's does not; the queue metric moved; Bull keys exist in Valkey; `this.helpers.httpRequest` works. |
| `06-metrics` | Every n8n process and Caddy expose metrics inside the stack; main carries the queue gauges; `/metrics` is not public. |
| `07-backup` | A backup lands encrypted on every `BACKUP_REMOTES` target, decrypts, its sha256s verify, its key bundle carries the running encryption key, and its metric is fresh. |
| `08-restore-test` | Every remote's newest bundle verifies and the newest restores into a scratch Postgres inside the backup container. The live database is never touched. |
| `09-monitoring` | The monitoring profile end to end. Skipped when `COMPOSE_PROFILES` does not list `monitoring`. |

**Why you care.** Checking all of this by hand is most of an afternoon, and you would not do it again after every
small change. The suite does it unattended and in the same order every time, which is what turns "it still works"
from an impression into a fact. It is the first thing to run after you touch `.env`, the Caddyfile or a pinned
version.

**Do this.**

- [ ] If you created the owner yourself in the browser in step 2, hand those credentials to the suite first. It has
      no other way in, and without them it stops at `03-owner` with *this instance already has an owner but
      compose/.smoke/owner.env is missing*:

```bash
export SMOKE_OWNER_EMAIL='you@example.com'
export SMOKE_OWNER_PASSWORD='the password you typed'
```

The suite reads both from the environment and `make` passes its environment through, so an `export` in this shell
is enough. Skip this step if `compose/.smoke/owner.env` already exists — then the suite created the owner itself
and already knows the password.

- [ ] Run the whole suite. How long it takes is a property of your host, not of the suite: the one figure recorded
      in this repo is 9/9 in about 37 s on a fresh 2-vCPU Ubuntu 24.04 host with `BACKUP_REMOTES=/backups/local`,
      while the same suite takes several minutes on a GitHub Actions runner. Let it finish.

```bash
make -C compose smoke
```

- [ ] Re-run only the two scripts covering what you built, for a quick check after a change:

```bash
make -C compose smoke ONLY=04,05
```

- [ ] Keep the workflows it creates, to open them in the UI. They — and the throw-away credential — then stay until
      the next run without `SMOKE_KEEP`, which clears every `kit-smoke-` workflow again:

```bash
SMOKE_KEEP=1 make -C compose smoke
```

**What you should see.** A `PASS`/`FAIL` row per selected script with its duration, then `smoke: all selected
scripts passed`. With the monitoring profile off, `09-monitoring` prints `monitoring profile off
(COMPOSE_PROFILES) — skipped` and counts as a pass; that is expected here, because `make init` leaves
`COMPOSE_PROFILES` empty and Part A never switched the profile on. Switching it on costs roughly another gigabyte
of RAM and gives you dashboards and alerts ([Monitoring](operations/monitoring.md) explains what they cover).
Script 04 may also warn that Postgres logged new `invalid input syntax ... NaN` errors — a known, harmless upstream
issue from an n8n-internal executions query; the executions still succeed.

**What it proves.** Every claim in this part, repeatably. Run it after any change, before you believe anything.

**If it goes wrong.** The failing script's `[FAIL]` lines name the check, and the run ends pointing at
`make logs SERVICE=<name> SINCE=10m`. The suite is built to be re-runnable: it reuses the owner, the session
cookie and the API key in `compose/.smoke/`. It still spends exactly two of n8n's five login attempts per run —
one deliberately wrong, one right — so three runs in quick succession can walk into the 429 from step 2; wait the
window out rather than retrying. Where `BACKUP_REMOTES` is empty, 07 stops the run on purpose — on this dev VM
`make init` set `/backups/local`, so it passes. Settings are in [Configuration](configuration.md); the threat
model is in [Security](security.md).

---

## Part C — Backups, restore, and the key that everything depends on { #part-c }

Do this part slowly: everything else in the kit can be rebuilt from git, the contents of your n8n instance
cannot. Work on the dev/test VM from Part A with the stack up (`make -C compose status` shows every service
`running`), and with at least one workflow and at least one credential saved in n8n — the restore test only
exercises credential decryption when there is a credential to decrypt. Budget about 45 minutes.

Every command below is written as `make -C compose <target>` and assumes your shell is in the repository root,
the directory you cloned into — `-C compose` is a path relative to where you are standing, because the kit's
targets live in `compose/Makefile`. The kit's own messages print the short form (`make doctor`): the same
command, run from inside `compose/`.

### C1. What is precious, and what the encryption key is

**What it is.** All of n8n's state is in one Postgres database, `n8n` (`compose/docker-compose.yml`):
workflows, credentials, execution history. Binary data (files passing through a workflow) is in there too,
because the kit sets `N8N_DEFAULT_BINARY_DATA_MODE: database` (`compose/docker-compose.yml`). A copy of that
database is therefore a copy of almost your whole instance — C11 lists the two things it leaves out. The
credentials in it are encrypted with `N8N_ENCRYPTION_KEY` from `compose/.env`: 64 characters that `make init`
generated once, shared by every n8n process.

**Why you care.** Lose the key and a restored database hands your workflows back with credentials nobody can
decrypt: the rows are there, the secrets inside them are noise. A database backup on its own is half a backup,
which is why this kit's bundles carry the key too.

!!! warning
    Copy `N8N_ENCRYPTION_KEY` out of `compose/.env` into your password manager now, and read it back from there
    once. Never paste it into a chat, a ticket or a commit. `make -C compose env-keys` prints key *names* only -
    that is what goes into bug reports.

**Do this.**

- [ ] Reveal the key with `grep '^N8N_ENCRYPTION_KEY=' compose/.env`, store it, then re-open the
      password-manager entry and compare its first and last four characters with the file.

**If it goes wrong.** `make -C compose doctor` fails with `N8N_ENCRYPTION_KEY is missing or shorter than 32
chars — every credential depends on it; restore it from your password manager (never generate a new one over an
existing database)` (`compose/scripts/doctor.sh`). A fresh key over an existing database does not repair
anything.

### C2. What a backup bundle contains

**What it is.** One file per backup, named `n8n-<UTC timestamp>-<kind>[-label].tar.age` — a label you pass is
lower-cased in it — holding three files (`compose/backup/backup.sh`):

| File | What it holds |
|---|---|
| `db.dump` | `pg_dump -Fc -Z6` (Postgres's own dump tool, compressed) of the whole `n8n` database |
| `key-bundle.env` | the `N8N_ENCRYPTION_KEY`, the n8n and Postgres versions, the domain, the timestamp |
| `manifest.json` | the bundle's own name, the sha256 checksum of `db.dump` and of `key-bundle.env`, `db.dump`'s size, and the workflow and credential counts |

**Why you care.** A restore needs both halves, so they ship together — encrypted, so the key riding along is not
a leak. The counts come from inside the dump rather than from the live database, so they match the snapshot
exactly even while n8n keeps writing.

**If it goes wrong.** The manifest is also a tamper check: the file's name and both sha256 checksums are
verified before anything in the bundle is used, and a name that disagrees with the manifest is refused with
`renamed or planted file, refusing it` (`compose/backup/lib.sh`). Do not restore such a bundle; find
out who wrote it.

### C3. age encryption and the two keys

**What it is.** `age` is a small file-encryption tool. You encrypt to a *recipient* (a public key, safe to
publish) and decrypt with that recipient's *private key*. Every bundle goes to two recipients:

| Recipient | Private half lives | So that |
|---|---|---|
| host key | `compose/secrets/age-key.txt`, on the VM | the machine can run the weekly restore test unattended |
| recovery key | your password manager | you can restore when the host is gone, and a stolen bucket is useless |

**Why you care.** The kit refuses to *make* a backup while `BACKUP_AGE_RECOVERY_PUBLIC_KEY` is empty
(`compose/backup/backup.sh`), and the restore test refuses a bundle it finds with fewer than two
recipients — a backup only the lost host can open is not a recovery plan.
`BACKUP_ALLOW_SINGLE_RECIPIENT=true` switches both refusals off; on a real instance, do not.

!!! info
    age proves confidentiality, not origin. Anyone who can write to your backup target and knows the public key
    (it is in `.env` as `BACKUP_AGE_PUBLIC_KEY`) can put a well-formed bundle there. So the kit treats the
    *running* `N8N_ENCRYPTION_KEY` as proof that a bundle is yours, and checks it before any of a bundle's SQL
    runs. See [Backup and restore](operations/backup-restore.md) and [Security](security.md).

**If it goes wrong.** While `BACKUP_AGE_RECOVERY_PUBLIC_KEY` is empty and `BACKUP_ALLOW_SINGLE_RECIPIENT` is not
`true`, `make -C compose preflight` fails and tells you to put the public key back with
`age-keygen -y <recovery key file>` (`compose/scripts/preflight.sh`).

### C4. `make detach-recovery-key` — getting the recovery key off the host

**What it is.** `make init` wrote the recovery private key to `compose/secrets/age-recovery-key.txt`. While it
sits there it protects nothing: whoever takes the VM takes it too. This command prints it once, makes you paste
it back *from* your password manager, checks the paste really is that key, then shreds the file.

**Why you care.** Once that file is more than seven days old, `make -C compose doctor` warns, in these words:
*"a backup that can be decrypted from the same host it protects is not a recovery plan"*
(`compose/scripts/doctor.sh`).

!!! danger
    This destroys the only copy of the recovery private key on the machine. On this dev VM the stakes are low -
    the host key still opens today's bundles. On a real instance a lost recovery key means every existing bundle
    can only ever be opened from that one host. Do not run it without your password manager open.

**Do this.** It is always interactive: `YES=1` and `CI=1` are deliberately ignored.

- [ ] Run it, with the password manager open:

`bash
make -C compose detach-recovery-key
`

- [ ] Copy the whole `AGE-SECRET-KEY-1...` line into a new entry named `n8nkit/age-recovery-key`.
- [ ] Paste it back when asked (input is hidden), then type `shred` at the last prompt.

**What you should see.** A red framed banner headed `RECOVERY KEY — copy the AGE-SECRET-KEY-1… line into your
password manager (entry n8nkit/age-recovery-key)`, then `Now paste the key back FROM the password manager (input
hidden), then Enter:`, then `[ OK ] the copy in your password manager is the recovery key`, and finally
`[ OK ] recovery key removed from this host (public key stays in .env: BACKUP_AGE_RECOVERY_PUBLIC_KEY)`
(`compose/scripts/detach-recovery-key.sh`). `make -C compose doctor` then says `recovery key
detached (private half off-host; backups are still encrypted to it)`.

**What it proves.** Your password manager holds a key that really opens your backups — verified while the
original still existed, so a truncated copy-paste cannot slip through.

**If it goes wrong.** A paste that does not match gives *"the pasted key is not the recovery key (truncated or
mistyped copy?) … nothing was shredded"*, and the file stays. If the key file on the host is not the one `.env`
encrypts to, the command stops before printing the key at all and tells you to fix `.env` first; nothing is
shredded then either. Running it a second time is harmless: `no secrets/age-recovery-key.txt on this host — the
recovery key is already detached`, exit 0.

!!! warning
    A recorded gap: **there is no supported way to rotate a detached recovery key** (`n8n-kit-HANDOFF.md`).
    `make init FORCE=1` keeps a detached key's public half on purpose, since dropping it would make existing
    bundles unrestorable. To replace one you work by hand: generate a new age key pair, put the new private half
    in the password manager, edit `BACKUP_AGE_RECOVERY_PUBLIC_KEY` in `.env`, run `make -C compose up`, and keep
    the old private key as long as bundles encrypted to it still matter.

### C5. `make backup-now` — take one and look at it

**What it is and why you care.** A backup on demand, kind `manual` — what you run before anything risky. The
nightly job does the same work with kind `daily`, at `BACKUP_SCHEDULE` (default `0 2 * * *`, read in the
container's `GENERIC_TIMEZONE`, not UTC — while the timestamp in the bundle's name is always UTC).

**Do this.**

- [ ] Take a labelled backup. The backup itself is about 5 s on a dev-sized database
      (`n8n-kit-HANDOFF.md`); the `make` wrapper adds a few seconds for the one-shot container it starts:

`bash
make -C compose backup-now NAME=before-drill
`

- [ ] Look at what landed. `make init` with a dev domain sets `BACKUP_REMOTES=/backups/local`, which is the
      directory `compose/backups` on the VM (`compose/docker-compose.yml`). Adjust the path below if
      your clone is not at `~/n8n-prod-kit`:

`bash
ls -l ~/n8n-prod-kit/compose/backups/manual/
`

In order, the script validates `BACKUP_REMOTES`, the retention numbers and the two age public keys (a mistake
there must alert, not silently stop every nightly backup); takes one shared lock so backups, restore tests and
restores never overlap; dumps the database into RAM-backed scratch space (a `tmpfs`, sized by
`BACKUP_TMPFS_SIZE`); counts rows inside the dump; writes `key-bundle.env` and `manifest.json`; tars all three
through `age` to both recipients; deletes the plaintext dump; copies the bundle to **every** target under
`<kind>/` (`compose/backup/backup.sh`).

**What you should see.** Lines from inside the backup container carry a UTC timestamp before `[ OK ]` or
`[info]`; host-side lines do not. Expect one line per target,
`[ OK ] /backups/local/manual/<name>.tar.age (<bytes> bytes)`, then `[ OK ] backup complete: ...`, and as the
last line `BACKUP OK <name> <bytes>` (`compose/backup/backup.sh`).

**What it proves.** The database dumps, both recipients are configured, and every target accepted the file.
Success is strict: one failed target means exit non-zero with `backup incomplete: N of M remote(s) failed`,
`backup_last_status 0` for every target, and a Telegram message when `ALERT_TELEGRAM_BOT_TOKEN` and
`ALERT_TELEGRAM_CHAT_ID` are both set.

**If it goes wrong.** `BACKUP_REMOTES is empty — nowhere to store the backup` means `.env` has no target.
`BACKUP_REMOTES entry '<x>' is not /backups/local, /backups/external[/dir] or an rclone remote
'name:bucket/path'` means a typo such as `r2/bucket`, which would write inside the container and vanish on
restart — that refusal is the point. A `/state` permission error is fixed by `make -C compose up`. A backup that
is `Killed` means raising `BACKUP_TMPFS_SIZE` and `MEM_LIMIT_BACKUP` together.

### C6. `make backups` — what exists, and what gets deleted when

**What it is and why you care.** The inventory: every bundle the kit recognises, on every target, newest first,
so you can name one in a restore.

**Do this.**

- [ ] List everything:

`bash
make -C compose backups
`

- [ ] Or list one target only, which is also how you work around a target you cannot reach:

`bash
make -C compose backups FROM=/backups/local
`

**What you should see.** One line per stored copy: the target, then `<directory>/<file name>`
(`compose/backup/restore.sh`). A `daily` bundle that was also copied to `monthly/` appears twice, under
both directories, with the same file name. With nothing there yet, `[warn] no backups found on:
/backups/local`. Files that do not match the kit's naming scheme are never listed, restored or pruned.

| Directory | What is in it | Pruned? |
|---|---|---|
| `daily/` | the cron job at `BACKUP_SCHEDULE` | yes — older than `BACKUP_RETENTION_DAILY_DAYS` (30) |
| `monthly/` | a copy of the first `daily` bundle of each UTC month; the file keeps its `-daily` name | yes — older than `BACKUP_RETENTION_MONTHLY_DAYS` (365) |
| `manual/` | `make backup-now` | never automatically |
| `pre-upgrade/` | `make upgrade` | never automatically |
| `pre-restore/` | `make restore`, before it overwrites anything | never automatically |

**What it proves.** That the copies you believe in exist, where you believe they are. Three details
(`compose/backup/backup.sh`): pruning runs only during a `daily` backup, never a manual one; it judges
age by the UTC timestamp in the name and never deletes the newest `BACKUP_RETENTION_MIN_KEEP` (default 7)
bundles of either directory, nor the bundle just written, so a clock that jumps forward cannot empty a target;
and a daily run makes sure the current UTC month has a bundle under `monthly/`, so a missed 1st heals itself
next night.

**If it goes wrong.** A target that cannot be listed gives `[FAIL] cannot list <remote>: ...` and exit 2. Fix
it, or work with one you can reach using `FROM=`.

### C7. `make restore-test` — "would the backup I have actually come back?"

**What it is and why you care.** That question, answered automatically at `RESTORE_TEST_SCHEDULE` (default
`0 3 * * 0`, Sunday 03:00 in `GENERIC_TIMEZONE`) and on demand here, without touching the live database. An
untested backup is a belief, not a backup; `make -C compose doctor` puts it the same way when the last one
failed: *"a backup that does not restore is not a backup"* (`compose/scripts/doctor.sh`).

**Do this.**

- [ ] Run it. Its default "latest" mode also enforces freshness, so if the stack has been off for a day or
      more, take a `make -C compose backup-now` first:

`bash
make -C compose restore-test
`

- [ ] Or test one named bundle instead of the newest, which skips the freshness check:

`bash
make -C compose restore-test BACKUP=n8n-<timestamp>-manual-before-drill
`

In "latest" mode it downloads, decrypts and sha256-verifies the newest bundle on **each** target — so a copy
that rotted on one target alone is found — and fails when any of them is older than `RESTORE_TEST_MAX_AGE_HOURS`
(26), which catches a nightly job that quietly stopped. The newest bundle overall then gets the full test: the
manifest must name the file, there must be at least two age recipients, and the bundle's `N8N_ENCRYPTION_KEY`
must equal the running one — all before any of its SQL runs. Only then does a throw-away Postgres start on the
RAM scratch, the dump load into it as an unprivileged role, the workflow count get compared with the manifest,
and one real credential get decrypted with `openssl` (`compose/backup/restore-test.sh`).

**What you should see.** `[ OK ] RESTORE TEST OK — <name>: N workflows, N credentials, credential decrypt ok,
<bytes> bytes, N remote(s) verified, Ns`, or on failure `[FAIL] RESTORE TEST FAILED: <reason> — <summary>`
(`compose/backup/restore-test.sh`). The same facts land in `/state/restore-test.json` as `tested_at`,
`backup`, `ok`, `note`, `workflow_count`, `credential_count`, `credential_decrypt`, `key_matches_running`,
`bundle_bytes`, `remotes_verified` and `duration_seconds` — take your own timing from the last of those, because
the repository records no measured figure for this command. No `make` target prints the file, so read it out of
the `backup_state` volume, which is named after your project (`COMPOSE_PROJECT_NAME` in `compose/.env`, default
`n8nkit`). The mount is read-only and the container runs as the uid that wrote the file:

`bash
docker run --rm -v n8nkit_backup_state:/state:ro n8nkit/backup:local cat /state/restore-test.json
`

`make -C compose doctor` summarises it as `restore test passed N day(s) ago`, or `no restore test has run yet —
make restore-test (weekly from cron)`.

**What it proves.** Every target's bytes are intact, the newest bundle is fresh, the dump loads into a Postgres
of the same version, the row count matches the manifest, and the bundle's key decrypts real credential data.

**What it does not prove.** It decrypts with the *host* key, so it never exercises your recovery key — it only
counts that a second recipient exists. It decrypts one credential, the oldest, and skips that step entirely when
the bundle holds none. It never starts n8n, so it says nothing about migrations or whether the app boots. It
covers nothing outside `db.dump`. And it does not exercise the live restore procedure — that is C8.

**If it goes wrong.** `the bundle's N8N_ENCRYPTION_KEY differs from the running one` means another instance's
bundle, or a changed key. `a credential could not be decrypted with the bundle's key` is the serious one:
investigate before trusting those backups.

### C8. The drill: delete a workflow on purpose, bring it back

**What it is and why you care.** The one exercise that proves the whole chain. Do it now, on this disposable
stack, so the first time you type `make restore` is not during an incident.

!!! danger
    `make restore` **replaces the live n8n database**. Workflows, credentials and executions created after the
    backup you restore are gone. On this dev VM that is the point. On a real instance you are rewinding to the
    moment the bundle was taken, and the kit's safety copy (below) is your only undo.

**Do this.** Allow 5-10 minutes.

- [ ] Note a workflow you can afford to lose, then take a fresh backup. Re-using the label from C5 is fine: the
      UTC timestamp in the name makes every bundle unique, and `latest` picks the newer one.

`bash
make -C compose backup-now NAME=before-drill
`

- [ ] In the n8n UI, delete that workflow. Confirm until it no longer appears in the list.
- [ ] Check the bundle is there and will be chosen as `latest`:

`bash
make -C compose backups
`

- [ ] Restore it, and answer the one prompt with `y`. No measured time for `make restore` on a 2 vCPU VM is
      recorded in the repository, so plan for a few minutes rather than seconds: the comparable CI step took
      about 1.5 minutes (`n8n-kit-HANDOFF.md`), and the script then waits up to 600 s for the stack to report
      healthy (`compose/scripts/restore.sh`).

`bash
make -C compose restore BACKUP=latest
`

- [ ] Reload the UI. The workflow is back. Open a credential and check it does not error — that is the
      encryption key having survived the round trip.

**What you should see,** in this order:

1. A `FETCHED <name>` block with the bundle's source, creation time, versions and counts, and a `key:` line
   reading `matches the running N8N_ENCRYPTION_KEY` (`compose/backup/restore.sh`).
2. `Replace the CURRENT n8n database (workflows, credentials, executions) with this backup? [y/N]`
   (`compose/scripts/restore.sh`; the `[y/N]` form is `compose/scripts/lib.sh`).
3. `[info] stopping n8n (N services)`, then `[info] safety backup of the current database (kind pre-restore)`.
4. `[info] restoring into the staging database n8n_restore (the live n8n is not touched until the swap)`, then
   `[ OK ] RESTORED <name>: N workflows, N credentials` (`compose/backup/restore.sh`).
5. `[info] emptying the job queue (Bull keys n8n:*)` — Bull is the queue library n8n runs on Valkey — then
   `[ OK ] restore complete (undo: make restore BACKUP=<pre-restore name> SKIP_SAFETY_BACKUP=1)`
   (`compose/scripts/restore.sh`), and finally the `make status` table: a row per service, STATE
   `running`, HEALTH `healthy`.

**What it proves,** through three mechanisms you just used.

*The safety backup.* Before anything is overwritten the kit stops every n8n process — so the copy catches the
last write — and takes a `pre-restore` backup. That is your undo, and the `restore complete` line prints the
exact command for it. `pre-restore` bundles are excluded from `latest` (`compose/backup/lib.sh`), so the next
`make restore BACKUP=latest` cannot accidentally undo your restore. `SKIP_SAFETY_BACKUP=1` skips the copy; on a
real stack that removes your undo.

*The key check, before the database is dropped.* If the bundle's key is not the running one, the run stops with
`the backup was made with a different N8N_ENCRYPTION_KEY: restored credentials would be unreadable`
(`compose/backup/restore.sh`) and `restore aborted before anything was changed (encryption key mismatch)`,
exit 3. Nothing was stopped, nothing was dropped. The check is load-bearing for a second reason: n8n connects
to Postgres as the bootstrap superuser, so a live restore runs with superuser rights (`n8n-kit-HANDOFF.md`),
and the matching key is what establishes that a bundle is yours before any of its SQL runs.

*The staging database.* The dump is loaded into a separate database `n8n_restore` and its workflow count checked
against the manifest; only then are the two renamed in one transaction, and the database you replaced is kept as
`n8n_prev` until the stack is healthy (`compose/backup/restore.sh`). Any failure up to the swap leaves
the live database untouched and the host script starts n8n again (`compose/scripts/restore.sh`).
The one exception is an exit code it does not recognise: then it deliberately leaves n8n stopped and names the
databases to inspect first.

Two steps are not optional. n8n caches the encryption key in a settings file in the `n8n_data` volume and refuses
to start when it disagrees with `.env`, so the restore deletes that file. And the job queue (the list of jobs
waiting for a worker) is emptied, because a job left from the timeline you just rewound names an execution id the
restored database will hand out again.

**If it goes wrong.** `could not list every remote` — fix the target or pick one with `FROM=/backups/local`. Exit
5, *"the backup … was made by n8n X, NEWER than the Y that would run on it"*, means the bundle is from a newer
n8n; move the pin first, as the message spells out. After an interrupted restore the decrypted dump is wiped on
every exit including Ctrl-C; `make -C compose restore-clean` empties that scratch volume by hand, and the live
database is untouched unless the swap had completed.

### C9. A new host: `ADOPT_KEY=1` and `AGE_KEY=file`

**What it is and why you care.** The disaster case: the VM is gone, and you have a bundle on an off-host target
plus the recovery key and old `N8N_ENCRYPTION_KEY` from your password manager. A new host's `make init` generates
*new* secrets, so the bundle's key is not the running key — exactly the mismatch C8 taught you.

| Switch | What it does |
|---|---|
| `AGE_KEY=/path/to/recovery.txt` | decrypt with the recovery private key instead of this host's |
| `ADOPT_KEY=1` | take the bundle's `N8N_ENCRYPTION_KEY` into `.env`, keeping the old file as `.env.bak.<timestamp>` |

**Do this.** Not by hand on your working dev stack — the drill destroys `.env` and the age keys. CI rehearses it
on every change (`tests/ci/dr-drill.sh`); the ordered procedure for a real rebuild is
[Rebuild on a new VPS](operations/rebuild-vps.md).

**What you should see.** With `ADOPT_KEY=1` the mismatch prints both key fingerprints, `bundle key:  abcd…wxyz
(64 chars)` and `running key: ...` (`compose/backup/restore.sh`), and then asks you to confirm that the
bundle's hint matches your password-manager entry (`compose/scripts/restore.sh`). That human comparison is
what ties the bundle to you, since age proves confidentiality and not origin.

**If it goes wrong.** Name the backup explicitly instead of using `latest`: once the new host has made a backup
of its own, `latest` would be that one, which the old recovery key cannot decrypt.

### C10. Where backups go: the three kinds of target

**What it is and why you care.** `BACKUP_REMOTES` is a space-separated list, and **every** entry receives
**every** backup. Three shapes are accepted, nothing else:

| Entry | Is | Buys you |
|---|---|---|
| `/backups/local` | the directory `compose/backups` on the VM | a fast undo; dies with the host |
| `/backups/external` | whatever `BACKUP_LOCAL_PATH` points at — external disk or NAS mount | survives the host's disks, not the room |
| `r2:BUCKET/PATH`, `s3:BUCKET/PATH` | an object store, reached with rclone (the copy tool in the backup image) | survives the building |

3-2-1 in two sentences: keep at least three copies, on at least two kinds of media, with at least one off-site.
One `BACKUP_REMOTES` line naming a local directory, an external disk and a bucket is that rule.

!!! warning
    As the kit stands, the off-host targets are **configured but untested** — there were no credentials to test
    them with (`n8n-kit-HANDOFF.md`). Local and external-disk targets are tested. Your first R2 run is real
    work, not a formality. And `BACKUP_LOCAL_PATH` is empty by default, which makes `/backups/external` the same
    directory as `/backups/local` rather than a second copy; `make -C compose preflight` warns about exactly
    that (`compose/scripts/preflight.sh`).

**Do this** for Cloudflare R2. Only three keys are yours to set in `compose/.env`
([Configuration](configuration.md)); type, provider, ACL and the `NO_CHECK_BUCKET` flag that bucket-scoped
tokens need are already in `compose/docker-compose.yml`. Quote the list, because it contains a space:

`ini
BACKUP_REMOTES="/backups/local r2:n8n-backups/dev"
RCLONE_CONFIG_R2_ACCESS_KEY_ID=...
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
RCLONE_CONFIG_R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
`

- [ ] Edit `compose/.env`, then `make -C compose up`. The scheduled job renders its crontab at container start,
      so the nightly backup only picks up a new target once the container has been recreated.
- [ ] `make -C compose backup-now NAME=r2-first`, and check for the `[ OK ]` line naming `r2:`.
- [ ] `make -C compose backups` — the bundle must appear under both targets.
- [ ] `make -C compose restore-test` — it verifies the newest bundle on *every* target, which proves the remote
      copy is readable rather than merely accepted.

**What it proves.** That the off-host copy is real. Give each stack its own path prefix: retention prunes every
kit bundle under `<target>/daily`.

**If it goes wrong.** An upload failure to `r2:` is almost always token scope or the endpoint URL; the error line
carries rclone's own last three lines (`compose/backup/backup.sh`).

### C11. What is not in a backup

**What it is and why you care.** The bundle carries the database and the key. It does **not** carry two Docker
volumes: `n8n_files` (`/home/node/.n8n-files`, the only tree the Read/Write Files node may touch) and `n8n_data`
(n8n's settings file, the event log, installed community packages) — `compose/docker-compose.yml`,
`n8n-kit-HANDOFF.md`.

**Do this.** Community packages recover by themselves — the kit sets `N8N_REINSTALL_MISSING_PACKAGES: "true"`
(`compose/docker-compose.yml`), so n8n reinstalls every package the database lists. Files do not, so check
whether anything is in that volume at all. The volume name is your project name plus `_n8n_files`
(`COMPOSE_PROJECT_NAME` in `compose/.env`, default `n8nkit`), the mount is read-only, and the listing works
because `make up` leaves that directory owned by n8n's uid at mode 0755:

`bash
docker run --rm -v n8nkit_n8n_files:/files:ro n8nkit/backup:local ls -la /files
`

**What you should see.** An empty listing is the comfortable answer: nothing outside Postgres is at risk. A
non-empty one is a decision you now make consciously — copy that volume separately, because putting it in the
bundle is a recorded future change, not something that works today.

**If it goes wrong.** `make -C compose up` builds the backup image when it does not exist yet
(`compose/Makefile:84`) and creates the volume on the first start. An empty listing of a volume you know holds
files usually means the project-name prefix is wrong.

### Part C recap — what you just proved

- [ ] `N8N_ENCRYPTION_KEY` is in your password manager, read back from there once.
- [ ] `make -C compose detach-recovery-key` is done and `make -C compose doctor` says *recovery key detached*.
- [ ] `make -C compose backup-now` ends in a `BACKUP OK` line.
- [ ] `make -C compose restore-test` ends in `RESTORE TEST OK`.
- [ ] You have deleted a workflow, restored it, and the restored credentials still work.
- [ ] You know which of your `BACKUP_REMOTES` targets you have actually tested.

---

## Part D — Changing a running system: upgrades, scale, and breaking it on purpose { #part-d }

Parts A to C got a stack up and proved it works. Part D changes it while it runs: a new n8n version, more workers, a
measured load, and three faults you cause yourself. Keep all of it on the disposable dev VM — two of these commands
can destroy data and one is designed to.

### D1. Image pins: digests, `versions.env`, and `make pin`

**What it is.** Every container starts from an image (a packaged, ready-to-run filesystem). `compose/versions.env`
names each image three ways: the repository, a human version tag, and a digest (a sha256 fingerprint of the exact
bytes). The compose file uses all three at once, as in `${N8N_IMAGE}:${N8N_VERSION}@${N8N_DIGEST:?run make pin}`.

**Why you care.** A tag can be re-pushed, so the same `2.42.4` can point at different bytes next month. A digest
cannot. The `:?run make pin` part is a guard: with a digest missing, `docker compose` refuses and says `run make pin`.

| Line in `versions.env` | What it does |
|---|---|
| `N8N_IMAGE` | where the n8n image comes from (the comment names a `ghcr.io` mirror with no Docker Hub quota) |
| `N8N_VERSION` | the n8n release — **also the tag of the runners image** |
| `N8N_DIGEST`, `RUNNERS_DIGEST` | the exact bytes of each image (own digests, one shared version) |
| `CADDY_*`, `POSTGRES_*`, `VALKEY_*`, monitoring | the same three lines per service |

The runners image is the sandbox that executes Code-node JavaScript, and it runs as a sidecar — a helper container
tied to one worker. A comment in `compose/docker-compose.yml` says "the runners image MUST match the n8n version
(docs); only the digest is its own", and `pin.sh` enforces that: the runners image has no version key of its own, so
the script resolves it against `N8N_VERSION`. One number moves both.

**Do this.**

- [ ] See what is pinned.

```bash
make -C compose version
```

- [ ] Check every digest is present and well formed. No network needed.

```bash
bash compose/scripts/pin.sh --check     # run this one from the repository root
```

**What you should see.** `make version` prints two lines, labelled `kit` and `n8n`. The check prints one line per
image; a bad one reads `is empty or malformed for` and tells you to run `make pin`. `make preflight` runs the same
check and reports `image digests pinned in versions.env`.

**What it proves.** The stack is reproducible: the same `make up` tomorrow starts the same software.

!!! warning

    `make pin` rewrites `compose/versions.env`, a file tracked in git, and needs the network. It is right on a fresh
    checkout or when you deliberately move a pin in a pull request. It is the **wrong** command for upgrading a
    running install — that is `make upgrade`, which backs up first. The Makefile says so on the target: "a running
    n8n: make upgrade".

**If it goes wrong.** Failures are almost always Docker Hub's anonymous pull quota (HTTP 429); `pin.sh` falls back to
two other APIs by itself. To move n8n only: `PIN_ONLY="N8N RUNNERS" make -C compose pin N8N_VERSION=<x>`.

### D2. The version guard: why `make up` refuses to upgrade for you

**What it is.** A check that runs before anything would start n8n — `make up`, `make restart` of an n8n service,
`make scale-workers`, `make restore`, `make chaos`. "What runs" comes from the n8n-main container's version label,
or, when the stack is down, the version n8n last recorded in the database. If the database cannot be read, it refuses
rather than guessing.

| What it finds | Why that is dangerous | Way out |
|---|---|---|
| an unfinished `make upgrade` | a half-migrated stack must not be restarted around | `make upgrade RESUME=1`, or `make rollback` |
| an unfinished `make rollback` | the same, and only the rollback knows where it stopped | `make rollback` again (`RESUME=1` is refused here) |
| `.env` sets `N8N_VERSION`, `N8N_DIGEST` or `RUNNERS_DIGEST` | Compose reads `.env` after `versions.env`, so the pin would never take effect | delete the line from `.env` |
| `versions.env` pins a **newer** n8n than runs | `make up` would migrate with no backup, in every process at once | `make upgrade` |
| `versions.env` pins an **older** n8n than runs | the old n8n starts on a newer schema and says nothing | `make rollback`, or pin forward |

Not every command runs every row. `make restart` of an n8n service checks only for an unfinished upgrade or rollback
(a restart never changes an image), and `make restore` checks that plus the `.env` keys — it is about to replace the
database anyway, and it version-checks the backup bundle itself.

**Why you care.** Before the guard existed, `make up` after a `git pull` recreated every n8n container on the new
image with no backup, and a `git checkout` of an older `versions.env` started an old n8n on a migrated schema without
a word — n8n applies only the migrations its own code knows about and ignores the rest
(`warning_bug_and_solutions.md`, the S7 entry).

**Do this.**

- [ ] Read the two sections `make doctor` prints for this.

```bash
make -C compose doctor
```

**What you should see.** Section headings `version lock` and `upgrade`, and on a healthy stack that has never been
upgraded, a line reading "n8n ... = runners ... = versions.env ... (digests match)" plus `no make upgrade on record`.

**What it proves.** The pin in the file and the images actually running cannot drift apart without something saying
so, in the one place a drift would otherwise be silent.

**If it goes wrong.** `FORCE_VERSION=1` skips the version comparison and nothing else — never a pending upgrade, never
the `.env` check. Use it only when you can say out loud why the two differ.

### D3. `make upgrade`: the guided procedure

**What it is.** One command that moves n8n and its runners sidecars to a new release in the order n8n's data needs,
with a backup in the middle. `make upgrade N8N_VERSION=x` picks a version; `make upgrade` alone applies whatever
`versions.env` pins now, which is what a `git pull` brought.

**Why you care.** The dangerous parts are database migrations (scripted schema changes) and processes racing to run
them. This script stops every n8n process, backs up, then starts **n8n-main alone** so exactly one process migrates.

The stages, in the order `compose/scripts/upgrade.sh` performs them:

| Stage | What happens | CI timing |
|---|---|---|
| 0. Checks | preflight (the host check: disk, ports, backup settings); Postgres and Valkey started if they are down; the running version read from n8n-main's image label and cross-checked against the database; the target vetted — a plain `x.y.z`, newer than what runs, same major unless `ALLOW_MAJOR=1`, a stable GitHub release unless `ALLOW_PRERELEASE=1`; only then its digests resolved into `.upgrade/target.env`, so a mistyped version stops here; then the plan, then a confirm | seconds |
| 1. Pull | fetch missing images, verify their version labels, rebuild the backup image — n8n still serves | network-bound |
| 2. Stop | let a scheduled backup in the sidecar finish, silence the Grafana alerts (monitoring profile only), stop the webhook processors and main, drain the workers (`UPGRADE_DRAIN_TIMEOUT`, 300 s), stop them, confirm no client still holds a session on n8n's database | 12 s |
| 3. Pre-upgrade backup | kind `pre-upgrade`, named `<from>-to-<to>`, to every `BACKUP_REMOTES` target; taken after the stop, so it holds the last write | 2 s |
| 4. Switch and migrate | rewrite only `N8N_VERSION`, `N8N_DIGEST`, `RUNNERS_DIGEST`; start n8n-main alone and watch it migrate (`UPGRADE_TIMEOUT`, 1800 s) | 11 migrations in 10 s |
| 5. Start the rest, verify | everything else up (`UPGRADE_START_TIMEOUT`, 600 s), every container's version and digest checked, then the smoke checks that are safe on a live host; the alert silence is lifted | 33 s |

Downtime is stages 2 to 5: **about one minute** with those numbers, which come from a CI run and are recorded in
[Upgrade and rollback](operations/upgrade-rollback.md). The command takes longer, because stages 0 and 1 run while n8n
still serves — CI's whole upgrade job, drill included, runs about 10 minutes. Budget 10 to 15 minutes of attention.

Stage 4 is the point of no return. Before it, any failure or Ctrl-C starts the old version again and nothing has
changed. After it you are either finishing the upgrade or rolling back.

Stage 3 is a real backup to every target in `BACKUP_REMOTES`, so the backup target from Part C has to work. If it does
not, the upgrade stops there and starts the old version again, with nothing changed.

**Do this.** Read this section, then walk D5 below: it performs a real upgrade and the rollback after it, so the
confirm prompt is not the first place you meet the plan.

**Where the state and logs live.** `compose/.upgrade/state.env` holds `PHASE` and both versions; each run also writes
`compose/.upgrade/<UTC timestamp>-upgrade.log`. Finished states move to `compose/.upgrade/history/`.

!!! note

    A closed SSH session does not stop an upgrade: the run ignores SIGHUP (the hang-up signal a closing terminal
    sends) and carries on, with its output in that log. Reconnect and read it, or run `make doctor`. `tmux` is still
    more comfortable.

**What it proves.** Moving n8n is one command with a backup in the middle and a printed way back, not a procedure you
have to remember under pressure.

**If it goes wrong.** From stage 4 on, a failure leaves `PHASE=failed` and prints both ways out —
`make upgrade RESUME=1   try the failed step again` and `make rollback           back to n8n <version>`. `RESUME=1`
continues the same target, starts Postgres and Valkey if they are down, and completes an interrupted version switch.
Until one finishes, `make up`, `make scale-workers`, `make restore`, `make chaos` and `make restart` of an n8n service
all refuse. A failed migration changes nothing in the database: n8n runs all pending migrations in one transaction, so
either all of them land or none does. Detail in [Upgrade and rollback](operations/upgrade-rollback.md).

### D4. `make rollback`: undoing the last upgrade

**What it is.** The matching undo. It reads n8n's migrations table, compares it with the mark taken before the
upgrade, and picks one of two modes.

| Mode | When | What it does | Data |
|---|---|---|---|
| `images` | no migration ran (usual for patch releases, and after a failed migration) | stop n8n, switch `versions.env` back, start the old version, verify | nothing lost |
| `restore` | a migration ran | fetch and verify the pre-upgrade backup **while n8n still serves**; then stop n8n, safety-backup the current database, restore, empty the job queue, switch back, start, verify | everything written after the backup is lost |

**Why you care.** Without it, a bad upgrade leaves you improvising. With it, the way back is one command that already
knows which backup belongs to this upgrade and what undoing it would cost.

**Do this.**

```bash
make -C compose rollback
```

The knobs: `YES=1` skips the confirmation question. `ROLLBACK_MODE=auto|images|restore` overrides the choice, and
`images` refuses when a migration ran. `FROM=<remote>` picks which backup target to fetch from — a target is a local
directory or an rclone remote, as listed in `BACKUP_REMOTES`. `ROLLBACK_CONFIRM=<backup name>` is **required**
whenever a restore would lose anything; `YES=1` is not enough on its own.

!!! danger

    In `restore` mode this replaces your n8n database with the pre-upgrade backup. Everything created after that
    backup — executions, workflow edits, credential changes — is gone. Before the confirm the script prints the
    counts it will discard, on a line beginning `LOST with the rollback:`. On this disposable dev stack that is fine
    and worth exercising once. On a real instance it is a data-loss event: read the counts, and prefer fixing
    forward when they are not zero.

**What it proves.** You have a tested way back, not a hope. **What it does not undo**, from the "Not covered" list in
[Upgrade and rollback](operations/upgrade-rollback.md): the `n8n_data` volume, third-party webhook registrations the
new version made, and Uptime Kuma's monitors, which are not paused — expect a DOWN/UP pair. Major versions need
`ALLOW_MAJOR=1` on the upgrade, and reading n8n's breaking-change list first.

**If it goes wrong.** Nothing is recorded and nothing is stopped until you answer the confirm. After that, a rollback
that stops — an error, Ctrl-C, a reboot — continues where it left off when you run `make rollback` again; it asks the
database itself whether the restore already happened. While nothing has been restored yet, `make rollback ABORT=1`
gives the rollback up and starts the new version again on its unchanged database.

### D5. Exercise: upgrade one patch release, then roll it back

Practise on this shape: 2.42.6 added no migrations over 2.42.4, so the rollback takes the `images` path and loses
nothing — the kit's hand-off notes record that exact pair being upgraded and rolled back on the build VM.
[Compatibility](compat.md) lists what the kit pins and where it was tested.

- [ ] Confirm the stack is healthy first.

```bash
make -C compose status
```

- [ ] Upgrade. Budget 10 to 15 minutes, of which about a minute is downtime.

```bash
make -C compose upgrade N8N_VERSION=2.42.6
```

Read the plan before answering the confirm. It ends with `If anything fails: make rollback returns to` your current
version.

- [ ] Re-run the end-to-end checks. On the 2 vCPU reference host the whole suite took about 40 seconds.

```bash
make -C compose smoke
```

- [ ] Roll back and watch it choose `images` mode (about 1.5 minutes in CI, plus the time the stack takes to start).

```bash
make -C compose rollback
```

- [ ] Confirm you are back where you started.

```bash
make -C compose doctor
```

**What you should see.** The rollback's plan line is "no migration ran, so only the images go back — no data is
lost", and it ends with `rolled back to n8n <version> (images)`. `make doctor` then reports `no make upgrade on
record` again, because a finished rollback files its state away in `compose/.upgrade/history/`.
`make upgrade N8N_VERSION=x` also edits `compose/versions.env`, which git tracks, so `git diff compose/versions.env`
should be empty again afterwards; if it is not, commit it or run `git checkout -- compose/versions.env` before your
next `git pull`.

### D6. `make scale-workers N=`: more hands on the queue

**What it is.** A worker is a container running `n8n worker`: it takes jobs off the queue (a list of jobs waiting for
a worker to pick them up) and executes the workflow. Workers come in pairs — `n8n-worker-N` plus a one-to-one
`n8n-worker-N-runners` sidecar — so the kit never uses `docker compose up --scale`. It writes `WORKER_REPLICAS` to
`.env`, rewrites `compose.scale.yml` (above two workers) or removes it (at two or fewer), converges the stack, then
verifies the result.

| Knob | Default | Range | How to change it |
|---|---|---|---|
| `WORKER_REPLICAS` | 2 | 1 to 16 | `make scale-workers N=4` |
| `WORKER_CONCURRENCY` | 10 | n8n recommends 5 or more | edit `compose/.env`, then `make up` |

Replicas are how many workers exist; concurrency is how many executions each runs at once. Four workers at
concurrency 10 is 40 executions in parallel.

**Why you care.** When executions pile up, raise concurrency first: it is cheaper, with no extra container and no
extra sidecar. Replicas buy isolation — one worker's memory limit cannot starve another, and a worker that dies takes
only *its* in-flight executions with it, measured at exactly one worker's concurrency, 10 of 120
([Scaling](operations/scaling.md), [Chaos drills](operations/chaos-drills.md)).

**Do this.** Scale up, then back down. Each step converges the whole stack and waits for every container to report
healthy, so expect a wait rather than an instant change — the reference run of `make up` on the kit's build VM needed
96 seconds to get the full stack healthy.

```bash
make -C compose scale-workers N=4
```

```bash
make -C compose scale-workers N=2
```

**What you should see.** `workers: 2 -> 4`, then `converging the stack`, then one `[ OK ]` line per worker and
sidecar, and finally
`scale-workers: 4 worker(s) + 4 runner sidecar(s) healthy (WORKER_REPLICAS=4 saved in .env)`.

**What it proves.** Capacity is one number in one file, verified rather than assumed: the script also checks that no
`n8n-worker-5` through `n8n-worker-16` is left behind.

**At `N=1`.** `n8n-worker-2` is a static service and cannot be omitted, so it is parked behind a Compose profile and
its two containers are removed explicitly. Do not run one worker if you care about lost work: the sweep that notices
a dead worker's orphaned jobs runs only *inside* another worker.

**If it goes wrong.** `N` outside 1 to 16 is refused with the usage line. A worker that does not come up healthy ends
the run with a count of problems and points at `make status / make logs SERVICE=<name>`. The version guard runs
before anything is changed, so a pending upgrade or a pin mismatch must be resolved before you scale.

### D7. `make loadtest`: measuring what this host can do

**What it is.** A measurement, not a test you pass. It publishes its own temporary workflow, fires `N` webhook POSTs
through Caddy with `P` in flight, samples the real queue depth from Valkey every second, waits for every execution to
reach a terminal state — finished one way or the other, success or error — then deletes the workflow (`KEEP=1` keeps
it). It refuses to start unless every service is healthy.

**Why you care.** "Can this host take my Monday-morning burst?" becomes a number you measured rather than guessed,
and re-running it with the same `N` and `P` after a change says whether the change helped.

**Do this.** The defaults are `N=200` requests with `P=20` in flight.

```bash
make -C compose loadtest
```

```bash
make -C compose loadtest N=1000 P=40
```

`MODE=async` (the default) answers each request as soon as the job is queued, so senders race ahead of the workers, a
backlog builds, then it drains — the only shape that measures capacity. `MODE=sync` holds each response until the
workflow finishes, measuring per-request latency, but it can never queue more than `P` jobs: with `P` at or below
`WORKER_REPLICAS × WORKER_CONCURRENCY` nothing ever waits and the peak depth is 0 by construction. The run says so
itself when it sees that.

**What you should see.** A report whose every label below is printed by `compose/scripts/loadtest.sh`.

| Report line | What it tells you |
|---|---|
| `sent`, plus the HTTP code histogram | intake health; `000` is a dropped connection |
| `send phase` with `req/s` | the intake rate: how fast the pool accepted work |
| `drain after send` / `end to end` | how long the workers needed, and the whole run |
| `executions` | success and error counts, this run only |
| `throughput … executions/min` | the headline number |
| `peak queue depth … waiting` | the backlog, from Valkey's `n8n:jobs:wait` list |
| per-worker job split | whether every worker took load |

**What "normal" looks like here.** On the 2 vCPU / 7.7 GB reference host, 2 workers at concurrency 10, async fixture
(a webhook feeding one Code node): a 200-job burst absorbed in 14 s, 40 req/s intake, peak backlog 161 waiting, about
850 executions/min ([Scaling](operations/scaling.md), [Compatibility](compat.md)). That is one run, on one host, with
one workflow shape. Your workflows will differ by an order of magnitude either way, because throughput mostly follows
how long one execution takes.

**What it proves.** The kit's published sizing numbers are reproducible on your host, and you now have a baseline of
your own to compare the next change against.

**If it goes wrong.** Non-200s at send with a queue that drains fine means the **intake** is the limit. A clean
histogram with a high peak and a long drain means the **workers** are — add concurrency first, then replicas. A slow
run on a small host is a measurement; only a queue that never drains is a failure, and that exits 2 with
`the queue did not drain within <N>s`, naming the three things to try.

!!! warning

    Every request becomes a stored execution, and n8n prunes executions globally, oldest first. When `N × 4` exceeds
    `EXECUTIONS_DATA_PRUNE_MAX_COUNT` (10000) the script stops and asks, because the run would push roughly `N` of
    the instance's existing executions out of the database. On a dev stack, say yes; elsewhere use a smaller `N`.
    The pruning settings are in [Configuration](configuration.md).

### D8. `make chaos`: three experiments

**What it is.** Three scripted failures, each with a hypothesis attached. A drill publishes its own
`kit-smoke-chaos-<run id>` workflow (the `main` drill adds a second one, ending in `-tick`, for a schedule trigger),
drives load through it, breaks one part of the stack, prints `[ OK ]` or `[FAIL]` per assertion, then cleans up.

!!! danger

    These drills kill and stop containers of the current Compose project on purpose. Never run them against a stack
    you did not create for testing. They never touch volumes, the database or `.env`, and the exit trap brings every
    service back with `compose up -d` — but on a production instance the `worker` drill causes **real lost
    executions**, and all three cause real downtime. Read [Chaos drills](operations/chaos-drills.md) first.

**Why you care.** Recovery behaviour you have never watched is a belief, not a property of your stack — and these
three drills are where the kit's own design notes were proved wrong twice.

Each drill takes 5 to 15 minutes, and `worker` needs at least 2 workers. Options: `N=` inputs to fire (120), `P=`
requests in flight (40), `OUTAGE=` seconds Valkey stays down (60), `YES=1` to skip the confirmation.

**Do this.** One at a time, reading the verdicts before you move on.

| Scenario | Hypothesis it tests | Command |
|---|---|---|
| `worker` | queued work survives a worker dying, and side effects are not duplicated | `make -C compose chaos SCENARIO=worker` |
| `redis` | webhooks fail loudly during a queue outage, and the queue survives on disk | `make -C compose chaos SCENARIO=redis` |
| `main` | restarting the editor and scheduler does not interrupt inbound webhooks | `make -C compose chaos SCENARIO=main` |

**What you should see.** The verdicts. Under `worker drill (TC-008)` the headline assertions are
`every input reached a terminal state (…) — nothing vanished` and
`never more side effects than inputs (…) — the idempotent key prevents duplicates`. *Idempotent* means doing the work
twice leaves the same result as doing it once — the drill's workflow writes one file named after the input, so a
replay overwrites instead of adding. Under `redis drill (TC-009)`:
`webhooks failed loudly while valkey was down (…/3 non-2xx) — no call was silently dropped` and a durability line
ending `— this is the AOF evidence`. AOF is Valkey's append-only file: it writes the queue to disk, so a restart does
not lose it. Under `main drill (TC-010)`:
`every webhook answered 200 across the restart (…) — the pool is independent of main` and
`the schedule trigger resumed on its own`. Measured: 40 of 40 webhooks at 200; Valkey stopped with 318 jobs waiting
and 303 were still in the wait list when it came back.

**What it proves.** The recovery behaviour the kit claims is behaviour you have watched — including the two places
where it is worse than you would guess.

**The two honest findings matter more than the green lines.**

First: **a killed worker's in-flight executions are lost.** They are not retried and not re-queued; they end as
`crashed`. n8n 2.x hard-codes `maxStalledCount: 0` in Bull, the job-queue library n8n runs on, so the first stall
takes Bull's fail branch and no environment variable reaches the re-enqueue path. Measured on 120 inputs: 110
succeeded, 10 crashed — exactly one worker's concurrency — settling 97 s after the kill, the lock duration (60 s) plus
the sweep interval (30 s). Queued work is safe; running work is not. `crashed` is also not proof that nothing
happened: in one run 112 inputs succeeded and 8 crashed, yet 114 files existed, because two of those crashed
executions had finished their write before the kill landed.

What the operator does about it, in order:

- Drain instead of killing. `docker stop` sends SIGTERM, the polite stop signal, which runs n8n's graceful shutdown;
  set `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above your slowest normal execution. `make upgrade` already drains this way.
- Run two or more workers, so something is alive to sweep the orphans.
- Give critical workflows an Error Workflow — the only automatic hook that still fires on this path.
- Make replays safe: key side effects on something from the input, so a re-run overwrites instead of duplicating.

Second: **`docker kill` does not exercise the restart policy at all.** Docker cancels a container's restart manager
when you stop or kill it yourself, so `restart: unless-stopped` deliberately stays out of it. Measured: the killed
worker stayed down for 14 minutes and came back only when `docker compose up -d` ran. The drill therefore does not
assert a self-restart; it reports
`did not come back on its own — expected: Docker treats an explicit kill as an operator stop`, brings the worker back
with `compose up -d`, and asserts that that worked.

**If it goes wrong.** A failed assertion keeps the evidence: the workflow is deactivated but not deleted, and its
files stay under `/home/node/.n8n-files/chaos-<run id>/`. The cleanup is deliberately not interruptible — it prints
`restoring the stack (this is not interruptible — it is what puts the stack back)` — so let it finish. If the stack
does not come back healthy it tells you to run `make up` and `make doctor`.

### D9. What I would do differently in production

Everything above assumes a host you can afford to break. In production the sequencing changes: the upgrade happens in
a scheduled window, after reading n8n's release notes; Uptime Kuma's monitors are paused by hand, because nothing
pauses them for you; an off-host backup target exists, so the pre-upgrade bundle is not only on the box you are
changing; `make chaos` is never run against production at all — it belongs on a clone, roughly quarterly; and
`make loadtest` is run before go-live, while nothing real depends on the host, then kept to a staging copy or a small
`N`, because every run evicts execution history. That sequencing is deliberately out of scope here and is kept in the
parked production plan, `n8n-kit-PROD-PLAN.md` in the repository root. See
[Backup and restore](operations/backup-restore.md) and [Monitoring](operations/monitoring.md) for the two things
production leans on hardest.

---

## Part E — Watching it: metrics, dashboards, alerts and the outside view { #part-e }

So far you have checked the stack by asking it. This part adds the machinery that watches while you are not looking:
numbers kept over time, container logs you can read in a browser, and messages sent to your phone when something
breaks. The session plan allows 45 minutes, nearly all of it waiting: for image downloads, for Grafana's first start,
for an alert to mature. It covers TC-017 and TC-018 on the sign-off sheet.

### E1. Turning monitoring on, and off again

**What it is.** A Compose profile is a label on a service that keeps it switched off until you ask for it. Seven
services carry one: `prometheus`, `grafana`, `loki`, `alloy`, `node-exporter` and `cadvisor` in the profile
`monitoring`, plus `uptime-kuma` in the profile `kuma`. Until you list the profile, those services are invisible to
`make up`, `make status` and `compose config --services`.

**Why you care.** They are not free. The seven memory ceilings in `.env` (`MEM_LIMIT_PROMETHEUS` and friends) add up
to about 2.9 GB as a ceiling, around 1 GB in practice. The hand-off's machine table records 2 vCPU as too thin for this
profile and says to raise the VM to 4 vCPU first. Grafana's first start also runs roughly 700 database migrations
before its port opens — about 40 seconds on a CI runner, about 10 minutes on the 4-vCPU build VM while it was
saturated.

**Do this.**

- [ ] Shut the VM down, raise it to 4 vCPU, boot it again.
- [ ] Edit `compose/.env`, set the profile line, save:

```ini
COMPOSE_PROFILES=monitoring
```

- [ ] Check the host first:

```bash
make -C compose preflight
```

- [ ] Start the enlarged stack. Six more images download — the core stack's pulls alone took about 4 minutes on this
      2-vCPU VM — and `make up` then waits up to 900 seconds for every container to report healthy, sized for
      Grafana's 300-second start window. Give it several minutes and do not interrupt it:

```bash
make -C compose up
```

!!! warning
    Set the profile **in `.env`**, not as a shell prefix. `COMPOSE_PROFILES=monitoring make up` does start the
    containers, because Compose reads that variable from the environment — but the kit's own scripts read it with a
    `.env` parser that never looks at the environment (`env_get` in `compose/scripts/lib.sh`). With the prefix form,
    `scripts/grafana-reload.sh` skips its reload, `scripts/kuma-setup.sh` skips claiming Kuma's admin account, and
    `make doctor` and smoke 09 report monitoring as off. Wherever you meet that prefix form, including the sign-off
    sheet at the end of this runbook, put the line in `.env` instead.

**What you should see.** `make up` ends with `scripts/status.sh`, a table with the columns SERVICE, STATE, HEALTH, UP
and RESTARTS: every row should read `running` and `healthy` (a service without a healthcheck shows `none`, which counts
as healthy), then `all <N> services running and healthy` and a `grafana:` line ending
`password GRAFANA_ADMIN_PASSWORD in .env`. Just before the table, `scripts/grafana-reload.sh` prints
`grafana: provisioning reloaded (data sources, alert rules + contact point, dashboards)`.

**What it proves.** Everything came up together, and Grafana re-read its rule and contact-point files. That matters:
Grafana loads alert rules only at start, and `make up` recreates Grafana only when its compose configuration changes,
so an update touching a rule file alone would otherwise keep the old rules running — that happened once, with 17 of 19
rules live.

**If it goes wrong.** A 502 at `https://n8n.localtest.me/grafana/` means Grafana is still starting, or the profile is
off: `make -C compose status`, then `make -C compose logs SERVICE=grafana SINCE=15m` (as in Part A, `make logs` follows
the log — Ctrl-C to stop). If the reload line reports a failure instead, Grafana rejected the credentials from `.env`.
The script's own hint, `make restart SERVICE=grafana`, helps when Grafana simply was not healthy yet. It does not help
when `GRAFANA_ADMIN_PASSWORD` was changed after Grafana first created its database: that password is applied once, at
first start, and changing it later needs `grafana cli admin reset-admin-password` inside the container — see
[Monitoring and alerts](operations/monitoring.md).

**Turning it off.** Run `make -C compose down` while the profile is still listed, then empty the line
(`COMPOSE_PROFILES=`) and `make -C compose up`. `down` keeps the volumes, so `n8nkit_prometheus_data`,
`n8nkit_grafana_data`, `n8nkit_loki_data` and `n8nkit_alloy_data` survive and your history returns when you switch the
profile on again.

!!! danger
    Reclaiming that space means `docker volume rm n8nkit_prometheus_data n8nkit_loki_data n8nkit_grafana_data
    n8nkit_alloy_data` on a **stopped** stack, plus `n8nkit_kuma_data` if you ran the kuma profile. On a disposable dev
    box that is fine: you lose metrics history, logs, Alloy's read positions and Grafana's own database, whose admin
    user is created again from `.env` at the next start. On a real stack it throws away the evidence you would need to
    explain an incident. Never reach for `make clean` here: that destroys the n8n database too.

### E2. What each piece does

**What it is, and why you care.** Six containers with one job each. When a dashboard is empty or an alert looks wrong,
the first question is which of the six to read the logs of.

| Piece | In plain words | Why you care |
|---|---|---|
| Prometheus | Asks every service for its counters every 15 s (cAdvisor every 30 s), stores them | "Was the queue full an hour ago?" gets an answer |
| Grafana | Draws the numbers, evaluates and sends the alerts | The one of these six you log into, at `/grafana/` |
| Loki | A database for log lines | Search logs in a browser, not over ssh |
| Alloy | Reads container logs from Docker, pushes them to Loki | Collects this project only; others stay out |
| node-exporter | Reports the host — CPU, memory, disks — and publishes the backup sidecar's metrics file | Says whether the VM is the problem, not n8n |
| cAdvisor | Reports each container: CPU, memory, restarts, health | Says *which* container is the problem |

Everything is scraped by service name over internal networks, and none of the six publishes a port. Grafana is the only
one of them a browser reaches, through Caddy, with its own login.

**Do this.**

- [ ] Read the Grafana URL and user from `make -C compose status`. The password is `GRAFANA_ADMIN_PASSWORD` in `.env`,
      generated by `make init`. Copy it from an editor into your password manager rather than printing it into a
      terminal, where it stays in your history. For bug reports use `make -C compose env-keys`: key names only.
- [ ] Log in and open **Connections -> Data sources**.
- [ ] Open **Explore**, pick Loki, run each of these, from [Monitoring and alerts](operations/monitoring.md):

```logql
{service="n8n-main"}
{service=~"n8n-.*", level="error"}
{service="caddy"} | json | status >= 500
```

**What you should see.** Two data sources, `Prometheus` and `Loki`, both not editable, because they are provisioned
from files. Lines for `n8n-main`; on a healthy stack the other two queries come back empty. Every line carries the
labels `service`, `container` and `project`; n8n and Caddy lines also carry `level`, because Alloy parses their JSON
logs and promotes that field to a label.

**What it proves.** The log path works end to end — Docker to Alloy to Loki to Grafana — and the dashboards and alert
rules will find their data sources under the fixed names they reference.

**If it goes wrong.** No lines at all: `make -C compose logs SERVICE=alloy SINCE=15m`. Two things keep Alloy quiet. It
reads the Docker socket, so a permission problem there stops it dead; and it collects only containers labelled with
this Compose project, which is why another stack on the same host never appears. An idle `n8n-main` also logs nothing
for long stretches, so widen the range to an hour before concluding anything.

### E3. The three dashboards

**What it is, and why you care.** Three dashboards in the Grafana folder **n8n-kit**, shipped as files
(`compose/monitoring/grafana/dashboards/*.json`) and provisioned with UI updates disabled, so edits made in the browser
are not saved. Each answers a different question, and knowing which to open saves you reading the wrong graphs.

| Dashboard | The question it answers |
|---|---|
| n8n Overview | Is n8n keeping up? Pools up or down, queue waiting and active, executions per minute, duration p50/p95, edge status codes, error lines |
| Host | Is the machine the bottleneck? CPU, memory, load per CPU, disks, I/O, CPU by Compose project, per-container memory against its own limit, restarts |
| Backups | Can I still restore? Hours since the last backup per target, last attempt, bundle size, restore-test status and age, TLS days left |

**Do this.**

- [ ] Open all three.
- [ ] For Backups, take a backup first so the panels have something to draw. Part C set
      `BACKUP_REMOTES=/backups/local`; if that key is still empty, this command stops with
      `BACKUP_REMOTES is empty — nowhere to store the backup`. See [Backup and restore](operations/backup-restore.md).

```bash
make -C compose backup-now
```

**What you should see.** Data in all three, with two honest exceptions: the execution-duration panels are legitimately
empty when nothing ran in the last few minutes, and the TLS panel reads
`not checked (TLS_MODE=internal, or no hourly check yet)`, which E6 explains.

**What it proves.** Prometheus is collecting all three families of numbers — n8n's own, the host's and each
container's — and the backup sidecar's metrics file is reaching node-exporter.

**If it goes wrong.** An empty container section on Host means cAdvisor cannot read Docker's directories or the
cgroups: `make -C compose logs SERVICE=cadvisor`.

### E4. Alerts, end to end

**What it is.** Nineteen rules in `compose/monitoring/grafana/provisioning/alerting/rules.yml`, evaluated by Grafana
every 30 seconds. There is no Alertmanager: Grafana decides and sends. Each rule has a severity, a threshold and a
`for:` duration the condition must hold before it fires — three use `for: 0s` and fire on the first evaluation that
sees the condition.

**Why you care.** On a dev box you are the only person watching, and you are not watching. The handful you will
actually meet: `N8nUIDown` (main unreachable, 2 m), `WebhookPoolDown` (no webhook processor up, 1 m), `WorkerPoolDown`
(nothing can execute, 2 m), `KitServiceUnhealthy` (Postgres, Valkey, Caddy, the backup sidecar or any n8n process
failing its Docker healthcheck, 5 m — this is how a dead Postgres or Valkey reaches you, since n8n keeps answering
`/metrics` without them), `DiskHigh` (a filesystem over 80 percent, 10 m) and `ContainerRestarting` (more than two
restarts in 15 minutes). Full table in [Monitoring and alerts](operations/monitoring.md).

**Getting a Telegram bot from scratch.** Telegram is the only delivery channel the kit ships.

- [ ] In Telegram, open a chat with **@BotFather**, send `/newbot`, answer its two questions, copy the token. It looks
      like `123456789:AAH...`. Put it in your password manager now.
- [ ] Create a group (or use a direct chat), add your bot, send any message there.
- [ ] Open `https://api.telegram.org/bot<token>/getUpdates` and copy `chat.id` from the JSON. Group and channel ids are
      negative, like `-1001234567890`.
- [ ] Put both into `compose/.env` and apply them with `make -C compose up`:

```ini
ALERT_TELEGRAM_BOT_TOKEN=123456789:AAH...
ALERT_TELEGRAM_CHAT_ID=-1001234567890
```

Both keys are used twice: `scripts/render.sh` writes Grafana's contact point into
`monitoring/grafana/provisioning/alerting/notifications.yml` (holding the reference `$ALERT_TELEGRAM_BOT_TOKEN`, never
the token itself), and the backup sidecar's `notify.sh` sends backup failures through the same bot. Alerts are grouped
per rule: the first message leaves 30 seconds after a group starts firing, a group that gains another alert waits
5 minutes, a still-firing group repeats every 4 hours, and one more message follows when it resolves.

!!! danger "Make an alert fire on purpose"
    This stops both webhook processors, so production webhooks return 502 while they are down. It destroys no data and
    is safe on a disposable dev stack. On a real stack it is a short, self-inflicted outage — announce it first.

- [ ] Stop the pool with the kit's own compose invocation, the one `make` runs for you: `--env-file versions.env`
      loads the image pins and `--env-file .env` then overrides them with your settings. The parentheses run it in
      a subshell, so your own shell stays in the repository root.
      Expect `WebhookPoolDown` within about 3 minutes — 15 s scrape, 30 s evaluation, 1 m `for:`, 30 s grouping:

```bash
(cd compose && docker compose --env-file versions.env --env-file .env \n   stop n8n-webhook-1 n8n-webhook-2)
```

- [ ] Bring them back and wait for the resolved message:

```bash
make -C compose up
```

**What you should see.** In Grafana, **Alerting -> Alert rules** shows `WebhookPoolDown` turning red. In Telegram, a
message beginning `🔴 FIRING` carrying the rule's summary, `No webhook processor is up - production webhooks fail`, and
after `make up` a second one beginning `✅ RESOLVED`. Both markers come from the template in `scripts/render.sh`.

**What it proves.** The whole chain: a real failure, a rule that notices, a message that reaches a human. This is
TC-018, and doing it by hand is the only way the kit ever proves delivery — the same drill in CI runs against a
deliberately invalid bot token, so it can check only that the alert fired and was routed to the Telegram contact point.

**Two recorded gotchas.** The contact point sets `parse_mode: None`, so messages go out as plain text. Grafana's
default is HTML, in which Telegram rejects any text containing `<...>` with `400 can't parse entities` — and rule
descriptions contain things like `make logs SERVICE=<name>`, so those alerts would silently never arrive. Leave it
alone. Second: a bot token is a password. If one lands in a chat log or a screenshot, send `/revoke` to @BotFather, put
the new token into `.env`, and run `make -C compose up`.

**If it goes wrong.** `make -C compose doctor` says which half is broken: with the keys unset it prints
`alerts are NOT sent anywhere (ALERT_TELEGRAM_BOT_TOKEN / ALERT_TELEGRAM_CHAT_ID empty)`; with them set,
`alerts are sent to Telegram`, and on a quiet stack `grafana: no alert firing`. If a rule fires but nothing arrives,
the token or the chat id is wrong: **Alerting -> Contact points -> Test** sends one immediately.

### E5. The outside view: Uptime Kuma

**What it is and why you care.** Everything above is the stack describing itself. If Caddy dies, or the VM's network
drops, the thing that would have told you is gone too. Uptime Kuma is a separate service that calls your public URLs on
a schedule and notifies you itself.

**Do this.**

- [ ] Set both switches in `compose/.env`. `make preflight` fails if they disagree, in either direction: the profile
      without the switch starts a Kuma that Caddy will not publish, and the switch without the profile makes Caddy
      publish `kuma.DOMAIN` with nothing behind it, which answers 502.

```ini
COMPOSE_PROFILES=monitoring,kuma
KUMA_ENABLED=on
```

- [ ] Make sure the machine with the browser resolves `kuma.n8n.localtest.me` to the host — the same hosts-file line as
      `n8n.localtest.me`. In `TLS_MODE=internal` preflight does not check that name for you; only the ACME modes do.
- [ ] `make -C compose up`, then log in at `https://kuma.n8n.localtest.me/` with `KUMA_ADMIN_USER` and
      `KUMA_ADMIN_PASSWORD` from `.env`, both generated by `make init`. `make status` prints that URL and the user.
- [ ] Add HTTP(s) monitors for `https://n8n.localtest.me/healthz`, `https://n8n.localtest.me/healthz/webhook` and
      `https://n8n.localtest.me/`, then add Kuma's own Telegram notification, under Settings, with the same bot.

**What you should see.** `make up` prints `uptime kuma: admin account created` the first time and
`uptime kuma: already set up` on later runs; `make doctor` confirms `uptime kuma: admin account exists`.

**What it proves.** `make up` claims the admin account for you, through Kuma's own setup event, because an unclaimed
first-run page is an open door: whoever reached `kuma.DOMAIN` first would create the only admin. During the build that
page sat open for an hour.

**If it goes wrong.** `make doctor` failing with `Uptime Kuma has no admin account yet` is repaired by
`make -C compose kuma-setup`. And mind the limit of what you just built: Kuma runs on this same host, so a dead VM
silences it too. A genuinely outside view also needs one free external uptime service.

### E6. The certificate check in the backup sidecar

**What it is and why you care.** A cron job inside the backup container, `backup/cert-check.sh`, runs hourly at minute
17: it opens a TLS connection to Caddy, reads the expiry of the certificate Caddy actually serves, and writes
`cert_expiry_timestamp_seconds` and `cert_check_success` into the metrics file node-exporter publishes. Those feed
`CertExpiring` (under 14 days left) and `CertCheckFailing` (three hourly checks failed in a row — the rule's `for:` is
2 h 30 m — so the first alert has gone blind). Caddy renews 30 days ahead, so fewer than 14 days left means renewal has
been failing for two weeks.

**Do this.**

- [ ] On this VM, expect nothing, and read the place that says so:

```bash
make -C compose doctor
```

**What you should see.** `make doctor` reports
`TLS_MODE=internal: certificates come from the kit's local CA (12 h leaf certs, renewed automatically)` and does not
check expiry at all. In that mode the script writes only the comment line
`# cert-check: TLS_MODE=internal (12 h certificates from the local CA) — not monitored` in place of the metric, and the
Backups dashboard says `not checked` instead of showing a red "No data".

**What it proves.** The kit distinguishes "nothing to watch" from "watching failed": a certificate reissued every
12 hours has nothing worth alerting on. This is the one monitoring feature you can exercise only in an ACME mode.

**If it goes wrong (ACME modes).** `make -C compose logs SERVICE=backup SINCE=3h` shows
`cert-check: could not read the certificate Caddy serves for ...` when the check fails.

### E7. Proving it with `make smoke ONLY=09`

**What it is and why you care.** One script, `tests/smoke/09-monitoring.sh`, checks the whole profile in a single run
(TC-017). It mostly works the way you do, through Caddy, and reaches inside the containers only where the outside
cannot see. Its longest single wait is 120 seconds, for every Prometheus scrape target to come up; others wait 30 to
90 seconds, so allow a few minutes.

**Do this.**

```bash
make -C compose smoke ONLY=09
```

**What you should see.** An `[ OK ]` line per check, and at the end `smoke: all selected scripts passed`. Among the
checks: `every Prometheus scrape target is up (<= 120 s)`, both data sources healthy through Caddy, the three
dashboards provisioned, `alert rules provisioned` with at least 19 and none evaluating in error, Loki holding n8n's and
Caddy's logs, and two security assertions: `a worker cannot reach Grafana, Loki, Alloy, the exporters or Kuma` and
`no n8n API key in Caddy's access log (Loki, last 5 min)`.

**What it proves.** Those last two are the point. Workers run whatever a workflow asks of them, including HTTP requests
to any address they can reach, so the probe runs *inside* a worker and must come back with nothing reachable. And
because Caddy's access log drops all request headers, the `X-N8n-Api-Key` the earlier smoke scripts just sent never
reaches the log store — an earlier version logged it in clear text and Loki kept it 14 days. Query strings are still
logged, so never put a secret in a webhook URL. More in [Security](security.md).

**If it goes wrong.** With the profile off the script prints `monitoring profile off (COMPOSE_PROFILES) — skipped` and
the run passes: that is a skip, not a pass. A failing target check prints the job, the instance and the last scrape
error.

### E8. Keeping a dev box tidy

**What it is and why you care.** Monitoring tells you the box is filling up, and is part of what fills it. `DiskHigh`
warns at 80 percent of a real filesystem — tmpfs, overlay, read-only mounts and `/boot` are excluded — which is the
right moment to act: Postgres and Valkey stop writing at 100 percent.

**Do this.**

- [ ] Look before deleting:

```bash
docker system df
docker builder du
```

- [ ] Reclaim the two safe pools. Both leave running projects untouched; on the shared build VM this pair took the root
      disk from 15 GB free to 32 GB:

```bash
docker builder prune -af
docker image prune -af
```

**What you should see.** `docker system df` reporting far less reclaimable space, and `make -C compose status` still
showing every service running and healthy.

**What it proves.** Disk can be recovered without touching the stack's data: these two commands remove build cache and
unused images, and no volume.

!!! danger
    `docker image prune -af` deletes every image no container currently uses, including the pinned n8n images of a
    stopped stack. `make up` pulls them again, which costs minutes, and a registry rate limit can make that fail at a
    bad moment. Do not run `docker system prune` on a shared host: it also removes stopped containers and networks
    belonging to other projects.

**If it goes wrong.** If `make up` then fails on an image pull, you have hit a registry limit. The Makefile already
retries three times, 20 and 40 seconds apart, before giving up — wait a few minutes and run it again.

Three groups of knobs trade disk against hindsight, all in `compose/.env`; see [Configuration](configuration.md).

| Knob | Default | What it trades |
|---|---|---|
| `PROM_RETENTION` / `PROM_RETENTION_SIZE` | `15d` / `2GB` | Whichever is hit first wins; lower, and older dashboard ranges go blank |
| `LOKI_RETENTION` | `336h` (14 days) | How far back you can search logs |
| `EXECUTIONS_DATA_PRUNE` | `true` | Off means the executions table grows forever, and backups with it |
| `EXECUTIONS_DATA_MAX_AGE` | `336` (hours) | How long you can still open a finished execution and see its data |
| `EXECUTIONS_DATA_PRUNE_MAX_COUNT` | `10000` | A hard cap, oldest first, for the hour a trigger misfires thousands of times |
| `EXECUTIONS_DATA_SAVE_ON_SUCCESS` | `all` | `none` saves disk and removes your ability to debug what worked |

- [ ] Confirm pruning runs. `make -C compose doctor` prints a line beginning `executions:` with the row count, the age
      of the oldest row and the settings in force, and warns instead when the oldest row is more than twice
      `EXECUTIONS_DATA_MAX_AGE` — n8n's hourly prune has stalled.

---

## Part F — Sign off, and what to do when a step fails { #part-f }

### The sign-off sheet

Fill this in as you go. The point is not bureaucracy: it is that in a month you will want to know which
of these you proved yourself and which you are still taking on trust.

| Part | Check | Passes when | Done |
|---|---|---|---|
| A | `make preflight` | no `[FAIL]` lines (TC-002) | |
| A | `make up` then `make status` | every service `running` and `healthy` (TC-003) | |
| A | `make doctor` | no `[FAIL]`; you have also seen it fail on purpose with `DOCTOR_SIMULATE` (TC-026) | |
| B | `make trust-ca`, then the browser | the editor loads over HTTPS without a certificate warning (TC-004) | |
| B | `curl -I https://n8n.localtest.me/healthz` and `/healthz/webhook` | `X-Kit-Upstream` names `n8n-main` for one and a webhook process for the other (TC-005) | |
| B | your own webhook workflow, called at its production URL | execution recorded as success, and it ran on a worker (TC-006) | |
| B | `make smoke` | every script PASS (09 skips while the monitoring profile is off) | |
| C | `make backup-now` then `make backups` | the bundle is listed on every target in `BACKUP_REMOTES` (TC-011) | |
| C | delete a workflow, then `make restore BACKUP=latest` | the workflow is back and its credential still works (TC-012) | |
| C | `make restore-test` | green, with a workflow count and a decrypted credential (TC-013) | |
| C | `make detach-recovery-key` | the recovery key is in your password manager, and `make doctor` says detached | |
| D | `make scale-workers N=4`, then `N=2` | four workers with four runner sidecars, all healthy, then back (TC-007) | |
| D | `make loadtest N=200` | the queue drains and every job reaches a terminal state | |
| D | `make chaos SCENARIO=worker` | the drill's own verdict, and you can explain what the killed worker cost (TC-008) | |
| D | `make chaos SCENARIO=redis` | webhooks returned errors rather than silent success, then the queue drained (TC-009) | |
| D | `make chaos SCENARIO=main` | webhooks kept answering through the restart (TC-010) | |
| D | `make upgrade` then `make rollback` | upgraded with a pre-upgrade backup taken first, then back where you started (TC-014, TC-015) | |
| E | `COMPOSE_PROFILES=monitoring` in `.env`, then `make up` | Prometheus targets up, three dashboards render (TC-017) | |
| E | the webhook-pool alert drill | `WebhookPoolDown` arrived, then resolved (TC-018) | |
| E | `make smoke ONLY=09` | PASS | |

### When a step fails

Work down this ladder. It is ordered by how often each rung turns out to hold the answer.

1. **`make status`** — which service is not healthy. Most failures are one container, not the stack.
2. **`make doctor`** — it is written to name the fix, not just the fault. Re-run it after every change.
3. **`make logs SERVICE=<that service> SINCE=30m`** — the last thing a container said before it gave up.
4. **[FAQ](faq.md)** — the gotchas that have already cost this project time, each with what to do.
5. **`warning_bug_and_solutions.md`** in the repository — the long version: every verified upstream
   quirk with the trace that proved it. If something surprising happens, look here before assuming it is
   your mistake.
6. **Open an issue.** Paste `make version`, `make doctor` and `make env-keys` — never `.env` itself, and
   never a secret's value. `make env-keys` prints key names only, which is exactly what a bug report
   needs.

A failure you can explain is worth more than a green run you cannot. If a step fails and the ladder
explains why, write the explanation in the sign-off sheet and carry on.

### What this runbook does not cover

Four things are deliberately absent, because they cannot be done honestly on a dev host:

- **A real certificate from a public authority.** Everything here uses the kit's internal CA. The real
  Let's Encrypt path needs a public hostname and a public host. It is the first phase of the production
  plan for that reason.
- **Off-host backups.** `BACKUP_REMOTES=/backups/local` is a local directory, which proves the mechanism
  but not the point of it. Pointing it at a real bucket is the highest-value hour available to this
  project, and it is listed as such in the production plan's improvement ledger.
- **A RHEL-family host.** The install path for Rocky, AlmaLinux, CentOS Stream, Oracle Linux and RHEL is
  tested in containers; SELinux enforcing and firewalld have never been exercised on real hardware. See
  [RHEL-family hosts](operations/rhel-hosts.md).
- **Workflow templates, Terraform and the Helm chart.** Planned milestones, not shipped code.

### Where to go next

- Keep the stack. Re-run `make smoke` and `make doctor` after every change you make to `.env`; they are
  the fastest way to find out you broke something.
- Read [Configuration](configuration.md) once, end to end, with your own `.env` open beside it. Every
  knob says what it does and why its default is what it is.
- When a production host is genuinely on the table, open `n8n-kit-PROD-PLAN.md`. It is parked on
  purpose: it starts with the decisions to make before spending money, and its improvement ledger is
  scored, so "what should I fix first" has an answer that does not depend on what you happen to
  remember.
