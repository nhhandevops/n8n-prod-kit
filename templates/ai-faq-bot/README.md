# `ai-faq-bot` — answer from your FAQ, or hand over to a human

A customer question arrives on a webhook, a model answers it **using only your FAQ**, and anything the FAQ
does not cover is handed to a person instead of guessed at.

This is the only template in the kit where **every answered request costs real money**, so most of it is
about deciding whether a request is worth paying for. Three guardrails run before the model does: a shared
secret, a rate limit per sender, and a cap on question length.

The wider topic — protecting an endpoint whose work is metered — is in
[docs/operations/paid-endpoints.md](../../docs/operations/paid-endpoints.md). This page is how to run it.

## The flow

```
Webhook (secret) → Check the question → Count this minute → Read the counter → Within the limit?
                                         (Valkey INCR)                          │
                                   ┌──────────────────────────────── true ──────┘
                                   │                                            └── false → 429
                                   └→ Answer from the FAQ ─→ Format the answer ─→ 200
                                      (model sub-node)        (KHONG_BIET → human)
```

| Node | What it is for |
|---|---|
| **Webhook** | Requires a shared secret (Header Auth). Answers through a Respond node so a refusal can be a real **429**. |
| **Check the question** | Trims, rejects an empty question, **caps length at 500**, and derives the sender and the per-minute counter key. |
| **Count this minute** | `INCR` in the kit's own Valkey — atomic, so a burst cannot slip past the limit. |
| **Read the counter** | Reads the count back (the Redis node returns it under the key's own name) and re-attaches the question. |
| **Within the limit?** | 20 per sender per minute, or the 429 branch. |
| **Answer from the FAQ** | The LLM Chain. Its system message holds **your FAQ** and the rules. |
| **Gemini (swap for your provider)** | The model sub-node — replace with OpenAI, Anthropic, Groq, Ollama, whatever you use. |
| **Format the answer** | Turns the model's `KHONG_BIET` into a hand-over, and flags `needsHuman`. |

## Set it up

1. **Three credentials.** Two are quick; one you may already have.

   | Credential | Type | Values |
   |---|---|---|
   | FAQ bot shared secret | *Header Auth* | name `X-Kit-FAQ-Secret`, value: a long random string you give to your callers |
   | Valkey | *Redis* | host `valkey`, port `6379`, database `0`, password = `VALKEY_PASSWORD` from `compose/.env` |
   | Your model | e.g. *Google Gemini (PaLM) API* | your API key |

   The Valkey one uses the broker this kit already runs — nothing new to deploy, and the counter costs
   nothing. It is the one credential whose values you already own.

2. **Import** `workflow.json`, pick those credentials on the three nodes that need them, and set the webhook
   **Path**.

   **The editor's import does not apply the file's `settings`**, so set *Settings → Error Workflow* by hand
   and point it at [`error-handler`](../error-handler/).

3. **Replace the FAQ.** Open **Answer from the FAQ** and edit the system message: the business name and the
   FAQ list. Everything the bot is allowed to say lives there. The shipped list is a coffee shop's, as an
   example of the shape — short, factual lines.

4. **Publish it**, then ask something:

   ```bash
   curl -sS -X POST https://n8n.example.com/webhook/<your-path> \
     -H 'Content-Type: application/json' -H 'X-Kit-FAQ-Secret: <your secret>' \
     --data @templates/ai-faq-bot/test-payload.json
   # -> {"answered":true,"answer":"...","needsHuman":false}
   ```

   Then ask something your FAQ does not cover. You should get `answered: false` and a hand-over message —
   **not** an invented answer. If you get an invented answer, your FAQ's rules are being ignored: check that
   rule 1 (reply `KHONG_BIET`) survived your edit.

## Why it refuses what it refuses

| Refused | Response | Because |
|---|---|---|
| no secret, or the wrong one | `401`/`403` | an unauthenticated metered endpoint is a budget anyone with the URL can spend |
| more than **20 questions a minute** from one sender | `429` + `retryAfterSeconds` | one caller in a loop should not be able to run up a bill |
| a question over **500 characters** | `500` | a 50 KB "question" is a mistake or an abuse of your budget as a pastebin |
| an empty question | `500` | nothing to answer |

n8n's own default for a webhook is **no** authentication, and that is right for an endpoint which only costs
CPU. This template departs from it deliberately.

## Decisions worth knowing before you edit it

- **`KHONG_BIET` is the whole guardrail.** The model is told to reply with exactly that when the FAQ does not
  answer the question, and **Format the answer** turns it into a hand-over with `needsHuman: true`. Without a
  sentinel, "the model is unsure" is a sentence a human has to judge; with one, it is a flag the workflow can
  act on. An FAQ bot's worst failure is confident invention — a made-up delivery fee is worse than no answer,
  because the customer believes it.
- **The counter key carries the minute** (`faq:rl:<sender>:<minute>`). n8n's Redis node calls `EXPIRE` on
  *every* `INCR`, so a single key per sender would have its window pushed out by continuous traffic and a
  busy sender would stay blocked until they stopped entirely. A fixed per-minute bucket makes that harmless.
- **The TTL is 120 s on a 60 s bucket.** The kit's Valkey runs `maxmemory-policy noeviction`, so counters
  that never expired would eventually fill the broker **the queue depends on**. Short TTLs keep a rate
  limiter from becoming an outage.
- **`maxOutputTokens` is 200 and `temperature` 0.2.** An FAQ answer is a lookup, not an essay, and output
  tokens are what the bill is made of.
- **The sender is caller-supplied** (`sender` in the body, falling back to `X-Forwarded-For`). It is a
  fairness key, not a security boundary — the shared secret is what keeps strangers out. If your callers are
  untrusted, derive the sender from something they cannot choose.
- **The model node is pinned to a named model**, not the node's default, because the default tracks preview
  models and a preview can be withdrawn under a shipped template. The field is a dropdown populated from
  your own account: pick the current flash-class model you actually have.
- **What the bot could not answer is your FAQ backlog.** Every `needsHuman: true` is a question your FAQ
  should cover. Log them.

## Tested

`tests/smoke/14-ai-faq-bot.sh` runs on every CI run. Two of the three guardrails are exercised **for real**:
a request with no secret and one with the wrong secret are refused; and the rate limit is driven against the
kit's actual Valkey — 23 questions from one sender in one minute split **exactly 20 answered / 3 refused with
429**, the refused sender stays refused for the rest of that minute with a `retryAfterSeconds` the caller can
use, a *different* sender is unaffected, and the counter exists in the broker with a TTL under 120 s. The
500-character cap is refused before the model would have run.

The model call is **stubbed**: the chain and its model sub-node are replaced by a Code node returning either
a canned answer or the `KHONG_BIET` sentinel, so both post-model paths are asserted. CI has no model
credential — and a test that paid a vendor per run would be a bad test. Your own first question (step 4) is
the only part that exercises the real model.
