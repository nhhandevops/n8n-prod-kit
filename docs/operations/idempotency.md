# Idempotency — doing the work once

Some workflows can run twice with no harm done. The ones that move money, send messages or create records
cannot. This page is about making the second delivery of the same work a no-op, and about the one case where
no automatic answer is correct.

The rule in one line: **let the database decide who is first, and key the decision on the intent rather than
on the delivery.** Everything below is a consequence of that.

The kit ships this as a template — [`templates/idempotent-webhook/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/idempotent-webhook)
— with a ledger schema, a least-privileged database role and a smoke test that fires one key at it twenty
times at once. That folder's README is the setup guide; this page is why it looks like that.

---

## Why the same work arrives twice

Not one of these is exotic. On a stack that runs for a month, most of them happen.

| Cause | What it looks like |
|---|---|
| **The sender retried** | Your endpoint took 31 s, the caller's timeout was 30 s, so it sent again. A timeout tells the sender *nothing* about whether the work happened — retrying is the only responsible thing it can do. |
| **A worker was killed** | n8n 2.x does not retry an execution that was in flight when its worker died; it ends as `crashed` and stays there ([chaos drills](chaos-drills.md)). Re-driving those inputs is a manual decision, and the only sane way to take it is to make the replay harmless. |
| **A `crashed` execution already did the work** | Measured in this kit's own drill: 112 successes, 8 crashed, **114** side-effect files. Two executions wrote their file and were killed before being marked done. `crashed` means *n8n does not know*, not *nothing happened*. |
| **Somebody clicked "Retry execution"** | One click in the editor. It is a new execution with a new id, running the same payload. |
| **Node-level retry** | `retryOnFail` re-sends an HTTP request whose *response* was lost. The remote may well have processed the first one. |
| **A rollback** | `make rollback` restores the pre-upgrade database ([upgrade and rollback](upgrade-rollback.md)). Executions recorded after that backup are gone from n8n's history — and if the ledger lives in the same database, from the ledger too. |

What is **not** on that list, in this kit: the queue. n8n 2.x hard-codes Bull's `maxStalledCount: 0`, so a
stalled job is failed rather than redelivered — the kit's queue is at-most-once, not at-least-once. The
duplicate pressure comes from the senders and from operators, not from Valkey.

---

## The key names the intent, not the delivery

A key identifies *one thing that should happen once*: this order, this payment, this invoice. Two deliveries
of that thing must produce the same key; a genuinely new thing must never reuse one.

**Where to get it**, best first:

1. **The caller's `Idempotency-Key` header.** The convention payment APIs use, and the only source that knows
   a retry is a retry.
2. **A stable business id from the payload** — `orderId`, `invoiceNo`, `paymentRef`. Good, as long as the
   sender really does reuse it on a retry.
3. **A hash of the fields that define the intent.** Last resort: see the trap below.

**What not to use** — each of these looks like a key and silently disables the gate:

| Not a key | What goes wrong |
|---|---|
| `crypto.randomUUID()`, `Date.now()`, `$execution.id` | Every delivery gets its own key, every key is new, every delivery does the work. The gate still runs, the ledger still fills up, nothing is ever deduplicated. This is the usual way the pattern is got wrong. |
| A hash of the **whole** payload | Two legitimately identical requests — the same customer ordering the same coffee twice — collapse into one. The second order is silently dropped, which is the opposite failure and much harder to notice. |
| A truncated key | Two keys that differ only after the cut collide, and one caller's work is skipped as somebody else's duplicate. Reject an over-long key instead; the template does. |

The two failure directions are worth naming, because the fix for one is the cause of the other: a key that is
**too unique** duplicates work, and a key that is **too coarse** loses it.

---

## Why "check, then act" is not a gate

The obvious shape — a `SELECT` to see whether the key is known, an `IF`, then the work — is a race, not a
gate:

```
execution A: SELECT ... WHERE key = 'order-1001'  -> no rows
execution B: SELECT ... WHERE key = 'order-1001'  -> no rows      <-- A has not inserted yet
execution A: charge the card
execution B: charge the card
```

With two workers at concurrency 10, this kit runs up to twenty executions at once; the window between the
`SELECT` and the `INSERT` is wide open. The fix is not a shorter window — it is to stop asking and let the
`PRIMARY KEY` answer:

```sql
INSERT INTO idempotency_keys (key, owner)
VALUES ($1, $2)
ON CONFLICT (key) DO UPDATE SET key = idempotency_keys.key
RETURNING (owner = $2) AS claimed, state, result, claimed_at;
```

One statement, exactly one row, every time. `ON CONFLICT … DO UPDATE` takes a row lock, so a second delivery
arriving in the same millisecond **waits** for the first to commit and then reads what it committed, instead
of also inserting. `owner` is written on insert and never changed, so `owner = $2` is "this execution claimed
it" — no need for the `xmax = 0` trick, which reads a Postgres internal rather than a documented contract.

`DO NOTHING` would be wrong here. On a conflict it returns **zero** rows — which the Postgres node at
`typeVersion` 2.8 turns into a single `{success: true}` item for a non-`SELECT` query. That item looks like
success, carries no `route`, and would send the delivery down whichever branch the `IF` node's type validation
happens to choose. The loser of a true tie also cannot *see* the winner's uncommitted row, so `DO NOTHING`
cannot tell "somebody else has it" from "nobody has it" at all.

---

## Where to keep the ledger

Three stores are available on a stack this kit builds. They are not equivalent.

| | Postgres table | Valkey `INCR` | "Remove Duplicates" node |
|---|---|---|---|
| Atomic under concurrency | **yes** — one `INSERT`, the index decides | **yes** — `INCR` returns 1 to exactly one caller | **no** (below) |
| Survives a restart | yes | at most 1 s lost (`appendfsync everysec`) | yes |
| In `make backup-now` | **yes** — it is in n8n's database | **no** | yes |
| Bounded history | no, you set retention | TTL per key | **yes — and it stops working at the limit** |
| Setup | a table, a role, one credential | one credential | none |
| Good for | anything that costs money | a short dedupe window, seconds to hours | a single-worker flow where a duplicate is an annoyance |

**The Postgres table is the kit's recommendation**, for one reason beyond atomicity: it lives in n8n's own
database, so every ledger row is carried by the backup, the restore and the DR drill this kit already proves
([backup and restore](backup-restore.md)). The rows, not the plumbing — a restore brings the table back
*without* its grants, and a rebuilt host has no ledger role at all. See *What a restore does to the ledger*
below; it is two commands, but it is not nothing.

### The built-in "Remove Duplicates" node is not a gate

n8n ships *Remove Duplicates → Remove Items Processed in Previous Executions*, which looks exactly like what
this page is about. It is genuinely useful — and it is not safe for a side effect that costs something. Both
reasons below were **measured** on this kit's stack (n8n 2.46.7, 2 workers × concurrency 10) and then traced to
the source, rather than reasoned about.

- **It deduplicates — until two deliveries race.** Delivered one after another, a repeated key is correctly
  skipped. Delivered **20 at once, 1 of 5 bursts did the work twice.** The store is one row per
  workflow-and-context in the `processed_data` table (`PRIMARY KEY (workflowId, context)`) holding the seen keys
  as a JSON list; the helper reads that row, compares in memory and writes the whole list back — `findOne` …
  `update`, with no transaction, no row lock and no unique constraint on the value
  (`packages/cli/src/deduplication/deduplication-helper.ts`). Two executions that check the same key before
  either writes both see it as new: the same check-then-act race as above, one layer down. Occasionally correct
  is the dangerous kind of wrong — it works in testing and fails on the busy day.
- **`historySize` is a hard ceiling, not a sliding window.** Past the limit the node does not forget the oldest
  key; it **refuses to run at all**. `RemoveDuplicatesV2.node.ts` checks
  `currentProcessedDataCount + items.length > maxEntriesNum` *before* recording anything and throws *"The number
  of items to be processed exceeds the maximum history size. Please increase the history size or reduce the
  number of items to be processed."* Measured with `historySize: 2`: once two keys were stored, **every** later
  delivery failed with HTTP 500 and nothing was recorded — including keys the node had never seen. At the
  default of 10 000 the workflow works for 10 000 distinct keys and then stops on the 10 001st, until somebody
  raises the limit or runs *Clear Deduplication History* — and clearing it is exactly what re-opens the replay
  window. The
  editor hints at it from half capacity: *"Some duplicates may be not be removed since you're approaching the
  maximum history size."*

Use it to stop reprocessing rows from a spreadsheet or a feed, where a duplicate is an annoyance and a stalled
workflow is obvious. Do not use it to stop charging a card twice.

### Valkey, in this kit's configuration

The broker runs `--appendonly yes --appendfsync everysec --maxmemory 256mb --maxmemory-policy noeviction`, so
a key is durable to within a second and is never evicted to make room. Two things to know before using it as
a ledger: it is **not** in the backup, and it shares those 256 MB with the queue — `noeviction` means a full
broker starts refusing writes, which is a queue outage, not a dedupe outage. Also, n8n's Redis node (still
version 1) has **no `SET NX`**: `INCR` with a TTL is the only atomic claim it can make, and `== 1` means you
are first.

---

## The lease, and the one case nobody can decide for you

A claim is not a completion. Between them the work is running, and that gap is where the interesting states
live. The template's claim query reports one of four:

| `route` | State of the key | What happens |
|---|---|---|
| `first` | nobody had it | do the work, then complete the lease |
| `replay` | completed earlier | answer with the stored result, do nothing else |
| `in_flight` | claimed recently, not completed | refuse with a 5xx — the caller retries and gets the result once it exists, *if* the claimer finishes |
| `stale` | claimed longer ago than the lease, never completed | **refuse and alert** |

`stale` is the honest case, and the reason this template does not try to be clever. The lease holder claimed
the key and never came back — which is exactly what a killed worker leaves behind. Whether the work happened
is **not knowable from the ledger**: a crashed execution may have died before its side effect or after it
(measured above). So neither automatic answer is safe. Redoing it may double a payment; skipping it may lose
an order. The template raises, the Error Workflow alerts
([error workflows](error-workflows.md), and the kit ships a handler in `templates/error-handler/`), and a
human reconciles against the downstream system before deleting the row to allow a retry.

**Size the lease above the slowest run of the work**, not above the average: an execution that is still
running when the lease expires gets declared stale and will be alerted on. The template uses 900 s.

Two consequences of that table to know before you run it in anger.

**A failed execution leaves a lease behind exactly like a killed one does.** The claim commits before the
work starts — it has to, that is the whole point — so if the thing you call is down and the work node
exhausts its retries, the key stays `in_progress`. Every delivery for the rest of the lease is then refused
as `in_flight`, and no `replay` ever comes, because nothing completed it; after the lease it is `stale`, with
the same reconcile and the same owner-run `DELETE` to re-open the key. During a downstream outage, that is
the shape of your backlog.

**All three refusals fail the execution, so all three reach the Error Workflow** — not only `stale`. On a
concurrent burst that is one alert per racing delivery (the kit measured 4 in-flight refusals in a 20-wide
burst), plus one for every keyless request anybody sends you. If only `stale` should page a human, filter in
the handler: `stale` is the message containing `never completed`. Alerting on all of them is defensible too,
as long as it is a choice rather than a surprise.

The best way to need this rarely is to not lose the lease holder in the first place: drain workers instead of
killing them (`N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above your p99, which is what `make upgrade` does) — see
[chaos drills](chaos-drills.md).

