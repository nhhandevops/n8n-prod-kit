# n8n-kit-PROD-PLAN.md — the production rollout, parked

> **Status: PARKED.** Nothing in this file is being executed. The project is deliberately in dev/test:
> one disposable VM, an internal certificate authority, local backups, no public DNS. The hands-on
> dev/test pass is [`docs/runbook.md`](docs/runbook.md) — do that first, and keep doing it.
>
> **This file is maintained, not run.** Every time the kit changes, §2 (the config diff), §4 (the gates)
> and §5 (the improvement ledger) are re-checked, so that on the day production is actually decided the
> sequence is already written and already current. §6 lists what triggers an update.
>
> **Last updated:** 2026-10-10 · **Parked by:** An, with Claude · **Unparks when:** §1 is satisfied.

---

## 0. How to use this file

| If you are… | Read |
|---|---|
| testing the kit on a dev box | not this file — [`docs/runbook.md`](docs/runbook.md) |
| about to spend money on a production host | §1, then §3 in order |
| deciding what to improve next | §5 only. It is scored, and the top of the table is the answer |
| an AI agent resuming this project | `n8n-kit-HANDOFF.md` first, then §5 and §6 here |

Three rules keep the plan honest:

1. **No step here may be performed on the dev host.** The dev host is a test subject; production
   discipline on it buys nothing and costs clarity.
2. **Every claim is checked against the code, not remembered.** Where this file and a script disagree,
   the script is right and this file is a bug.
3. **A gate is a gate.** The phases in §3 end with something that is either true or false. "Probably
   fine" is not a gate.

---

## 1. What this plan is waiting on

Production is unparked when all three are true:

| # | Condition | Where it stands (2026-10-10) |
|---|---|---|
| 1 | **M0 is closed**: three people who have never seen the project follow `docs/quickstart.md` on their own fresh host, timed, and the GitHub Release is flipped from pre-release to release (TC-025) | not started — needs a public host, a domain and three people |
| 2 | **Every blocker in §5 is cleared** (score ≥ 20 band) | 10 open, 7 of them under an hour of work each |
| 3 | **Three decisions are written down**, in `n8n-kit-HANDOFF.md` §3: the OS family, the host size, and who is on the hook when it pages at 02:00 | OS family leaning RHEL-family (Rocky/Alma), which makes D-10 in §5 a blocker; size and ownership undecided |

Until then this file only gets edited, never executed.

---

## 2. What production needs that the dev stack does not

`make init` writes a `.env` tuned for a safe first run. Production is that file with deliberate changes.
Every row is a key that exists in `compose/.env.example` today; the comment in that file explains the
setting, and [Configuration](docs/configuration.md) explains the reasoning.

### Must change

| Key | Dev (now) | Production | Why it matters |
|---|---|---|---|
| `DOMAIN` | `n8n.localtest.me` | a real hostname you own | webhook URLs are built from it; changing it later re-points every integration |
| `TLS_MODE` | `internal` | `acme-staging` for the first run, then `acme` | a mis-pointed DNS record on the real ACME endpoint burns Let's Encrypt rate limits for days; staging is free to get wrong |
| `ACME_EMAIL` | `dev@example.com` | a mailbox someone reads | it is where expiry warnings go |
| `BACKUP_REMOTES` | `/backups/local` | at least one off-host target **and** the local one, e.g. `"r2:your-bucket/prod /backups/local"` | a backup on the same disk as the database is not a backup. Every listed target must succeed for the backup to count |
| `UI_PROTECT` | `off` | `on`, with `UI_ALLOW_CIDR` and `UI_BASIC_AUTH_USER`/`_HASH` | otherwise the editor — and the credential store behind it — is one password away from the internet. Webhooks, forms, MCP and the health routes stay open by design |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `30` | above your p99 execution duration | this is the window a worker gets to finish before it is cut. Work still running past it dies as `crashed` and **is not retried** (§8 risk 1) |
| `EXECUTIONS_TIMEOUT` | `-1` (no limit) | a real number of seconds | one stuck execution otherwise holds a concurrency slot for ever |
| `COMPOSE_PROFILES` | empty | `monitoring,kuma` | you cannot operate what you cannot see. Needs roughly 4 vCPU / 8 GB — size the host for it, do not bolt it on later |
| `KUMA_ENABLED` | `off` | `on`, plus a public DNS record for `kuma.DOMAIN` | the outside view: it notices what an internal check cannot |
| `ALERT_TELEGRAM_BOT_TOKEN` / `_CHAT_ID` | empty | a **fresh** bot from @BotFather | the token used while building the monitoring profile was pasted into a build chat; revoke it with `/revoke` and issue a new one for production |

