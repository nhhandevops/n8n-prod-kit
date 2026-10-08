# Backup and restore

The `backup` service (compose/backup/) protects the Postgres database (workflows, credentials, executions, binary data)
**and** the `N8N_ENCRYPTION_KEY` that encrypts the credentials in it.

## What a backup is

`n8n-<UTC timestamp>-<kind>[-label].tar.age` — a tar of three files, encrypted with [age](https://age-encryption.org) to
**two** recipients:

| File | Content |
|---|---|
| `db.dump` | `pg_dump -Fc` of the n8n database |
| `key-bundle.env` | `N8N_ENCRYPTION_KEY`, n8n and Postgres versions, domain, creation time |
| `manifest.json` | its own name, sizes, sha256 of every file, workflow/credential counts (counted in the dump itself) |

| Recipient | Private key | Used for |
|---|---|---|
| host key | `compose/secrets/age-key.txt` (stays on the host) | the weekly restore test, `make restore` |
| recovery key | **your password manager** (`make detach-recovery-key` moves it there) | restoring on a new host after this one is lost |

A backup without the recovery recipient is refused (`BACKUP_ALLOW_SINGLE_RECIPIENT=true` overrides that), and the
restore test fails on a bundle that has only one.

Kinds and where they go (`<remote>/<kind>/`): `daily` (cron), `monthly` (the first daily bundle of each UTC month — a
missed 1st is filled in by the next daily run), `manual` (`make backup-now`), `pre-restore` (taken automatically before
every restore), `pre-upgrade` (S7). Retention prunes only daily/ (`BACKUP_RETENTION_DAILY_DAYS`) and monthly/
(`BACKUP_RETENTION_MONTHLY_DAYS`), judged by the UTC time in the name, and **never** the `BACKUP_RETENTION_MIN_KEEP`
(default 7) newest of either — a clock that jumps ahead cannot empty a remote. Files that do not follow the naming
scheme are never listed, restored or deleted.

**Not in the bundle:** the `n8n_files` volume (files written by the Read/Write Files node) and the `n8n_data` volume
(n8n's settings file, event logs, installed community packages). The kit sets `N8N_REINSTALL_MISSING_PACKAGES=true`, so
after a restore onto a new host n8n reinstalls every community package the database lists. If workflows keep files in
`/home/node/.n8n-files`, back that volume up separately.

## Configure

In `compose/.env` (every key is explained in `.env.example`):

```ini
BACKUP_ENABLED=true
BACKUP_REMOTES="r2:n8n-backups/prod /backups/external"   # every target receives every backup
BACKUP_LOCAL_PATH=/mnt/usb/n8n-backups                     # appears as /backups/external
RCLONE_CONFIG_R2_ACCESS_KEY_ID=...                         # R2 API token scoped to the bucket
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
RCLONE_CONFIG_R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
ALERT_TELEGRAM_BOT_TOKEN=...                               # failures are sent here
ALERT_TELEGRAM_CHAT_ID=...
```

- `BACKUP_REMOTES` accepts `/backups/local`, `/backups/external[/dir]` and rclone remotes `name:bucket/path` — anything
  else (a typo like `r2/bucket`) is refused, because it would be written inside the container and lost on restart.
  Give every stack its own prefix: retention prunes every kit bundle under `<target>/daily`.
- `BACKUP_LOCAL_PATH` must exist and be empty or hold only kit backups, outside system directories and `$HOME`:
  `make up` hands it to the backup container's uid. Use a dedicated sub-directory of the mounted disk.
- `BACKUP_TMPFS_SIZE` (default 1g) is the scratch space for dump, bundle and restore-test database; it counts against
  `MEM_LIMIT_BACKUP` (default 1536m), which must stay at least 256m above it. `make doctor` warns when the bundles
  outgrow it.

Then `make up`. A backup counts as successful only when **every** target received it. **Any** failure — configuration,
pg_dump, a full tmpfs, encryption, an upload, the monthly copy — sets `backup_last_status 0` and alerts.

## Day to day

| Command | What it does |
|---|---|
| `make backup-now [NAME=label]` | manual backup to every target now |
| `make backups [FROM=remote]` | list every bundle, newest first |
| `make restore-test [BACKUP=name]` | verify every target's newest bundle and restore the newest into a scratch Postgres — never touches the live DB |
| `make doctor` | shows the age and last status of the backups per target and the last restore test |
| `make detach-recovery-key` | prints the recovery key, makes you paste it back from the password manager, then shreds it from the host |

The restore test also runs every Sunday 03:00 (`RESTORE_TEST_SCHEDULE`). Per target it downloads, decrypts and
sha256-checks the newest bundle and fails when it is older than `RESTORE_TEST_MAX_AGE_HOURS` (26). The newest bundle
overall is then restored. It must be encrypted to two keys and carry the running encryption key, both checked
before any of its SQL runs. The restore goes into a scratch Postgres as an unprivileged role. The test then compares
the workflow count with the manifest and decrypts a credential with the bundle's key. Metrics land in the backup
service's `/state/metrics.prom`.

Backup jobs, restore tests and restores share one lock (`/state/backup.lock`), so they never overlap, whichever
container runs them.

## Restore (same host)

```bash
make backups                              # pick one, or use latest
make restore BACKUP=latest                # asks before touching anything
```

`latest` is the newest bundle on any target **except** `pre-restore/` safety copies and names more than a day in the
future (reported as a clock jump). When a target cannot be listed, `latest` refuses — the newest backup could be there —
so fix it or pick a target with `FROM=<remote>`.

What happens:
1. Lock, fetch, decrypt and verify. The manifest must name the file, which catches renamed copies.
2. **Key check.** A bundle with a different `N8N_ENCRYPTION_KEY` stops here (exit 3) and nothing is changed.
3. Confirm, then stop all n8n processes and take the **safety backup** (kind `pre-restore`) of the now quiet database.
4. `pg_restore` into a **staging database** and check its workflow count.
5. Swap the staging database in atomically. The replaced database is kept as `n8n_prev` until the stack is healthy.
6. Reset n8n's cached key file, empty the job queue, start the stack and wait for it to be healthy.

If anything fails before the swap, the live database is untouched and n8n is started again.

The decrypted dump in the `backup_work` volume is deleted on every exit, including errors and Ctrl-C. The last line of
the output prints the undo command (`make restore BACKUP=<pre-restore name> SKIP_SAFETY_BACKUP=1`).

## Restore on a new host (disaster recovery)

The old host is gone; you have the recovery key and the `N8N_ENCRYPTION_KEY` (password manager) and the backups on an
off-host target.

```bash
# 1. new VPS: bootstrap + clone, then init — it creates a NEW .env, new secrets and new age keys; that is expected:
#    the backup carries the old N8N_ENCRYPTION_KEY
sudo scripts/bootstrap-host.sh
cd compose && make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com
# 2. point the kit at the same backup target(s) as before: BACKUP_REMOTES + RCLONE_CONFIG_* in compose/.env
make up
# 3. the recovery key, for this restore only (paste the AGE-SECRET-KEY-... line)
install -m 600 /dev/stdin /tmp/recovery.txt
# 4. restore, decrypting with the recovery key, and take over the backup's encryption key
make backups                                   # note the name of the newest backup of the OLD host
make restore BACKUP=<that name> AGE_KEY=/tmp/recovery.txt ADOPT_KEY=1
shred -u /tmp/recovery.txt
```

Name the backup explicitly. Once the new host has made a backup of its own (its 02:00 job), `latest` would be that
one, and the old recovery key cannot decrypt it.

`ADOPT_KEY=1` shows a hint of the bundle's key (`abcd…wxyz (64 chars)`) and asks you to compare it with the
`N8N_ENCRYPTION_KEY` in your password manager. `YES=1` skips that comparison, so use it only in automation you
trust. The restore then writes that key into `.env` (the previous file is kept as `.env.bak.<ts>`) and resets
n8n's settings file in the `n8n_data` volume. n8n caches its key there and would otherwise refuse to start
("Mismatching encryption keys"). Every restored credential then decrypts.

Afterwards: `make detach-recovery-key` for the NEW recovery key `make init` created, and `make backup-now`, so the
first backup of the new host exists.

CI runs this whole procedure on every change (`tests/ci/dr-drill.sh`): back up, destroy the stack including its
`.env` and age keys, init a new host, check that a restore without `ADOPT_KEY` refuses, restore with the recovery key
and `ADOPT_KEY=1`, then run the full smoke suite.

## Security model

age gives **confidentiality, not origin**: anyone who can write to a backup target and knows a public key (it is in
`.env`) can create a bundle that decrypts fine. The kit therefore:

- treats the running `N8N_ENCRYPTION_KEY` as the proof that a bundle is ours. A bundle with another key is never
  restored without `ADOPT_KEY=1`, and never executed by the restore test.
- binds each file name to its manifest, ignores future-dated names, and never lets `latest` pick a safety copy.
- runs the restore test's `pg_restore` as an unprivileged role, so archive SQL cannot reach `COPY … PROGRAM`.
- keeps the recovery key off the host (`make detach-recovery-key`).

Scope the bucket tokens to the backup prefix, and keep the external disk away from other users.

Known limitation: n8n itself connects as the Postgres superuser the image creates (`POSTGRES_USER`), so a live restore
runs as superuser. That is safe only after the key check, or after your comparison under `ADOPT_KEY`. A dedicated
non-superuser role for n8n is on the roadmap.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `make doctor`: last backup > 26 h, or last attempt failed | `make logs SERVICE=backup SINCE=48h`; `make backup-now` |
| `BACKUP_REMOTES entry … is not …` | use `/backups/local`, `/backups/external[/dir]` or `name:bucket/path` |
| `BACKUP_RETENTION_… must be a whole number >= 1` | days, without a unit (`30`, not `30d`); `0` is refused |
| upload failed to `r2:` | token scope / endpoint; R2 tokens scoped to one bucket need `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true` (set by the kit) |
| restore: `could not list every remote` | fix the remote (credentials, network) or choose one: `FROM=/backups/local` |
| `renamed or planted file, refusing it` | a bundle whose name does not match its manifest — do not restore it; find out who wrote it |
| restore test: credential could not be decrypted | the bundle key does not match the data — investigate before trusting these backups |
| `/state` permission denied | `make up` (runs scripts/backup-perms.sh) |
| tmpfs full / backup `Killed` | raise `BACKUP_TMPFS_SIZE` and `MEM_LIMIT_BACKUP` together |
| n8n-main: `Mismatching encryption keys` after a manual key change | delete `/home/node/.n8n/config` in the `n8n_data` volume (make restore does this itself) |
| a restore was interrupted | `make restore-clean` empties the work volume; the live database is untouched unless the swap had completed |
