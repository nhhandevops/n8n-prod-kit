# Error workflows

**n8n never retries a failed execution by itself.** Not a node that threw, not an execution that hit its
timeout, not one whose worker was killed. There is no dead-letter queue and no automatic second attempt; the
execution is written to the database with status `error` or `crashed` and that is the end of it. Node-level
*Retry on Fail* does not change this — it runs inside the execution process and dies with it.

An **Error Workflow** is the one automatic hook that is still called. It is an ordinary workflow that starts with
an Error Trigger node; you attach it to each workflow that matters (*Settings → Error Workflow*), and n8n runs it
with a description of the failure. What it does from there is up to you: a Telegram message, a Slack post, a row
in a spreadsheet, a re-submission of the payload.

The kit ships one: `templates/error-handler/` — Error Trigger → a Code node that formats the alert → a Telegram
node. Its [README](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/error-handler) has the
install steps. This page is the operations side: when n8n calls a handler, what it hands over, where it runs in
queue mode, and the four ways people end up with a handler that never fires.

## The five-minute version

1. Import `templates/error-handler/workflow.json` in the editor (*Workflows → ⋯ → Import from File*).
2. Fill in the Telegram credential and your chat id — the same bot you use for `ALERT_TELEGRAM_*` is fine.
3. **Publish the handler.** A handler that is only saved never runs (see below).
4. On every workflow whose failure must not be silent: *Settings → Error Workflow →* the handler, then save and
   publish that workflow.
5. `make -C compose doctor` tells you how many workflows still have none, and fails outright if a workflow points
   at a handler that is not published.

## When n8n calls the handler

Verified against the pinned image (n8n 2.44.6: `dist/execution-lifecycle/execution-lifecycle-hooks.js`,
`dist/execution-lifecycle/execute-error-workflow.js`, `dist/workflow-runner.js`,
`dist/workflows/workflow-execution.service.js`).

