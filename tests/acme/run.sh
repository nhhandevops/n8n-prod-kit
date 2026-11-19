#!/usr/bin/env bash
# tests/acme/run.sh — does the kit's ACME path actually work?
#
# Every row in docs/compat.md is an internal CA, so the kit's headline claim — a fresh host gets a publicly
# trusted certificate — rested on config that had never once completed an ACME order. This exercises that
# path against **Pebble**, Let's Encrypt's own test CA: a real ACME account, a real order, a real HTTP-01
# validation against the real Caddyfile, and a real certificate served over TLS.
#
# What it proves: the shipped Caddyfile's ACME branch is structurally correct — Caddy registers, is
# challenged on its HTTP port, installs the certificate, and serves it for DOMAIN with the kit's security
# headers in place.
# What it CANNOT prove, and nothing on a private host can: public DNS, a reachable port 80 from the internet,
# Let's Encrypt's own rate limits, and the IPv6 preference that `make preflight` now checks for. Those stay
# open until a public host exists (ledger D-9).
#
# Nothing of the kit's own stack is touched: separate project name, separate network, ports 8080/8443, and
# only 127.0.0.1 publishings. Safe to run beside a live stack.
#
# Usage:  tests/acme/run.sh            (KEEP=1 leaves the containers up for inspection)
# shellcheck disable=SC2310,SC2311,SC2312,SC2016  # functions run via check/retry; the `bash -c` snippet is literal
set -euo pipefail

ACME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KIT_DIR="$(cd "${ACME_DIR}/../../compose" && pwd)"
# shellcheck source=../../compose/scripts/lib.sh
source "${KIT_DIR}/scripts/lib.sh"

need_cmd docker curl openssl

STATE="${ACME_DIR}/.state"
PROJECT=kitacme
FAILED=0
DOMAIN_UNDER_TEST=n8n.localtest.me

check() {   # check "description" cmd...
  local desc="${1}"
  shift
  if "${@}" >/dev/null 2>&1; then
    ok "${desc}"
  else
    fail "${desc}"
    FAILED=$((FAILED + 1))
  fi
}

# The smoke suite's wait_for lives in tests/smoke/lib.sh, which cannot be sourced here: it requires a
# configured kit (.env, PUBLIC_URL, compose/.smoke) and this harness deliberately depends on none of that.
retry() {   # retry SECONDS cmd...
  local deadline=$(( SECONDS + ${1} ))
  shift
  until "${@}" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

# Pebble is pinned by digest like everything else the kit pulls. `latest` is the only tag the project
# publishes, which is exactly why the digest matters.
PEBBLE_DIGEST="${PEBBLE_DIGEST:-sha256:0c81f05db371f436c97fb894bd6d2ab8fc9c8e2ce40f8bef8a8e15941bcd75ef}"

# shellcheck disable=SC2317  # runs from the trap
cleanup() {
  if [[ "${KEEP:-}" == "1" ]]; then
    info "KEEP=1 — leaving the containers up: docker compose -p ${PROJECT} -f ${ACME_DIR}/docker-compose.yml logs"
    return 0
  fi
  acme_compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${STATE}"
}
trap cleanup EXIT

acme_compose() {
  PEBBLE_DIGEST="${PEBBLE_DIGEST}" \
    docker compose -p "${PROJECT}" --project-directory "${ACME_DIR}" \
    --env-file "${KIT_DIR}/versions.env" -f "${ACME_DIR}/docker-compose.yml" "${@}"
}

mkdir -p "${STATE}"

# --- the CA's own API certificate ------------------------------------------------------------------------
# Caddy will not talk to an ACME directory it cannot verify, so the root that signs Pebble's API certificate
# has to be on disk before Caddy starts. It is inside the Pebble image; take it from there rather than
# vendoring a copy that would rot.
# The config Caddy will read: every shipped file, copied, plus the two the test adds. See the volumes comment
# in docker-compose.yml for why this is a copy rather than the directory itself.
info "assembling the Caddy config from compose/caddy/ plus the test's TLS policy"
mkdir -p "${STATE}/caddy"
cp -a "${KIT_DIR}/caddy/." "${STATE}/caddy/"
cp -a "${ACME_DIR}/tls-acmetest.caddy" "${STATE}/caddy/tls-acmetest.caddy"
check "the Caddyfile under test is byte-identical to the shipped one" \
  cmp -s "${KIT_DIR}/caddy/Caddyfile" "${STATE}/caddy/Caddyfile"

# The image is distroless — no shell, no cat, no ls — so the file is taken out with `docker cp` from a
# container that is created and never started. (`docker run --entrypoint cat` fails with
# "executable file not found in $PATH", which is how this was found.)
info "extracting Pebble's API root from the image"
pebble_cid="$(docker create "ghcr.io/letsencrypt/pebble@${PEBBLE_DIGEST}")"
docker cp "${pebble_cid}:/test/certs/pebble.minica.pem" - 2>/dev/null |
  tar -xO >"${STATE}/caddy/pebble-minica.pem"
docker rm -f "${pebble_cid}" >/dev/null 2>&1 || true
check "Pebble's API root extracted ($(wc -c <"${STATE}/caddy/pebble-minica.pem" 2>/dev/null || echo 0) bytes)" \
  openssl x509 -in "${STATE}/caddy/pebble-minica.pem" -noout -subject

# --- up -------------------------------------------------------------------------------------------------
info "starting Pebble and the kit's Caddy (project ${PROJECT}, ports 8080/8443)"
acme_compose up -d --quiet-pull

# Caddy validates the whole shipped Caddyfile at startup, so a config that does not parse never gets this far.
caddy_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${PROJECT}-caddy-1" 2>/dev/null)" == "true" ]]
}
check "the kit's Caddyfile started under TLS_MODE=acmetest" retry 60 caddy_running

