#!/usr/bin/env bash
# compose/backup/restore.sh — the container half of a restore. The host script compose/scripts/restore.sh drives it
# (lock, key check, confirm, stop n8n, safety backup, swap, restart, clean); never run `apply` against a live stack by
# hand.
#
#   restore.sh list  [--from REMOTE]          every bundle on every remote, newest first (unlistable remotes: exit 2)
#   restore.sh fetch NAME|latest [--from R]   download + decrypt + verify into /work/current; prints a summary
#   restore.sh keycheck                       exit 0 when the fetched bundle's N8N_ENCRYPTION_KEY is the running one,
#                                             3 when it differs (prints both key hints), 1 when nothing is fetched
#   restore.sh apply [--adopt-key]            restore /work/current/db.dump into a STAGING database (<db>_restore),
#                                             verify its counts, then swap it in atomically; the replaced database is
#                                             kept as <db>_prev until `finalize`. Exit 3 = key mismatch (nothing
#                                             touched), 4 = restore/verify/swap failed (the live database untouched).
#                                             --adopt-key writes the bundle's key to /work/adopt.key for the host.
#   restore.sh finalize                       drop <db>_prev and empty /work (after the stack is healthy again)
#   restore.sh clean                          empty /work (the decrypted dump and key never stay on disk)
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail
# shellcheck source=lib.sh
source /opt/backup/lib.sh

cmd="${1:-}"
shift || true
current="${WORK_DIR}/current"
db="${PGDATABASE:-n8n}"
staging="${db}_restore"
prev="${db}_prev"
# Database names are identifiers in the SQL below; the kit uses n8n, anything exotic is refused.
[[ "${db}" =~ ^[a-z_][a-z0-9_]{0,40}$ ]] || die "unsupported PGDATABASE '${db}'" 2

psql_admin() { PGOPTIONS='-c client_min_messages=warning' psql -X -v ON_ERROR_STOP=1 -d postgres -q "${@}"; }

