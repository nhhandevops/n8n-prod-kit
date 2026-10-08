#!/usr/bin/env bash
# compose/scripts/pin.sh — resolve the image tags of versions.env to immutable index digests and
# rewrite the *_DIGEST lines in place. S2 contract §0, §3, §7 "pin.sh".
#
# Usage:
#   make pin [N8N_VERSION=2.42.5]     resolve every image, rewrite changed *_DIGEST lines
#   scripts/pin.sh --check            no network: exit 1 if any *_DIGEST is empty or malformed
#                                     (init.sh and preflight.sh call this)
# Environment:
#   N8N_VERSION=x        rewrite N8N_VERSION= first (n8n AND the runners sidecar share it — the
#                        kit's version lock), then resolve
#   PIN_FORCE_HUB_API=1  skip `docker buildx imagetools` and go straight to the registry HTTP APIs
#                        (useful when the Docker Hub anonymous pull quota is exhausted, HTTP 429)
#
# Why digests: a tag can be re-pushed; `image: name:tag@sha256:…` makes every `make up` start the
# exact bytes that were tested. The compose file requires them (`${X_DIGEST:?run make pin}`).
#
# Resolution order per image (first success wins; every failure is explained on stderr):
#   1. docker buildx imagetools inspect <ref> --format '{{.Manifest.Digest}}'   (the index digest —
#      the same value `docker pull` prints — for multi-arch and single-arch images alike)
#   2. Docker Hub tags API   https://hub.docker.com/v2/repositories/<ns>/<name>/tags/<tag>  -> .digest
#      Only for Hub-hosted images: `caddy` -> library/caddy, `valkey/valkey`, `n8nio/runners`, and
#      docker.n8n.io/n8nio/n8n -> n8nio/n8n (docker.n8n.io is a redirect to Docker Hub). This API is
#      NOT subject to the pull-rate quota that breaks step 1 on shared IPs (verified: 429 on 1, 200 here).
#   3. Registry HTTP API v2 (any registry, e.g. ghcr.io/n8n-io/n8n): anonymous bearer token from the
#      WWW-Authenticate challenge, then HEAD /v2/<path>/manifests/<tag> -> Docker-Content-Digest.
# Non-zero exit if ANY image could not be resolved; the lines of the others are still rewritten.
set -euo pipefail
shopt -s inherit_errexit

__script_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
KIT_DIR="$(cd "${__script_dir}/.." && pwd)"
unset __script_dir
cd "${KIT_DIR}"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"

versions_file="${KIT_DIR}/versions.env"
# Capture the override BEFORE anything could set N8N_VERSION from the file.
requested_n8n_version="${N8N_VERSION:-}"
mode="pin"
for arg in "${@}"; do
  case "${arg}" in
    --check)
      mode="check"
      ;;
    -h | --help)
      sed -n '2,24p' "${BASH_SOURCE[0]:-$0}" >&2
      exit 0
      ;;
    *)
      die "unknown argument '${arg}' (usage: pin.sh [--check]; see --help)"
      ;;
  esac
done

if [[ ! -f "${versions_file}" ]]; then
  die "${versions_file} not found — the kit checkout is incomplete"
fi

# The pinned images: KEY -> <IMAGE var> <VERSION var>. RUNNERS has no version of its own. The second line is the
# monitoring profile (pinned even when the profile is off: compose interpolates every service's image).
pin_keys=(N8N RUNNERS CADDY POSTGRES VALKEY
  PROMETHEUS GRAFANA LOKI ALLOY NODE_EXPORTER CADVISOR KUMA)
version_var_of() {
  local key="${1}"
  if [[ "${key}" == "RUNNERS" ]]; then
    printf 'N8N_VERSION\n'
  else
    printf '%s_VERSION\n' "${key}"
  fi
}

is_digest() {
  [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]]
}

# --- --check: offline validation ------------------------------------------------------------------------------
if [[ "${mode}" == "check" ]]; then
  problems=0
  for key in "${pin_keys[@]}"; do
    version_var="$(version_var_of "${key}")"
    image="$(env_get "${key}_IMAGE" "${versions_file}")"
    version="$(env_get "${version_var}" "${versions_file}")"
    digest="$(env_get "${key}_DIGEST" "${versions_file}")"
    digest_ok=0
    # shellcheck disable=SC2310
    if is_digest "${digest}"; then
      digest_ok=1
    fi
    if [[ -z "${image}" || -z "${version}" ]]; then
      fail "${key}: ${key}_IMAGE/${version_var} missing in versions.env"
      problems=$((problems + 1))
    elif (( digest_ok == 0 )); then
      fail "${key}_DIGEST is empty or malformed for ${image}:${version} — run 'make pin'"
      problems=$((problems + 1))
    else
      ok "${key}: ${image}:${version}@${digest:0:19}…"
    fi
  done
  if (( problems > 0 )); then
    exit 1
  fi
  exit 0