---

## Operating the ledger

**Hand the key downstream.** If the remote system honours an `Idempotency-Key` header, forward the same key
(the template does). Your gate stops a replay from reaching it at all; the header covers the one case your
gate cannot see — a retry *inside* one execution, after a response was lost.

**Retention.** One row per key, kept forever unless you delete it. Keep them for longer than the longest
retry window of any sender, measured in days, and expire the rest:

```sql
DELETE FROM idempotency_keys WHERE state = 'done' AND claimed_at < now() - interval '30 days';
```

Run that as the table's owner. The role the workflow holds deliberately has no `DELETE` — a workflow that can
delete ledger rows can replay a payment.

**Watch for leases that never completed.** This is the queue of things a human owes an answer to:

```sql
SELECT key, owner, claimed_at, now() - claimed_at AS age
FROM idempotency_keys WHERE state = 'in_progress' ORDER BY claimed_at;
```

Empty is the normal answer. A handful of rows after an incident is expected; a steadily growing count means
executions are dying between claim and completion.

**What a restore does to the ledger.** Two separate things, and the second one surprises people.

*The rows move back in time.* Because the ledger is in n8n's database, `make restore` and a migration-mode
`make rollback` rewind it with everything else. A key recorded after the backup is gone, so the same delivery
can be accepted again — correct if the downstream work was also rolled back, a duplicate if it was not. After
restoring a stack that charges money, reconcile against the downstream system before re-opening the endpoint
to traffic.