# --- the certificate ------------------------------------------------------------------------------------
# The chain Pebble issues is signed by a root generated for this run, so the client trust comes from its
# management API rather than from a file in the repo.
roots_ready() {
  curl -fsS --max-time 5 --cacert "${STATE}/caddy/pebble-minica.pem" https://127.0.0.1:15000/roots/0 \
    -o "${STATE}/pebble-root.pem"
}
check "Pebble's issuing root fetched from its management API" retry 60 roots_ready

# This is the assertion the whole harness exists for: a TLS handshake for DOMAIN that validates against the
# CA's root means the full order — account, authorization, HTTP-01 challenge, finalize, install — completed.
served() {
  curl -sS --max-time 10 --cacert "${STATE}/pebble-root.pem" \
    --resolve "${DOMAIN_UNDER_TEST}:8443:127.0.0.1" \
    -o "${STATE}/body" -D "${STATE}/headers" \
    "https://${DOMAIN_UNDER_TEST}:8443/healthz"
}
check "Caddy completed an ACME order and serves a certificate the CA's root validates (<= 180 s)" \
  retry 180 served

# What was actually served, read off the wire rather than out of Caddy's storage.
leaf() {
  openssl s_client -connect "127.0.0.1:8443" -servername "${DOMAIN_UNDER_TEST}" \
    -CAfile "${STATE}/pebble-root.pem" </dev/null 2>/dev/null
}
leaf_text="$(leaf | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)"
printf '%s\n' "${leaf_text}" | sed 's/^/      /'
check "...for ${DOMAIN_UNDER_TEST} itself" grep -qF "CN=${DOMAIN_UNDER_TEST}" <<<"${leaf_text}"
check "...issued by Pebble, not by Caddy's internal CA" grep -qiE 'issuer=.*pebble' <<<"${leaf_text}"
chain_verifies() {
  openssl s_client -connect "127.0.0.1:8443" -servername "${DOMAIN_UNDER_TEST}" \
    -CAfile "${STATE}/pebble-root.pem" -verify_return_error </dev/null >/dev/null 2>&1
}
check "...and the chain verifies against the CA root" chain_verifies

# The ACME traffic itself, from the CA's side: proof the challenge was really served over HTTP rather than
# the certificate coming from anywhere else.
pebble_log="$(acme_compose logs pebble 2>/dev/null || true)"
check "Pebble recorded an HTTP-01 validation for ${DOMAIN_UNDER_TEST}" \
  grep -qE "http-01|HTTP-01" <<<"${pebble_log}"
check "...and finalized an order" grep -qiE 'finaliz|certificate' <<<"${pebble_log}"

# And the rest of the shipped edge still behaves while a real certificate is in play: the security headers
# are set by the same site block that the TLS policy lives in, so a mistake there would show here.
check "the kit's security headers are present on an ACME-served response" \
  grep -qi 'strict-transport-security' "${STATE}/headers"
check "...and the Server banner is still removed" bash -c '! grep -qi "^server:" "$1"' _ "${STATE}/headers"

if (( FAILED > 0 )); then
  warn "acme: ${FAILED} check(s) failed — rerun with KEEP=1 and read: docker compose -p ${PROJECT} logs caddy"
  exit 1
fi
ok "acme: the shipped Caddyfile completes a real ACME order against a test CA"
