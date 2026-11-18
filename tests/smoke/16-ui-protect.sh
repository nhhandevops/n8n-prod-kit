#!/usr/bin/env bash
# 16-ui-protect — UI_PROTECT=on, exercised with real requests instead of only parsed.
#
# Why this exists: `make lint` runs `caddy validate` for all twelve TLS_MODE x UI_PROTECT x KUMA_ENABLED
# combinations, so the kit knew the config PARSES — and nothing had ever sent a request through it. The docs
# make four behavioural claims about it (docs/configuration.md, docs/faq.md, docs/architecture.md), every one
# of them untested until now, and PROD-PLAN's **D-3** is "UI_PROTECT=on with an allow-list and basic auth,
# verified from outside": this script is the half that does not need an outside vantage point.
#
# What it proves, in the order the claims matter:
#   1. a client outside UI_ALLOW_CIDR gets a bare **403** and is never offered a password prompt — the
#      ordering that ui-protect-on.caddy's `route` wrapper exists for (inside a plain `handle`, Caddy would
#      sort basic_auth ahead of respond and leak a 401 challenge to blocked addresses);
#   2. inside the CIDR, the editor answers **401** with a `WWW-Authenticate` challenge, **200** with the
#      right password and **401** with the wrong one;
#   3. **production traffic is not behind the password**: /webhook/*, /form/*, /form-waiting/*,
#      /webhook-waiting/* and both health paths stay open with no credentials at all. This is the claim
#      `templates/form-order-intake/` depends on — a form customers cannot reach is not a form;
#   4. **/rest and /api/v1 ARE behind it**, which is the trap worth knowing before go-live: with a tight
#      UI_ALLOW_CIDR, every kit script that talks to the API from the host (this suite, kuma-setup) is
#      blocked too, because `remote_ip` is the Docker bridge gateway and not 127.0.0.1.
#
# NOT asserted: `request_header -Authorization` (the edge password is not forwarded upstream). Proving it
# needs an upstream that echoes headers, and the only protected path that could is a *test* webhook, which
# answers solely while the editor is listening. The directive is in ui-protect-on.caddy and reviewed there.
#
# Flipping UI_PROTECT is a change to the operator's own .env, so it is OPT-IN:
#   * UI_PROTECT already on  -> runs read-only against the live setting (needs UI_BASIC_AUTH_* to be known);
#   * SMOKE_UI_PROTECT=1     -> flips it on with a generated password, runs, and restores all four variables;
#   * otherwise              -> skips, like 09-monitoring does without the monitoring profile.
# The restore runs from a trap and is asserted at the end: a half-finished run must never leave somebody
# locked out of their own editor.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329  # functions run via check/wait_for
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

ui_protect_now="$(env_get UI_PROTECT)"
ui_protect_now="${ui_protect_now:-off}"

if [[ "${ui_protect_now}" != "on" && "${SMOKE_UI_PROTECT:-}" != "1" ]]; then
  info "skipped: UI_PROTECT=${ui_protect_now} in compose/.env"
  info "  this script changes UI_PROTECT and restores it, so it asks first:"
  info "  SMOKE_UI_PROTECT=1 make -C compose smoke ONLY=16"
  finish
fi

ensure_api_key || die "no API key (run 03-owner first)"

# --- everything that needs the API happens BEFORE the protection goes on ----------------------------------
# With UI_PROTECT=on, /api/v1 is behind the edge password (claim 4), so the fixtures cannot be created later.
nonce="$(rand_hex 6)"
hook_path="kit-smoke-uip-${nonce}"
form_path="kit-smoke-uipform-${nonce}"

api POST /api/v1/workflows "$(workflow_from_fixture wf-webhook-echo.json "kit-smoke-uip-${nonce}" "${hook_path}")"
hook_id="$(req_body | jq -r '.id // empty')"
check "a webhook workflow to probe with (HTTP ${REQ_STATUS})" test -n "${hook_id}"
[[ -n "${hook_id}" ]] || finish
api POST "/api/v1/workflows/${hook_id}/activate"
check "...published (HTTP ${REQ_STATUS})" status_is 200

