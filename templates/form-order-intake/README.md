# `form-order-intake` — a hosted order form, no credentials

A customer opens a link, fills in five fields, and gets a page back with a reference number they can quote
on the phone. n8n hosts the form itself: there is no website to build, no Google Form to copy answers out of,
and nothing to deploy when you change a field.

**It is the only template in the kit that needs no credential of any kind.** The only thing you set is the
form's path. That is asserted on every CI run, because it is the reason this is the first template to try on
a fresh stack.

What it does *not* do is keep the order anywhere. It validates one, answers the customer, and stops — the
hand-on is yours to add, and ["What to add next"](#what-to-add-next) is the shortest route to each option.

The mechanics of n8n's forms — the two routes a submission travels, the positional wire format, and the
retention cost of a completion page — are in
[docs/operations/forms.md](../../docs/operations/forms.md). This page is how to run it.

## The flow

```
Order form → Check the order → Usable order? ─true→ Confirm it            ("Da nhan don", with the reference)
 (/form/…)    (validate,                      └false→ Tell them what to fix ("Chua gui duoc", with the reason)
               normalise the phone,
               build the reference)
```

| Node | What it is for |
|---|---|
| **Order form** | The hosted form. Five fields: name, phone, item (dropdown), quantity, note. Serves the page on `GET /form/<path>` and accepts the submission on `POST`. |
| **Check the order** | The second line of validation — the things a browser cannot check. Normalises the phone, builds the reference, and decides `valid` / `problem`. It does **not** throw. |
| **Usable order?** | An IF on `valid`, strict type validation. |
| **Confirm it** | A Form Ending page: "order received", with the reference. |
| **Tell them what to fix** | A Form Ending page: what was wrong, in Vietnamese and English. |

## Set it up

1. **Import** `workflow.json` (*Workflows → ⋯ → Import from File*).

2. **Set the path.** Open **Order form** → **Options → Path** and replace `__PATH__` with something a customer
   can read, e.g. `dat-hang`. The form is then at `https://n8n.example.com/form/dat-hang`.

   **Do not put the path in the node's old top-level field** — at node version 2.2 and later n8n ignores it
   and serves the form at `/form/<a uuid>` instead, with a 404 at the path you chose. There is a whole
   section about this in [forms.md](../../docs/operations/forms.md#the-path-is-an-option-not-a-field); the
   short version is that the only place the path belongs is **Options**.

3. **Edit the fields** to be your fields. Two rules:

   - Keep a **Custom Field Name** on every field (the `fieldName` key). That is what the rest of the
     workflow reads, so a renamed label — a typo fixed, an English line added — cannot break anything
     downstream. `tests/smoke/15-form-order-intake.sh` asserts all five are still pinned.
   - **Leave the phone as a text field.** A number field eats the leading zero, and every Vietnamese mobile
     starts with one.

4. **Point *Settings → Error Workflow*** at the [`error-handler`](../error-handler/) template. The editor's
   import does **not** apply the file's `settings` (verified in the 2.46.7 editor), so this one is by hand.
   Without it, a form that breaks at 2 a.m. is silent.

5. **Publish it**, then submit one order yourself — from the browser, or from a terminal:

   ```bash
   # A submission is multipart with POSITIONAL keys, and it answers with the URL of the page to show.
   curl -sS -X POST https://n8n.example.com/form/dat-hang \
     -F 'field-0=Nguyen Thi Mai' -F 'field-1=+84 901 234 567' -F 'field-2=Ca phe sua da' \
     -F 'field-3=2' -F 'field-4=giao truoc 9h'
   # -> {"formWaitingUrl":"https://n8n.example.com/form-waiting/1234?signature=…"}
   #    GET that URL to get the page the customer reads.
   ```

   There is no `test-payload.json` here, unlike the kit's other templates: the Form Trigger rejects anything
   that is not `multipart/form-data`, so the curl above *is* the payload. The field keys are positional
   (`field-0` … `field-4`), which means **reordering the fields is a breaking change** for anything that
   posts directly.

## What to add next

The template ends at the confirmation page. Insert your hand-on **before** *Confirm it*, so a customer is
only told "received" once it is:

| To do this | Add | And read |
|---|---|---|
| Keep the order where staff can see it | the Google Sheets node from [`sheets-order-log`](../sheets-order-log/) | [Calling other APIs](../../docs/operations/outbound-apis.md) |
| Tell someone an order arrived | the HTTP Request node from [`gchat-approval`](../gchat-approval/) | [Approvals](../../docs/operations/approvals.md) |
| Hold orders in your own database | the claim query from [`idempotent-webhook`](../idempotent-webhook/) | [Idempotency](../../docs/operations/idempotency.md) |

## Decisions worth knowing before you edit it

- **The confirmation is shown after the workflow runs** (`responseMode: lastNode`), which is what lets it
  carry the reference. The alternative, *On Received*, answers before the workflow runs — so a customer who
  typos their phone number reads "thanks, we will call you" and then never hears from anyone. A lost order
  every time is worse than the retention cost in the next point.
- **Every submission parks an execution for ever.** A Form Ending node stops its execution at n8n's
  wait-indefinitely sentinel and never resumes it, and pruning skips `waiting` executions outright — so each
  submission leaves a row that nothing deletes on its own, and those rows count toward
  `EXECUTIONS_DATA_PRUNE_MAX_COUNT` for *every* workflow on the instance.
  [forms.md](../../docs/operations/forms.md#the-cost-of-a-completion-page) has the measured size and the
  sweep. Budget for it, or run the sweep monthly; do not discover it at 10 000 orders.
- **The validation does not throw.** A human is reading the other end. An n8n error page with a stack trace
  is not an answer to "I typed my phone wrong", so an invalid order is routed to a page that says what to
  fix — one problem at a time, because a form that lists five faults at once gets abandoned.
- **The phone is normalised, not just checked.** `+84 901 234 567`, `0901-234-567` and `0901234567` are one
  customer, and they become one string (`0901234567`). Without that, your "how many repeat customers?" query
  is wrong and nobody can tell why.
- **The reference is not a token.** `DH-20261118-A7KQ` is a date plus four random characters, meant to be
  read out over the phone. It is unique enough that two orders in the same minute cannot collide, and not
  secret — do not use it to authorise anything.
- **The form is public.** Anyone with the link can submit, as many times as they like; that is what a form
  is. If your hand-on costs money or quota per order, put a gate in front of it —
  [Endpoints that cost money](../../docs/operations/paid-endpoints.md) is the pattern, and
  `templates/ai-faq-bot/` is a working one.
- **A dropdown is a closed list.** The item field ships with four options including *Khac / Other*, which
  sends the customer to the note field. A free-text item field is one edit away, and then your records have
  "ca phe sua da", "Cafe sua da" and "CF sữa đá" in them. Prefer the dropdown.

## Tested

`tests/smoke/15-form-order-intake.sh` imports **this** `workflow.json` on every CI run and drives it on a
real stack: the form is served from the webhook pool (never main) at the path from *Options*, a good order is
accepted and its confirmation page carries the reference, the phone is normalised, the quantity arrives as a
number, the pinned field names are what the workflow sees, and four bad orders — a non-Vietnamese number,
quantity 0, quantity 100, no name — each come back on the "what to fix" page with the right reason rather
than an error page. It also asserts the parking behaviour described above, so that a future n8n version
changing it is a failing test rather than a surprise.

It is the only template whose tested path involves no vendor at all: nothing in this flow leaves your host.
