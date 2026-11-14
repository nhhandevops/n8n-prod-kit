# `gchat-approval` — ask a human in Google Chat, then act

A request arrives, the workflow posts a card to a Google Chat space with **Approve** and **Reject** buttons,
and stops. Whoever clicks decides what happens next. Nothing runs in the meantime, and the execution holds no
worker while it waits.

**It needs no credential.** A Google Chat space's *incoming webhook* URL is the only secret involved, and it
goes in one HTTP Request node — no Google Cloud project, no OAuth consent screen, no service account.

The mechanics of waiting executions, and the one case where this pattern is the wrong one, are in
[docs/operations/approvals.md](../../docs/operations/approvals.md). This page is how to run it.

## The flow

```
Webhook → Build the approval card → Ask in Google Chat → For a decision ─true→ Do the approved thing
                                                         (waits)         └false→ Record the rejection
```

| Node | What it is for |
|---|---|
| **Webhook** | Answers the caller **immediately** (`onReceived`). It must not hold the request open — a human may take a day. |
| **Build the approval card** | Validates the request (`ref`, `requester`, numeric `amountVnd`), formats the amount, and builds the Chat card. Each button is a link back into *this* execution. |
| **Ask in Google Chat** | POSTs the card to your space's incoming-webhook URL. **Replace the placeholder URL.** |
| **For a decision** | A Wait node, *On Webhook Call*. The execution is parked here with a 2-day deadline. |
| **Approved?** | `query.approved == 'true'` — which button was clicked. |
| **Do the approved thing** | **Replace this node** with what the approval unlocks. |
| **Record the rejection** | So that "no" is recorded rather than looking the same as "never answered". |

## Set it up

1. **Get the space's webhook URL.** In Google Chat, open the space → *Apps & integrations* → *Webhooks* →
   *Add webhooks*, name it, copy the URL. It looks like
   `https://chat.googleapis.com/v1/spaces/AAAA.../messages?key=...&token=...`.

   That URL is a secret — anyone holding it can post to the space as this webhook. It is also the only
   credential here, which is the trade: no OAuth, but the URL lives in the workflow rather than in n8n's
   encrypted credential store. If that matters to you, put it in an
   [HTTP Header Auth credential](https://docs.n8n.io/integrations/builtin/credentials/httprequest/) or a
   `$vars` variable instead of pasting it into the node.

2. **Import** `workflow.json` (*Workflows → ⋯ → Import from File*), paste that URL into **Ask in Google
   Chat**, set the webhook **Path**, and replace **Do the approved thing**.

   **The editor's import does not apply the file's `settings`** (verified in the 2.46.7 editor), so set
   *Settings → Error Workflow* by hand and point it at the [`error-handler`](../error-handler/) template.
   Without it, a failed approval is silent.

3. **Publish it**, then send one request:

   ```bash
   curl -sS -X POST https://n8n.example.com/webhook/<your-path> \
     -H 'Content-Type: application/json' \
     --data @templates/gchat-approval/test-payload.json
   # -> {"message":"Workflow was started"} immediately, and a card appears in the space
   ```

   Click **Approve**. The execution resumes, takes the approved branch and finishes. Clicking again gets a
   `409` — the decision is already taken.

## Decisions worth knowing before you edit it

- **The buttons append `&approved=true`, not `?approved=true`.** `{{ $execution.resumeUrl }}` already carries
  the execution's resume token as `?signature=…`, and n8n answers **401** to a resume without it. A `?` here
  breaks every button. `tests/smoke/12-gchat-approval.sh` asserts the `&` for exactly this reason.
- **The webhook answers `onReceived`.** With `lastNode` the caller's HTTP request would stay open until
  somebody clicked — minutes or days.
- **Limit Wait Time is 2 days.** Without a limit, a request nobody answers waits for ever and is invisible.
  `EXECUTIONS_TIMEOUT` does *not* cut the wait short — that deadline is computed per job, and a parked
  execution is not a running job ([approvals.md](../../docs/operations/approvals.md) has the detail).
- **A deadline with no click is a rejection.** Measured, with the wait shortened to 30 s: the execution
  resumes at the deadline, `query.approved` is absent, the IF node reads that as false (it does not error),
  and the run ends `success` through *Record the rejection*. Safe, but not always what you want — if "nobody
  answered" deserves a reminder or an escalation instead, branch on something that tells the two apart, such
  as `$json.query === undefined`.
- **The decision is a plain query parameter.** The token proves the link came from your workflow and is
  unguessable, but whoever holds the link can send either answer. That is fine among colleagues and wrong
  when the approver benefits from the other answer — in that case use a vendor node's *Send and Wait*
  operation, which HMAC-signs the parameter. [approvals.md](../../docs/operations/approvals.md) compares the
  two.
- **A retry of the HTTP node posts the card twice.** Both cards link to the same execution, so the decision
  is still taken once; it is noise, not a second approval.
- **Make the approved action idempotent.** A chat client can prefetch a link, and two cards can exist. The
  second *click* is safe (409), the second *GET from a scanner* is not a human decision at all. See
  [Idempotency](../../docs/operations/idempotency.md) and `templates/idempotent-webhook/`.

## Tested

`tests/smoke/12-gchat-approval.sh` imports **this** `workflow.json` on every CI run and drives the whole
path on a real stack: the execution parks in `waiting` with a ~2-day deadline, the card's links point at that
execution's waiting webhook on the webhook pool, a link with a wrong token is refused with **401** while the
execution stays parked, **Approve** resumes it down the approved branch, a second click gets **409**,
**Reject** takes the other branch, and nothing is left parked at the end.

The Google Chat leg itself is not tested: the node is pointed at a collector workflow instead of a space, the
same way `10-error-workflow` swaps the Telegram node. That leg is one URL, and step 1 above is all of it.
