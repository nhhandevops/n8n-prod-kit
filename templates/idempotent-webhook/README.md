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
| `in_flight` | somebody else holds the lease and is still inside it | `500` — retry; by then it is `replay`… |
| `stale` | claimed over `LEASE_SECONDS` ago and never completed | `500`, and a human has to look |

…**unless that execution failed.** The claim is committed before the work starts, so an execution that dies
in `Do the work` leaves the lease behind: the key is then refused as `in_flight` for the rest of the lease —
`replay` never comes, because nothing completed it — and after that as `stale`. Same reconcile, same
owner-run `DELETE` to re-open the key. Expect this whenever the thing you call has an outage.

**All three refusals fail the execution, so all three reach the Error Workflow** — not just `stale`. On a
burst, that is one alert per concurrent delivery (the kit measured 4 in-flight refusals in a 20-wide burst),
plus one for every keyless request anybody sends you. If only `stale` should page you, filter in the handler:
the `stale` message is the one containing `never completed`.

`stale` is the honest case. The work may or may not have happened — a crashed execution can die *after* its
side effect — and this template refuses to decide that for you. Reconcile, then delete the row to allow a
retry. The lease is 900 s, as the `900` in the **Claim the key** node's Query Parameters; make it longer than
the slowest run of the work, or an execution still running will be declared stale.

## Set it up

1. **Create the ledger and its role** (once). From the repository root:

   ```bash
   read -rsp 'password for the n8n_idem role: ' pw && echo
   esc=${pw//\\/\\\\}; esc=${esc//\'/\'\'}
   { printf "\\set idem_password '%s'\n" "${esc}"; cat templates/idempotent-webhook/schema.sql; } \
     | ( cd compose && docker compose --env-file versions.env --env-file .env \
           exec -T postgres psql -U n8n -d n8n -v ON_ERROR_STOP=1 )
   unset pw esc
   ```

   The password goes in on **stdin**: on a command line it would be readable by every user on the host in
   `/proc/<pid>/cmdline`. The `esc=` line escapes backslashes and single quotes for psql's `\set` lexer,
   which otherwise eats a `\` and ends the value at a `'` — storing a password that is not the one you typed,
   with `password authentication failed for user "n8n_idem"` as the only symptom. Re-running the file is
   safe, and re-running it with a new password is how you rotate one.

2. **Add one Postgres credential** in n8n — host `postgres`, port `5432`, database `n8n`, user `n8n_idem`,
   the password from step 1, SSL off (the connection never leaves the internal Docker network).

   Use `n8n_idem`, **not** `n8n`. The `n8n` role is the database's bootstrap superuser, and a credential
   holding it lets any workflow on the instance read every stored credential and drop n8n's own tables.
   `n8n_idem` can read the ledger, insert a claim, and write `state`/`result`/`done_at` — `UPDATE` is granted
   per column, so it cannot rewrite a `key` or an `owner`, cannot `DELETE`, and cannot touch anything else in
   the database. What it can still do is complete *any* key in that one table, so treat the credential as
   shared by every workflow you hand it to.

3. **Import** `workflow.json` (*Workflows → ⋯ → Import from File*), pick that credential on both Postgres
   nodes, set the webhook **Path**, replace **Do the work**, and point *Settings → Error Workflow* at the
   [`error-handler`](../error-handler/) template — `stale` is only useful if it reaches you.

   **The editor's import applies the file's nodes and connections, not its `settings`** (verified in the
   2.46.7 editor: `importWorkflowData()` never reads that key). So the shipped `executionTimeout: 300` is
   dropped on this path and the instance default applies — `EXECUTIONS_TIMEOUT=3600` in this kit's
   `.env.example`, i.e. an hour during which a hung call holds its lease. Set *Settings → Timeout Workflow*
   to 300 s by hand after importing, and keep a request timeout on whatever replaces **Do the work**.
   Importing with `POST /api/v1/workflows` instead does keep `settings` — which is why the smoke test, which
   does exactly that, cannot catch this for you.

4. **Publish it**, then try it twice with the same key:

   ```bash
   curl -sS -X POST https://n8n.example.com/webhook/<your-path> \
     -H 'Content-Type: application/json' -H 'Idempotency-Key: order-1001' \
     --data @templates/idempotent-webhook/test-payload.json
   # again, same key → {"outcome":"duplicate", …} and the work does not run a second time
   ```

## Decisions worth knowing before you edit it

- **The Postgres nodes are pinned to `typeVersion` 2.8**, the default in n8n 2.46.7. What 2.8 fixes is
  parameter binding: a single expression yields exactly one bind value, and a missing element becomes SQL
  `NULL` instead of shifting every later parameter one place left. The template's array form
  (`={{ [ $json.key, $json.owner, 900 ] }}`) is bound element-wise from 2.5 on, so it is not exposed to the
  older comma split — that one bites a Query Parameters expression resolving to a *string*, where a key like
  `order,1001` becomes two bind values. If you rebuild these nodes by hand in an older editor, check the
  version badge and keep the array form.
- **Keys are bound as `$1`/`$2`, never pasted into the SQL.** The key is caller-supplied input; these two
  nodes are the only place in the template where it touches SQL.
- **Query Batching is `independently`.** The default, "Single Query", concatenates every input item's
  statement into one call and therefore one implicit transaction: a single failing claim rolls the others
  back, and no claim is visible to another worker until the whole batch commits. `independently` gives each
  item its own statement, its own transaction and its own `route`. It makes no difference to the shipped
  template, which handles one intent per execution — the **Idempotency key** node reads
  `$input.first().json` — but it is the right setting to find here if you adapt the gate to a batch, and that
  adaptation means changing that Code node too.
- **`Do the work` retries 3 times.** That is safe *only* because the same `Idempotency-Key` goes with every
  try. Against a remote that ignores the header, switch **Retry On Fail** *off* and let the caller's retry come
  back through the gate instead — lowering **Max Tries** does not do it. n8n clamps the value
  (`Math.max(2, maxTries || 3)` in `workflow-execute.ts`, and the editor's own minimum is 2), so a node with
  `retryOnFail: true` sends the work at least twice however you set it. Only the toggle disables retrying.
- **The 0-row case is caught in `Answer the caller`, not by a checkbox.** `Mark the key done`'s `UPDATE`
  matches no rows if the lease is not this execution's. At `typeVersion` 2.8 the node does not go quiet on
  that: it emits one `{success: true}` item (`utils.ts` substitutes it for an empty result on a non-`SELECT`
  query), which carries no `state` — so the guard that matters is `row.state !== 'done'` in the next node,
  which raises rather than answering 200 for work nothing will remember. "Always Output Data" is left on only
  in case a future node version stops substituting that item; it is not what catches the 0-row case today,
  and every version this kit has shipped against substitutes it (`utils.ts`, both the `< 2.3` and the current
  branch).
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

## After a restore, re-run `schema.sql`

`make restore` and a migration-mode `make rollback` rebuild the database with
`pg_restore --no-owner --no-privileges`, so the ledger's **rows** come back and its **grants** do not; on a
rebuilt host the `n8n_idem` role does not exist at all. The symptom is every delivery answering 500, with
`permission denied for table idempotency_keys` in the execution — or an authentication failure on a new host.
Re-run this folder's `schema.sql` with the same password (it is written to be safe to re-run) and the
credential works again. [Idempotency](../../docs/operations/idempotency.md) has the rest of what a restore
does to a ledger.
