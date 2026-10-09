# Upgrade and rollback

`make upgrade` moves n8n (and its task-runner sidecars, which must always run the same version) to a new release with a
backup first. `make rollback` undoes the last upgrade, whether it failed or finished. Both keep their state in
`compose/.upgrade/state.env` and log every run to `compose/.upgrade/<time>-upgrade.log` / `-rollback.log`, so an
interruption never leaves you guessing. A closed SSH session does not stop them (they ignore SIGHUP and carry on;
reconnect and read the log, or run `make doctor`) — running them inside `tmux` or `screen` is still the comfortable way.

## Upgrade

```bash
make upgrade N8N_VERSION=2.42.6      # a version you choose
make upgrade                         # the version versions.env pins now (after a `git pull` of the kit)
```

What happens, in order:

1. **Checks, nothing changed yet** — preflight (disk, ports, backup configuration), the version that really runs (the
   n8n-main container's image label, cross-checked with n8n's own version record in the database), the target:
   a plain release `x.y.z`, newer than what runs, a stable GitHub release (`ALLOW_PRERELEASE=1` for a beta), the same
   major version (`ALLOW_MAJOR=1` after reading n8n's breaking changes). The target's image digests are resolved into
   a copy (`.upgrade/target.env`), so a mistyped version stops here. Then the plan and a confirm (`YES=1` skips it).
2. **Pull** the images that are missing, check that the n8n and runners images really carry the target version, and
   rebuild the backup image — while n8n still serves.
3. **Stop** — a scheduled backup in the sidecar may finish first, then the sidecar stops (its cron must not run a
   `pg_dump` during the migration). The alerts are silenced in Grafana (monitoring profile; the silence expires on its
   own and is lifted at the end, also on failure). The webhook processors and n8n-main stop first, so nothing new
   arrives from outside. The workers keep running — they finish what runs and keep taking queued executions — for up to
   `UPGRADE_DRAIN_TIMEOUT` (300 s) until none is active; whatever still runs then gets n8n's own grace period
   (`N8N_GRACEFUL_SHUTDOWN_TIMEOUT`, 30 s) and shows as crashed. Queued jobs stay in Valkey for the new workers. No
   client may still hold a session on n8n's database (Postgres' own autovacuum workers do not count).
4. **Pre-upgrade backup** to every `BACKUP_REMOTES` target: kind `pre-upgrade`, label `<from>-to-<to>`, e.g.
   `n8n-20261009T101500Z-pre-upgrade-2.41.7-to-2.42.4`. Taken after the stop, so it holds every last write.
   **If it fails — or anything before this point fails, or you press Ctrl-C — the old version is started again,
   nothing has changed, and the previous upgrade's rollback point (if there was one) is back.**
5. **Switch** `versions.env` (only `N8N_VERSION`, `N8N_DIGEST`, `RUNNERS_DIGEST`) and start **n8n-main alone**: it runs
   the database migrations while webhooks and workers stay stopped. Progress (`Starting migration …`) is printed;
   `UPGRADE_TIMEOUT` (1800 s) bounds it. This is the point of no return: the previous upgrade's rollback point is gone.
6. **Start** everything else, then **verify**: every n8n container runs the target version and digest, and the smoke
   checks that are safe on a production host run on the core services (n8n, Caddy, Postgres, Valkey, backup) —
   health, TLS and routing, metrics, plus a real webhook → queue → worker → Code-node round trip when smoke credentials
   exist (`compose/.smoke/owner.env`, or `SMOKE_OWNER_EMAIL` + `SMOKE_OWNER_PASSWORD`). The monitoring checks run after
   that and only warn: a slow Grafana cannot fail an n8n upgrade. The silence is lifted.

Downtime is steps 3–6: about one minute on a small instance (CI: stop 12 s, backup 2 s, 11 migrations 10 s, rest of
the stack 33 s), more with a long drain, a big database or a busy host.

### When it fails

From step 5 on, a failure leaves `PHASE=failed` and prints both ways out:

| | |
|---|---|
| `make upgrade RESUME=1` | try the failed step again — after fixing what the log shows (disk space, a typo in `.env`, a timeout). It starts Postgres and Valkey if they are down and completes an interrupted version switch. |
| `make rollback` | go back to the old version (below) |

Until one of them finishes, `make up`, `make scale-workers`, `make restore` and `make restart` of an n8n service refuse
to run: they would start n8n in the middle of it. `make doctor` shows the state.

A migration that fails changes **nothing** in the database: n8n runs all pending migrations in one transaction. A
single statement is limited by `DB_POSTGRESDB_STATEMENT_TIMEOUT` (`.env`, milliseconds, default 300000 = 5 min) — on a
very large database raise it (e.g. `1800000`) and run `make upgrade RESUME=1`.

## Rollback

```bash
make rollback YES=1
```

It decides from the database whether a migration ran (n8n's `migrations` table, compared with its state before the
upgrade):

| | What it does | Data |
|---|---|---|
| **no migration ran** (patch releases usually have none; a failed migration rolled back) | stop n8n, switch `versions.env` back, start the old version, verify | nothing lost |
| **a migration ran** | fetch, decrypt and verify the pre-upgrade backup **while n8n still serves**, then stop n8n, restore it (a safety backup of the current database first — labelled with the version that wrote it —, staging database, atomic swap), empty the job queue, switch back, start the old version, verify, drop the replaced database | everything written after the backup is lost |