*The grants do not come back at all.* `make restore` rebuilds the database with
`pg_restore --no-owner --no-privileges` (`compose/backup/restore.sh`), so the table and its rows return while
every `GRANT` on it is dropped — and on a rebuilt host the `n8n_idem` role does not exist in the first place,
because roles live in the cluster rather than in the dump. The ledger then looks fine and every delivery
answers 500 with `permission denied for table idempotency_keys`, or fails to authenticate at all. **Re-run
`templates/idempotent-webhook/schema.sql` with the same password after any restore, migration-mode rollback,
or host rebuild** — it is written to be safe to re-run, and it is the whole fix. Put it next to
`make detach-recovery-key` in your own rebuild checklist; the kit's is in
[rebuild a host](rebuild-vps.md).

**Use a least-privileged role.** `POSTGRES_USER` (`n8n`) is the database's bootstrap superuser. A credential
holding it gives every workflow on the instance — and anyone who can edit one — the ability to read every
stored credential and drop n8n's tables. The shipped schema creates `n8n_idem`, which can claim and complete
keys in one table and nothing else.

---

## What this kit actually proves

`tests/smoke/11-idempotency.sh` runs on every CI run, against a real stack with the webhook pool, the queue
and two workers. It imports the shipped template, creates the ledger from the shipped `schema.sql`, and
asserts:

