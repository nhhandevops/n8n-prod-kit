# Forms n8n hosts for you

A Form Trigger turns a workflow into a public web form. No website, no hosting, no deploy step when you add
a field — n8n serves the page, and the submission starts an execution. For a small business taking orders or
booking appointments, it is the shortest distance between "we need a form" and a working one, and the kit
ships a worked example:
[`templates/form-order-intake/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/form-order-intake),
the only template here that needs **no credential of any kind**.

It is also the n8n feature whose behaviour is least like what the editor suggests. Four things are worth
knowing before you put one in front of customers; all four are measured on this kit's stack against the
pinned n8n (2.46.7), and the last one is the only one with an operational cost.

---

## A submission travels two routes, not one

The kit's Caddyfile has sent `/form/*` and `/form-waiting/*` to the webhook pool since S2, and both are on
the path of a **single** submission:

```
GET  /form/<path>                         → the page the customer fills in
POST /form/<path>                         → {"formWaitingUrl": ".../form-waiting/<execution id>?signature=<token>"}
GET  /form-waiting/<id>?signature=<token> → the page the customer reads back
```

The POST does **not** answer with the page. It answers with a 138-byte JSON envelope naming the URL where
the page will be, and the form's own JavaScript follows it. So:

- **Both routes must reach the webhook pool.** Only `/form/*` is the obvious one; a reverse proxy that routes
  `/form/*` and forgets `/form-waiting/*` gives you a form that accepts an order and then shows the customer
  nothing. `tests/smoke/04-webhook-routing.sh` asserts both, and `15-form-order-intake.sh` drives both.
- **A test that stops at the POST has tested half the flow.** Ours did, and passed, while the confirmation
  page was never fetched.

### Posting to a form directly

If something other than a browser submits — a mobile app, a partner's system, a test — two rules apply, both
from the node's own source rather than from the docs:

- **It must be `multipart/form-data`.** The Form Trigger asserts the content type outright
  (`nodes/Form/utils/utils.ts`) and refuses anything else, JSON included.
- **The keys are positional**: `field-0`, `field-1`, … in the order the fields appear in the node, *not* the
  field names. Reordering the fields in the editor is therefore a **breaking change** for every direct
  caller, and nothing warns you.

```bash
curl -sS -X POST https://n8n.example.com/form/dat-hang \
  -F 'field-0=Nguyen Thi Mai' -F 'field-1=0901234567' -F 'field-2=Ca phe sua da' -F 'field-3=2'
# -> {"formWaitingUrl":"https://n8n.example.com/form-waiting/3361?signature=6faa93…"}
```

## The path is an option, not a field

**At node version 2.2 and later, a Form Trigger's path lives in *Options → Path*.** Set at the top level —
where older workflows kept it, and where a hand-written `workflow.json` naturally puts it — it is **silently
ignored**.

`FormTriggerV2` declares the top-level `path` property only for `@version <= 2.1`, and the webhook's path is
resolved as:

```
$parameter["path"] || $parameter["options"]?.path || $webhookId
```

A stored key the node's current version does not declare is invisible to `$parameter`, so at 2.6 the first
term is always empty, the second is where your path has to be, and a workflow carrying only a top-level path
falls through to the third. The form is then served at `/form/<a uuid>` — a URL nobody has.

**The symptom** is a `404` at your own path, with
`The requested webhook "GET dat-hang" is not registered` in a webhook container's log, while
`select "webhookPath" from webhook_entity` shows a UUID. If you see that, look at *Options* before anything
else: the kit's own template shipped this way, and three rounds of plausible hypotheses were tested and
disproved before someone read the property declarations.

## The page is served only once the execution parks

A completion page is rendered from whatever the workflow ended on, which means the page cannot exist until
the execution has got there. A `GET` of the `formWaitingUrl` **before** that point does not 404 — it
**blocks**, and your client times out. The form's own JavaScript polls; anything else must too.

This matters for tests and for health checks. `curl --max-time 10` against a waiting URL returns `000`, which
reads like a TLS or DNS failure and is neither.

## The cost of a completion page

A Form Ending node (the **Form** node's *completion* operation) ends the workflow by **parking its execution
for ever**:

```
status  = waiting
waitTill = 3000-01-01 00:00:00+00     ← n8n's wait-indefinitely sentinel
```

Nothing resumes it. Serving the page does not; the workflow's own `executionTimeout` does not (measured: a
template with `executionTimeout: 120` was still parked 140 s later, because an execution timeout is computed
per *job* and a parked execution is not a running job); a restart does not.

And **pruning never removes it.** From the pinned image's own compiled
`@n8n/db/dist/repositories/execution.repository.js`:

```js
.set({ deletedAt: () => dbNowLiteral(isPostgres) })
.where({
  deletedAt: IsNull(),
  status: Not(In(['new', 'running', 'waiting'])),   // ← parked executions are never soft-deleted
})
```

That exclusion is deliberate and correct — an approval link must not be pruned out from under the person
holding it ([Approvals](approvals.md)). The consequence for forms is that **every submission leaves a row
that nothing will ever delete**, and there is one more turn of the screw. The count-based prune picks its
cutoff like this:

```js
const countCutoff = this.createQueryBuilder('execution')
  .select('execution.id')
  .where('execution.id NOT IN ' + annotatedExecutionsSubQuery.getQuery())
  .orderBy('execution.id', 'DESC')
  .offset(pruneDataMaxCount)       // ← no status filter: parked rows are counted
  .limit(1);
```

There is no status filter on the cutoff. Parked executions **occupy slots in
`EXECUTIONS_DATA_PRUNE_MAX_COUNT`** (10 000 in this kit) while being exempt from deletion themselves — so a
busy form shortens the execution history of **every other workflow on the instance**. A form taking 300
orders a day eats the whole 10 000-row budget in five weeks, and the first thing you notice is that
yesterday's failed invoice run is no longer in the list.

**What one submission costs**, measured on this stack with the shipped template:

| | bytes |
|---|---|
| `execution_data.data` — the run itself | 1 694 |
| `execution_data."workflowData"` — the copy of the workflow kept with every execution | 3 607 |
| **total per submission** | **5 301** |

10 000 of them is **51 MB** of `execution_data`, plus the `execution_entity` row and its indexes, in every
backup, for ever. The `workflowData` copy is two thirds of it and grows with the workflow, not with the order.

### The sweep

Parked form executions are safe to delete: nothing is waiting for them, and no data is lost that the
confirmation page did not already show the customer. Do it through the **public API**, which lists exactly
the parked rows and deletes the execution with its data (verified: `execution_data` has
`ON DELETE CASCADE`, and no orphan rows are left):

```bash
# every parked execution older than 30 days, deleted one at a time
KEY=<your n8n API key>
cutoff=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
curl -sS -H "X-N8N-API-KEY: ${KEY}" \
  'https://n8n.example.com/api/v1/executions?status=waiting&limit=250' |
  jq -r --arg c "${cutoff}" '.data[] | select(.startedAt < $c) | .id' |
  while read -r id; do
    curl -sS -o /dev/null -w "${id} %{http_code}\n" -H "X-N8N-API-KEY: ${KEY}" \
      -X DELETE "https://n8n.example.com/api/v1/executions/${id}"
  done
```

Three things about that loop:

- **`status=waiting` is the whole filter you need** — it returns the parked rows and nothing else.
- **Check the workflow ids before you run it the first time.** Approval and Wait-node executions are also
  `waiting`, and deleting one of those throws away a decision somebody was asked to make. Filter on the form
  workflow's `workflowId` if the instance has both. (Parked-for-ever rows can be told apart in SQL by
  `"waitTill" > now() + interval '100 years'`; the public API does not expose `waitTill`.)
- **Run it monthly**, from cron on the host or from an n8n Schedule Trigger workflow. It is not urgent and
  it is not optional.

**Deleting the workflow takes its executions with it** (`execution_entity."workflowId"` references
`workflow_entity` with `ON DELETE CASCADE`) — which is the quickest cleanup after testing, but note that
n8n refuses to delete a published workflow:

```
409 {"message":"Cannot delete a published workflow. Unpublish it before deleting."}
409 {"message":"Workflow is still being unpublished. Please try again in a few moments."}
```

Unpublishing is asynchronous — it has to withdraw the registration from every webhook process — so a delete
sent immediately after it gets the second message. Wait a moment and send it again.

### What not to do about it

- **Do not switch the trigger to *Respond: On Received* to avoid the parking.** That answers the customer
  before the workflow runs, so somebody who typos their phone number is told "thanks, we will call you" and
  then never hears from anyone. A lost order every time is worse than a retention problem at ten thousand.
- **Do not raise `EXECUTIONS_DATA_PRUNE_MAX_COUNT` and call it solved.** It postpones the same arithmetic and
  grows every backup in the meantime.
- **Do not turn pruning off.** See [Configuration](../configuration.md) — that is how a database fills a disk
  and Postgres stops accepting writes.

## Validate in a Code node, and do not throw

A browser enforces *required* and the number type, and a direct POST ignores both. So whatever the form
must guarantee has to be checked again inside the workflow — but **not with an error**: a person is reading
the other end, and an n8n error page is not an answer to "I typed my phone wrong".

Return a verdict instead of throwing, branch on it, and give each branch a completion page of its own: one
that confirms, one that says what to fix. The shipped template does exactly that, one problem at a time,
because a form that lists five faults at once gets abandoned.

Two field-level details that cost real orders:

- **A phone field must be text, not a number.** A number field eats the leading zero, and every Vietnamese
  mobile starts with one.
- **Normalise before you store.** `+84 901 234 567`, `0901-234-567` and `0901234567` are one customer; left
  as typed they are three, and no query will ever tell you.

## Pin the field names

Every field has an optional **Custom Field Name** (`fieldName`, from node version 2.4; it appears under that
label from 2.5). Set it on every field. Without one, the output key is the **label** — so fixing a typo in a
label, or adding an English line to it, silently renames the key every downstream node reads. With one, the
label is free to change.

---

## What the kit asserts on every CI run

`tests/smoke/15-form-order-intake.sh` drives the shipped template on a real stack: the form is served from
the webhook pool (never main) at the path taken from *Options*, a good order is accepted, the page behind its
`formWaitingUrl` carries the reference, the phone is normalised, the quantity arrives as a number, the pinned
field names are what the workflow sees, and four bad orders each come back on the "what to fix" page instead
of an error page.

It also asserts the parking: every submission leaves an execution parked with the wait-indefinitely
sentinel. That assertion exists so that an n8n version which stops parking — or starts resuming — is a
failing test rather than a surprise in somebody's database.

---

## See also

- [`templates/form-order-intake/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/form-order-intake) — the worked example
- [Approvals](approvals.md) — the other waiting pattern, where the execution *does* resume
- [Endpoints that cost money](paid-endpoints.md) — a form is public; gate it if what it triggers costs you
- [Configuration](../configuration.md) — `EXECUTIONS_DATA_PRUNE_MAX_COUNT`, `EXECUTIONS_DATA_MAX_AGE`, `PUBLIC_URL`
- [Scaling](scaling.md) — what else fills the executions table
