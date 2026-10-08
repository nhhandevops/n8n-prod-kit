#!/usr/bin/env bash
# tests/ci/up.sh — bring the kit up on a fresh CI runner (GitHub Actions ubuntu-24.04) the way a user would:
# `make init` + `make up`, with exactly two CI-only adjustments:
#   1. the dev domain goes into /etc/hosts (n8n.localtest.me resolves publicly too; this removes the DNS dependency)
#   2. images are pulled from registries without Docker Hub's anonymous pull quota (shared runner IPs hit HTTP 429).
#      The digests in compose/versions.env stay authoritative — the mirrors serve the SAME manifests (verified
#      2026-10-08: ghcr.io/n8n-io/{n8n,runners}, ghcr.io/valkey-io/valkey, public.ecr.aws/docker/library/{caddy,postgres}),
#      so a mirror that ever diverged would fail the pull instead of running a different image.
# Used by .github/workflows/ci.yml (smoke job) and weekly-latest-n8n.yml. Needs passwordless sudo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
cd "${REPO_DIR}"

echo "127.0.0.1 n8n.localtest.me kuma.n8n.localtest.me" | sudo tee -a /etc/hosts >/dev/null
# age for `make init` (the init script falls back to the backup image's age when the host has none; CI uses the
# distribution package to exercise the common path)
sudo apt-get install -y -qq age >/dev/null
# Valkey wants overcommit (preflight only warns without it); bootstrap-host.sh sets the same on real hosts.
sudo sysctl -q -w vm.overcommit_memory=1

make -C compose init DOMAIN=n8n.localtest.me CI=1

cat >>compose/.env <<'ENV'

# --- CI only (tests/ci/up.sh): same digests as versions.env, registries without Docker Hub's anonymous quota ---
N8N_IMAGE=ghcr.io/n8n-io/n8n
RUNNERS_IMAGE=ghcr.io/n8n-io/runners
VALKEY_IMAGE=ghcr.io/valkey-io/valkey
CADDY_IMAGE=public.ecr.aws/docker/library/caddy
POSTGRES_IMAGE=public.ecr.aws/docker/library/postgres
ENV

make -C compose up
make -C compose doctor
