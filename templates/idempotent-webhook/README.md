# `idempotent-webhook` — do the work once, no matter how often it is delivered

A webhook that charges a card, sends a Zalo message or appends a row **must not do it twice** when the same
delivery arrives again. It will arrive again: senders retry on a timeout even when the work succeeded, a
killed worker leaves executions that n8n never retries, and "Retry execution" in the editor is one click.

This template puts a claim in front of the work. Postgres decides who claimed a key first, so the decision
holds even when two deliveries land in the same millisecond on two different workers.

Why each piece is the way it is — and the measured limits of the alternatives — is in
[docs/operations/idempotency.md](../../docs/operations/idempotency.md). This page is how to run it.

## The flow

```
Webhook → Idempotency key → Claim the key → First time? ─true→ Do the work → Mark the key done → Answer the caller
                                                         └false→ Replay, wait, or alert
```

| Node | What it is for |
|---|---|
| **Idempotency key** | Reads the key from the `Idempotency-Key` header, or `idempotencyKey` / `orderId` in the body. **Refuses the request** when there is none, and rejects a key over 200 characters instead of truncating it (two keys that differ only after the cut would collide, and a collision silently skips somebody's work as a duplicate). |
| **Claim the key** | One `INSERT … ON CONFLICT DO UPDATE … RETURNING` that both claims the key and reports who holds it. Returns exactly one row with a `route` of `first`, `replay`, `in_flight` or `stale`. |
| **First time?** | `route == 'first'` — the only path to the work. |
| **Do the work** | **Replace this node.** The placeholder is an HTTP POST to `https://api.example.com/charge` that forwards the same key as an `Idempotency-Key` header. |
| **Mark the key done** | Completes the lease and stores what to answer on every later delivery. |
| **Answer the caller** | Confirms the ledger write landed; raises if it did not, rather than answering 200 for work nothing will remember. |
| **Replay, wait, or alert** | `replay` → answers with the stored result. `in_flight` → raises, so the caller retries and gets the result once it exists. `stale` → raises, because a lease that was claimed and never completed is a job for a human, not for a guess. |

The four routes, and the answer the caller gets:

| `route` | Means | Caller sees |
|---|---|---|
| `first` | nobody had this key; this execution owns it | `200` `{outcome: "done", result: …}` |
| `replay` | the first execution finished | `200` `{outcome: "duplicate", result: …}` — the *same* result |
| `in_flight` | somebody else holds the lease and is still inside it | `500` — retry; by then it is `replay` |
| `stale` | claimed over `LEASE_SECONDS` ago and never completed | `500` + the Error Workflow fires |

`stale` is the honest case. The work may or may not have happened — a crashed execution can die *after* its
side effect — and this template refuses to decide that for you. Reconcile, then delete the row to allow a
retry. The lease is 900 s, as the `900` in the **Claim the key** node's Query Parameters; make it longer than
the slowest run of the work, or an execution still running will be declared stale.

## Set it up

1. **Create the ledger and its role** (once). From the repository root:

   ```bash
   read -rsp 'password for the n8n_idem role: ' pw && echo
   { printf "\\set idem_password '%s'\n" "${pw}"; cat templates/idempotent-webhook/schema.sql; } \
     | ( cd compose && docker compose --env-file versions.env --env-file .env \
           exec -T postgres psql -U n8n -d n8n -v ON_ERROR_STOP=1 )
   unset pw
   ```

   The password goes in on **stdin**: on a command line it would be readable by every user on the host in
   `/proc/<pid>/cmdline`. Re-running the file is safe, and re-running it with a new password is how you
   rotate one.

2. **Add one Postgres credential** in n8n — host `postgres`, port `5432`, database `n8n`, user `n8n_idem`,
   the password from step 1, SSL off (the connection never leaves the internal Docker network).

   Use `n8n_idem`, **not** `n8n`. The `n8n` role is the database's bootstrap superuser, and a credential
   holding it lets any workflow on the instance read every stored credential and drop n8n's own tables.
   `n8n_idem` can claim and complete keys in one table and do nothing else.

3. **Import** `workflow.json` (*Workflows → ⋯ → Import from File*), pick that credential on both Postgres
   nodes, set the webhook **Path**, replace **Do the work**, and point *Settings → Error Workflow* at the
   [`error-handler`](../error-handler/) template — `stale` is only useful if it reaches you.

4. **Publish it**, then try it twice with the same key:

   ```bash
   curl -sS -X POST https://n8n.example.com/webhook/<your-path> \
     -H 'Content-Type: application/json' -H 'Idempotency-Key: order-1001' \
     --data @templates/idempotent-webhook/test-payload.json
   # again, same key → {"outcome":"duplicate", …} and the work does not run a second time
   ```

## Decisions worth knowing before you edit it

- **The Postgres nodes are pinned to `typeVersion` 2.8.** Before 2.8 the node split a Query Parameters
  expression on commas, so a key like `order,1001` became *two* bind values and the query failed — or worse,
  bound the wrong value. 2.8 is the default in n8n 2.46.7; if you rebuild these nodes by hand in an older
  editor, check the version badge.
- **Keys are bound as `$1`/`$2`, never pasted into the SQL.** The key is caller-supplied input; these two
  nodes are the only place in the template where it touches SQL.
- **Query Batching is `independently`.** The default, "Single Query", collapses a batch of input items into
  one call and returns one result for all of them — every item of a batch would get the same `route`.
- **`Do the work` retries 3 times.** That is safe *only* because the same `Idempotency-Key` goes with every
  try. Against a remote that ignores the header, set **Max Tries** to 1 and let the caller's retry come back
  through the gate instead.
- **`Mark the key done` has "Always Output Data" on.** Its `UPDATE` matches 0 rows if the lease is not this
  execution's. Without the setting the branch would end on an empty output and the caller would be told
  nothing at all; with it, **Answer the caller** sees the empty row and raises.
- **Ownership is a column, not `xmax = 0`.** The usual trick for "did my `INSERT` create this row" reads
  Postgres' internal `xmax`, which is folklore rather than a documented contract. Here the row records the
  execution that inserted it, and `owner = $2` is the test.

## Keep the table from growing forever

One row per key, kept forever. Expire what is older than your senders' retry window (days, not months) —
as the owner, not from a workflow, which is why the `n8n_idem` role has no `DELETE`:

```sql
DELETE FROM idempotency_keys WHERE state = 'done' AND claimed_at < now() - interval '30 days';
```

Leases that were claimed and never completed are the ones to look at, not to delete:

```sql
SELECT key, owner, claimed_at FROM idempotency_keys WHERE state = 'in_progress' ORDER BY claimed_at;
```

## Tested

`tests/smoke/11-idempotency.sh` imports **this** `workflow.json` on every CI run, fires the same key at it
20 times at once through the webhook pool, and asserts the work happened exactly once — then fires a second
key and asserts it was not blocked.
