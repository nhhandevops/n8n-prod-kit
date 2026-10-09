#!/usr/bin/env bash
# compose/scripts/kuma-setup.sh — claim Uptime Kuma's admin account right after `make up` (profile kuma), so its first-run
# page is never left open: whoever reaches kuma.DOMAIN first would otherwise create the only admin (review 2026-10-09).
# Kuma's database type is preset by compose (UPTIME_KUMA_DB_TYPE=sqlite), and this script sends Kuma's own "setup"
# socket.io event from inside the container (the image ships socket.io-client). Idempotent: an instance that already has
# a user answers "has been initialized" and is left alone.
# Credentials: KUMA_ADMIN_USER (default admin) / KUMA_ADMIN_PASSWORD in .env — generated here when missing (older .env).
# The password travels on stdin, never on a command line.
#   kuma-setup.sh           create the admin account if Kuma has none (make up runs this)
#   kuma-setup.sh --check   exit 0 when an admin exists, 1 when Kuma would still show its first-run page (doctor, smoke 09)
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=lib.sh
source "${KIT_DIR}/scripts/lib.sh"
cd "${KIT_DIR}"

mode=setup
if [[ "${1:-}" == "--check" ]]; then
  mode=check
fi
profiles=",$(env_get COMPOSE_PROFILES | tr -d ' '),"
if [[ "${profiles}" != *",kuma,"* ]]; then
  exit 0
fi
user="$(env_get KUMA_ADMIN_USER)"
user="${user:-admin}"
if [[ ! "${user}" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]; then
  die "KUMA_ADMIN_USER='${user}' — use letters, digits and . _ @ - only"
fi
pass="$(env_get KUMA_ADMIN_PASSWORD)"
if [[ "${mode}" == "check" ]]; then
  pass="check-mode-sends-no-password"   # --check never creates an account and never touches .env
elif [[ -z "${pass}" ]]; then
  pass="$(rand_hex 16)"
  env_set KUMA_ADMIN_USER "${user}"
  env_set KUMA_ADMIN_PASSWORD "${pass}"
  ok "generated KUMA_ADMIN_PASSWORD in .env (store it in your password manager)"
fi
if [[ ! "${pass}" =~ ^[A-Za-z0-9._~+/=@%-]{12,128}$ ]]; then
  die "KUMA_ADMIN_PASSWORD must be 12-128 characters of letters, digits and . _ ~ + / = @ % -"
fi

# Runs inside the container (cwd /app, where socket.io-client lives); reads {"user","pass"} from stdin.
js='
const { io } = require("socket.io-client");
let input = "";
process.stdin.on("data", (d) => { input += d; });
process.stdin.on("end", () => {
  const { user, pass, mode } = JSON.parse(input);
  const s = io("http://127.0.0.1:3001", { transports: ["websocket"], reconnection: false, timeout: 20000 });
  const done = (code, msg) => { console.log(msg); s.close(); process.exit(code); };
  s.on("connect_error", (e) => done(2, "cannot connect to Kuma: " + e.message));
  // Kuma registers its handlers after some async work per connection, then tells the client what it needs: "setup" =
  // no user yet (send ours now). It sends "loginRequired" to every new client — on a fresh instance TOGETHER with
  // "setup" (verified 2026-10-09) — so "already set up" is only concluded when no "setup" follows within 3 s.
  let setupSeen = false;
  s.on("loginRequired", () => setTimeout(() => { if (!setupSeen) { done(0, "already set up"); } }, 3000));
  s.on("setup", () => {
    setupSeen = true;
    if (mode === "check") { done(1, "no admin account yet"); return; }
    s.emit("setup", user, pass, (res) => {
      if (res && res.ok) { done(0, "admin account created"); }
      else if (res && /initialized/i.test(String(res.msg))) { done(0, "already set up"); }
      else { done(1, "setup refused: " + (res && res.msg)); }
    });
  });
  setTimeout(() => done(3, "no answer from Kuma within 30 s"), 30000);
});
'
rc=0
out="$(printf '{"user":"%s","pass":"%s","mode":"%s"}' "${user}" "${pass}" "${mode}" |
  compose exec -T -w /app uptime-kuma node -e "${js}" 2>&1)" || rc=$?
if [[ "${mode}" == "check" ]]; then
  printf '%s\n' "${out##*$'\n'}"
  exit "${rc}"
fi
(( rc == 0 )) || die "could not set up Uptime Kuma's admin account: ${out##*$'\n'} — retry with: make kuma-setup"
ok "uptime kuma: ${out##*$'\n'} (user ${user}, password KUMA_ADMIN_PASSWORD in .env)"