fi

# --- pin: network resolution ----------------------------------------------------------------------------------
need_cmd curl jq

if [[ -n "${requested_n8n_version}" ]]; then
  current_n8n_version="$(env_get N8N_VERSION "${versions_file}")"
  if [[ "${requested_n8n_version}" != "${current_n8n_version}" ]]; then
    env_set N8N_VERSION "${requested_n8n_version}" "${versions_file}"
    info "N8N_VERSION: ${current_n8n_version} -> ${requested_n8n_version} (n8n and runners)"
  fi
fi

# 1. imagetools ---------------------------------------------------------------------------------------------------
digest_via_imagetools() {
  local ref="${1}"
  local out
  if [[ "${PIN_FORCE_HUB_API:-}" == "1" ]]; then
    info "  imagetools skipped (PIN_FORCE_HUB_API=1)"
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    info "  imagetools skipped (docker not installed)"
    return 1
  fi
  if ! out="$(docker buildx imagetools inspect "${ref}" --format '{{.Manifest.Digest}}' 2>&1)"; then
    warn "  imagetools failed: ${out##*$'\n'}"
    return 1
  fi
  out="${out//[[:space:]]/}"
  # shellcheck disable=SC2310
  if ! is_digest "${out}"; then
    warn "  imagetools returned no digest for ${ref}: '${out}'"
    return 1
  fi
  printf '%s\n' "${out}"
}

