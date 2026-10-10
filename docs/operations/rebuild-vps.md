# Rebuild on a new VPS

The runbook for putting this instance back on a host that has nothing on it: bootstrap, clone, restore from an
off-host backup with the recovery key, verify. It is the same procedure whether the old host was lost or you are
moving to a bigger one.

The restore itself — what the bundle contains, what the key check does, what `ADOPT_KEY=1` means — is
[backup-restore.md](backup-restore.md). Read that alongside this page the first time; everything here is the order to
do things in, not a second explanation of them.

## What you need before you start

| | |
|---|---|
| An off-host backup | a bundle on an `r2:`/`s3:` remote or an external disk you still have, plus the `RCLONE_CONFIG_*` credentials for it |
| The **recovery key** | the `AGE-SECRET-KEY-…` line from your password manager (put there by `make detach-recovery-key`) |
| The old **`N8N_ENCRYPTION_KEY`** | to compare against the bundle's key under `ADOPT_KEY=1` |
| DNS control for `DOMAIN` | the A/AAAA record has to point at the new host before a certificate can be issued |
| The old host's n8n version | the restore refuses a bundle made by a newer n8n than the new clone pins |

If the recovery key only ever existed on the lost host, its backups cannot be decrypted anywhere else. That is the
whole reason `make detach-recovery-key` exists, and why a backup without the recovery recipient is refused by default.

**What the bundle does not carry**, and you therefore rebuild by hand: the `n8n_files` volume (files written by the
Read/Write Files node), Caddy's certificates (ACME simply issues new ones), Grafana's and Uptime Kuma's own databases (Grafana's dashboards, alert rules and contact point are provisioned from files, and `make up` creates Kuma's admin again, but Kuma's monitors have to be re-added),
and your `.env` — new secrets are generated below. Community packages come back on their own: the kit sets
`N8N_REINSTALL_MISSING_PACKAGES=true`, so n8n reinstalls every package the restored database lists.

## 1. Point DNS at the new host

Do this first, because `make preflight` checks it: in either ACME mode (`acme` and `acme-staging`) it **fails** when `DOMAIN` does not resolve to this
host's public IP, and Caddy cannot complete an HTTP-01 challenge either. To rehearse the whole procedure without
spending Let's Encrypt quota, set `TLS_MODE=acme-staging` — untrusted certificates, no rate limits.

## 2. Bootstrap the host

```bash
curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash -s -- --yes
```

Installs Docker Engine and the Compose plugin from Docker's own repository plus `make`, `jq` and `git`, sets
`vm.overcommit_memory=1` (Valkey needs it), enables `docker.service`, adds the invoking `sudo` user to the `docker`
group, and opens http/https in firewalld when firewalld is active. It is idempotent.

Supported: Ubuntu 24.04 / 26.04, Debian 12 / 13, and RHEL / Rocky / AlmaLinux / CentOS Stream / Oracle Linux 9 and 10.
Other apt or dnf releases are attempted with a warning; anything else exits 2. On an Enterprise Linux host read
[rhel-hosts.md](rhel-hosts.md) as well. On a ufw host the script changes nothing and does not need to: Docker
publishes ports through its own iptables chains, ahead of ufw's INPUT rules. Keep ssh allowed.

**Log out and back in** before the next step, or your shell is not in the `docker` group yet and `make preflight` will
say the daemon is unreachable.

## 3. Clone and initialise

```bash
git clone https://github.com/nhhandevops/n8n-prod-kit && cd n8n-prod-kit/compose
make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com
```

`make init` writes a **new** `.env` with **new** secrets and a **new** pair of age keys. That is expected and correct:
the backup carries the old `N8N_ENCRYPTION_KEY` and the restore takes it over in step 6.

## 4. Re-apply the settings the old host had

`init` leaves `BACKUP_REMOTES` empty on a production domain, so the new host cannot see the old backups until you
point it at them. Edit `compose/.env`:

```ini
BACKUP_REMOTES="r2:n8n-backups/prod"
RCLONE_CONFIG_R2_ACCESS_KEY_ID=...
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
RCLONE_CONFIG_R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
```