### Decide consciously

| Key | Default | Decide | Trade |
|---|---|---|---|
| `WORKER_REPLICAS` / `WORKER_CONCURRENCY` | `2` / `10` | from your own `make loadtest` numbers, not from ours | more workers cost RAM; more concurrency per worker costs CPU and Postgres connections |
| `EXECUTIONS_DATA_SAVE_ON_SUCCESS` | `all` | `none` for high-volume, noisy workflows | `all` is a complete audit trail and the fastest-growing table you own |
| `EXECUTIONS_DATA_MAX_AGE` / `_PRUNE_MAX_COUNT` | `336` h / `10000` | match your retention policy | the only thing stopping the database growing for ever |
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | `-1` | a cap if a burst must never swamp the host | a cap turns overload into queueing instead of thrash |
| `N8N_PUBLIC_API_DISABLED` | `false` | `true` unless you use the public API | one less authenticated surface; the smoke suite needs it, production may not |
| `N8N_TEMPLATES_ENABLED`, `N8N_VERSION_NOTIFICATIONS_ENABLED` | `true` | `false` if outbound calls from the editor are unwanted | convenience versus a closed box |
| `BACKUP_RETENTION_DAILY_DAYS` / `_MONTHLY_DAYS` / `_MIN_KEEP` | `30` / `365` / `7` | by how far back you must be able to go | storage is cheap; a short retention hides a slow corruption |
| `BACKUP_LOCAL_PATH` | empty | an external disk or NAS mount if you have one | the third copy in 3-2-1, and the one that survives a cloud account problem |
| `PROM_RETENTION`, `LOKI_RETENTION` | `15d`, `336h` | by disk | metrics and logs are the only record of why something happened |
| `BACKUP_ALLOW_SINGLE_RECIPIENT` | `false` | leave it `false` | `true` means one lost key makes every bundle unreadable |

### Do not change

`N8N_ENCRYPTION_KEY` after the first start (it is what credentials are encrypted with), the hardening
block (`N8N_BLOCK_ENV_ACCESS_IN_NODE`, `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES`,
`N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS`, `NODES_EXCLUDE`), or the image pins by hand — `make pin` and
`make upgrade` own `compose/versions.env`.

### Outside the kit, still yours

Cloud firewall open on tcp 80, tcp 443, udp 443 and your SSH only · SSH keys only, no password login ·
unattended security updates on the host · a separate non-root operator account in the `docker` group ·
monitoring of the host itself if your provider offers it · where the `N8N_ENCRYPTION_KEY` and the age
recovery key live (a password manager, read back once to prove it) · who answers the alerts.

---

## 3. The rollout, phase by phase

Each phase ends with a gate. Do not start the next phase until the gate is true. Nothing here is novel —
it is `docs/quickstart.md` with the production decisions made in a deliberate order.

### P0 — Decide and size (no machines yet)

Answer in writing, in `n8n-kit-HANDOFF.md` §3:

- Which workflows actually go to production, and what happens if one runs twice? (See §8 risk 1.)
- Expected executions per hour, peak burst, and the longest single execution you tolerate.
- OS family: Ubuntu 24.04 (the path with the most mileage here) or Rocky/AlmaLinux 9 (intended, but the
  SELinux + firewalld path has never been run on real hardware — D-10).
- Host size: 2 vCPU / 8 GB runs the core stack; the monitoring profile wants roughly 4 vCPU / 8 GB.
- Off-host backup target, and who holds its credentials.
- Who is on the hook when it pages, and on what channel.

**Gate:** all six answered and committed. An unanswered question here becomes an outage later.

### P1 — The host

```bash
# on a fresh host, as a user with sudo
curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash -s -- --yes
# then log out and back in — docker group membership only applies to a new login session
git clone https://github.com/nhhandevops/n8n-prod-kit && cd n8n-prod-kit/compose
```

Then: firewall down to 80/443/udp 443 plus SSH, SSH keys only, unattended upgrades on, clock synced.

**Gate:** `docker run --rm hello-world` works without sudo, and `make preflight` (after P2) has no `[FAIL]`.

### P2 — Configuration and secrets

```bash
make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com
# apply §2 "Must change" and your §2 "Decide consciously" answers to .env
make detach-recovery-key      # prints the offline recovery key ONCE — into a password manager
make preflight
```

`N8N_ENCRYPTION_KEY` goes to the password manager **and is read back from there once** before anything
real exists. A key you have never read back is a key you do not have.

