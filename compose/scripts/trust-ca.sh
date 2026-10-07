#!/usr/bin/env bash
# compose/scripts/trust-ca.sh — make the dev CA (TLS_MODE=internal) trusted (`make trust-ca`).
#
#   1. ensures secrets/dev-root.crt exists (runs dev-ca.sh when it does not)
#   2. copies it to ~/n8nkit-root.crt and, under WSL, to the Windows Downloads folder
#   3. installs it into this host's trust store when the tools exist (update-ca-certificates on Debian/Ubuntu,
#      update-ca-trust on the RHEL family) — needs root; warns instead of failing when sudo is unavailable
#   4. prints the one-liners for a Windows browser (certutil) and for fetching the file over ssh
# curl/wget on this host trust the cert after step 3; browsers on another machine need step 4.
# shellcheck disable=SC2310,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

cert="${KIT_DIR}/secrets/dev-root.crt"
if [[ ! -s "${cert}" ]]; then
  info "no exported dev CA yet — running dev-ca.sh"
  "${KIT_DIR}/scripts/dev-ca.sh"
fi
if [[ ! -s "${cert}" ]]; then
  die "dev CA still missing (${cert}) — is TLS_MODE=internal?"
fi

# 2. copies a human can find
cp -f "${cert}" "${HOME}/n8nkit-root.crt"
ok "copied to ${HOME}/n8nkit-root.crt"
for win_dl in /mnt/c/Users/*/Downloads; do
  if [[ -d "${win_dl}" && "${win_dl}" != *"/Public/"* && "${win_dl}" != *"/Default/"* ]]; then
    if cp -f "${cert}" "${win_dl}/n8nkit-root.crt" 2>/dev/null; then
      ok "copied to ${win_dl}/n8nkit-root.crt (WSL)"
    fi
  fi
done

# 3. host trust store
as_root() {
  if [[ "$(id -u)" == "0" ]]; then
    "${@}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -n "${@}"
  else
    return 1
  fi
}
installed=0
if command -v update-ca-certificates >/dev/null 2>&1; then
  if as_root install -m 644 "${cert}" /usr/local/share/ca-certificates/n8nkit-root.crt && as_root update-ca-certificates >/dev/null 2>&1; then
    ok "installed into the host trust store (update-ca-certificates)"
    installed=1
  fi
elif command -v update-ca-trust >/dev/null 2>&1; then
  if as_root install -m 644 "${cert}" /etc/pki/ca-trust/source/anchors/n8nkit-root.crt && as_root update-ca-trust >/dev/null 2>&1; then
    ok "installed into the host trust store (update-ca-trust)"
    installed=1
  fi
fi
if (( installed == 0 )); then
  warn "not installed into the host trust store (no root/sudo -n, or no update-ca-* tool) — curl can use: curl --cacert ${cert} …"
fi

# 4. other machines
domain="$(env_get DOMAIN)"
https_port="$(env_get HTTPS_PORT)"
log ""
log "Windows browser (admin PowerShell), after copying the file over:"
log "  scp <this-host>:${cert} \$env:USERPROFILE\\Downloads\\n8nkit-root.crt"
log "  certutil -addstore -f ROOT \$env:USERPROFILE\\Downloads\\n8nkit-root.crt"
log "Then open: https://${domain}${https_port:+:${https_port}}/   (ports 443 need no suffix)"
log "macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain n8nkit-root.crt"
