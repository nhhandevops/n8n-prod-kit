# Security

What the kit hardens by default, what it leaves to you, and the checklist to work through before you give anyone the
URL. Every setting named here comes from `compose/docker-compose.yml`, `compose/caddy/` or `compose/.env.example`.

## The edge: one container, three ports

Only the `caddy` service publishes ports: `HTTP_PORT` (default 80) for the ACME HTTP-01 challenge and the permanent
redirect, and `HTTPS_PORT` (default 443) as TCP plus UDP for HTTP/3. Postgres, Valkey, all five n8n processes, the
runner sidecars, the backup sidecar and the monitoring profile publish nothing at all.

Two networks are declared `internal: true`, so a container attached only to them has no route off the host:

| Network | Members | Why |
|---|---|---|
| `internal` (`internal: true`) | caddy, all five n8n processes, the runner sidecars, postgres, valkey, backup, prometheus | backend traffic; Postgres, Valkey and the runner sidecars live **only** here |
| `proxy` | caddy, n8n-main, both webhook processes, the workers, backup | the workers need outbound HTTP for Request/API nodes; nothing here publishes a port except caddy |
| `monitoring` (`internal: true`) | Prometheus, Grafana, Loki, Alloy, node-exporter, cAdvisor | Loki holds every log line and has no login |
| `edge-grafana` / `edge-kuma` | caddy plus that one service | a workflow on a worker cannot reach Grafana or Kuma except through Caddy |

The sidecars that execute Code-node JavaScript (and Python, when `RUNNERS_LANGS` enables it) are on `internal` only: a
Code node's network calls go through the worker's helpers, not out of the sandbox. Caddy's admin API binds
`localhost:2019` and is never published — its `/config/` response contains the basic-auth hash.

## TLS and response headers

`TLS_MODE` picks one of three Caddy snippets: `acme` (Let's Encrypt production, the default), `acme-staging` (the same
flow against the staging CA, to rehearse DNS and firewall changes without burning production rate limits) and
`internal` (Caddy's own CA, 12-hour leaf certificates, what `make init` selects for dev names such as
`n8n.localtest.me`). Renewal is automatic; `make doctor` reads the certificate actually being served.

Every response of every site carries these, from the `security_headers` snippet:

| Header | What it stops |
|---|---|
| `Strict-Transport-Security: max-age=31536000; includeSubDomains` | a downgrade to plain HTTP for a year, `kuma.DOMAIN` included. No `preload`: a one-way door for the whole domain |
| `X-Content-Type-Options: nosniff` | the browser guessing a content type other than the one sent |
| `X-Frame-Options: SAMEORIGIN` | the editor being framed by another origin; n8n's own iframes keep working |
| `Referrer-Policy: strict-origin-when-cross-origin` | full URLs leaking to third parties |
| `Permissions-Policy: camera=(), microphone=(), geolocation=()` | browser features the workflow UI never needs |
| `-Server` | the `Server: Caddy` banner |