Then go through the rest of your old `.env` while you are in there. The ones that are easy to forget:
`UI_PROTECT` with `UI_ALLOW_CIDR` / `UI_BASIC_AUTH_USER` / `UI_BASIC_AUTH_HASH` (the hash must stay single-quoted),
`COMPOSE_PROFILES` and `KUMA_ENABLED`, `ALERT_TELEGRAM_BOT_TOKEN` / `ALERT_TELEGRAM_CHAT_ID`, `GENERIC_TIMEZONE` and
`TZ`, `WORKER_REPLICAS` and `WORKER_CONCURRENCY`, and any `MEM_LIMIT_*` you had tuned. Every key is commented in
`.env.example`.

```bash
make preflight && make up
```

## 5. Put the recovery key on the host, for this restore only

```bash
install -m 600 /dev/stdin /tmp/recovery.txt
# paste the AGE-SECRET-KEY-... line, then Ctrl-D
```

## 6. Restore, naming the bundle explicitly

```bash
make backups                      # newest first; note the name of the newest bundle of the OLD host
make restore BACKUP=<that name> AGE_KEY=/tmp/recovery.txt ADOPT_KEY=1
shred -u /tmp/recovery.txt
```

Name it. `latest` would become the new host's own first backup as soon as it makes one, and the old recovery key
cannot decrypt that.

`ADOPT_KEY=1` prints a hint of the bundle's encryption key and asks you to compare it with the one in your password
manager; the restore then writes that key into `.env` (keeping the old file as `.env.bak.<ts>`) and resets n8n's
cached settings file, which would otherwise make n8n refuse to start with "Mismatching encryption keys". Without
`ADOPT_KEY=1` the restore stops at the key check (exit 3) and changes nothing — on a new host that refusal is the
expected first answer, not a fault.

## 7. Verify

```bash
make status                       # every service running + healthy, and the login URL
make doctor                       # certificate, DNS, disk, Postgres, Valkey, backups
```

Then log in at `PUBLIC_URL` with the **old** owner account — user accounts came back with the database — and open a
credential that stores a secret. If it decrypts, the key adoption worked. Fire one production webhook you know, and
check the execution appears.

For the full end-to-end suite:

```bash
SMOKE_OWNER_EMAIL=you@example.com SMOKE_OWNER_PASSWORD='…' make smoke
```

The owner variables are needed because `compose/.smoke/owner.env` does not exist in a fresh clone; without them the
suite stops with "this instance already has an owner but compose/.smoke/owner.env is missing". Note that the suite's
backup test runs a real `make backup-now`, so run it **after** the restore, never before.

## 8. Close the loop

```bash
make detach-recovery-key          # move the NEW recovery key into your password manager
make backup-now                   # first backup of the new host
make restore-test                 # prove the new host can restore its own bundle
```

The `N8N_ENCRYPTION_KEY` in the new `.env` is now the old one, so what is in your password manager still matches — it
is the *recovery* key that is new and needs storing. If workflows keep files in `/home/node/.n8n-files`, restore that
volume from wherever you back it up separately: it is not in the bundle.

## If something stops you

| Message | What it means |
|---|---|
| preflight: `DNS: … but this host's public IP is …` | the record still points at the old host (step 1) |
| restore: `exit 3`, keys do not match | expected without `ADOPT_KEY=1` on a new host — nothing was changed |
| restore: `was made by n8n X, NEWER than Y that would run on it` (exit 5) | move the new host to that version first with `make upgrade N8N_VERSION=X`, then restore **by name** (the upgrade's own backup would be newer than the one you want) |
| `could not list every remote` | `latest` refuses while a target is unreadable; fix the credentials or pick one with `FROM=<remote>` |
| `renamed or planted file, refusing it` | the bundle's name does not match its manifest — do not restore it, find out who wrote it |
| a restore was interrupted | `make restore-clean` empties the work volume; the live database is untouched unless the swap had completed |

This whole procedure runs in CI on every change (`tests/ci/dr-drill.sh`): back up, destroy the stack including its
`.env` and age keys, init a new host, confirm a restore without `ADOPT_KEY` refuses, restore with the recovery key and
`ADOPT_KEY=1`, then run the full smoke suite. So if it fails for you and not there, start by comparing your `.env` with
what the old host had — `make env-keys` lists the key names without their values, which is also what belongs in a bug
report.
