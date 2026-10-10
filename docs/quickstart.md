# Quickstart

This page takes a fresh Linux host to a working HTTPS n8n in queue mode: Caddy, n8n-main, two webhook
processors, two workers with a task-runner sidecar each, Postgres 18, Valkey and the backup sidecar —
**eleven containers**, every pulled image pinned to a digest. Fifteen minutes, most of it waiting for a
package install and an image pull.

Follow route **A** for a public host with a real domain and a Let's Encrypt certificate, route **B** for a
laptop or VM on `n8n.localtest.me` with Caddy's own CA. Only `make init` differs — route B then adds one step, `make trust-ca`.

## Before you type anything

`make preflight` checks the host size, the two ports being free and the DNS record, and exits 1 on any FAIL. It does not check the distribution (`scripts/bootstrap-host.sh` does, exiting 2), and it cannot tell whether 80 and 443 reach the host from the Internet.

| Requirement | Detail |
|---|---|
| Host size | 2 CPUs, 3500 MB RAM, 10 GB free on Docker's data directory. Below any of these, preflight FAILs. |
| Distribution | Ubuntu 24.04 / 26.04, Debian 12 / 13, or RHEL / Rocky / AlmaLinux / CentOS Stream / Oracle Linux 9 and 10. Ubuntu 24.04 LTS is the reference image. Anything else: install Docker Engine (>= 27) and the Compose plugin (>= 2.30) plus `make`, `jq`, `git` and `openssl` yourself, set `vm.overcommit_memory=1`, then start at step 2. |
| DNS (route A) | An `A` record for your domain pointing at this host. Preflight resolves the name over IPv4 and compares the answer with the address `api.ipify.org` reports; a mismatch is a FAIL, because Let's Encrypt would fail the same way and each attempt counts against its limits. |
| Ports | 80/tcp, 443/tcp and 443/udp (HTTP/3) must reach the host, and nothing else may listen on 80 or 443 — Caddy is the only container that publishes ports. On a cloud host, open all three in the security group too. |

Route B needs none of this: `localtest.me` and every name under it resolve to `127.0.0.1` from any machine.
If you cannot free 80 or 443, pass `HTTP_PORT=` and `HTTPS_PORT=` to `make init` instead — but ACME's HTTP-01
challenge needs port 80, so a publicly trusted certificate is then not available.

## 1. Prepare the host

```bash
curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash -s -- --yes
```

`--yes` is required in this piped form: there is no terminal to answer a prompt. From a clone,
`sudo bash scripts/bootstrap-host.sh` asks first.

It adds Docker's own package repository, installs `docker-ce docker-ce-cli containerd.io
docker-buildx-plugin docker-compose-plugin make jq git`, sets `vm.overcommit_memory=1` now and in
`/etc/sysctl.d/90-n8nkit.conf` (Valkey needs it), enables and starts `docker.service`, adds the invoking user
to the `docker` group, and — on Enterprise Linux hosts where firewalld is running — opens the `http` and
`https` services. Nothing else: SELinux stays enforcing, because the kit's bind mounts carry `:z`. A second
run changes nothing and takes about a second. It ends with two blocks worth reading, `Done on this host:` and
`Deliberately NOT done:`. Exit code 2 means an unsupported distribution, 3 conflicting packages (it names the
removal command), 4 a daemon that did not come up.

**Then log out and back in.** Group membership only applies to a new login session, and skipping this is the
most common first failure — `make preflight` reports `docker daemon not reachable` a minute later.
`newgrp docker` works in the current shell if you prefer.

## 2. Create the configuration

```bash
git clone https://github.com/nhhandevops/n8n-prod-kit && cd n8n-prod-kit/compose

# route A — public host
make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com

