# FAQ

Almost everything on this page is a problem that actually happened on a real host while the kit was
built, with the fix that went into the code or the `.env` file. Each answer says what to do.

When something is wrong and you do not know what, start with `make doctor`. It is read-only, every
failure it prints comes with its fix, and its output is what a bug report needs. `make env-keys` prints
the key *names* in `.env` for the same purpose — never paste the values.

## Before you install

**Do I need a public domain?**

For a real instance, yes: `TLS_MODE=acme` means Let's Encrypt, and `DOMAIN` must resolve to the host on
ports 80 and 443 (`make preflight` compares the DNS answer with the host's public IP). For local work,
give `make init` a dev name — `*.localtest.me`, `*.local`, `*.test`, `*.internal`, `*.home.arpa`,
`localhost` or an IPv4 address — and it switches to `TLS_MODE=internal`, Caddy's own CA. Then
`make trust-ca` installs or prints that CA for your browser. `TLS_MODE=acme-staging` is the third
option: untrusted certificates, no rate limits, for rehearsing DNS and firewall changes.

**Ports 80 and 443 are taken by something else. Can I still run it?**

Yes. Set `HTTP_PORT` and `HTTPS_PORT` at init time, for example
`make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443`. Caddy listens on the same numbers
*inside* the container on purpose, so the HTTP-to-HTTPS redirect and the `Alt-Svc` header carry a port a
browser can reach, and `init` appends a non-443 port to `PUBLIC_URL` so webhook URLs stay correct. If
you get the ports wrong, `preflight` names the process holding them.

**How much host does it need?**

`make preflight` requires at least 2 CPUs, 3.5 GB RAM and 10 GB free on the Docker root, plus Docker
Engine 27 or newer and Compose 2.30 or newer. The default `MEM_LIMIT_*` values add up to about 6.6 GB
of *limits* with two workers — a cap on runaway executions, not a reservation — and are sized for a
4 GB host. The `monitoring` profile adds roughly 1 GB in practice. Valkey also wants
`vm.overcommit_memory=1`, which `bootstrap-host.sh` sets persistently.

**Why Postgres, and not SQLite?**

Queue mode means five n8n processes plus a backup sidecar reading and writing the same workflows,
credentials and executions, so `DB_TYPE` is fixed to `postgresdb` in `docker-compose.yml` rather than
exposed as a knob. The rest leans on that: binary data is stored in the database
(`N8N_DEFAULT_BINARY_DATA_MODE=database`, since filesystem mode is unsupported in queue mode), backups
are `pg_dump -Fc`, and a restore stages into a second database and swaps it in atomically. n8n 2.x
supports Postgres 16, 17 and 18; 16 logs "compatibility support only", so the kit ships 18.

**Does this work on Kubernetes?**

Not yet. A Helm chart is milestone M2.5 and Terraform for AWS is M2; both have placeholder READMEs in
`k8s/` and `terraform/` describing the planned shape. Today the kit is Docker Compose on one host.

**Can I run two instances on one host?**

Yes — a second checkout needs a different `COMPOSE_PROJECT_NAME` (the prefix of every container, network
and volume name) and different `HTTP_PORT` / `HTTPS_PORT` in its own `.env`; there is deliberately no
project name in `docker-compose.yml` so that a second copy only needs a different `.env`. Give each
stack its own backup prefix too: retention prunes every kit bundle under `<target>/daily`.

## Keys, logins and access

**What happens if I lose `N8N_ENCRYPTION_KEY`?**

Every stored credential becomes unreadable: the key encrypts every credential stored in Postgres, so each one has to be re-entered by hand. Store it in
a password manager the moment `make init` prints it. The key is also written into every backup bundle
(`key-bundle.env`), which is why the recovery key matters: with the offline recovery key you can decrypt
a bundle on a new host and adopt its encryption key with
`make restore BACKUP=<name> AGE_KEY=<file> ADOPT_KEY=1`. Both halves live in your password manager, not
on the host — `make detach-recovery-key` moves the recovery key there and shreds the local copy.

**n8n refuses my login with HTTP 429.**

n8n rate-limits `/rest/login` to five attempts per window per client IP and this is not configurable by
environment variable. The response's `Retry-After` header says how many seconds to wait. The limit is
per client IP and the kit trusts Caddy's `X-Forwarded-*` (`N8N_PROXY_HOPS=1`), so it is your address
being counted, not the proxy's. The smoke suite works around it by reusing a session cookie and making
exactly two login attempts per run.

**I turned on `UI_PROTECT` and the basic-auth password never matches.**

The bcrypt hash from `caddy hash-password` contains `$` segments, and Compose interpolates them away in
an unquoted or double-quoted value — silently. Write it single-quoted in `.env`
(`UI_BASIC_AUTH_HASH='$2a$14$...'`) or double every `$`. Generate it from `compose/` with:

```bash
docker compose --env-file versions.env --env-file .env run --rm caddy caddy hash-password --plaintext 'your-password'
```

**Does `UI_PROTECT` break my webhooks?**

No. The IP allow-list and basic auth are imported only in front of the editor, the API and `/grafana/`.
Production webhooks, forms, MCP endpoints and the health paths are never behind them, so integrations
keep working. Two things to know: with `UI_ALLOW_CIDR` set, a foreign address gets 403 *before* the auth
prompt; and clients on the host itself arrive through Docker's NAT as the bridge gateway (`172.x.x.1`),
not as their own address.

## Workflows and nodes

**The Read/Write Files node cannot write anything.**

This was broken on every fresh install until 2026-10-10. `/home/node/.n8n-files` does not exist in the
n8n image, so Docker created the volume's mount point as `root:root` while n8n runs as uid 1000, and
every write failed with `EACCES`. Run `make up` again: it now runs `scripts/files-perms.sh` after
`compose up`, which chowns that directory to 1000 once, with no restart needed. Check it with:

```bash
docker compose --env-file versions.env --env-file .env exec -T n8n-worker-1 sh -c 'ls -ld /home/node/.n8n-files'
```

That tree is the node's whole world (`N8N_RESTRICT_FILE_ACCESS_TO`), and
`N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true` keeps nodes out of `/home/node/.n8n`. Note that the
`n8n_files` volume is **not** in the backups — back it up separately if workflows keep files there.

**A Code node fails with "fetch is not defined" or "process is not defined".**

Both are the sandbox working as intended. Code-node tasks run in the runner sidecar, which has no
network of its own and no environment access (`N8N_BLOCK_ENV_ACCESS_IN_NODE=true`). For HTTP calls use
`this.helpers.httpRequest(...)`, which the worker executes, or an HTTP Request node. For configuration,
pass values in through the workflow rather than reading `process.env`.

**How do I enable Python Code nodes?**

Set `RUNNERS_LANGS="javascript python"` in `.env` — quoted, two words. It is the sidecar's command line;
there is no `N8N_NATIVE_PYTHON_RUNNER` variable in 2.x. Budget about 75 MiB more per concurrent Python
task and raise `MEM_LIMIT_RUNNERS` accordingly.

**Where are the Execute Command and Local File Trigger nodes?**

Disabled on purpose through `NODES_EXCLUDE`, which repeats n8n's own default list. Any value you set
*replaces* that list, so keep both entries when you add your own exclusions.

**Can I install community nodes?**

Yes, but packages n8n has not verified are off by default
(`N8N_UNVERIFIED_PACKAGES_ENABLED=false`, which is n8n 3.0's default). Installed packages live in the
`n8n_data` volume, which backups do not carry — the kit sets `N8N_REINSTALL_MISSING_PACKAGES=true` so
that after a restore onto a new host n8n reinstalls everything the restored database lists.

## When something breaks

**I killed a worker and lost executions. Shouldn't they be retried?**

No, and this is the most important thing on this page. When a worker dies without a graceful shutdown,
the executions it had *in flight* are lost: they end as `crashed` and are never re-queued. n8n builds
its Bull queue with `maxStalledCount: 0` and n8n 2.0 removed the stalled-job retry deliberately, so no
environment variable brings it back. Work that was still *queued* is safe — another worker takes it.
Measured on the kit's own stack with 120 inputs: 110 succeeded, 10 crashed, 0 errored.

What to do: stop workers with `docker stop` (or `make upgrade`, which drains) and set
`N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above your p99 execution time; run at least two workers, because the
stalled sweep only runs inside a surviving worker; give critical workflows an Error Workflow, the only
automatic hook that still fires; and keep workflows replay-safe. A `crashed` execution may *already*
have done its side effect — in one drill 112 successes and 8 crashes had produced 114 files — so treat
"crashed" as "n8n does not know whether it completed". [Chaos drills](operations/chaos-drills.md) has
the full account.

**`docker kill` did not restart the container, although `restart: unless-stopped` is set.**

Expected. `docker kill` and `docker stop` both cancel the container's restart manager and mark it
manually stopped, so no restart policy applies — the same goes for `docker compose kill|stop|down` and
`docker rm -f`. Bring it back with `docker compose up -d`. To exercise the restart policy for real, kill
the container's main process from the host:

```bash
sudo kill -9 "$(docker inspect -f '{{.State.Pid}}' n8nkit-n8n-worker-1-1)"
```

`docker exec <container> kill -9 1` does nothing: the kernel discards a SIGKILL sent to a PID-namespace
init from inside that namespace.

**What happens if the queue goes away?**

Webhooks fail loudly while Valkey is unreachable — 502 or 503, never a silent 2xx — and jobs queued
before the outage run afterwards, because Valkey keeps an append-only file (`--appendonly yes
--appendfsync everysec`). In one drill Valkey was stopped with 321 jobs waiting and 337 jobs
completed after it came back; nothing was lost. Every service reconnects by itself; a worker's readiness probe requires
a live Redis connection, so "healthy again" is the reconnect signal.

**The Postgres log shows `invalid input syntax for type integer: NaN`.**

Harmless, and upstream. It comes from an n8n-internal paginated executions query around
webhook-triggered executions; n8n handles the error, the executions succeed and nothing is logged on the
n8n side. No public API call triggers it. Smoke test 04 counts new occurrences and warns rather than
failing.

## Day-to-day operations

**Image pulls fail with `toomanyrequests` or HTTP 429.**

Registries throttle anonymous clients: Docker Hub allows 100 pulls per hour per IP, and the AWS public
registry rejects bursts. `make up` and `make pull` already retry three times, 20 s and 40 s apart. If it
keeps failing, `docker login`, or point the image variables in `.env` at a mirror that serves the same
manifests — `N8N_IMAGE=ghcr.io/n8n-io/n8n`, `RUNNERS_IMAGE=ghcr.io/n8n-io/runners`,
`GRAFANA_IMAGE=mirror.gcr.io/grafana/grafana`; the alternatives are comments in `compose/versions.env`.
The digests stay authoritative, so a mirror that ever diverged would fail the pull rather than run a
different image.

**After a `git pull`, `make up` refuses to start.**

That is the version guard. A `git pull` can move the n8n pin in `versions.env`, and starting the new
image through `make up` would migrate the database with no backup and with every process type migrating
at once. Starting an *older* n8n on a newer schema is worse and silent. Run `make upgrade` with no
version to apply the pin the pull brought, or `make upgrade N8N_VERSION=2.42.6` to choose one; it takes a
pre-upgrade backup and lets n8n-main migrate alone. See
[Upgrade and rollback](operations/upgrade-rollback.md).

**`make up` timed out or `n8n-main` is unhealthy for minutes on a first install.**

A first start runs every migration — 275 of them for 2.41.7 — which took 6.5 minutes on a loaded build
VM and 51 seconds on an idle one. That is why `n8n-main` has a 600 s start period (300 s for webhooks
and workers) with a 5 s start interval, and why `make up` waits up to 900 s. Watch it with
`make logs SERVICE=n8n-main`; the health table comes from `make status`.

**n8n-main logs `Mismatching encryption keys` and will not start.**

n8n caches its encryption key in `/home/node/.n8n/config` in the `n8n_data` volume and refuses a
different `N8N_ENCRYPTION_KEY`. If you changed the key by hand, delete that file so n8n re-creates it
from `.env`. `make restore` does this itself after every successful swap.

**Which n8n versions can I run?**

n8n 2.x stable releases. n8n and its task-runner sidecar must share a version, and
`make pin N8N_VERSION=x` moves both. n8n 3.0 removes settings the kit already avoids and will get its
own row in [Compatibility](compat.md) after a weekly run against it; that weekly run pins the newest
stable release and runs the smoke suite, so a breaking change opens an issue before anyone upgrades.
