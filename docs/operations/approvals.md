# Approvals and waiting executions

Some workflows should stop and ask a person. An expense over a limit, a refund, a discount, a post that goes
out under the company's name — the automation gets everything ready, and a human decides.

n8n does that by **suspending the execution**: it writes the row, lets go of the worker, and resumes when
somebody calls a URL it generated. That is a different shape from everything else in this kit, and this page
is what it means operationally. The kit ships it as a template —
[`templates/gchat-approval/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/gchat-approval)
— which asks in a Google Chat space and needs no credential at all.

---

## What a waiting execution actually is

When an execution reaches a **Wait** node set to *On Webhook Call*:

1. the execution's row gets `status = 'waiting'` and `waitTill` = the deadline (or far future with no limit);
2. the worker is released — a parked execution occupies **no** concurrency slot;
3. when the resume URL is called, the execution is picked up **as a new job** and continues from that node;
4. if the deadline passes first, the wait-tracker resumes it anyway, with no webhook data.

Point 3 is the one with consequences, below.

## The resume URL, and the token on it

`{{ $execution.resumeUrl }}` yields:

```
https://n8n.example.com/webhook-waiting/<executionId>?signature=<resume token>
```

Three things about it, all read out of n8n 2.46.7 rather than assumed:

- **The token is not optional.** `cli/src/webhooks/waiting-webhooks.ts` validates it for any execution whose
  data carries a `resumeToken` and answers **401** otherwise. Anyone who strips or edits it gets nothing.
- **It exists before the Wait node runs.** The token is generated when the execution's run data is created
  (`run-execution-data-factory.ts`: `options.resumeToken ?? generateSecureToken()`), so a Code node earlier in
  the workflow can build the link — which is how the template puts Approve and Reject buttons in a message
  that is sent *before* the wait.
- **Append your own parameters with `&`, never `?`.** The URL already has a query string. A `?` here produces
  a link whose token is part of a malformed second query, and every click 401s. This is the one-character
  mistake worth knowing about; the kit's `tests/smoke/12-gchat-approval.sh` asserts the `&`.

In this kit the resume URL is served by the **webhook pool**, not by `n8n-main`: the Caddyfile routes
`/webhook-waiting/*`, `/form-waiting/*` and the two vendor variants (`/webhook-waiting-slack*`,
`/webhook-waiting-telegram*`) to the pool. `PUBLIC_URL` is what the link is built from, so it has to be
reachable from wherever the person clicking it is sitting — on a `localtest.me` dev stack, only that host.

## Two ways to ask, and the difference that matters

| | Wait node + your own message | A vendor node's **Send and Wait** operation |
|---|---|---|
| What the kit's template uses | ✅ | documented alternative |
| Credentials | **none** — a Google Chat space's incoming-webhook URL *is* the credential | that vendor's full credential (Chat needs OAuth2 or a service account) |
| The decision in the URL | a plain `approved=true` query parameter | **HMAC-signed** (`getSignedResumeUrl`), so it cannot be flipped |
| You control the message | yes — it is your own card/HTTP request | n8n builds it |

The security line is the one to think about. With the Wait-node pattern, the token proves the link came from
your workflow, and it is unguessable — but **whoever holds the link can send either answer**, because the
`approved` flag is just a query parameter. For an internal approval among colleagues, that is fine: the
approver could also simply click Approve.

It is **not** fine when the person holding the link benefits from the other answer. A customer-facing
"confirm your refund" link, or anything where the approver is the requester, should use a vendor node's
*Send and Wait* operation, which signs the parameter — or should verify the decision server-side instead of
trusting the click.

## What the execution timeout does **not** bound

This kit sets `EXECUTIONS_TIMEOUT=3600` (and caps it there with `EXECUTIONS_TIMEOUT_MAX`), so the obvious
worry is that an approval dies after an hour. It does not.

The deadline is computed **per job**, in the worker, at the moment it picks the job up
(`cli/src/scaling/job-processor.ts`: `executionTimeoutTimestamp = Date.now() + workflowTimeout * 1000`). A
parked execution is not a running job, and the resume is a *new* job with a *new* deadline. So the timeout
bounds the active segments — everything before the wait, and everything after the resume — and never the
waiting itself. A two-day approval works on the kit's default settings.

What bounds the wait is the Wait node's own **Limit Wait Time**, which the template sets to 2 days.

## When nobody answers

Without a limit, a forgotten request waits for ever and is invisible: no failure, no alert, nothing to notice.
With one, the execution resumes at the deadline **with no webhook data** — so in a workflow that branches on
`query.approved`, a timeout is not an approval.

Measured on the kit's stack with the template's wait shortened to 30 s and nobody clicking: the row went
`running` → `waiting` → `success` at the deadline, taking the **rejected** branch
(`lastNodeExecuted: Record the rejection`, `outcome: rejected`). The IF node's strict type validation does
not error on the missing parameter; it simply reads false. So in this template **a deadline is a rejection**,
which is the safe default but not always the one you want: if "nobody answered" deserves a reminder or an
escalation rather than a no, branch on something that tells them apart, such as `$json.query === undefined`.

Waiting executions are easy to lose track of, so two facts about them:

- **Pruning does not delete them.** The pruning query excludes `new`, `running` and `waiting` outright, with
  n8n's own comment *"Only mark executions as deleted if they are in an end state"*. A 2-day link cannot be
  pruned out from under the person who holds it. (They do still count toward `EXECUTIONS_DATA_PRUNE_MAX_COUNT`
  when it computes its cutoff, so a large pile of parked executions makes the retention window shorter for
  everything else.)
- **A restart does not lose them.** The row carries the deadline, and the wait-tracker picks parked executions
  up again after the stack comes back. `make upgrade`'s drain does not need to wait for them either, since
  they hold no worker.

To see what is parked, with the oldest first:

```sql
SELECT id, "workflowId", "startedAt", "waitTill"
FROM execution_entity WHERE status = 'waiting' ORDER BY "waitTill";
```

## A clicked link is not a safe action

Two clicks on Approve do **not** run the action twice — the second call finds the execution finished and gets
a **409** (`"has finished already"`), which `tests/smoke/12-gchat-approval.sh` asserts. That covers the double
click, and it is not the whole story:

- a chat client or a link scanner may **prefetch** the URL, which resumes the execution before any human
  decided;
- the message itself can be posted twice if the HTTP node retries, so two cards can exist for one execution;
- and the approved action may be retried internally for its own reasons.

So the thing the approval unlocks should be idempotent regardless — [Idempotency](idempotency.md) is the
pattern, and `templates/idempotent-webhook/` is a working gate you can put in front of the side effect.

Prefetching is the one worth a second thought: if an accidental GET must not count as a decision, use the
*Send and Wait* operation (its links are signed and n8n renders a confirmation page rather than acting on a
bare GET), or make the approval a POST form instead of a link.

---

## What this kit proves

`tests/smoke/12-gchat-approval.sh` runs on every CI run against a real stack and drives the whole path: the
shipped template suspends, the card's links point at that execution's waiting webhook on the pool, a link
with a **wrong token is refused with 401** while the execution stays parked, Approve resumes it and takes the
approved branch, a **second click gets 409**, Reject takes the other branch, the parked row's deadline is
~2 days out, and nothing is left waiting at the end.

It does not prove the Google Chat leg: the node is pointed at a collector workflow instead of a space, the
same way `10-error-workflow` swaps the Telegram node. Posting a card to a real space is one URL and is
covered by the template's README.

## See also

- [`templates/gchat-approval/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/gchat-approval) — the workflow and how to point it at your space
- [Idempotency](idempotency.md) — making the approved action safe to repeat
- [Error workflows](error-workflows.md) — how a failed or timed-out approval reaches you
- [Configuration](../configuration.md) — `EXECUTIONS_TIMEOUT`, `EXECUTIONS_DATA_PRUNE_MAX_COUNT`, `PUBLIC_URL`