**Gate:** `make preflight` clean; both secrets verified out of the password manager; `make doctor` reports
the recovery key as detached.

### P3 — TLS, staging first

DNS `A`/`AAAA` for `DOMAIN` (and `kuma.DOMAIN` if `KUMA_ENABLED=on`) pointing at the host, propagated —
`make preflight` checks this and will refuse a mismatch.

```bash
# .env: TLS_MODE=acme-staging
make up && make status && make doctor
# the browser will warn: a staging certificate is deliberately untrusted. That is the signal it worked.
# then .env: TLS_MODE=acme
make up && make status && make doctor
curl -s -o /dev/null -w '%{http_code}\n' https://n8n.example.com/metrics   # must be 404
```

**Gate:** a publicly trusted certificate, `make doctor` reporting days left, `/metrics` 404 from outside,
and `make smoke` green.

### P4 — Backups off-host, before any real data

Create the bucket and a token scoped to it, set `BACKUP_REMOTES` to the off-host target **and**
`/backups/local`, then:

```bash
make backup-now
make backups            # the bundle is listed on every target
make restore-test       # fetch, decrypt, restore into a scratch Postgres, decrypt a credential
```

Then the drill that actually matters: on a **separate scratch host** that has never held the host key,
restore the bundle using the offline recovery key (`AGE_KEY=` plus `ADOPT_KEY=1`), exactly as
[Backup and restore](docs/operations/backup-restore.md) describes for disaster recovery.

**Gate:** a production bundle restored on a host that never had the host key — performed, not reasoned
about. This is the single most valuable hour in the whole plan.

### P5 — Make it visible, and prove the alerts

```bash
# .env: COMPOSE_PROFILES=monitoring,kuma  KUMA_ENABLED=on  ALERT_TELEGRAM_*
make up && make status
make smoke ONLY=09
```

Then fire one on purpose: stop both webhook processors, wait for `WebhookPoolDown` to arrive, start them
again, wait for the resolved message. An alert path that has never delivered is not an alert path.

**Gate:** a real alert received and resolved on this host; Uptime Kuma checking from outside the box;
`make doctor` with no `[FAIL]`.

### P6 — Prove it under load, then rehearse the bad days

```bash
make loadtest N=200 P=20          # sized to your expected peak, not to ours
make scale-workers N=<from the numbers>
make upgrade                      # one rehearsal while nothing real depends on it
make rollback                     # and the way back
```

Write the numbers into `n8n-kit-HANDOFF.md` (and `docs/sizing.md` when it exists — D-16). Set
`N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above the p99 execution duration you just measured.

**Gate:** your own load numbers recorded; one upgrade and one rollback performed on this host.

### P7 — Go live

Work the 11-step list in [Security → Before you give out the URL](docs/security.md). Then import the
workflows, give out the URL, and watch it for seven days: `make doctor` daily, the Sunday restore-test
report, the dashboards, and whether any alert is noise. Then settle into the rhythm:

| Cadence | Do |
|---|---|
| daily (first week, then on alert) | `make doctor`; skim failed executions |
| weekly | read the Sunday restore-test report; check disk and `docker system df` |
| monthly | `make upgrade` in a window, having read the n8n release notes; keep the rollback path open |
| quarterly | restore a bundle on a scratch host; `make chaos` on a **clone**, never on production |
| yearly | prove the offline recovery key still restores, from the password manager copy |

**Never on production:** `make chaos`, `make clean`, `make restore` without reading what it will replace,
or editing the repo over a Windows share (line endings and file modes both matter).

---

## 4. Readiness gates, as one checklist

Copy this into the go-live issue and tick it there.

**Hard gates — no production without these**

- [ ] TC-025: three outside testers completed the quickstart on their own host (M0's definition of done)
- [ ] Route A walked: a real public host with real Let's Encrypt, not an internal CA
- [ ] An off-host backup target verified by `make backup-now` plus `make backups` plus `make restore-test`
- [ ] A bundle restored on a host that never held the host key, using the offline recovery key
- [ ] `N8N_ENCRYPTION_KEY` and the recovery key read back out of the password manager
- [ ] One alert delivered **and** resolved on the production host
- [ ] `UI_PROTECT=on`, verified from outside `UI_ALLOW_CIDR`, with a production webhook still answering
- [ ] MFA on the owner account; test accounts and test API keys deleted
- [ ] `https://DOMAIN/metrics` returns 404 from outside
- [ ] Firewall: tcp 80, tcp 443, udp 443, SSH — nothing else
- [ ] One `make upgrade` plus `make rollback` rehearsed on this host
- [ ] `make doctor` with no `[FAIL]`, `make smoke` green

