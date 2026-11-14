# `sheets-order-log` — one order, one spreadsheet row

An order arrives on a webhook — from a form, a shop, a Zalo bot, anything that can POST JSON — and becomes
one row in a Google Sheet. The caller gets a receipt naming the order and the execution that wrote it.

It is deliberately small. The interesting part is not the append; it is **refusing the orders that would make
a bad row**, because a wrong row in a spreadsheet is somebody's afternoon, while a refused request is a line
in a log.

Rate limits, OAuth against this kit, and what a 429 costs inside the queue are in
[docs/operations/outbound-apis.md](../../docs/operations/outbound-apis.md). This page is how to run it.

## The flow

```
Webhook → Normalise the order → Append the row → Answer the caller
```

| Node | What it is for |
|---|---|
| **Webhook** | POST, answers with the receipt (`lastNode`) — the caller learns the order was recorded, not merely received. |
| **Normalise the order** | Validates, trims, caps lengths, stamps `receivedAt` in UTC, and builds the row. **Its output keys are the sheet's column headers.** |
| **Append the row** | The Google Sheets node, *Append*, mapping columns automatically. **Configure this one.** |
| **Answer the caller** | The receipt: `logged`, `orderId`, `receivedAt`, `executionId`. |

## The sheet

Create a sheet with a tab called **`Orders`** and put **exactly these headers in row 1**, in any order:

```
receivedAt   orderId   customer   phone   item   qty   amountVnd   note   executionId
```

The node maps input fields to columns **by header name**, so these names are the contract between the
template and your spreadsheet. Rename one here and you must rename it in *Normalise the order* too — the
smoke test asserts the exact set, so a drift breaks CI rather than your Monday.

`executionId` earns its column: when a row looks wrong, that is how you find the execution that produced it
in n8n's own list.

## Set it up

1. **A Google Sheets credential.** In n8n: *Credentials → New → Google Sheets OAuth2 API*. The redirect URI
   to paste into your Google Cloud OAuth client is

   ```
   <PUBLIC_URL>/rest/oauth2-credential/callback
   ```

   On a dev stack with the internal CA, the browser doing that redirect must trust the kit's CA
   (`make trust-ca`) or the callback fails at the TLS handshake.
   [outbound-apis.md](../../docs/operations/outbound-apis.md) has the rest, including why changing
   `PUBLIC_URL` later invalidates the credential.

2. **Import** `workflow.json` (*Workflows → ⋯ → Import from File*), then on **Append the row**: pick that
   credential, paste your sheet's URL into **Document** (the field is flagged until you do — it ships with
   `PUT-YOUR-GOOGLE-SHEET-URL-HERE` on purpose), and leave **Sheet** as `Orders` unless your tab is called
   something else.

   **The editor's import does not apply the file's `settings`**, so set *Settings → Error Workflow* by hand
   and point it at [`error-handler`](../error-handler/). A spent retry should reach you.

3. **Publish it**, then send one order:

   ```bash
   curl -sS -X POST https://n8n.example.com/webhook/<your-path> \
     -H 'Content-Type: application/json' \
     --data @templates/sheets-order-log/test-payload.json
   # -> {"logged":true,"orderId":"DH-2026-0117","receivedAt":"…Z","executionId":"…"}
   ```

   Check the sheet. That single run is the one part of this template no CI run can prove for you.

## What it refuses, and why

| Refused | Because |
|---|---|
| no `orderId` | a row that cannot be traced back to an order is not worth having |
| `amountVnd` not a non-negative number | an order for "abc" dong is a data-entry bug, not an order |
| `qty` not a whole number ≥ 1 | 1.5 coffees is a typo upstream |
| neither `customer` nor `phone` | a row identifying nobody cannot be followed up |

Each refusal **names the field** in the error, so the caller can fix it without asking you. The execution
fails, which means it is visible, alertable and re-drivable — and nothing is written, which the smoke test
asserts for every one of the four.

Fields are trimmed, internal whitespace is collapsed, and long ones are capped (`item` 200, `note` 500,
`customer` 120). Caps rather than rejections: an over-long note is still a usable order.

## Decisions worth knowing before you edit it

- **`receivedAt` is ISO 8601 in UTC.** A sheet of orders gets read months later, often from another
  timezone, and `14/11/2026 23:05` with no offset is ambiguous. Add a pretty local-time column if you like,
  but keep one machine-readable one.
- **The webhook answers `lastNode`**, so the caller waits for the append — a few hundred milliseconds — and
  learns whether it worked. If your caller times out aggressively, switch it to `onReceived` and accept that
  a failed append becomes invisible to them.
- **"Minimise API Calls" is on.** It appends instead of read-then-update: one Google request per row instead
  of two, which directly doubles how many orders a minute you fit under the quota. It assumes the sheet is
  append-only with no gaps. A log is.
- **The append retries 4 times, 3 s apart.** Enough to ride out a 429 blip, not an outage — and n8n clamps
  `maxTries` to 2–5 and `waitBetweenTries` to 5 s, so a long backoff needs a Wait node instead. Past that
  the execution fails on purpose, so you hear about it.
- **One order per execution.** The template does not batch. Around **60 rows a minute** on one OAuth user is
  the practical ceiling; above that, buffer and append in batches
  ([outbound-apis.md](../../docs/operations/outbound-apis.md)).
- **Duplicates are not deduplicated.** Two identical POSTs make two rows. For a log that is usually
  preferable to silently dropping one — but if a double-submitted form must not double a row, put the
  [`idempotent-webhook`](../idempotent-webhook/) gate in front, keyed on `orderId`.

## Tested

`tests/smoke/13-sheets-order-log.sh` runs on every CI run and covers everything up to the vendor node: one
order makes exactly one row with the documented columns, `receivedAt` is UTC ISO 8601, numbers stay numbers,
all four refusals are refused and write nothing, and **20 orders fired at once become exactly 20 rows** — no
loss, no duplicates. It also asserts the shipped node's own shape (resource locators, automatic mapping,
*Minimise API Calls*, the retry), so an edit cannot quietly break them.

It does **not** test the append: CI has no Google account, so the node is pointed at a collector workflow,
the same way `10-error-workflow` swaps the Telegram node. Step 3 above is that test, and it takes a minute.
