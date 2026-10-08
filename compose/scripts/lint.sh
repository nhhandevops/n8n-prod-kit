#!/usr/bin/env bash
# compose/scripts/lint.sh — static checks for the Compose kit (`make lint`, also run by CI on every PR).
#
#   1. shellcheck -x on every script (the repo's .shellcheckrc enables all optional checks)
#   2. yamllint on the compose files (repo .yamllint: 160 columns, truthy/document-start off)
#   3. docker compose config -q — with the real .env when present, otherwise with a throw-away env built
#      from .env.example plus dummy secrets, so the check works on a fresh clone and in CI
#   4. caddy validate inside the pinned Caddy image for EVERY TLS_MODE x UI_PROTECT x KUMA_ENABLED
#      combination (the snippet files are only loaded by the combination that names them)
#   5. the monitoring profile: yamllint + dashboards JSON + promtool / loki -verify-config / alloy fmt in their images
# Exit 1 on the first failing group; prints what it ran so a CI log is self-explanatory.
# shellcheck disable=SC2312,SC2016
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

need_cmd docker shellcheck yamllint grep awk mktemp jq

status=0
tmp_env=''
cleanup() {
  if [[ -n "${tmp_env}" && -f "${tmp_env}" ]]; then
    rm -f "${tmp_env}"
  fi
}
trap cleanup EXIT