**Soft gates — go without them, but write down that you did**

- [ ] If the host is RHEL-family: the SELinux-enforcing plus firewalld path exercised on real hardware
- [ ] `make rotate-recovery-key` exists, or the manual rotation is written down in your own runbook
- [ ] Error Workflows on every workflow whose failure must not be silent
- [ ] Idempotency keys wherever a replay would double a side effect
- [ ] Load numbers from this host recorded, not inherited from the dev VM

---

## 5. The improvement ledger

This is the part that updates. The question "what should I improve next?" is answered by the score, not by
whatever is freshest in memory.

**Score = (Harm × Likelihood × Reach) ÷ Effort**

| Factor | 1 | 3 | 5 |
|---|---|---|---|
| **Harm** — what it costs when it goes wrong | cosmetic | a bad day, recoverable | unrecoverable data, credential or trust loss |
| **Likelihood** — that it bites within 90 days of go-live | unlikely | even odds | near certain |
| **Reach** — who it reaches (max 3) | only this operator | every operator who runs the kit | everyone whose workflows depend on it |
| **Effort** | under an hour | a working session | a milestone |

Bands: **≥ 20 blocker** (clear before production) · **8–19 next** · **< 8 later**.

| # | Improvement | H | L | R | E | Score | Band |
|---|---|---|---|---|---|---|---|
| D-2 | Raise `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above the measured p99 execution duration | 4 | 4 | 3 | 1 | **48** | blocker |
| D-1 | Test an off-host backup target end to end (bucket, token, `make backup-now`, `make restore-test`) | 5 | 3 | 3 | 1 | **45** | blocker |
| D-3 | `UI_PROTECT=on` with an allow-list and basic auth, verified from outside | 4 | 4 | 2 | 1 | **32** | blocker |
| D-4 | Prove the alert path on the production host (fire one, resolve it) | 4 | 4 | 2 | 1 | **32** | blocker |
| D-5 | `N8N_ENCRYPTION_KEY` and the recovery key in a password manager, read back once | 5 | 2 | 3 | 1 | **30** | blocker |
| D-6 | MFA on the owner account; delete test accounts and API keys | 5 | 3 | 2 | 1 | **30** | blocker |
| D-7 | DR drill: restore on a host that never held the host key (`AGE_KEY` plus `ADOPT_KEY=1`) | 5 | 3 | 3 | 2 | **22** | blocker |
| D-8 | Host hardening: firewall to 80/443/udp443 plus SSH, keys only, unattended upgrades | 5 | 4 | 2 | 2 | **20** | blocker |
| D-9 | Route A: real Let's Encrypt on a real public host (`acme-staging` first) | 4 | 5 | 2 | 2 | **20** | blocker |
| D-10 | If production is RHEL-family: SELinux-enforcing plus firewalld run on real hardware | 4 | 5 | 2 | 2 | **20** | blocker (conditional) |
| D-11 | `EXECUTIONS_TIMEOUT` from `-1` to a real ceiling | 3 | 3 | 2 | 1 | **18** | next |
| D-12 | An Error Workflow on every workflow whose failure must not be silent — the only hook that survives a killed worker | 4 | 3 | 3 | 2 | **18** | next |
| D-13 | TC-025: three outside testers walk the quickstart | 3 | 5 | 3 | 3 | **15** | next (and an M0 gate) |
| D-14 | Move the n8n pin to the current patch release (CI's upgrade drill tests the move) | 2 | 3 | 2 | 1 | **12** | next |
| D-15 | Idempotency keys wherever a replay would double a side effect | 4 | 3 | 3 | 3 | **12** | next |
| D-16 | `docs/sizing.md` — needs a second data point from a 4 vCPU host | 2 | 3 | 3 | 2 | **9** | next |
| D-17 | `make rotate-recovery-key` (today a detached recovery key can only be replaced by hand) | 4 | 2 | 2 | 2 | **8** | next |
| D-18 | A fresh Telegram bot token; `/revoke` the one exposed in a build chat | 2 | 3 | 1 | 1 | **6** | later |
| D-19 | Add `n8n_files` (and a decision on `n8n_data`) to the backup bundle | 3 | 2 | 2 | 2 | **6** | later |
| D-20 | Report the Postgres `NaN` query upstream | 1 | 3 | 2 | 1 | **6** | later |
| D-21 | A dedicated non-superuser Postgres role for n8n | 3 | 2 | 2 | 3 | **4** | later |
| D-22 | Pause the Bull queue during `make upgrade`'s drain to shorten downtime | 2 | 3 | 2 | 3 | **4** | later |
| D-23 | `make chaos` in the weekly workflow (too slow for per-PR) | 2 | 2 | 2 | 2 | **4** | later |
| D-24 | A `crash` scenario that SIGKILLs the container's host PID, to exercise `restart: unless-stopped` for real | 2 | 2 | 2 | 2 | **4** | later |
| D-25 | Grafana on its own hostname instead of sharing the n8n origin | 3 | 2 | 1 | 2 | **3** | later |

**What the table is saying:** seven of the ten blockers are an hour or less of work each, and five of them
are configuration rather than code. The cheapest meaningful improvement available is D-2 — one number in
`.env` — because the kit's one genuinely unrecoverable failure mode is a worker being cut off
mid-execution, and that number is the whole of the mitigation.

Scores are re-derived, not inherited: when the kit changes, Harm and Effort move. Shipping D-17, for
instance, lowers the effort behind D-5 and raises nothing.

---

## 6. When to update this file

| Trigger | Update |
|---|---|
| a new `make` target, or a changed one | §3 commands; §2 if it adds a knob |
| a new key in `compose/.env.example` | §2 — decide which of the three groups it belongs to |
| a finding in `warning_bug_and_solutions.md` or `n8n-kit-HANDOFF.md` §5 | §5 as a new scored row; §8 if it is a go-live risk |
| an item shipped | §5 — delete the row, and note it in §9 |
| an n8n major version | §2 "Do not change", §3 P6, and `docs/compat.md` |
| a decision in §1 answered | §1, and `n8n-kit-HANDOFF.md` §3 |
| this file older than the last release tag | re-read §2 against `.env.example` and §4 against `docs/security.md` |

---

## 7. What it costs

| Item | Rough |
|---|---|
| VPS, 2 vCPU / 8 GB, core stack only | 100–150k đ per month (or about €4–6) |
| VPS, 4 vCPU / 8 GB, with monitoring | roughly double |
| Domain | about 200k đ per year |
| Off-host backups (Cloudflare R2: 10 GB free tier, no egress fee) | 0 at this size |
| Telegram alerts | 0 |
| A second scratch host for the DR drill, for one hour | hourly billing, pennies |

The expensive resource is not money. It is the hour in P4.

---

## 8. Risks at go-live

| # | Risk | What actually happens | Mitigation |
|---|---|---|---|
| 1 | **A killed worker loses its in-flight executions** — upstream, not fixable here: n8n 2.0 removed Bull's stalled-job retry and hard-codes `maxStalledCount: 0` | executions on a worker that dies without a graceful shutdown end as `crashed` and are never retried. A `crashed` execution may already have performed its side effect | drain instead of killing (what `make upgrade` does), two or more workers, `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above p99, an Error Workflow, idempotent side effects. Measured in [Chaos drills](docs/operations/chaos-drills.md) |
| 2 | `docker kill` does not trigger `restart: unless-stopped` | a container you killed by hand stays dead and looks like the kit failed to recover | `make up` brings it back; the drills document the distinction |
| 3 | The encryption key is lost | the database restores and every stored credential is undecryptable | the key is inside every bundle, encrypted to two age recipients, and in a password manager you have read back |
| 4 | DNS wrong on the first real ACME run | Let's Encrypt rate-limits the hostname for days | `TLS_MODE=acme-staging` first; `make preflight` compares DNS to the host's address |
| 5 | A backup target silently stops working | you discover it the day you need it | a backup counts as successful only when **every** target succeeded; `BackupMissing` and the weekly restore test both alert |
| 6 | Disk fills | Postgres stops, and so does everything else | `DiskHigh` at 80 %, execution pruning on, `PROM_RETENTION` and `LOKI_RETENTION` set |
| 7 | `make rollback` does not undo everything | the `n8n_data` volume, third-party webhook registrations and Uptime Kuma are not rolled back | listed under "Not covered" in [Upgrade and rollback](docs/operations/upgrade-rollback.md); read it before the first production upgrade |
| 8 | n8n connects to Postgres as the bootstrap superuser | a live restore runs with more privilege than it needs | the key check and the `ADOPT_KEY` comparison guard the destructive path today; D-21 fixes it properly |

---

## 9. Plan changelog

| Date | Change |
|---|---|
| 2026-10-10 | Created and parked at kit v0.1.0 (n8n 2.42.4). Dev/test is the current phase and `docs/runbook.md` is the thing being worked. §5 seeded with 25 scored items from `n8n-kit-HANDOFF.md` §2 and §5, `warning_bug_and_solutions.md`, and `docs/security.md`. |
