# Error handler — Telegram alert

One workflow, three nodes. Every other workflow points at it, and when one of them fails you get a message that
says which workflow, which node, what the error was and a link to the execution.

Why it matters on this kit: **n8n never retries a failed execution by itself.** Not a node error, not a timeout,
not an execution whose worker was killed (n8n 2.x hard-codes Bull's `maxStalledCount` to `0`, so a stalled job
fails instead of being re-queued). Node-level *Retry on Fail* runs inside the execution and dies with it. An Error
Workflow is the one automatic hook that is still called — see
[Error workflows](../../docs/operations/error-workflows.md) for the full path and its limits.

## What is in it

| Node | Type | What it does |
|---|---|---|
| **Error Trigger** | `n8n-nodes-base.errorTrigger` | Receives the failure. n8n calls this workflow, so there is nothing to configure. |
| **Build alert** | Code | Turns n8n's payload into one short alert. Handles both shapes it can arrive in (a failed execution, or a trigger that could not start) and truncates long messages. No network and no `$env` — this kit blocks both in Code nodes. |
| **Send alert** | Telegram → `sendMessage` | Sends `{{ $json.text }}` as plain text. **This is the node you swap** for Slack, email, a webhook into your own system — anything. |

`Build alert` also emits the pieces separately (`workflowName`, `nodeName`, `executionId`, `executionUrl`,
`message`, `mode`, `kind`, `retryOf`, `stack`), so a different channel can format its own message.

The alert looks like this:

```text
n8n FAILED: Zalo order intake
node: HTTP Request
error: Invalid JSON in response body
execution 4821, mode webhook
https://n8n.example.com/workflow/7fKq9c2Xa1/executions/4821
```

## Install it

1. **Import** — in the editor: *Workflows → ⋯ (top right) → Import from File* → `workflow.json`. (The kit has no
   `import-template` target yet; the editor is the supported way.)
2. **Point the Telegram node at your bot** — click *Send alert*, create a *Telegram API* credential with the bot
   token from [@BotFather](https://t.me/botfather), and replace `PUT-YOUR-TELEGRAM-CHAT-ID-HERE` with your chat
   id. If you already set `ALERT_TELEGRAM_BOT_TOKEN` / `ALERT_TELEGRAM_CHAT_ID` in `compose/.env` for backup and
   Grafana alerts, use the same two values — n8n cannot read `.env`, so they have to be entered here as well.
3. **Publish it.** This is the step everyone forgets: n8n runs the *published* version of an error workflow, so a
   handler that is only saved never runs and nothing says so. `make -C compose doctor` fails on exactly this.
4. **Attach it to the workflows that matter** — open each one, *Settings → Error Workflow →
   "Error handler - Telegram alert"*, then save and publish that workflow. Do it for every workflow whose failure
   must not be silent; `make -C compose doctor` counts the ones you have not done yet.

## Test it

- **In the editor, without breaking anything:** open the handler and click *Execute workflow*. The Error Trigger
  injects a sample failure (`Example Error Message`, node `Node With Error`, execution `231`) precisely so that
  handlers can be developed, so you should get a real Telegram message with sample content.
  `test-payload.json` in this folder is the same payload in the shape n8n really sends, for pinning into the
  Error Trigger while you edit.
- **For real:** add a Code node containing `throw new Error('test alert');` to a copy of one of your workflows,
  publish it, and trigger it through its production URL. Within a second or two the alert arrives.
  **A manual run does not work for this** — n8n skips the error workflow when the execution mode is `manual`, so
  "Execute workflow" on the *failing* workflow proves nothing. The kit's smoke test does the same thing
  automatically: `tests/smoke/10-error-workflow.sh`.

## What it catches, and what it cannot

| Failure | Alert? |
|---|---|
| A node throws (bad credential, 4xx/5xx from an API, bad data, Code node error) | ✅ |
| The execution hits `EXECUTIONS_TIMEOUT` | ✅ |
| A worker is killed mid-execution and the job stalls | ✅ once n8n gives up on the job — the alert says `job stalled more than maxStalledCount` |
| A trigger cannot start at all (expired OAuth, poller broken) | ✅ as the `trigger` shape — no execution id, nothing ran |
| A **manual** run fails | ❌ by design |
| The whole instance is down, or Postgres/Valkey is gone | ❌ — nothing is left to run the handler. That is what the monitoring profile and Uptime Kuma are for |
| The handler itself fails (wrong chat id, Telegram down) | ❌ — it will not alert about itself. Check *Executions* filtered to this workflow; the Telegram node retries 3 times first |

Two more things worth knowing before you rely on it:

- **No flood protection.** One workflow failing a thousand times sends a thousand messages, and Telegram will
  start answering `429`. For a rate rather than a message per failure, use the kit's Grafana alert
  `ExecutionFailureRate` (monitoring profile) and keep this handler for the first signal.
- **Do not build a cycle.** n8n only guards the case where a workflow is its own error workflow. If A's handler is
  B and B's handler is A, a failure ping-pongs between them. Give the handler no error workflow of its own.

## Other channels

Replace *Send alert* with any sending node — keep the node name and the connection stays intact:

| Channel | Node | Notes |
|---|---|---|
| Slack | Slack → *Send message* | Text in `{{ $json.text }}` |
| E-mail | Send Email | Subject `n8n failed: {{ $json.workflowName }}`, body `{{ $json.text }}` |
| Anything HTTP | HTTP Request → POST, JSON body `{{ JSON.stringify($json) }}` | What the smoke test uses, so this path is exercised on every CI run |
| Several at once | Keep *Build alert* and connect two sinks to it | Each failure then alerts both |