form_json="$(jq -c --arg n "kit-smoke-uipform-${nonce}" --arg p "${form_path}" '
  .name = $n
  | .nodes = [ .nodes[] | if .type == "n8n-nodes-base.formTrigger" then .parameters.options.path = $p else . end ]
  ' "${SMOKE_DIR}/../../templates/form-order-intake/workflow.json")"
api POST /api/v1/workflows "${form_json}"
form_id="$(req_body | jq -r '.id // empty')"
check "a form workflow to probe with (HTTP ${REQ_STATUS})" test -n "${form_id}"
[[ -n "${form_id}" ]] || finish
api POST "/api/v1/workflows/${form_id}/activate"
check "...published (HTTP ${REQ_STATUS})" status_is 200

# The echo fixture is POST-only, so a GET would 404 for a reason that has nothing to do with the password.
ping_webhook() {
  req POST "/webhook/${hook_path}" -H 'Content-Type: application/json' --data "{\"ping\":\"${nonce}\"}"
}
webhook_ready() { ping_webhook; status_is 200; }
form_ready() { req GET "/form/${form_path}"; status_is 200; }
check "the webhook answers before the protection goes on (<= 180 s)" \
  wait_for 180 "the webhook to register on the pool" webhook_ready
check "the form answers before the protection goes on (<= 180 s)" \
  wait_for 180 "the form to register on the pool" form_ready

# --- turn the protection on, remembering what to put back -------------------------------------------------
orig_protect="$(env_get UI_PROTECT)"
orig_cidr="$(env_get UI_ALLOW_CIDR)"
orig_user="$(env_get UI_BASIC_AUTH_USER)"
orig_hash="$(env_get UI_BASIC_AUTH_HASH)"
restored=0

restore_env() {
  [[ "${restored}" == "0" ]] || return 0
  restored=1
  env_set UI_PROTECT "${orig_protect}"
  env_set UI_ALLOW_CIDR "${orig_cidr}"
  env_set UI_BASIC_AUTH_USER "${orig_user}"
  env_set UI_BASIC_AUTH_HASH "${orig_hash}"
  compose up -d --no-deps --force-recreate caddy >/dev/null 2>&1 || true
}
trap restore_env EXIT

apply_caddy() {   # apply_caddy CIDR -> recreate caddy with the current .env and wait for it to answer
  env_set UI_ALLOW_CIDR "${1}"
  compose up -d --no-deps --force-recreate caddy >/dev/null 2>&1
  local try
  for try in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(service_health caddy)" == "healthy" ]] && break
    sleep 2
  done
  edge_up() { req GET /healthz; [[ "${REQ_STATUS}" != "000" ]]; }
  wait_for 60 "the edge to answer again" edge_up >/dev/null
}

if [[ "${ui_protect_now}" != "on" ]]; then
  ui_pass="$(rand_hex 16)"
  ui_hash="$(compose exec -T caddy caddy hash-password --plaintext "${ui_pass}" 2>/dev/null | tr -d '\r\n')"
  check "caddy hashed a generated password (bcrypt)" grep -qE '^\$2[aby]\$[0-9]{2}\$' <<<"${ui_hash}"
  env_set UI_PROTECT on
  env_set UI_BASIC_AUTH_USER kitsmoke
  env_set UI_BASIC_AUTH_HASH "${ui_hash}"
  # The hash is full of '$'. It must land in .env single-quoted or Compose interpolation eats it and no
  # password ever matches — the FAQ entry for "the basic-auth password never matches". env_set does that;
  # this asserts it, because the failure is silent and costs an hour.
  check "the bcrypt hash is stored so Compose cannot interpolate it away" \
    grep -qE "^UI_BASIC_AUTH_HASH='\\\$2[aby]\\\$" "${KIT_DIR}/.env"
  ui_user=kitsmoke
else
  ui_user="${orig_user}"
  ui_pass="${SMOKE_UI_PASSWORD:-}"
  [[ -n "${ui_pass}" ]] ||
    info "UI_PROTECT was already on: export SMOKE_UI_PASSWORD to also check that the right password works"
fi