- one key delivered **20 times at once** does the work **exactly once** (the burst matches the stack's full
  concurrency: `WORKER_CONCURRENCY` 10 × 2 workers);
- the ledger ends with one row for that key, `done`, owned by the execution that claimed it, with a result
  stored;
- a later delivery of the same key answers `duplicate` with that stored result and does **not** do the work
  again;
- a **different** key is accepted and does the work — the gate deduplicates keys, not traffic;
- a delivery with no key at all is refused;
- a planted lease that is young is refused as `in_flight`, and one claimed an hour ago is refused as `stale`
  with a message that asks for a human;
- the ledger role may insert and update its own table, may not delete from it, and may not read
  `credentials_entity`.

What it deliberately does not assert: that the race *fails* without the gate. A race that reproduces once in
five tries cannot be a CI assertion — it would be a flaky test. That measurement was taken by hand on
`n8nvm` (2026-11-12) and is recorded here and in the bug log instead.

---

## See also

- [`templates/idempotent-webhook/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/idempotent-webhook) — the workflow, the schema, the setup
- [Chaos drills](chaos-drills.md) — what a killed worker costs, measured
- [Error workflows](error-workflows.md) — how `stale` reaches you
- [Backup and restore](backup-restore.md) — what the ledger rides along with
- [Configuration](../configuration.md) — `WORKER_CONCURRENCY`, `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`
