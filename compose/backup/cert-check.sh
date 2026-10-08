#!/usr/bin/env bash
# compose/backup/cert-check.sh — hourly (cron in the backup sidecar): the expiry of the certificate Caddy actually
# serves for DOMAIN -> cert_expiry_timestamp_seconds in /state/metrics.prom (node-exporter's textfile collector), which
# feeds the CertExpiring alert without a blackbox exporter. Caddy renews 30 days ahead, so the alert (< 14 days) means
# renewal keeps failing.
# TLS_MODE=internal: Caddy's local CA issues 12-hour certificates and renews them all the time — nothing to watch; the
# metric is removed instead (the alert then has no data, i.e. stays quiet).
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail
# shellcheck source=lib.sh
source /opt/backup/lib.sh

if [[ "${TLS_MODE:-acme}" == "internal" ]]; then
  printf '# cert-check: TLS_MODE=internal (12 h certificates from the local CA) — not monitored\n' | write_metrics cert
  exit 0
fi
domain="${DOMAIN:?DOMAIN not set}"
port="${HTTPS_PORT:-443}"
pem="$(openssl s_client -connect "caddy:${port}" -servername "${domain}" </dev/null 2>/dev/null || true)"
end="$(printf '%s\n' "${pem}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
expiry=''
if [[ -n "${end}" ]]; then
  expiry="$(date -u -d "${end}" +%s 2>/dev/null || true)"
fi
lbl="$(label_of "${domain}")"
if [[ -z "${expiry}" ]]; then
  warn "cert-check: could not read the certificate Caddy serves for ${domain} on caddy:${port}"
  printf 'cert_check_success{domain="%s"} 0\n' "${lbl}" | write_metrics cert
  exit 1
fi
{
  printf '# HELP cert_expiry_timestamp_seconds Unix time when the certificate served for the domain expires\n'
  printf '# TYPE cert_expiry_timestamp_seconds gauge\n'
  printf 'cert_expiry_timestamp_seconds{domain="%s"} %s\n' "${lbl}" "${expiry}"
  printf 'cert_check_success{domain="%s"} 1\n' "${lbl}"
} | write_metrics cert
info "cert-check: ${domain} expires $(date -u -d "@${expiry}" +%F) ($(( (expiry - $(date +%s)) / 86400 )) days)"