# --- 1. inside the allow-list: the password is the gate ---------------------------------------------------
apply_caddy '0.0.0.0/0 ::/0'

req GET /
check "the editor answers 401 with no credentials (HTTP ${REQ_STATUS})" status_is 401
check "...offering a basic-auth challenge ($(header_of WWW-Authenticate))" \
  grep -qi '^basic' <<<"$(header_of WWW-Authenticate)"
check "...and the realm is not n8n's login page (no HTML body)" \
  bash -c '[[ $(wc -c <"$1") -lt 200 ]]' _ "${STATE_DIR}/last.body"

req GET / -u "${ui_user}:wrong-${RANDOM}"
check "a wrong password is refused (HTTP ${REQ_STATUS})" status_is 401

if [[ -n "${ui_pass}" ]]; then
  req GET / -u "${ui_user}:${ui_pass}"
  check "the right password reaches n8n's own login page (HTTP ${REQ_STATUS})" status_is 200
fi

# claim 4, the one that bites the operator's own tooling
req GET /rest/settings
check "/rest is behind the edge password too (HTTP ${REQ_STATUS})" status_is 401
api GET '/api/v1/workflows?limit=1'
check "/api/v1 is behind it even with a valid API key (HTTP ${REQ_STATUS})" status_is 401
info "that is the go-live trap: with a tight UI_ALLOW_CIDR, this suite and kuma-setup are blocked as well —"
info "  a request from the host arrives from the Docker bridge gateway, not 127.0.0.1"

# claim 3: nothing a customer touches is behind the password
ping_webhook
check "a production webhook stays open (HTTP ${REQ_STATUS})" status_is 200
check "...and was not challenged" test -z "$(header_of WWW-Authenticate)"
req GET "/form/${form_path}"
check "a hosted form stays open (HTTP ${REQ_STATUS})" status_is 200
check "...and was not challenged" test -z "$(header_of WWW-Authenticate)"
req GET "/form-waiting/1?signature=not-a-real-token"
check "/form-waiting is n8n's to refuse, not Caddy's (HTTP ${REQ_STATUS}, no challenge)" \
  test -z "$(header_of WWW-Authenticate)"
req GET "/webhook-waiting/1?signature=not-a-real-token"
check "/webhook-waiting likewise (HTTP ${REQ_STATUS}, no challenge)" \
  test -z "$(header_of WWW-Authenticate)"
req GET /healthz
check "/healthz stays open (HTTP ${REQ_STATUS})" status_is 200
req GET /healthz/webhook
check "/healthz/webhook stays open (HTTP ${REQ_STATUS})" status_is 200

# --- 2. outside the allow-list: 403, and never a prompt ---------------------------------------------------
apply_caddy '203.0.113.0/24'

req GET /
check "from outside UI_ALLOW_CIDR the editor answers 403 (HTTP ${REQ_STATUS})" status_is 403
check "...with NO password prompt — the ordering ui-protect-on.caddy's route wrapper exists for" \
  test -z "$(header_of WWW-Authenticate)"
req GET / -u "${ui_user}:${ui_pass:-whatever}"
check "...and a correct password does not get in either (HTTP ${REQ_STATUS})" status_is 403
ping_webhook
check "the allow-list does not touch production webhooks (HTTP ${REQ_STATUS})" status_is 200
req GET "/form/${form_path}"
check "nor hosted forms (HTTP ${REQ_STATUS})" status_is 200

# --- 3. put it back, and prove it went back ---------------------------------------------------------------
restore_env
check "UI_PROTECT is back to '${orig_protect:-off}' in .env" \
  test "$(env_get UI_PROTECT)" = "${orig_protect}"
check "UI_ALLOW_CIDR is back to what it was" test "$(env_get UI_ALLOW_CIDR)" = "${orig_cidr}"
check "UI_BASIC_AUTH_HASH is back to what it was" test "$(env_get UI_BASIC_AUTH_HASH)" = "${orig_hash}"
editor_open() { req GET /; [[ "${REQ_STATUS}" == "200" ]]; }
if [[ "${orig_protect}" != "on" ]]; then
  check "the editor is reachable again without a password" wait_for 60 "the edge to come back" editor_open
fi

finish
