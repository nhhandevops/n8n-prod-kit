#!/usr/bin/env bash
# compose/backup/notify.sh LEVEL MESSAGE — send an alert to Telegram (ALERT_TELEGRAM_BOT_TOKEN + ALERT_TELEGRAM_CHAT_ID).
# Without both variables it only logs. Never fails its caller: a broken alert channel must not turn a good backup into a
# failed one. The bot token is part of the URL, which curl reads from stdin (-K -): never logged, and never on a
# command line, where every user of the host could read it in /proc.
# shellcheck disable=SC2312
set -uo pipefail

level="${1:-info}"
message="${2:-}"
text="[n8n-kit ${DOMAIN:-?}] ${level^^}: ${message}"
printf '%s [notify] %s\n' "$(date -u +%FT%TZ)" "${text}" >&2

if [[ -z "${ALERT_TELEGRAM_BOT_TOKEN:-}" || -z "${ALERT_TELEGRAM_CHAT_ID:-}" ]]; then
  exit 0
fi
if ! curl -fsS -m 15 -o /dev/null -K - --data-urlencode "chat_id=${ALERT_TELEGRAM_CHAT_ID}" --data-urlencode "text=${text}" \
    2>/dev/null <<<"url = \"https://api.telegram.org/bot${ALERT_TELEGRAM_BOT_TOKEN}/sendMessage\""; then
  printf '%s [notify] Telegram delivery failed (token/chat id wrong, or no egress)\n' "$(date -u +%FT%TZ)" >&2
fi
exit 0
