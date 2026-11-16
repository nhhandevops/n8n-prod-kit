# When a request costs money

Most webhooks cost you CPU. Some cost you cash: a model answers a question, an SMS goes out, a paid lookup
runs. The difference matters because the failure mode changes. An overloaded stack tells you immediately —
queues grow, `make doctor` complains. **An abused paid endpoint tells you at the end of the month.**

n8n exposes trigger URLs publicly by design, and its webhook node defaults to no authentication. That is the
right default for work that only costs CPU. This page is about the endpoints where it is the wrong one, and
the kit ships one as a worked example:
[`templates/ai-faq-bot/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/ai-faq-bot).

---

## Three things before the money is spent

In this order, because each is cheaper than the next.

### 1. Make the caller prove who they are

Use the Webhook node's own **Header Auth** (or Basic Auth) rather than a check written in a Code node. Two
reasons, and neither is about elegance:

- the secret then lives in n8n's **encrypted credential store**, not in the workflow — so it is not in your
  backups in clear, not in an export, and not visible to everyone who can open the workflow;
- the check runs **before** the workflow starts, so a bad request costs you nothing at all, not even an
  execution record.

A failed header check answers `401`/`403` and never reaches a node.

**What a shared secret is not.** If the caller is a browser — a chat widget on your website — then whatever
the page holds, the public holds. A secret only works between servers. For a public widget, put your own
small backend in front, or accept that the rate limit below is your real defence.

### 2. Rate-limit per caller, in the broker you already run

This kit runs Valkey for the queue, and the Redis node's **`INCR` is atomic**, which is exactly what a
counter needs: twenty simultaneous requests get twenty different numbers, so a burst cannot slip past the
limit the way a read-then-write check would ([idempotency](idempotency.md) has the same argument at length).

Three details that decide whether it works:

| | |
|---|---|
| **Bucket the key by time** | `faq:rl:<sender>:<minute>`. n8n's Redis node calls `EXPIRE` on *every* `INCR`, so one key per sender has its window pushed out by continuous traffic — a busy caller would never get a fresh window and would stay blocked until it stopped entirely. A per-minute key makes that harmless: the old bucket just expires unused. |
| **Always set a TTL** | The kit's Valkey runs `maxmemory-policy noeviction` on a 256 MB budget, deliberately, so that a full broker **errors instead of silently dropping queue jobs**. Counters without a TTL would fill it, and your rate limiter would become a queue outage. |
| **Count per sender, not per endpoint** | A global counter lets one noisy caller silence everyone. Derive the sender from something meaningful; if your callers are untrusted, derive it from something they cannot choose. |

A rate limit is a **fairness** mechanism, not a budget: 20 requests a minute is still 28,800 a day.

### 3. Cap the work itself

Reject an over-long input rather than truncating it — truncating answers a question nobody asked, and
teaches the caller nothing. Cap the *output* too, at the vendor's knob (`maxOutputTokens` and friends):
output is usually what the bill is made of, and an FAQ answer is a lookup, not an essay.

## And cap it where the kit cannot reach

Everything above is inside your stack, which means all of it can be bypassed by a bug in your own workflow. So
set a limit at the provider as well — a monthly budget cap, a quota, a key restricted to one model. That is
the only control that still holds when the mistake is yours, and it is the difference between a surprising
bill and a stopped one.

Prefer the cheap model by default. For an FAQ lookup the difference between a flash-class model and a
frontier one is invisible to the customer and very visible on the invoice.

## Noticing it

A paid endpoint's spend is proportional to its execution count, so the kit's existing monitoring is a usable
proxy: the monitoring profile's execution-rate panels and the `ExecutionFailureRate` alert already watch
volume ([monitoring](monitoring.md)). Watching **that workflow's** execution count is watching your bill.

Two things worth logging in the workflow itself, because nothing else will tell you:

- **what was asked and by whom** — a sender suddenly asking a hundred times is the signal;
- **what the bot could not answer.** In the FAQ template every `needsHuman: true` is a question your FAQ
  should have covered. That log is your FAQ backlog, and shortening it reduces spend.

## What this kit proves

`tests/smoke/14-ai-faq-bot.sh` drives the two guardrails that do not need a vendor, on every CI run:

- a request with **no secret** and one with the **wrong secret** are refused;
- the rate limit runs against the **real Valkey**: 23 questions from one sender in one minute split exactly
  **20 answered / 3 refused with 429**, the refused sender stays refused for the rest of that minute with a
  `retryAfterSeconds` it can use, a **different sender is unaffected**, and the counter exists in the broker
  with a TTL under 120 s;
- a 600-character question is refused **before** the model would have run.

The model call itself is stubbed — CI holds no model credential, and a test that paid a vendor per run would
be a bad test. That leg is one question from your own terminal, and the template's README step 4 is it.

---

## See also

- [`templates/ai-faq-bot/`](https://github.com/nhhandevops/n8n-prod-kit/tree/main/templates/ai-faq-bot) — the worked example
- [Calling other APIs](outbound-apis.md) — the same relationship from the other side: their rate limit, your retries
- [Idempotency](idempotency.md) — why an atomic counter and not a read-then-write check
- [Monitoring and alerts](monitoring.md) — the execution-rate panels that double as a spend signal
- [Security](../security.md) — what else is exposed, and what the kit closes by default
