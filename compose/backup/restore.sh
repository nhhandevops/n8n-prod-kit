#!/usr/bin/env bash
# compose/backup/restore.sh — the container half of a restore. The host script compose/scripts/restore.sh drives it
# (stops n8n, takes a safety backup, flushes the queue, restarts); never run `apply` against a live stack by hand.
#
#   restore.sh list  [--from REMOTE]          every bundle on every remote, newest first
#   restore.sh fetch NAME|latest [--from R]   download + decrypt + verify sha256 into /work/current; prints a summary
#   restore.sh apply [--adopt-key]            replace the live n8n database with /work/current/db.dump
#                                             (refuses — exit 3 — when the bundle's encryption key differs from the
#                                             running one, unless --adopt-key, which leaves the key in /work/adopt.key
#                                             for the host script to write into .env)
#   restore.sh clean                          remove /work/*
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail
# shellcheck source=lib.sh
source /opt/backup/lib.sh

cmd="${1:-}"
shift || true
current="${WORK_DIR}/current"

case "${cmd}" in
  list)
    from=''
    [[ "${1:-}" == "--from" ]] && from="${2:-}"
    found=0
    for r in $(if [[ -n "${from}" ]]; then printf '%s\n' "${from}"; else remotes; fi); do
      while IFS=$'\t' read -r remote path; do
        printf '%-28s %s\n' "${remote}" "${path}"
        found=1
      done < <(list_remote "${r}" | sort -t$'\t' -k2 -r)
    done
    (( found )) || warn "no backups found on: ${from:-${BACKUP_REMOTES:-<BACKUP_REMOTES empty>}}"
    ;;

  fetch)
    want="${1:-latest}"
    from=''
    [[ "${2:-}" == "--from" ]] && from="${3:-}"
    hit="$(resolve_bundle "${want}" "${from}" || true)"
    [[ -n "${hit}" ]] || die "backup '${want}' not found on ${from:-${BACKUP_REMOTES:-<none>}} (make backups lists them)"
    remote="${hit%%$'\t'*}"
    path="${hit#*$'\t'}"
    rm -rf "${WORK_DIR:?}"/*
    info "fetching ${remote}/${path}"
    rclone copyto "${remote}/${path}" "${WORK_DIR}/bundle.tar.age"
    unpack_bundle "${WORK_DIR}/bundle.tar.age" "${current}" || die "could not decrypt/verify ${path} (wrong age key? corrupt file?)"
    rm -f "${WORK_DIR}/bundle.tar.age"
    key_state="DIFFERENT from the running N8N_ENCRYPTION_KEY"
    [[ "$(bundle_key "${current}")" == "${N8N_ENCRYPTION_KEY:-}" ]] && key_state="matches the running N8N_ENCRYPTION_KEY"
    jq -r --arg src "${remote}/${path}" --arg key "${key_state}" \
      '"FETCHED \(.name)\n  source:      \($src)\n  created:     \(.created_at) (n8n \(.n8n_version), postgres \(.postgres_version), domain \(.domain))\n  contents:    \(.counts.workflows) workflows, \(.counts.credentials) credentials, db.dump \(.files["db.dump"].bytes) bytes (sha256 verified)\n  key:         \($key)"' \
      "${current}/manifest.json"
    ;;

  apply)
    [[ -s "${current}/db.dump" ]] || die "nothing fetched — run: restore.sh fetch <name|latest>"
    if [[ "$(bundle_key "${current}")" != "${N8N_ENCRYPTION_KEY:-}" ]]; then
      if [[ "${1:-}" != "--adopt-key" ]]; then
        fail "the backup was made with a different N8N_ENCRYPTION_KEY: restored credentials would be unreadable"
        exit 3
      fi
      ( umask 077 && bundle_key "${current}" >"${WORK_DIR}/adopt.key" )
      warn "restoring with the bundle's encryption key — the host script writes it into .env"
    fi
    info "replacing database ${PGDATABASE:-n8n} (drop, create, restore in one transaction)"
    psql -v ON_ERROR_STOP=1 -d postgres -qc "DROP DATABASE IF EXISTS \"${PGDATABASE:-n8n}\" WITH (FORCE)"
    psql -v ON_ERROR_STOP=1 -d postgres -qc "CREATE DATABASE \"${PGDATABASE:-n8n}\" OWNER \"${PGUSER:-n8n}\""
    pg_restore --no-owner --no-privileges --single-transaction --exit-on-error -d "${PGDATABASE:-n8n}" "${current}/db.dump"
    workflows="$(psql -Atc 'select count(*) from workflow_entity')"
    expected="$(jq -r '.counts.workflows' "${current}/manifest.json")"
    [[ "${workflows}" == "${expected}" ]] || die "restored ${workflows} workflows, the manifest says ${expected}"
    ok "RESTORED $(jq -r .name "${current}/manifest.json"): ${workflows} workflows, $(psql -Atc 'select count(*) from credentials_entity') credentials"
    ;;

  clean)
    rm -rf "${WORK_DIR:?}"/*
    ;;

  *)
    die "usage: restore.sh list|fetch|apply|clean (see the header)" 2
    ;;
esac
