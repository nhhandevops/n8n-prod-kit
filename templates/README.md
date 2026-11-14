# Workflow templates

Ready-to-import n8n workflows. Each template is a folder with `workflow.json`, a `README.md` (what it does,
credentials needed, how to test) and, where it helps, a `test-payload.json`. Import through the editor:
*Workflows → ⋯ (top right) → Import from File*.

## Shipped

| Template | What it does |
|---|---|
| [`error-handler/`](error-handler/) | The Error Workflow every other workflow should point at: Error Trigger → a Code node that formats the failure → a Telegram message. n8n retries nothing by itself, so without one a failed execution is silent. `make -C compose doctor` counts the workflows that have none; `tests/smoke/10-error-workflow.sh` proves the path on every CI run. Background: [docs/operations/error-workflows.md](../docs/operations/error-workflows.md). |
| [`idempotent-webhook/`](idempotent-webhook/) | A webhook that cannot do its work twice, however often the same delivery arrives: Postgres claims the idempotency key, the work runs only for the execution that won the claim, and a replay is answered with the first result. Ships the ledger schema and a least-privileged database role; `tests/smoke/11-idempotency.sh` fires one key at it 20 times at once on every CI run. Background: [docs/operations/idempotency.md](../docs/operations/idempotency.md). |
| [`gchat-approval/`](gchat-approval/) | Stop and ask a human: the workflow posts an Approve/Reject card to a Google Chat space and suspends until somebody clicks, then branches on the answer. **No credential** — a space's incoming-webhook URL is the only secret. `tests/smoke/12-gchat-approval.sh` drives the whole waiting path on every CI run, including the 401 a tampered link gets and the 409 a second click gets. Background: [docs/operations/approvals.md](../docs/operations/approvals.md). |
| [`sheets-order-log/`](sheets-order-log/) | An order POSTed to a webhook becomes one row in a Google Sheet, with the caller getting a receipt. Refuses the orders that would make a bad row (no `orderId`, a negative amount, a fractional quantity, nobody to contact) and names the field in the error. `tests/smoke/13-sheets-order-log.sh` asserts the row's columns — they are the contract with your header row — and that 20 orders at once become exactly 20 rows. Background: [docs/operations/outbound-apis.md](../docs/operations/outbound-apis.md). |

## Planned (milestone M1)

Vietnamese-business templates, each with a screenshot and a test payload:
`zalo-form-notify` · `vietqr-payment-link` · `ai-faq-bot` (`gchat-approval` and `sheets-order-log` are shipped, above). **`vietqr-payment-link` is deliberately last**: a payment QR is the one template whose correctness a smoke test cannot establish — only scanning it with a real banking app against a real account can — so it waits until it can be validated that way (decided 2026-11-15).

Want one that is not listed? Open a [template request](https://github.com/nhhandevops/n8n-prod-kit/issues/new?template=template-request.yml).
