# Calling other people's APIs

Everything in this kit so far has been about work arriving. This page is about work leaving: a row appended to
a spreadsheet, a message sent, an invoice raised. Two things about that are different from everything else
here — **somebody else decides how fast you may go**, and **somebody else holds the credential** — and both
have a shape specific to this kit.

It applies to any outbound node. The worked example is Google Sheets, because
[`templates/sheets-order-log/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/sheets-order-log)
is the first template to need it.

---

## Your stack is faster than their API

This is the part that surprises people, and `docs/sizing.md` has the numbers: on four cores with two workers
this kit absorbs a 200-job burst in seconds and sustains **well over a thousand executions a minute**. No
third-party API will accept that.

Google Sheets, as an example, allows **300 write requests per minute per project and 60 per minute per user**
([usage limits](https://developers.google.com/sheets/api/limits)); over that you get **HTTP 429**. One OAuth
account appending one row per execution is therefore good for about **one row per second, sustained** — fine
for an order log, hopeless for a ten-thousand-row import. Check the live page before planning against those
numbers; Google revises them, and older figures (500 per 100 seconds) still circulate.

Three ways to stay under the ceiling, cheapest first:

| | |
|---|---|
| **Halve the calls** | The Sheets node's *Minimise API Calls* option (`useAppend`) appends instead of read-then-update: one request per row rather than two. Safe when the sheet is append-only with no gaps, which a log is. The template turns it on. |
| **Send fewer, bigger requests** | One execution appending 50 rows costs one request; 50 executions appending one row each cost 50. If the data arrives in a stream, buffer it — a Schedule trigger that drains a queue every minute will outperform a webhook-per-row at high volume, and it is one request instead of sixty. |
| **Ask for more** | Google's Cloud console takes quota-increase requests. Approval is not guaranteed, and it is the last resort rather than the first. |

## What a 429 costs you inside the kit

A retrying node **holds its worker slot while it waits**. That is the part worth thinking about: with
`WORKER_CONCURRENCY=10` and two workers, twenty executions each sleeping 3 seconds between tries are twenty
slots doing nothing, and new work queues behind them. A burst that gets rate-limited therefore costs more
than the burst itself.

So configure the retry to absorb a *blip*, not an outage:

- **Retry, but not forever.** The template uses 4 tries with 3 s between them — about 9 seconds of patience
  per order. n8n clamps `maxTries` to 2–5, and `waitBetweenTries` to at most 5000 ms, so a long backoff is
  not available: a Wait node is how you build one.
- **Let the failure through once retries are spent.** A failed execution is visible, alertable and
  re-drivable; a silently swallowed one is none of those. Point the workflow's *Error Workflow* at
  [`templates/error-handler/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/error-handler)
  and the kit will tell you ([error workflows](error-workflows.md)).
- **Re-driving is a replay.** Whatever you re-drive may already have half-happened — the remote may have
  accepted the write and lost the response. [Idempotency](idempotency.md) is the pattern, and
  `templates/idempotent-webhook/` is a working gate.

Worth knowing from the kit's own measurements: a retry that holds a slot is the same cost shape as the
in-flight work a killed worker loses ([chaos drills](chaos-drills.md)) — the stack's capacity is slots ×
time, and anything that holds a slot without working spends it.

## Credentials, and the one thing specific to this kit

Most outbound nodes need a credential. The kit's part in that is the **OAuth redirect URI**, which n8n builds
from your instance's base URL:

```
<PUBLIC_URL>/rest/oauth2-credential/callback
```

Verified against n8n 2.46.7 (`frontend.service.ts` builds it from `instanceBaseUrl` + the REST endpoint), and
`/rest/*` is routed to `n8n-main` by this kit's Caddyfile. Three consequences:

- **Paste that exact URL** into the provider's OAuth client (for Google: Cloud console → *APIs & Services* →
  *Credentials* → your OAuth client → *Authorised redirect URIs*). n8n also shows it in the credential dialog;
  if the two disagree, `PUBLIC_URL` is wrong — which is the same misconfiguration that breaks webhook URLs.
- **`PUBLIC_URL` must be the address a browser really reaches.** On a dev stack using the internal CA, the
  redirect lands on `https://n8n.localtest.me`, so that browser has to trust the kit's CA
  (`make trust-ca`) or the callback fails at the TLS handshake with nothing useful in the logs.
- **Changing `PUBLIC_URL` invalidates existing OAuth credentials**, because the redirect no longer matches.
  Re-authorise them, and update the provider's allow-list, as part of any domain move.

For API-key credentials none of this applies — paste the key and go. Prefer that where a provider offers
both; it is one fewer thing to break when the domain changes.

**Keep the secret in a credential, not in a node.** A URL pasted into an HTTP Request node is stored in the
workflow, which means it is in every backup, visible to anyone who can open the workflow, and in the diff if
you export it. n8n's credential store is encrypted with `N8N_ENCRYPTION_KEY`. Where a provider's "credential"
*is* a URL — a Google Chat space webhook, a Slack incoming webhook — use an
[HTTP Header Auth or query-auth credential](https://docs.n8n.io/integrations/builtin/credentials/httprequest/)
or `$vars` rather than inlining it. `templates/gchat-approval/` says the same thing in its own README,
because it ships with exactly that trade.

## What the kit can and cannot test for you

Nothing in CI has a Google account, so no smoke test here can prove a row reaches a spreadsheet. The kit
draws the line deliberately:

- **Tested**: everything up to the vendor node — the validation, the normalisation, the field names, the
  refusals, and that a burst loses nothing. `tests/smoke/13-sheets-order-log.sh` swaps the Sheets node for a
  collector and asserts the row it *would* have appended, because those field names are the contract with
  your header row.
- **Asserted statically**: the shipped node's own shape — resource locators, the automatic column mapping,
  *Minimise API Calls*, the retry — so a later edit cannot quietly break them.
- **Yours, once**: the append itself. Point the template at a real sheet, send one order, see the row. That
  is the whole of it, and `docs/compat.md` records when it was last done.

This is the same split as `templates/error-handler/`, whose Telegram leg no CI run has ever sent a message
through.

---

## See also

- [`templates/sheets-order-log/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/sheets-order-log) — the worked example
- [Idempotency](idempotency.md) — because re-driving a failed outbound call is a replay
- [Endpoints that cost money](paid-endpoints.md) — the same relationship from the other side: your endpoint, somebody else's bill
- [Error workflows](error-workflows.md) — how a spent retry reaches you
- [Scaling](scaling.md) and [Sizing](../sizing.md) — what the stack can push, which is the other half of this page
- [Configuration](../configuration.md) — `PUBLIC_URL`, `WORKER_CONCURRENCY`, `N8N_ENCRYPTION_KEY`
