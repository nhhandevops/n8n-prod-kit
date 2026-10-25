# Workflow templates

Ready-to-import n8n workflows. Each template is a folder with `workflow.json`, a `README.md` (what it does,
credentials needed, how to test) and, where it helps, a `test-payload.json`. Import through the editor:
*Workflows → ⋯ (top right) → Import from File*.

## Shipped

| Template | What it does |
|---|---|
| [`error-handler/`](error-handler/) | The Error Workflow every other workflow should point at: Error Trigger → a Code node that formats the failure → a Telegram message. n8n retries nothing by itself, so without one a failed execution is silent. `make -C compose doctor` counts the workflows that have none; `tests/smoke/10-error-workflow.sh` proves the path on every CI run. Background: [docs/operations/error-workflows.md](../docs/operations/error-workflows.md). |

## Planned (milestone M1)

Vietnamese-business templates, each with a screenshot and a test payload:
`zalo-form-notify` · `vietqr-payment-link` · `sheets-order-log` · `gchat-approval` · `ai-faq-bot`.

Want one that is not listed? Open a [template request](https://github.com/nhhandevops/n8n-prod-kit/issues/new?template=template-request.yml).