# route B — laptop or VM
make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443
```

`ACME_EMAIL` is mandatory on a public domain (Let's Encrypt registers the account with it and sends expiry
warnings) and is filled in as `dev@example.com` on a dev name. Any name no public CA can issue for —
`*.localtest.me`, `*.local`, `*.test`, `*.internal`, `*.home.arpa`, `localhost`, a bare IPv4 address — also
switches `TLS_MODE` to `internal` and `BACKUP_REMOTES` to `/backups/local`.

`make init` copies `.env.example` to `.env`, chmods it 600 *before* writing anything secret into it, fills in
the domain, ports, TLS mode and `PUBLIC_URL`, and generates seven secrets: `N8N_ENCRYPTION_KEY` (64
characters), `POSTGRES_PASSWORD`, `VALKEY_PASSWORD`, `N8N_RUNNERS_AUTH_TOKEN`, `GRAFANA_ADMIN_PASSWORD`,
`GRAFANA_SECRET_KEY` and `KUMA_ADMIN_PASSWORD`. It creates two `age` key pairs under `secrets/` for the
encrypted backups, self-checks (key length, secrets present, mode 600, digests pinned, `docker compose
config` parses) and prints a red banner.

**Do what the banner says now, not later.** Two of these cannot be recovered:

| Save | Where it is | What losing it costs |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | `compose/.env` — reveal it with `grep '^N8N_ENCRYPTION_KEY=' .env` | Every credential stored in Postgres becomes unreadable. A backup without this key restores a database you cannot use. |
| The recovery age key | `compose/secrets/age-recovery-key.txt` | Encrypted backups could then only be opened on this host — exactly the host a disaster takes away. |

Put both in a password manager, then run `make detach-recovery-key`: it prints the recovery key once, makes
you paste it back to prove the copy, and shreds it from the host. `make doctor` warns once it has sat here
for more than seven days.

If `age-keygen` is not installed — it is not part of the bootstrap — `init` builds the kit's backup image to
borrow its copy, which costs one Docker build.

## 3. Preflight

```bash
make preflight
```

One read-only line per check, as `[ OK ]` / `[warn]` / `[FAIL] <what> — <how to fix>`. Warnings never block;
any FAIL exits 1. It covers Docker ≥ 27 and Compose ≥ 2.30, `.env` mode and required keys, pinned digests,
the HTTP and HTTPS ports (naming the process and PID holding one), disk, RAM, CPUs, clock synchronisation,
`vm.overcommit_memory`, the backup configuration and DNS.

`make up` runs preflight itself, before the pull, so this step is optional — but on its own it takes seconds
and catches a wrong DNS record before you wait for an image pull.

## 4. Start the stack

```bash
make up
```

In order: preflight, the version guard, `render` (generated Compose fragments and Prometheus targets), a
`pull` of every pinned image, a local build of the backup image, backup volume permissions, the dev-CA export
on route B, `docker compose up -d --wait` with a 900-second timeout, the `n8n_files` ownership fix, a Caddy
configuration reload, Kuma and Grafana setup when those profiles are on, and the status table.

The pull and the first migrations are the slow parts, and both are one-offs. CI measured `init` + `up` +
`doctor` at 171 seconds end to end on a GitHub runner; on a heavily loaded VM a first start took 6.5 minutes,
of which 2m41s was the initial migrations (275 of them on the version measured). Hence the 600-second start
period on `n8n-main`'s health check and the 900-second wait. Meanwhile `make logs SERVICE=n8n-main` shows the
`Starting migration …` lines. Pulls are retried three times, 20 and 40 seconds apart, because public
registries throttle anonymous clients: a `toomanyrequests` error on the first attempt is normal, not fatal.

Caddy starts before n8n is ready and answers 502 until `/healthz/readiness` passes. That is deliberate — a
502 is honest, whereas a starting n8n answers *every* path with HTTP 200 and would accept a webhook it never
runs.

## 5. Confirm it worked

```bash
make status
```

A table of `SERVICE  STATE  HEALTH  UP  RESTARTS` for every service in the resolved configuration, then:

```text
[ OK ] all 11 services running and healthy
  n8n:  https://n8n.example.com/