# --- 1. shellcheck -------------------------------------------------------------------------------------------------
# -x follows `source` so lib.sh is checked in the context of every caller (SC1091 otherwise reports "not following").
info "shellcheck -x scripts/*.sh"
if shellcheck -x scripts/*.sh; then
  ok "shellcheck clean"
else
  fail "shellcheck reported problems"
  status=1
fi

# --- 2. yamllint ----------------------------------------------------------------------------------------------------
yaml_files=(docker-compose.yml compose.dev.yml)
if [[ -f compose.scale.yml ]]; then
  yaml_files+=(compose.scale.yml)
fi
# yamllint only looks for .yamllint in the current directory; the repo keeps one at its root.
yamllint_args=(-s)
if [[ -f "${KIT_DIR}/../.yamllint" ]]; then
  yamllint_args+=(-c "${KIT_DIR}/../.yamllint")
fi
info "yamllint ${yamllint_args[*]} ${yaml_files[*]}"
if yamllint "${yamllint_args[@]}" "${yaml_files[@]}"; then
  ok "yamllint clean"
else
  fail "yamllint reported problems"
  status=1
fi

# --- 3. docker compose config ---------------------------------------------------------------------------------------
env_for_config="${KIT_DIR}/.env"
if [[ ! -f "${env_for_config}" ]]; then
  tmp_env="$(mktemp "${KIT_DIR}/.env.lint.XXXXXX")"
  cp .env.example "${tmp_env}"
  {
    printf 'DOMAIN=n8n.example.com\nACME_EMAIL=admin@example.com\nPUBLIC_URL=https://n8n.example.com/\n'
    printf 'N8N_ENCRYPTION_KEY=lint-only-lint-only-lint-only-lint-only-lint-only-lint-only-lint\n'
    printf 'POSTGRES_PASSWORD=lintlintlintlint\nVALKEY_PASSWORD=lintlintlintlint\n'
    printf 'N8N_RUNNERS_AUTH_TOKEN=lintlintlintlint\nGRAFANA_ADMIN_PASSWORD=lintlint\n'
  } >>"${tmp_env}"
  env_for_config="${tmp_env}"
  info "no .env — compose config runs against .env.example + dummy secrets"
fi
info "docker compose config -q (docker-compose.yml + compose.dev.yml)"
if docker compose --project-directory "${KIT_DIR}" --env-file versions.env --env-file "${env_for_config}" \
    -f docker-compose.yml -f compose.dev.yml config -q; then
  ok "compose config parses"
else
  fail "compose config failed"
  status=1
fi

# --- 4. caddy validate ----------------------------------------------------------------------------------------------
caddy_image="$(env_get CADDY_IMAGE versions.env):$(env_get CADDY_VERSION versions.env)"
# A real bcrypt hash (of the string "secret") — Caddy validates the hash format at provision time, so a placeholder
# such as "x" would fail with "illegal base64 data" and hide real errors.
lint_hash='$2a$14$F5ChMWCL9FuTubLx0Z1.nOw90btPQPpHjdoyFx6ENIZrLPqvSwhHe'
caddy_failures=0
info "caddy validate in ${caddy_image} (TLS_MODE x UI_PROTECT x KUMA_ENABLED)"
for tls in internal acme acme-staging; do
  for ui in off on; do
    for kuma in off on; do
      if out="$(docker run --rm -v "${KIT_DIR}/caddy:/etc/caddy:ro" \
          -e DOMAIN=n8n.example.com -e ACME_EMAIL=admin@example.com -e TLS_MODE="${tls}" \
          -e HTTP_PORT=80 -e HTTPS_PORT=443 -e UI_PROTECT="${ui}" -e UI_ALLOW_CIDR='0.0.0.0/0 ::/0' \
          -e UI_BASIC_AUTH_USER=admin -e UI_BASIC_AUTH_HASH="${lint_hash}" -e KUMA_ENABLED="${kuma}" \
          -e WEBHOOK_UPSTREAMS='n8n-webhook-1:5678 n8n-webhook-2:5678' \
          "${caddy_image}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
        ok "caddy validate tls=${tls} ui=${ui} kuma=${kuma}"
      else
        fail "caddy validate tls=${tls} ui=${ui} kuma=${kuma}"
        printf '%s\n' "${out}" | grep -E '"level":"error"|^Error|error' | head -5 >&2
        caddy_failures=$((caddy_failures + 1))
      fi
    done
  done
done
if (( caddy_failures > 0 )); then
  status=1
fi

# --- 5. monitoring profile configuration ---------------------------------------------------------------------------
# Each config is checked by its own tool inside the pinned image. *_IMAGE from the environment overrides versions.env
# (CI uses Docker Hub mirrors). Grafana's provisioning has no offline validator: smoke 09 checks it on a live stack.
image_of() {   # image_of KEY -> <image>:<version>
  local img
  img="$(printenv "${1}_IMAGE" || true)"
  printf '%s:%s\n' "${img:-$(env_get "${1}_IMAGE" versions.env)}" "$(env_get "${1}_VERSION" versions.env)"
}
lint_run() {   # lint_run WHAT docker-run-args... — run, print the tool output only on failure
  local what="${1}" out
  shift
  if out="$(docker run --rm "${@}" 2>&1)"; then
    ok "${what}"
  else
    fail "${what}"
    printf '%s\n' "${out}" | tail -8 >&2
    status=1
  fi
}
info "monitoring: yamllint, dashboards JSON, promtool, loki -verify-config, alloy fmt"
mapfile -t monitoring_yaml < <(find monitoring -name '*.yml' -not -path '*/targets/*' | sort)
if yamllint "${yamllint_args[@]}" "${monitoring_yaml[@]}"; then
  ok "yamllint monitoring/ (${#monitoring_yaml[@]} files)"
else
  fail "yamllint monitoring/"
  status=1
fi
for dashboard in monitoring/grafana/dashboards/*.json; do
  if jq -e '.uid and .title and (.panels | length > 0)' "${dashboard}" >/dev/null; then
    ok "dashboard ${dashboard##*/}"
  else
    fail "dashboard ${dashboard##*/} is not valid dashboard JSON (uid, title, panels)"
    status=1
  fi
done
# promtool also reads the file_sd target files; a fresh clone has none yet (render.sh writes them), so check a copy
lint_targets="$(mktemp -d)"
cp -r monitoring/prometheus/. "${lint_targets}/"
if [[ ! -f "${lint_targets}/targets/n8n.json" ]]; then
  printf '[{"targets": ["n8n-worker-1:5678"]}]\n' >"${lint_targets}/targets/n8n.json"
fi
chmod -R a+rX "${lint_targets}"
lint_run "promtool check config" -v "${lint_targets}:/etc/prometheus:ro" --entrypoint promtool \
  "$(image_of PROMETHEUS)" check config /etc/prometheus/prometheus.yml
rm -rf "${lint_targets}"
lint_run "loki -verify-config" -v "${KIT_DIR}/monitoring/loki/loki.yml:/etc/loki/loki.yml:ro" -e LOKI_RETENTION=336h \
  "$(image_of LOKI)" -config.file=/etc/loki/loki.yml -config.expand-env=true -verify-config
lint_run "alloy fmt (syntax)" -v "${KIT_DIR}/monitoring/alloy/config.alloy:/c.alloy:ro" "$(image_of ALLOY)" fmt /c.alloy

if (( status == 0 )); then
  ok "lint: all checks passed"
else
  die "lint: some checks failed (see above)"
fi