Responses Caddy generates itself — a 502 from a dead upstream, a 401 from basic auth — bypass the normal header
handler, so every site re-imports the snippet inside `handle_errors`. `request_body max_size 64MiB` caps uploads and
webhook payloads (n8n's own `N8N_PAYLOAD_SIZE_MAX` default is 16 MiB).

Access logs are JSON on stdout with **all request headers dropped** (`request>headers delete`). Caddy redacts only
`Authorization` and `Cookie`, so `X-N8n-Api-Key` and any header a webhook uses for authentication would otherwise sit
in Loki for 14 days. Query strings are still logged: keep secrets out of webhook URLs.

## Container hardening

| Setting | Where | What it stops |
|---|---|---|
| `no-new-privileges:true` | every service | a setuid binary in the container gaining privileges |
| `cap_drop: [ALL]` | every service except `uptime-kuma` | every Linux capability, `CAP_CHOWN` and `CAP_DAC_OVERRIDE` included |
| `cap_add: [NET_BIND_SERVICE]` | caddy only | not a loosening: `/usr/bin/caddy` carries that capability as a file capability, and exec of such a binary fails without it in the bounding set |
| `read_only: true` | every service except `uptime-kuma` | writes outside the named volumes and the measured tmpfs set (n8n: `/tmp`, `~/.cache`, `~/.npm`) |
| non-root users | caddy `1000:1000`, postgres `70:70`, valkey `999:1000`, backup `70:70`, n8n and the runners at the image's uid 1000 | a container escape landing as root |
| memory limits from `MEM_LIMIT_*` | every service | a runaway execution taking the host down; the container is OOM-killed and restarted instead |
| `json-file` logs, 20 MB x 5 | every service | logs filling the disk, which stops Postgres and Valkey writing |

Alloy and cAdvisor (monitoring profile only) read the Docker socket and the host filesystem: read-only, `cap_drop:
ALL`, no published port — and still root-equivalent. A compromise of either is a compromise of the host.

## n8n's own settings

The kit sets these explicitly, even where they match n8n 2.x's default, so a future default change cannot quietly
loosen your instance.

| Setting | What it stops |
|---|---|
| `N8N_BLOCK_ENV_ACCESS_IN_NODE=true` | Code nodes and expressions reading `process.env`, where the database and Valkey passwords and the encryption key live |
| `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true` | a Read File node reaching `/home/node/.n8n`: settings file, cached encryption key, event logs |
| `N8N_RESTRICT_FILE_ACCESS_TO` (2.x default) | file nodes touching anything outside `/home/node/.n8n-files`, the dedicated `n8n_files` volume. Not exposed as a knob on purpose |
| `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true` | `/home/node/.n8n/config` drifting off mode 0600 on a volume three roles share |
| `N8N_GIT_NODE_DISABLE_BARE_REPOS=true` | the Git node operating on bare repositories, a known RCE vector |
| `NODES_EXCLUDE` | the Execute Command and Local File Trigger nodes. Any value **replaces** n8n's built-in list, so keep both entries when adding your own |
| `N8N_UNVERIFIED_PACKAGES_ENABLED=false` | installing community packages n8n has not verified (the n8n 3.0 default, pinned early) |
| `N8N_RUNNERS_MODE=external` + `N8N_RUNNERS_AUTH_TOKEN` | Code-node tasks running inside the n8n process: they run in a separate container with no volumes, no capabilities and no route off the host |
| `N8N_SECURE_COOKIE=true`, `N8N_SAMESITE_COOKIE=lax`, `N8N_PROXY_HOPS=1` | the session cookie travelling without TLS, and n8n mis-reading client IPs behind exactly one proxy |
| `N8N_DIAGNOSTICS_ENABLED=false`, `N8N_PERSONALIZATION_ENABLED=false`, `N8N_HIRING_BANNER_ENABLED=false` | telemetry and questionnaires leaving a self-hosted instance |

MFA is not enforced by the kit: `N8N_MFA_ENFORCED_ENABLED=true` takes effect only together with
`N8N_SECURITY_POLICY_MANAGED_BY_ENV=true`, and both would have to be added to `.env` **and** to the compose
environment map. Enable MFA per user in the UI instead.

## Protecting the editor

By default the editor and `/rest` API are guarded by n8n's own login only. `UI_PROTECT=on` adds two layers in front,
in this order: an IP allow-list (`UI_ALLOW_CIDR`) that answers a bare 403 without offering a password prompt, then
HTTP basic auth. The edge password is stripped (`request_header -Authorization`) before the request reaches n8n, so it
never travels on to n8n, Grafana or Kuma.

```ini
UI_PROTECT=on
UI_ALLOW_CIDR='203.0.113.0/24'
UI_BASIC_AUTH_USER=ops
UI_BASIC_AUTH_HASH='$2a$14$…'
```

Then `make up`. The hash comes from `docker compose run --rm caddy caddy hash-password --plaintext 'your-password'` and **must be
single-quoted** in `.env` (or every `$` doubled), or Compose interpolates the `$…` segments away and no password ever
matches. `remote_ip` is the TCP peer: a request made on the Docker host itself arrives from the bridge gateway, not
`127.0.0.1`.

The snippet is imported into three places only — the catch-all handler, the `/grafana/*` handler and the `kuma.DOMAIN` site, so production webhooks, forms, MCP endpoints and the health
routes stay open — that is the point, integrations keep working. `make lint` runs `caddy validate` over all twelve
`TLS_MODE` x `UI_PROTECT` x `KUMA_ENABLED` combinations, but the 403/401 behaviour is not covered by the smoke suite;
test it from outside your allow-list once.

## Secrets

`make init` writes `compose/.env` at mode 600 *before* anything secret lands in it, creates `compose/secrets/` at mode
700, and generates `N8N_ENCRYPTION_KEY` (48 random bytes, 64 base64 characters), `POSTGRES_PASSWORD` and
`VALKEY_PASSWORD` (48 hex), `N8N_RUNNERS_AUTH_TOKEN` (64 hex), `GRAFANA_ADMIN_PASSWORD` (24 hex),
`GRAFANA_SECRET_KEY` (40 hex), `KUMA_ADMIN_PASSWORD` (32 hex) and the two age keys. `compose/.env`,
`compose/secrets/*`, `compose/backups/*` and `*.age` are gitignored — keep it that way, and use `make env-keys` (key
names only, values hidden) when pasting configuration into a bug report.

Two things must leave the host:

1. **`N8N_ENCRYPTION_KEY`**, into a password manager. It encrypts every stored credential; without it a restored
   database is unreadable. `make init` prints a red banner saying so.
2. **The recovery age key.** `make detach-recovery-key` prints it once, asks you to paste it back *from* the password
   manager (so a truncated copy is caught while the original still exists), checks that it is the key
   `BACKUP_AGE_RECOVERY_PUBLIC_KEY` encrypts to, and only then shreds the file. It is always interactive: `YES=1` and
   `CI=1` are ignored, because shredding the only copy must never happen unattended.

Every backup is encrypted to **two** age recipients: the host key (`secrets/age-key.txt`, used by the weekly restore
test and `make restore`) and that recovery key. A bundle with one recipient is refused unless
`BACKUP_ALLOW_SINGLE_RECIPIENT=true`, and `make preflight` fails for the same reason while `BACKUP_AGE_RECOVERY_PUBLIC_KEY` is empty and that override is not set — a
backup only the lost host can decrypt is not a recovery plan. After `make up`, `secrets/age-key.txt` is owned by the
backup container's uid 70 at mode 0440 with your group, so you are not locked out. age gives confidentiality, not
origin: anyone who can write to a target and knows the public key can plant a bundle, which is why the kit treats the
running encryption key as proof that a bundle is yours — see [Backup and restore](operations/backup-restore.md).

## What `make doctor` checks

It is read-only and prints the fix next to every failure. The security-relevant checks: `.env` is mode 600 ·
`N8N_ENCRYPTION_KEY` present and at least 32 characters · no `N8N_ENDPOINT_*` override in `.env` (custom endpoint
names would be routed to the wrong process) · `secrets/age-key.txt` present when backups are on · the recovery key's
public half matches `.env`, and whether the private half is still on this host (a warning after 7 days) · the
certificate being served, warning under 14 days left and failing when expired · `DOMAIN` resolving to this host's
public IP · the published ports actually being served · every service running and healthy, with restart counts · n8n
and the runners matching each other and the digests in `versions.env` · disk, clock sync, SELinux state and firewalld
(a failure when it is active without http/https allowed) · backup age and status per target, and the last restore test.

It does not check `UI_PROTECT`, and it cannot tell you whether your cloud firewall is sane.

## Public API and metrics

`/metrics*` answers **404** at the edge, and so does `/grafana/metrics*`. Not theoretical: before that handler
existed, `https://DOMAIN/metrics` served about 180 `n8n_*` series, workflow counts and queue depth among them, to
anyone on the Internet. Smoke test 06 asserts the 404 on every run. Prometheus scrapes each n8n process and
`caddy:2020` over the backend network instead, and that listener is not published.

n8n's public API (`/api/v1`) is **on** by default (`N8N_PUBLIC_API_DISABLED=false`), protected by API keys you create
in the UI; smoke test 03 proves a bogus key gets a 401, as does a wrong password on the login route. If nothing calls
the API, set `N8N_PUBLIC_API_DISABLED=true` — one fewer authenticated surface. The health routes (`/healthz`,
`/healthz/webhook`) are deliberately public and report liveness only.

## What the kit does not do

Be straight with whoever you hand this to:

- **No WAF, no bot filtering, no rate limiting at the edge.** The only request-level limit is the 64 MiB body cap.
  n8n rate-limits login attempts itself (the smoke suite is written around five per window), but your webhook paths
  are as open as the Internet.
- **No SSO, SAML or LDAP.** Those are n8n enterprise features and out of scope for the kit.
- **No secrets-manager integration.** Secrets live in `compose/.env` at mode 600 and in your password manager.
- **No vulnerability scanning.** Images are pinned by digest and moved with `make pin`; nothing in CI scans them for
  CVEs, and Dependabot only watches the GitHub Actions.
- **No host hardening beyond one firewall rule.** `scripts/bootstrap-host.sh` opens http/https in firewalld when
  firewalld is running and leaves SELinux alone; on ufw hosts it changes nothing, because Docker publishes ports
  through its own iptables chains ahead of ufw's INPUT rules. SSH, accounts and unattended upgrades are yours.
- **n8n connects to Postgres as the superuser** the image creates, so a live `make restore` runs as superuser. A
  dedicated non-superuser role is on the roadmap.
- **`uptime-kuma` is the one container without a read-only root filesystem and without `cap_drop: ALL`.** It is
  optional and off by default.

## Before you give out the URL

1. `make doctor` — no `[FAIL]` lines. Fix what it names, re-run.
2. `N8N_ENCRYPTION_KEY` is in your password manager, read back from there once.
3. `make detach-recovery-key` is done, and `make doctor` says *recovery key detached*.
4. At least one off-host target in `BACKUP_REMOTES`, then `make backup-now` and `make restore-test` both green.
5. `TLS_MODE=acme`, the certificate is from a public CA, and `make doctor` reports the days left.
6. `curl -s -o /dev/null -w '%{http_code}' https://DOMAIN/metrics` returns `404`.
7. The owner account has a strong password and MFA enabled in the UI; delete accounts you created for testing.
8. Decide on `UI_PROTECT`. If you enable it, check from outside `UI_ALLOW_CIDR` that you get a 403 and that a
   production webhook still answers.
9. Decide on `N8N_PUBLIC_API_DISABLED`, and delete the API keys you made while testing.
10. The cloud firewall allows only tcp 80, tcp 443, udp 443 and your SSH; on an EL host,
    `firewall-cmd --list-services` lists http and https.
11. `git status` is clean of `.env` and `secrets/`, and `make smoke` passes end to end.