case "${cmd}" in
  list)
    from=''
    [[ "${1:-}" == "--from" ]] && from="${2:-}"
    mapfile -t rs < <(if [[ -n "${from}" ]]; then printf '%s\n' "${from%/}"; else remotes; fi)
    found=0
    unreachable=0
    for r in "${rs[@]}"; do
      if ! list_remote "${r}" >/tmp/list.lst; then
        fail "cannot list ${r}: $(tail -1 /tmp/rclone-list.err 2>/dev/null)"
        unreachable=1
        continue
      fi
      while IFS=$'\t' read -r remote path; do
        printf '%-28s %s\n' "${remote}" "${path}"
        found=1
      done < <(awk -F'\t' '{ n = $2; sub(/.*\//, "", n); print n "\t" $0 }' /tmp/list.lst | sort -r | cut -f2-)
    done
    (( found )) || warn "no backups found on: ${from:-${BACKUP_REMOTES:-<BACKUP_REMOTES empty>}}"
    (( unreachable == 0 )) || exit 2
    ;;

  fetch)
    want="${1:-latest}"
    from=''
    [[ "${2:-}" == "--from" ]] && from="${3:-}"
    rc=0
    hit="$(resolve_bundle "${want}" "${from}")" || rc=$?
    if (( rc == 2 )); then
      die "could not list every remote — fix it, or restore from a specific one: FROM=<remote>"
    fi
    [[ -n "${hit}" ]] || die "backup '${want}' not found on ${from:-${BACKUP_REMOTES:-<none>}} (make backups lists them)"
    remote="${hit%%$'\t'*}"
    path="${hit#*$'\t'}"
    rm -rf "${WORK_DIR:?}"/*
    info "fetching ${remote}/${path}"
    if ! rclone copyto "${remote}/${path}" "${WORK_DIR}/bundle.tar.age" ||
      ! unpack_bundle "${WORK_DIR}/bundle.tar.age" "${current}" "${path##*/}"; then
      rm -rf "${WORK_DIR:?}"/*
      die "could not download/decrypt/verify ${path} (wrong age key? corrupt or renamed file?)"
    fi
    rm -f "${WORK_DIR}/bundle.tar.age"
    printf '%s/%s\n' "${remote}" "${path}" >"${current}/source"
    key_state="DIFFERENT from the running N8N_ENCRYPTION_KEY"
    [[ "$(bundle_key "${current}")" == "${N8N_ENCRYPTION_KEY:-}" ]] && key_state="matches the running N8N_ENCRYPTION_KEY"
    jq -r --arg src "${remote}/${path}" --arg key "${key_state}" \
      '"FETCHED \(.name)\n  source:      \($src)\n  created:     \(.created_at) (n8n \(.n8n_version), postgres \(.postgres_version), domain \(.domain))\n  contents:    \(.counts.workflows) workflows, \(.counts.credentials) credentials, db.dump \(.files["db.dump"].bytes) bytes (sha256 verified)\n  key:         \($key)"' \
      "${current}/manifest.json"
    ;;

  keycheck)
    [[ -s "${current}/db.dump" ]] || die "nothing fetched — run: restore.sh fetch <name|latest>"
    bk="$(bundle_key "${current}")"
    if [[ "${bk}" == "${N8N_ENCRYPTION_KEY:-}" ]]; then
      exit 0
    fi
    printf 'bundle key:  %s\nrunning key: %s\n' "$(key_hint "${bk}")" "$(key_hint "${N8N_ENCRYPTION_KEY:-}")"
    exit 3
    ;;

  apply)
    [[ -s "${current}/db.dump" ]] || die "nothing fetched — run: restore.sh fetch <name|latest>"
    bk="$(bundle_key "${current}")"
    if [[ "${bk}" != "${N8N_ENCRYPTION_KEY:-}" ]]; then
      if [[ "${1:-}" != "--adopt-key" ]]; then
        fail "the backup was made with a different N8N_ENCRYPTION_KEY: restored credentials would be unreadable"
        exit 3
      fi
      # the key goes into .env (and is sourced by bash): only the characters n8n/openssl keys are made of
      [[ "${bk}" =~ ^[A-Za-z0-9+/=._~:@%-]{16,255}$ ]] ||
        die "the bundle's N8N_ENCRYPTION_KEY has an unexpected format — refusing to adopt it (set it in .env by hand if it is genuine)" 3
      ( umask 077 && printf '%s\n' "${bk}" >"${WORK_DIR}/adopt.key" )
      warn "restoring with the bundle's encryption key — the host script writes it into .env"
    fi
    take_lock 900 || die "a backup or restore test is still running after 15 min — the live database was NOT touched" 4
    info "restoring into the staging database ${staging} (the live ${db} is not touched until the swap)"
    psql_admin -c "DROP DATABASE IF EXISTS \"${staging}\" WITH (FORCE)" -c "CREATE DATABASE \"${staging}\" OWNER \"${PGUSER:-n8n}\""
    drop_staging() { psql_admin -c "DROP DATABASE IF EXISTS \"${staging}\" WITH (FORCE)" || true; }
    if ! pg_restore --no-owner --no-privileges --single-transaction --exit-on-error -d "${staging}" "${current}/db.dump"; then
      drop_staging
      die "pg_restore failed — the live database was NOT touched" 4
    fi
    workflows="$(psql -X -d "${staging}" -Atc 'select count(*) from workflow_entity')"
    credentials="$(psql -X -d "${staging}" -Atc 'select count(*) from credentials_entity')"
    expected="$(jq -r '.counts.workflows' "${current}/manifest.json")"
    if [[ "${workflows}" != "${expected}" ]]; then
      drop_staging
      die "the restored copy has ${workflows} workflows, the manifest says ${expected} — the live database was NOT touched" 4
    fi
    info "swapping ${staging} in (the replaced database is kept as ${prev} until the stack is healthy)"
    if ! psql_admin -c "DROP DATABASE IF EXISTS \"${prev}\" WITH (FORCE)" \
      -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = '${db}' AND pid <> pg_backend_pid()" \
      -c "BEGIN" -c "ALTER DATABASE \"${db}\" RENAME TO \"${prev}\"" -c "ALTER DATABASE \"${staging}\" RENAME TO \"${db}\"" -c "COMMIT" >/dev/null; then
      drop_staging
      die "could not swap the databases (a session still connected?) — the live database was NOT touched" 4
    fi
    ok "RESTORED $(jq -r .name "${current}/manifest.json"): ${workflows} workflows, ${credentials} credentials"
    ;;

  finalize)
    psql_admin -c "DROP DATABASE IF EXISTS \"${prev}\" WITH (FORCE)"
    rm -rf "${WORK_DIR:?}"/*
    ;;

  clean)
    rm -rf "${WORK_DIR:?}"/*
    ;;

  *)
    die "usage: restore.sh list|fetch|keycheck|apply|finalize|clean (see the header)" 2
    ;;
esac
