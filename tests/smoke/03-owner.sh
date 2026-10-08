#!/usr/bin/env bash
# 03-owner — the instance has an owner (created on first run), login works and rejects a wrong password, and an
# API key for the public API exists and is accepted while a bogus key is rejected.
# shellcheck disable=SC2310,SC2311,SC2312,SC2329,SC2016  # functions run via check/wait_for; bash -c snippets are literal on purpose
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh"

req GET /rest/settings
check "/rest/settings answers 200" status_is 200
check "owner account available" ensure_owner

# Exactly two login attempts per run (n8n allows 5 per window): one wrong, one right.
login_attempt "$(jq -nc --arg e "${SMOKE_OWNER_EMAIL:-}" '{emailOrLdapLoginId: $e, password: "definitely-wrong-1A"}')"
check "wrong password rejected (HTTP ${REQ_STATUS})" status_is 401

check "owner login works" ensure_session fresh
check "logged-in user is the instance owner" test "$(req_body | jq -r '.data.role')" = "global:owner"

check "API key available" ensure_api_key
api GET '/api/v1/workflows?limit=1'
check "public API accepts the key (HTTP ${REQ_STATUS})" status_is 200
req GET '/api/v1/workflows?limit=1' -H 'X-N8N-API-KEY: not-a-real-key'
check "public API rejects a bogus key (HTTP ${REQ_STATUS})" status_is 401
finish