The bundle is fetched from the local target the upgrade recorded; when it is not there, every `BACKUP_REMOTES` target
is searched; `FROM=<remote>` picks one. Before a restore the confirm shows how many executions, workflow changes and
credential changes would be lost, and the workflow/credential counts now and in the backup. Whenever that is not
nothing, `YES=1` is not enough: `make rollback ROLLBACK_CONFIRM=<backup name>`. `ROLLBACK_MODE=images|restore` overrides
the choice (`images` refuses when a migration ran: the old n8n would run on the newer schema, which n8n does not detect).

Nothing is recorded and nothing is stopped until that confirm. From then on (`PHASE=rolling-back`) a rollback that stops
— an error, Ctrl-C, a reboot — continues where it stopped when you run `make rollback` again; whether the restore
already swapped the database is read from the database itself. From the restore to the version switch Ctrl-C is
ignored. While nothing has been restored yet, `make rollback ABORT=1` gives the rollback up and starts the new version
again on its unchanged database. Only n8n's three version keys go back — pins of other images that a `git pull` moved
meanwhile stay (Grafana and Postgres cannot return to an older version of their data).

The rollback point lasts until the next `make upgrade` passes its version switch (an attempt that stops before that
gives it back). Old states are kept in `compose/.upgrade/history/`, run logs in `compose/.upgrade/`. Keep the last
pre-upgrade bundle while you may still want `make rollback`; pre-upgrade and pre-restore bundles are never deleted by
retention — remove old ones by hand.

## The version guard

`make up` (also `scale-workers`, and `restore` for the pending check) compares `versions.env` with what runs —
n8n-main's image label, or, when the stack is down, the version n8n last recorded in its database — and refuses when
they differ. When it cannot read the database it refuses too (it never guesses):

| Situation | Message points to |
|---|---|
| a `git pull` brought a newer pin | `make upgrade` (backup + migrations in order) |
| `versions.env` is older than what ran (a `git checkout`, an old copy) | `make rollback`, or pin forward: `PIN_ONLY='N8N RUNNERS' make pin N8N_VERSION=<running>` |
| an upgrade is unfinished | `make upgrade RESUME=1` / `make rollback` |
| a rollback is unfinished | `make rollback` (or `make rollback ABORT=1`) |
| `.env` sets `N8N_VERSION`, `N8N_DIGEST` or `RUNNERS_DIGEST` | remove it — `versions.env` holds the n8n pins |

`FORCE_VERSION=1` overrides the comparison (not a pending upgrade) — only when you know why they differ. `make restart`
only refuses for an n8n service during an unfinished upgrade (a restart never changes an image). `make clean` discards
the upgrade state together with the volumes it described. `make restore` refuses a bundle made by a **newer** n8n than
the version that would run on it (exit 5) and says which bundle to restore after moving to that version. Every backup
records the n8n version from the database it dumps (n8n's own record), not from `versions.env`.

## versions.env is a tracked file

`make upgrade N8N_VERSION=x` changes `compose/versions.env` in your checkout. Commit it to your fork, or run
`git checkout -- compose/versions.env` before the next `git pull`; afterwards `make up` tells you whether the pulled
pin is newer (→ `make upgrade`) or older than what runs (→ pin forward). Without `N8N_VERSION`, `make upgrade` applies
the pin exactly as it came through git (its digests are checked, not re-resolved). Only a `N8N_VERSION` given on the
make command line counts — a stale shell export of it is ignored.

## Tested

- CI (`upgrade` job, every push): the stack starts on the previous minor (`UPGRADE_FROM`, 2.41.7 → 2.42.4: 11
  migrations), then `tests/ci/upgrade-drill.sh` — `make up` refuses the new pin; `make upgrade SMOKE_FAIL=1` upgrades
  and fails verification on purpose; `make rollback` refuses without `ROLLBACK_CONFIRM`, then restores the pre-upgrade
  backup (a workflow written under the new version is gone, every older one is back); `make upgrade
  N8N_VERSION=<pin>` succeeds; a second upgrade has nothing to do and a failed attempt keeps the rollback point; an
  image-only rollback over migrations is refused.
- The weekly job upgrades from the kit's pin to n8n's newest stable release (majors included) with data in it.
- On the build VM (busy host, load 10–40): the same drill, plus an upgrade interrupted during the stop (the old
  version came back by itself), a failed n8n-main start resumed with `RESUME=1`, and an images-only rollback of a patch
  upgrade (no restore, no data lost).
- `SMOKE_FAIL=1` makes the verification fail after everything really passed — for drills of your own.

## Not covered

- The `n8n_data` volume (event logs, installed community packages) is not rolled back; n8n reinstalls missing packages
  (`N8N_REINSTALL_MISSING_PACKAGES=true`), and nothing in it is known to break an older version.
- Third-party webhooks that the new version registered (Telegram, Stripe…) stay registered after a rollback; the old
  version re-registers its own when it activates the workflows.
- Uptime Kuma is not paused automatically — pause its monitors for the window, or expect a DOWN/UP pair.
- Major versions (3.x): `ALLOW_MAJOR=1` lets you through, but read n8n's breaking-change list and test on a copy first.
