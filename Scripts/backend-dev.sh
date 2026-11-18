#!/bin/bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/backend-dev.sh
# Description: A real SP Drive backend for the app's functional tests, on this Mac: the cluster's code (a clone of
# sp-drive.git in ~/dev/sp-drive-testbed), its own PostgreSQL database, its own data folder and master key, the job
# worker inline. Nothing here touches production.
#   Scripts/backend-dev.sh start      fresh database + data, one account, prints the environment for tests
#   Scripts/backend-dev.sh stop
#   Scripts/backend-dev.sh env        prints the environment of the running instance
#   Scripts/backend-dev.sh web-stop | web-start     takes the server down / brings it back (same data): "offline" tests
#   Scripts/backend-dev.sh token <device name>      a new device session token for the test account
#   Scripts/backend-dev.sh approve <CODE>           approves a device-link code as the test account (fresh passkey)
set -euo pipefail
export PATH="/opt/homebrew/opt/postgresql@17/bin:/opt/homebrew/bin:$PATH"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
HELPER="$(cd "$(dirname "$0")" && pwd)/backend-helper.mts"
BED="${SPDRIVE_TESTBED:-$HOME/dev/sp-drive-testbed}"
PORT="${SPDRIVE_TEST_PORT:-8665}"
DB="sp_drive_macdev"
STATE="/tmp/spdrive-backend-dev"
ENVF="$STATE/env"
EMAIL="owner@example.test"

server_env() {
  export DATABASE_URL="postgres://127.0.0.1/$DB" SPD_ORIGIN="http://localhost:$PORT" SPD_RP_ID=localhost PORT="$PORT" HOST=127.0.0.1
  export SPD_DATA_DIR="$STATE/data" SPD_MASTER_KEY_FILE="$STATE/master.key" SPD_INLINE_WORKER=on SPD_APP_DIR="$BED" SPD_AV_MODE=optional SPD_CLAMD_SOCKET=""
  export SPD_APPLE_APP_IDS="3YM54G49SN.ai.spboucher.spdrive,3YM54G49SN.ai.spboucher.spdrive.ios" SPD_DEFAULT_QUOTA_GB=5
}
stop_web() {
  [ -f "$STATE/web.pid" ] && kill "$(cat "$STATE/web.pid")" 2>/dev/null || true; rm -f "$STATE/web.pid"
  local p; p="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"; [ -n "$p" ] && kill $p 2>/dev/null || true
  for _ in $(seq 1 40); do lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || return 0; sleep 0.1; done
}
web() {
  server_env; cd "$BED"
  nohup node --import tsx services/api/src/main.ts >> "$STATE/web.log" 2>&1 & echo $! > "$STATE/web.pid"
  for _ in $(seq 1 100); do curl -fsS "http://127.0.0.1:$PORT/api/v1/health/live" >/dev/null 2>&1 && return 0; sleep 0.2; done
  echo "server did not start"; tail -20 "$STATE/web.log"; return 1
}
helper() { server_env; cd "$BED"; SPDRIVE_STATE="$STATE" SPDRIVE_BASE="http://127.0.0.1:$PORT" node --import tsx "$HELPER" "$@"; }

case "${1:-}" in
stop) stop_web; echo stopped ;;
web-stop) stop_web ;;
web-start) web ;;
env) cat "$ENVF" ;;
token) helper token "$EMAIL" "${2:-Mac de test}" ;;
approve) helper approve "$EMAIL" "$2" ;;
start)
  [ -d "$BED/node_modules" ] || { echo "testbed missing: clone sp-drive.git into $BED and run pnpm install"; exit 1; }
  stop_web; rm -rf "$STATE"; mkdir -p "$STATE/data"
  dropdb -h 127.0.0.1 --if-exists "$DB" 2>/dev/null; createdb -h 127.0.0.1 "$DB"
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex")+"\n")' > "$STATE/master.key"; chmod 600 "$STATE/master.key"
  web
  INVITE="$(server_env; cd "$BED"; node --import tsx services/api/src/cli.ts invite --email "$EMAIL" --admin 2>/dev/null | grep -o '/invite/[A-Za-z0-9_-]*' | head -1 | cut -d/ -f3)"
  [ -n "$INVITE" ] || { echo "could not create the invitation"; exit 1; }
  helper register "$EMAIL" "$INVITE"
  TOKEN="$(helper token "$EMAIL" "Suite de tests")"
  cat > "$ENVF" <<EOT
export SPDRIVE_TEST_URL=http://127.0.0.1:$PORT
export SPDRIVE_TEST_TOKEN=$TOKEN
export SPDRIVE_TEST_SCRIPT=$SELF
export SPDRIVE_TEST_DB=postgres://127.0.0.1/$DB
EOT
  chmod 600 "$ENVF"
  echo "backend ready on http://127.0.0.1:$PORT (branch $(git -C "$BED" rev-parse --abbrev-ref HEAD) @ $(git -C "$BED" rev-parse --short HEAD)); environment in $ENVF" ;;
*) echo "usage: $0 start|stop|env|web-stop|web-start|token <name>|approve <CODE>"; exit 2 ;;
esac
