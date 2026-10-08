# Backup and restore

The `backup` service (compose/backup/) protects everything that cannot be recreated: the Postgres database (workflows,
credentials, executions, binary data) **and** the `N8N_ENCRYPTION_KEY` that encrypts the credentials in it.

## What a backup is

`n8n-<UTC timestamp>-<kind>[-label].tar.age` — a tar of three files, encrypted with [age](https://age-encryption.org) to
**two** recipients:

| File | Content |
|---|---|
| `db.dump` | `pg_dump -Fc` of the n8n database |
| `key-bundle.env` | `N8N_ENCRYPTION_KEY`, n8n and Postgres versions, domain, creation time |
| `manifest.json` | sizes, sha256 of every file, workflow/credential counts |

| Recipient | Private key | Used for |
|---|---|---|
| host key | `compose/secrets/age-key.txt` (stays on the host) | the weekly restore test, `make restore` |
| recovery key | **your password manager** (`make detach-recovery-key` moves it there) | restoring on a new host after this one is lost |

Kinds and where they go (`<remote>/<kind>/`): `daily` (cron, kept `BACKUP_RETENTION_DAILY_DAYS`), `monthly` (the daily
backup of the 1st, kept `BACKUP_RETENTION_MONTHLY_DAYS`), `manual` (`make backup-now`), `pre-restore` (taken
automatically before every restore), `pre-upgrade` (S7). Only daily/monthly are pruned.

## Configure

In `compose/.env` (every key is explained in `.env.example`):

```ini
BACKUP_ENABLED=true
BACKUP_REMOTES="r2:n8n-backups/prod /backups/external"   # every target receives every backup
BACKUP_LOCAL_PATH=/mnt/usb-backup                          # appears as /backups/external
RCLONE_CONFIG_R2_ACCESS_KEY_ID=...                         # R2 API token scoped to the bucket
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
RCLONE_CONFIG_R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
ALERT_TELEGRAM_BOT_TOKEN=...                               # failures are sent here
ALERT_TELEGRAM_CHAT_ID=...
```

Then `make up`. A backup counts as successful only when **every** target received it; a partial failure alerts.

## Day to day

| Command | What it does |
|---|---|
| `make backup-now [NAME=label]` | manual backup to every target now |
| `make backups [FROM=remote]` | list every bundle, newest first |
| `make restore-test [BACKUP=name]` | restore the newest (or named) backup into a scratch Postgres and verify it — never touches the live DB |
| `make doctor` | shows the age of the last backup per target and the last restore test |
| `make detach-recovery-key` | prints the recovery key once, then shreds it from the host |

The restore test also runs every Sunday 03:00 (`RESTORE_TEST_SCHEDULE`): it checks the sha256s, restores, compares the
workflow count with the manifest, decrypts a credential with the bundle's key and confirms that key matches the running
one. Metrics land in the backup service's `/state/metrics.prom` (Prometheus in S6).

## Restore (same host)

```bash
make backups                              # pick one, or use latest
make restore BACKUP=latest                # asks before touching anything
```

What happens: fetch + decrypt + verify → confirm → **safety backup of the current database** (kind `pre-restore`) →
stop all n8n processes → drop, recreate and `pg_restore` in one transaction → empty the job queue → start → status.
To undo a restore: `make restore BACKUP=<the pre-restore name>`.

If the backup was made with a different `N8N_ENCRYPTION_KEY` than the one in `.env`, the restore stops **before**
touching the database (exit 3).

## Restore on a new host (disaster recovery)

The old host is gone; you have the recovery key (password manager) and the backups on an off-host target.

```bash
# 1. new VPS: bootstrap + clone, then init — it creates a NEW .env, new secrets and new age keys; that is expected:
#    the backup carries the old N8N_ENCRYPTION_KEY
sudo scripts/bootstrap-host.sh
cd compose && make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com
# 2. point the kit at the same backup target(s) as before: BACKUP_REMOTES + RCLONE_CONFIG_* in compose/.env
make up
# 3. the recovery key, for this restore only (paste the AGE-SECRET-KEY-... line)
install -m 600 /dev/stdin /tmp/recovery.txt
# 4. restore the newest backup, decrypting with the recovery key, and take over the backup's encryption key
make restore BACKUP=latest AGE_KEY=/tmp/recovery.txt ADOPT_KEY=1
shred -u /tmp/recovery.txt
```

`ADOPT_KEY=1` writes the backup's `N8N_ENCRYPTION_KEY` into `.env` (the previous `.env` is kept as `.env.bak.<ts>`)
and the stack restarts with it, so every restored credential decrypts. Afterwards: store that key in the password
manager, `make detach-recovery-key` for the NEW recovery key `make init` created, and `make backup-now` so the first
backup of the new host exists. Verified end to end on 2026-10-08 (new key in `.env`, external key file, mismatch stop
without `ADOPT_KEY`, then restore with it; credentials decrypt, smoke 01/04/05 green).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `make doctor`: last backup > 26 h | `make logs SERVICE=backup SINCE=48h`; `make backup-now` |
| upload failed to `r2:` | token scope / endpoint; R2 tokens scoped to one bucket need `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true` (set by the kit) |
| restore test: credential could not be decrypted | the bundle key does not match the data — investigate before trusting these backups |
| `/state` permission denied | `make up` (runs scripts/backup-perms.sh) |
| tmpfs full during backup/restore test | raise `BACKUP_TMPFS_SIZE` and `MEM_LIMIT_BACKUP` together |