| The execution… | Handler runs? |
|---|---|
| ended with any status other than `success` or `waiting`, in any non-manual mode (`webhook`, `trigger`, `cli`, `integrated`, `retry`, `error`) | **yes** |
| ran in mode `manual` — "Execute workflow" in the editor, or a test URL | **no**, by design |
| stalled because its worker died, and n8n gave up on the job (`crashed`) | **yes** — dispatched by `n8n-main`, which builds the *worker's* hook set for exactly this case |
| was already marked `crashed` by execution recovery (n8n's startup sweep, or the much slower queue recovery) | **no** — a recovery transition runs no lifecycle hooks, and whoever claims the row first wins |
| was refused by an instance policy | **no** |
| is itself a handler run (mode `error`) whose error workflow is itself | **no** — n8n's only loop guard |

So the coverage you get is: node errors, bad credentials, bad data, HTTP failures, timeouts, triggers that cannot
start, and the stall path after a killed worker. What you do **not** get is an alert when the instance itself is
down — nothing is left to run the handler. That is what the monitoring profile and Uptime Kuma are for
([Monitoring and alerts](monitoring.md)).

## What arrives at the Error Trigger

One item, in one of two shapes. The kit's template reads both; a hand-built handler should too.

| Field | Failed execution | Trigger that could not start |
|---|---|---|
| `workflow.id`, `workflow.name` | ✅ | ✅ |
| `execution.id` | ✅ | — (nothing ran, so there is no execution) |
| `execution.url` | ✅ link straight to the run | — |
| `execution.error` | `{ message, stack, name, node? }` | under `trigger.error` instead |
| `execution.lastNodeExecuted` | name of the node that failed | — |
| `execution.mode` | `webhook`, `trigger`, `cli`, … | under `trigger.mode` |
| `execution.retryOf` | the execution this was a retry of, if any | — |

`execution.error.node` is present for node errors and absent for others (a stalled job, for instance), which is
why the template falls back to `lastNodeExecuted`.

The Error Trigger node also has a convenience worth knowing: run the **handler** manually and it injects a sample
payload (`Example Error Message`, node `Node With Error`, execution `231`) so you can develop the handler without
breaking anything.

## Where it runs in queue mode

- The **worker** that ran the failed execution dispatches the handler, from the same hook that writes the
  execution's final state. For a stalled job there is no live worker left, so `n8n-main` does it instead.
- The handler is then an ordinary execution: queued, picked up by a worker, and visible in *Executions* with mode
  `error`. It obeys its own settings, including its own timeout.
- Because it is a normal execution, it needs the handler's **published** version — which is the trap below.
- `tests/smoke/10-error-workflow.sh` asserts this whole path on every CI run: a deliberate failure, the template
  as the handler, the alert read back, mode `error`, and a worker log line proving which process ran it.

## Four ways to end up with a handler that never fires

**1. It is saved but not published.** n8n loads the *published* version of an error workflow. A handler you
imported, configured and saved — but never published — is skipped with a single line in the worker's log:

```text
Calling Error Workflow for "<failing workflow id>". Workflow "<handler id>" is not active and cannot be executed
```

Nothing else says so: the failing workflow looks correctly configured, and *Settings → Error Workflow* still
shows the handler. `make -C compose doctor` reports this as a **FAIL** because it is indistinguishable, from the
outside, from having no alerting at all.

**2. You tested it with a manual run.** Failures in mode `manual` never dispatch a handler. Testing by clicking
*Execute workflow* on the failing workflow proves nothing; trigger it through its production URL or schedule
instead. (Running the *handler* manually is fine and useful — see the sample payload above.)

**3. The handler refuses the call.** An error workflow is invoked like a sub-workflow, so the handler's
*Settings → This workflow can be called by* applies. With the kit's defaults (one owner, one project) this is
never a problem; on an instance where that setting was narrowed, or where
`N8N_WORKFLOW_CALLER_POLICY_DEFAULT_OPTION` was changed, the call is refused. It is not silent: n8n records a
failed execution *of the handler* explaining that permissions do not allow it. The shipped template sets
`callerPolicy: workflowsFromSameOwner` explicitly.

**4. The handler itself fails.** A handler does not alert about itself, and n8n's loop guard only covers the case
where a workflow is its own error workflow — if A's handler is B and B's handler is A, a failure ping-pongs
between them. Give the handler no error workflow of its own, keep it short, and check *Executions* filtered to
the handler now and then. The template's Telegram node retries three times before giving up.

## Operating it

| | |
|---|---|
| **No flood protection** | One workflow failing a thousand times sends a thousand messages, and Telegram starts answering `429`. Keep the handler as the first signal and use Grafana's `ExecutionFailureRate` alert for the rate ([Monitoring and alerts](monitoring.md)). |
| **An alert is not a replay** | The handler tells you what failed; it does not re-run it. "Retry execution" in the UI is a manual action. If you re-drive a failed payload, make the workflow idempotent first — a `crashed` execution may already have done its side effect ([Chaos drills](chaos-drills.md)). |
| **Give it a ceiling** | The handler is a normal execution and can hang like any other. The template sets `executionTimeout: 120`; the instance-wide ceiling is `EXECUTIONS_TIMEOUT` ([Configuration](../configuration.md)). |
| **Drain, do not kill** | The stall path works, but it costs you an execution. `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` above your p99 (what `make doctor` measures) and `docker stop` rather than `docker kill` means far fewer handler calls in the first place. |

## What the kit checks for you

```bash
make -C compose doctor     # FAIL: a workflow points at a handler that is not published
                           # WARN: N of M published workflows have no Error Workflow at all
make -C compose smoke      # 10-error-workflow: the whole path, end to end (TC-027)
```

`doctor` does not count a workflow that carries an Error Trigger of its own: a workflow that handles its own
errors is its own handler (n8n calls that the *internal* error workflow) and needs nothing attached.

## Related

- [Chaos drills](chaos-drills.md) — what a killed worker really costs, and why replays need idempotency
- [Monitoring and alerts](monitoring.md) — the rate-based alerts, and what to watch when the instance itself is gone
- [Configuration](../configuration.md) — `EXECUTIONS_TIMEOUT`, `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`
- [Runbook](../runbook.md) — the hands-on walk through every feature of the kit