# Split an image reference into registry host and repository path.
#   caddy                      -> docker.io  library/caddy
#   valkey/valkey              -> docker.io  valkey/valkey
#   docker.n8n.io/n8nio/n8n    -> docker.io  n8nio/n8n      (docker.n8n.io redirects to Docker Hub)
#   ghcr.io/n8n-io/runners     -> ghcr.io    n8n-io/runners
split_ref() {
  local image="${1}"
  local host path first
  first="${image%%/*}"
  if [[ "${image}" != */* ]]; then
    host="docker.io"
    path="library/${image}"
  elif [[ "${first}" == *.* || "${first}" == *:* || "${first}" == "localhost" ]]; then
    host="${first}"
    path="${image#*/}"
  else
    host="docker.io"
    path="${image}"
  fi
  case "${host}" in
    docker.io | index.docker.io | registry-1.docker.io | docker.n8n.io)
      host="docker.io"
      if [[ "${path}" != */* ]]; then
        path="library/${path}"
      fi
      ;;
    *)
      ;;
  esac
  printf '%s %s\n' "${host}" "${path}"
}

# 2. Docker Hub tags API ------------------------------------------------------------------------------------------
digest_via_hub_api() {
  local path="${1}" tag="${2}"
  local url body http out
  url="https://hub.docker.com/v2/repositories/${path}/tags/${tag}"
  body="$(mktemp)"
  http="$(curl -sS -o "${body}" -w '%{http_code}' --max-time 30 "${url}" 2>&1)" || {
    warn "  hub-api: curl failed: ${http}"
    rm -f "${body}"
    return 1
  }
  if [[ "${http}" != "200" ]]; then
    out="$(jq -r '.message // .errinfo.message // empty' "${body}" 2>/dev/null || true)"
    warn "  hub-api: HTTP ${http} for ${url}${out:+ — ${out}}"
    rm -f "${body}"
    return 1
  fi
  out="$(jq -r '.digest // empty' "${body}")"
  rm -f "${body}"
  # shellcheck disable=SC2310
  if ! is_digest "${out}"; then
    warn "  hub-api: no index digest in the response for ${path}:${tag}"
    return 1
  fi
  printf '%s\n' "${out}"
}

# 3. Registry API v2 (any registry) --------------------------------------------------------------------------------
digest_via_registry_v2() {
  local host="${1}" path="${2}" tag="${3}"
  local api challenge realm service token headers digest status_line
  local -a auth_header=()
  api="https://${host}"
  if [[ "${host}" == "docker.io" ]]; then
    api="https://registry-1.docker.io"
  fi
  # Anonymous token: the registry's /v2/ answers 401 with WWW-Authenticate: Bearer realm=..,service=..
  challenge="$(curl -sSI --max-time 30 "${api}/v2/" 2>/dev/null | tr -d '\r' | grep -i '^www-authenticate:' || true)"
  token=''
  if [[ "${challenge}" =~ realm=\"([^\"]+)\" ]]; then
    realm="${BASH_REMATCH[1]}"
    service=''
    if [[ "${challenge}" =~ service=\"([^\"]+)\" ]]; then
      service="${BASH_REMATCH[1]}"
    fi
    token="$(curl -sS --max-time 30 "${realm}?service=${service}&scope=repository:${path}:pull" 2>/dev/null | jq -r '.token // .access_token // empty' || true)"
    if [[ -z "${token}" ]]; then
      warn "  registry-v2: could not obtain an anonymous token from ${realm}"
      return 1
    fi
    auth_header=(-H "Authorization: Bearer ${token}")
  fi
  headers="$(curl -sSI --max-time 30 "${auth_header[@]}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "${api}/v2/${path}/manifests/${tag}" 2>&1 | tr -d '\r')" || {
    warn "  registry-v2: HEAD failed for ${api}/v2/${path}/manifests/${tag}"
    return 1
  }
  digest="$(printf '%s\n' "${headers}" | grep -i '^docker-content-digest:' | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' || true)"
  # shellcheck disable=SC2310
  if ! is_digest "${digest}"; then
    status_line="${headers%%$'\n'*}"
    warn "  registry-v2: no Docker-Content-Digest for ${host}/${path}:${tag} (${status_line})"
    return 1
  fi
  printf '%s\n' "${digest}"
}

resolve_digest() {
  local image="${1}" tag="${2}"
  local host path out ref_parts
  ref_parts="$(split_ref "${image}")"
  host="${ref_parts%% *}"
  path="${ref_parts##* }"
  # Each resolver returns 1 for "try the next one"; that is the intended control flow, hence the
  # SC2310 (set -e suspended in `if`) directives.
  # shellcheck disable=SC2310
  if out="$(digest_via_imagetools "${image}:${tag}")"; then
    printf '%s imagetools\n' "${out}"
    return 0
  fi
  if [[ "${host}" == "docker.io" ]]; then
    # shellcheck disable=SC2310
    if out="$(digest_via_hub_api "${path}" "${tag}")"; then
      printf '%s hub-api\n' "${out}"
      return 0
    fi
  fi
  # shellcheck disable=SC2310
  if out="$(digest_via_registry_v2 "${host}" "${path}" "${tag}")"; then
    printf '%s registry-v2\n' "${out}"
    return 0
  fi
  return 1
}

failures=0
changed=0
for key in "${pin_keys[@]}"; do
  version_var="$(version_var_of "${key}")"
  image="$(env_get "${key}_IMAGE" "${versions_file}")"
  version="$(env_get "${version_var}" "${versions_file}")"
  old_digest="$(env_get "${key}_DIGEST" "${versions_file}")"
  if [[ -z "${image}" || -z "${version}" ]]; then
    fail "${key}: ${key}_IMAGE or ${version_var} missing in versions.env"
    failures=$((failures + 1))
    continue
  fi
  info "${key}: ${image}:${version}"
  # shellcheck disable=SC2310
  if ! resolved="$(resolve_digest "${image}" "${version}")"; then
    fail "${key}: could not resolve ${image}:${version} (see the warnings above — wrong tag, no network, or registry down)"
    failures=$((failures + 1))
    continue
  fi
  new_digest="${resolved%% *}"
  via="${resolved##* }"
  if [[ "${new_digest}" == "${old_digest}" ]]; then
    ok "${key}: unchanged ${new_digest} (via ${via})"
  else
    env_set "${key}_DIGEST" "${new_digest}" "${versions_file}"
    changed=$((changed + 1))
    if [[ -z "${old_digest}" ]]; then
      ok "${key}: pinned ${new_digest} (via ${via})"
    else
      warn "${key}: UPDATED ${old_digest} -> ${new_digest} (via ${via}) — the tag was re-pushed or the version changed"
    fi
  fi
done

if (( failures > 0 )); then
  die "${failures} image(s) could not be resolved; versions.env was updated for the others only" 1
fi
if (( changed > 0 )); then
  ok "versions.env: ${changed} digest line(s) rewritten — review 'git diff compose/versions.env' and commit"
else
  ok "versions.env: all digests already current"
fi
