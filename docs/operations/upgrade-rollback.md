# Upgrade and rollback

`make upgrade` moves n8n (and its task-runner sidecars, which must always run the same version) to a new release with a
backup first. `make rollback` undoes the last upgrade, whether it failed or finished. Both keep their state in
`compose/.upgrade/state.env`, so an interruption — Ctrl-C, a closed SSH session, a reboot — never leaves you guessing.

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
2. **Pull** the new images and rebuild the backup image while n8n still serves.
3. **Stop** — a scheduled backup in the sidecar may finish first, then the sidecar stops (its cron must not run a
   `pg_dump` during the migration). The alerts are silenced in Grafana (monitoring profile; the silence expires on its
   own). The webhook processors and n8n-main stop first, so no new execution starts; the workers get
   `UPGRADE_DRAIN_TIMEOUT` (300 s) to finish what is running; queued jobs stay in Valkey for the new workers. Nothing
   may still hold a session on n8n's database.
4. **Pre-upgrade backup** to every `BACKUP_REMOTES` target: kind `pre-upgrade`, label `<from>-to-<to>`, e.g.
   `n8n-20261009T101500Z-pre-upgrade-2.41.7-to-2.42.4`. Taken after the stop, so it holds every last write.
   **If it fails, the old version is started again and nothing has changed.**
5. **Switch** `versions.env` (only `N8N_VERSION`, `N8N_DIGEST`, `RUNNERS_DIGEST`) and start **n8n-main alone**: it runs
   the database migrations while webhooks and workers stay stopped. Progress (`Starting migration …`) is printed;
   `UPGRADE_TIMEOUT` (1800 s) bounds it.
6. **Start** everything else, then **verify**: every n8n container runs the target version and digest, and the smoke
   checks that are safe on a production host run — health, TLS and routing, metrics, plus a real webhook → queue →
   worker → Code-node round trip when smoke credentials exist (`compose/.smoke/owner.env`, or `SMOKE_OWNER_EMAIL` +
   `SMOKE_OWNER_PASSWORD`), plus the monitoring checks with that profile. The silence is lifted.

Downtime is steps 3–6: typically one to three minutes plus the backup and the migrations.

### When it fails

From step 5 on, a failure leaves `PHASE=failed` and prints both ways out:

| | |
|---|---|
| `make upgrade RESUME=1` | try the failed step again — after fixing what the log shows (disk space, a typo in `.env`, a timeout) |
| `make rollback` | go back to the old version (below) |

Until one of them finishes, `make up`, `make restart`, `make scale-workers` and `make restore` refuse to run: they
would start n8n in the middle of it. `make doctor` shows the state.

A migration that fails changes **nothing** in the database: n8n runs all pending migrations in one transaction. A
single migration statement is limited by n8n's `DB_POSTGRESDB_STATEMENT_TIMEOUT` (5 minutes by default) — set it
higher in `.env` before upgrading a very large database.

## Rollback

```bash
make rollback YES=1
```

It decides from the database whether a migration ran (n8n's `migrations` table, compared with its state before the
upgrade):

| | What it does | Data |
|---|---|---|
| **no migration ran** (patch releases usually have none; a failed migration rolled back) | stop n8n, switch `versions.env` back, start the old version, verify | nothing lost |
| **a migration ran** | stop n8n, restore the pre-upgrade backup (with a safety backup of the current database first, staging database, atomic swap), switch back, start the old version, verify, drop the replaced database | everything written after the backup is lost |

Before a restore the confirm shows how many executions, workflow changes and credential changes would be lost. When an
upgrade had **finished** and n8n was used since, `YES=1` is not enough: `make rollback ROLLBACK_CONFIRM=<backup name>`.
`ROLLBACK_MODE=images|restore` overrides the choice (`images` refuses when a migration ran: the old n8n would run on the
newer schema, which n8n does not detect).

From the restore to the version switch, Ctrl-C and a lost SSH session are ignored; a rollback that stops anywhere else
continues where it stopped when you run `make rollback` again. Only n8n's three version keys go back — pins of other
images that a `git pull` moved meanwhile stay (Grafana and Postgres cannot return to an older version of their data).

The rollback point lasts until the next `make upgrade`. Old states are kept in `compose/.upgrade/history/`.
Pre-upgrade and pre-restore bundles are never deleted by retention — remove old ones by hand once you no longer need
them.

## The version guard

`make up` (also `restart`, `scale-workers`, `restore`) compares `versions.env` with what runs — n8n-main's image label,
or, when the stack is down, the version n8n last recorded in its database — and refuses when they differ:

| Situation | Message points to |
|---|---|
| a `git pull` brought a newer pin | `make upgrade` (backup + migrations in order) |
| `versions.env` is older than what ran (a `git checkout`, an old copy) | `make rollback`, or pin forward: `PIN_ONLY='N8N RUNNERS' make pin N8N_VERSION=<running>` |
| an upgrade or rollback is unfinished | `make upgrade RESUME=1` / `make rollback` |

`FORCE_VERSION=1` overrides the comparison (not a pending upgrade) — only when you know why they differ.
`make restore` also refuses a bundle made by a **newer** n8n than `versions.env` pins (exit 5).

## versions.env is a tracked file

`make upgrade N8N_VERSION=x` changes `compose/versions.env` in your checkout. Commit it to your fork, or run
`git checkout -- compose/versions.env` before the next `git pull`; afterwards `make up` tells you whether the pulled
pin is newer (→ `make upgrade`) or older than what runs. Without `N8N_VERSION`, `make upgrade` applies the pin exactly
as it came through git (its digests are checked, not re-resolved).

## Tested

- CI (`upgrade` job, every push): the stack starts on the previous minor (`UPGRADE_FROM`, 2.41.7 → 2.42.4: 11
  migrations), then `tests/ci/upgrade-drill.sh` — `make up` refuses the new pin; `make upgrade SMOKE_FAIL=1` upgrades
  and fails verification on purpose; `make rollback` restores the pre-upgrade backup (a workflow written under the new
  version is gone, every older one is back); `make upgrade N8N_VERSION=<pin>` succeeds; a second upgrade has nothing
  to do; an image-only rollback over migrations is refused.
- `SMOKE_FAIL=1` makes the verification fail after everything really passed — for drills of your own.

## Not covered

- The `n8n_data` volume (event logs, installed community packages) is not rolled back; n8n reinstalls missing packages
  (`N8N_REINSTALL_MISSING_PACKAGES=true`), and nothing in it is known to break an older version.
- Third-party webhooks that the new version registered (Telegram, Stripe…) stay registered after a rollback; the old
  version re-registers its own when it activates the workflows.
- Uptime Kuma is not paused automatically — pause its monitors for the window, or expect a DOWN/UP pair.
- Major versions (3.x): `ALLOW_MAJOR=1` lets you through, but read n8n's breaking-change list and test on a copy first.