```

It exits 1 if anything is not `running` and `healthy`, and names the service to inspect with
`make logs SERVICE=<name> SINCE=10m`. On route B it also reminds you that the certificate comes from the
kit's local CA.

## 6. Create the owner account

Open the URL `make status` printed. n8n shows its first-run setup page, and the account you create there is
the instance owner. The password needs at least eight characters with a digit and an uppercase letter. Setup
happens once only — a second attempt answers `400 Instance owner already setup`.

Do this **before** `make smoke`, which creates an owner itself when the instance has none
(`smoke-owner@example.com`, password in `compose/.smoke/owner.env`) and then the setup page is gone.

With an owner in place, the optional end-to-end proof is `make smoke`: health, the HTTP→HTTPS redirect,
certificate chain and security headers, owner/login/API key, a webhook answered by the pool rather than by
main, a real execution on a worker including a Code node, metrics, then a backup and a restore test. It is
idempotent and deletes the workflows it created. The suite runs its scripts in order and stops at the first
failure, so on a fresh route-A install it gets as far as `07-backup` and stops there: `BACKUP_REMOTES` is
still empty. Route B passes all of it, because `init` set `BACKUP_REMOTES=/backups/local` for the dev domain.

## Route B: trusting the dev CA

With `TLS_MODE=internal`, Caddy mints its own CA and issues 12-hour certificates from it. `make up` exports
only the root certificate to `compose/secrets/dev-root.crt` — never the CA's private key — and mounts it into
every n8n process as `NODE_EXTRA_CA_CERTS`, so n8n can call its own `PUBLIC_URL`. Browsers and `curl` still
have to be told:

```bash
make trust-ca
```

What it does depends on where you run it, so read its output rather than assuming. It always copies the
certificate to `~/n8nkit-root.crt`, and under WSL into the Windows `Downloads` folder as well. Beyond that:

- On the host itself it installs into the system trust store with `update-ca-certificates` (Debian, Ubuntu)
  or `update-ca-trust` (RHEL family). It escalates with `sudo -n`, which never prompts, so if your `sudo`
  wants a password it prints `not installed into the host trust store` and offers `curl --cacert <path>`
  instead. Delete the sentence.
- For a browser on **another** machine it prints the lines you need: an `scp` of the certificate and
  `certutil -addstore -f ROOT` for an administrator PowerShell on Windows, plus the `security
  add-trusted-cert` equivalent for macOS. The URL to open is printed between the Windows lines and the macOS one.

Because `localtest.me` resolves to `127.0.0.1` everywhere, the browser has to run on the host that runs the
stack. From elsewhere you need an SSH port forward or an entry in that machine's own hosts file — neither is
something the kit sets up for you.

## It is working — now what

Run `make doctor`. It is the diagnostic to paste into a bug report: version lock, every service's health with
the last 20 log lines of anything unhealthy, ports, DNS, certificate expiry, disk, Postgres, Valkey and
backups. On a fresh public install it reports one FAIL — `BACKUP_REMOTES is empty` — and it is right to.
Clearing that is the next job.

| Next | Where |
|---|---|
| An off-host backup target, and a restore you have actually tested | [Backup and restore](operations/backup-restore.md) |
| Prometheus, Grafana, Loki and alerting (`COMPOSE_PROFILES=monitoring`) | [Monitoring](operations/monitoring.md) |
| Moving to a new n8n release, and undoing it | [Upgrade and rollback](operations/upgrade-rollback.md) |
| What a killed worker, a Valkey outage or a main restart really cost | [Chaos drills](operations/chaos-drills.md) |
| SELinux, firewalld and the dnf install path | [RHEL-family hosts](operations/rhel-hosts.md) |

`make help` lists every target. `make scale-workers N=4` sets the worker count (1 to 16, each with its own
runner sidecar). `UI_PROTECT=on` with `UI_ALLOW_CIDR='203.0.113.0/24'` puts an IP allow-list and basic auth
in front of the editor and API while leaving webhooks, forms and MCP endpoints open; `.env.example` explains
every setting, including why that bcrypt hash must be single-quoted. For a bug report, `make env-keys` prints
the key *names* in `.env` — never the file itself.

## When a step fails

Every message below has been seen on a real host. Script output goes to stderr, so capture it with `2>&1` if
you want to keep it.

| Message | What it means and what to do |
|---|---|
| `docker daemon not reachable — is … in the docker group?` | No new login session since the bootstrap added you to `docker`. Log out and back in, or `newgrp docker`. |
| `port 443 is in use by <process> (pid N)` | Something else holds the port Caddy publishes. Stop it, or set `HTTP_PORT`/`HTTPS_PORT` in `.env` and run `make up` again — `make init` refuses to overwrite an existing `.env` (exit 2). |
| `DNS: … but this host's public IP is …` | The record points elsewhere, and every failed Let's Encrypt validation counts. Fix the record; while testing, `TLS_MODE=acme-staging` runs the same flow against the staging CA with no production rate limits (untrusted certificates on purpose). |
| `.env already exists — nothing changed` (exit 2) | `init` never overwrites secrets. Edit `.env` in place; `FORCE=1` regenerates every secret in `.env`, encryption key included, which makes existing credentials unreadable; the `age` keys in `secrets/` are kept, so old backups stay decryptable. |
| `versions.env has unpinned images — run: make pin` | A digest is missing; `make pin` writes them. On a running install, change n8n's version with `make upgrade`, never `make pin` plus `make up`. |
| `image pull failed — retrying in 20 s` | Anonymous registry rate limits; it retries three times. `versions.env` names mirrors serving the same digests. |
| `n8n-main` stays `starting` for minutes | The first start runs every migration. Watch `make logs SERVICE=n8n-main`; `up` allows 900 seconds. |
| HTTP 502 from the editor right after `make up` | Caddy is up, n8n is not ready yet. Wait for `make status` to report `healthy`. |
| `429` and a `Retry-After` header when logging in | n8n limits `/rest/login` to five attempts per window per client IP, and it is not configurable. Wait it out. |
| Caddy logs `Import file is empty` | `tls-acme.caddy` is empty on purpose: no `tls` directive means Caddy's default Let's Encrypt automation. A warning, not an error. |
| A script piped over SSH stops silently at `make up` | `make up` and `docker compose up` read stdin and swallow the rest of the script. Copy it to the host and run it as a file with `</dev/null`. |
| A Read/Write Files node fails with a permission error | The `n8n_files` volume predates the kit's chown of its mount point. Run `make up` again — `files-perms.sh` fixes it in place, no restart needed. |

If a failure is not in this list, `make doctor` and `make env-keys` are what a bug report needs. The kit's own
record of verified upstream gotchas, with sources, lives in `warning_bug_and_solutions.md`.
