#!/bin/bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/backend-dev.sh
# Description: A real SP Drive backend for the app's functional tests, on this Mac: the cluster's code (a clone of
# sp-drive.git in ~/dev/sp-drive-testbed), its own PostgreSQL database, its own data folder and master key, the job
# worker inline. Nothing here touches production. Since SP Drive 2.0 the clone follows branch `next` (set
# SPDRIVE_TESTBED_REF to pin another ref): `start` fetches it, installs the locked dependencies and builds the local
# text helper (PDF text, OCR, embeddings). The AI provider of the testbed is a FAKE local server (Scripts/fake-ai.mjs):
# no real model and no real key are ever involved.
#   Scripts/backend-dev.sh start      fresh database + data, one account, prints the environment for tests
#   Scripts/backend-dev.sh stop
#   Scripts/backend-dev.sh env        prints the environment of the running instance
#   Scripts/backend-dev.sh web-stop | web-start     takes the server down / brings it back (same data): "offline" tests
#   Scripts/backend-dev.sh token <device name>      a new device session token for the test account
#   Scripts/backend-dev.sh token2 <device name>     … for the second test account (member@example.test), for sharing tests
#   Scripts/backend-dev.sh ai on|off                starts / stops the fake AI provider (the API reads it at start: follow with web-stop, web-start)
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
EMAIL2="member@example.test"
AIPORT="${SPDRIVE_TEST_AI_PORT:-8669}"
REF="${SPDRIVE_TESTBED_REF:-next}"

server_env() {
  export DATABASE_URL="postgres://127.0.0.1/$DB" SPD_ORIGIN="http://localhost:$PORT" SPD_RP_ID=localhost PORT="$PORT" HOST=127.0.0.1
  export SPD_DATA_DIR="$STATE/data" SPD_MASTER_KEY_FILE="$STATE/master.key" SPD_INLINE_WORKER=on SPD_APP_DIR="$BED" SPD_AV_MODE=optional SPD_CLAMD_SOCKET=""
  export SPD_AI_ENV_FILE="$STATE/ai.env" SPD_BACKUP_DIR="$STATE/backups"   # never the operator's ~/.config/sp-drive/ai.env
  export SPD_APPLE_APP_IDS="3YM54G49SN.ai.spboucher.spdrive,3YM54G49SN.ai.spboucher.spdrive.ios" SPD_DEFAULT_QUOTA_GB=5
}
stop_web() {
  local old=""; [ -f "$STATE/web.pid" ] && old="$(cat "$STATE/web.pid")"
  [ -n "$old" ] && kill "$old" 2>/dev/null || true; rm -f "$STATE/web.pid"
  local p; p="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"; [ -n "$p" ] && kill $p 2>/dev/null || true
  for _ in $(seq 1 40); do lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.1; done
  # a server told to stop keeps running for as long as an event stream is open (and keeps pinging it): end it for good,
  # by its own PID only
  for q in $old $p; do if kill -0 "$q" 2>/dev/null; then sleep 0.3; kill -9 "$q" 2>/dev/null || true; fi; done
}
web() {
  server_env; cd "$BED"
  nohup node --import tsx services/api/src/main.ts >> "$STATE/web.log" 2>&1 & echo $! > "$STATE/web.pid"
  for _ in $(seq 1 100); do curl -fsS "http://127.0.0.1:$PORT/api/v1/health/live" >/dev/null 2>&1 && return 0; sleep 0.2; done
  echo "server did not start"; tail -20 "$STATE/web.log"; return 1
}
ai_stop() { local p; p="$(lsof -tiTCP:"$AIPORT" -sTCP:LISTEN 2>/dev/null || true)"; [ -n "$p" ] && kill $p 2>/dev/null || true; }
ai_start() {
  ai_stop
  nohup node "$(dirname "$SELF")/fake-ai.mjs" "$AIPORT" >> "$STATE/fake-ai.log" 2>&1 &
  printf 'SPD_AI_MACLUSTR_URL=http://127.0.0.1:%s/v1\nSPD_AI_MACLUSTR_KEY=fake-local-key\nSPD_AI_MACLUSTR_MODELS=fake-qwen|Faux Qwen (test)|Alibaba\nSPD_AI_MACLUSTR_MODEL=fake-qwen\n' "$AIPORT" > "$STATE/ai.env"; chmod 600 "$STATE/ai.env"
}
helper() { server_env; cd "$BED"; SPDRIVE_STATE="$STATE" SPDRIVE_BASE="http://127.0.0.1:$PORT" node --import tsx "$HELPER" "$@"; }

case "${1:-}" in
stop) stop_web; ai_stop; echo stopped ;;
ai) if [ "${2:-on}" = on ]; then ai_start; else ai_stop; : > "$STATE/ai.env"; fi ;;
token2) helper token "$EMAIL2" "${2:-Mac du membre}" ;;
web-stop) stop_web ;;
web-start) web ;;
env) cat "$ENVF" ;;
token) helper token "$EMAIL" "${2:-Mac de test}" ;;
approve) helper approve "$EMAIL" "$2" ;;
start)
  [ -d "$BED/node_modules" ] || { echo "testbed missing: clone sp-drive.git into $BED and run pnpm install"; exit 1; }
  stop_web; ai_stop; rm -rf "$STATE"; mkdir -p "$STATE/data"
  if [ "${SPDRIVE_TESTBED_UPDATE:-1}" = 1 ]; then
    git -C "$BED" fetch -q origin "$REF" && git -C "$BED" checkout -q -B "$REF" "origin/$REF" || echo "warning: could not update the testbed to origin/$REF (offline?) — using what is there"
    (cd "$BED" && pnpm install --frozen-lockfile >/dev/null 2>&1) || echo "warning: pnpm install failed"
  fi
  [ -f "$BED/scripts/textkit-build.sh" ] && (cd "$BED" && zsh scripts/textkit-build.sh >/dev/null 2>&1 || echo "warning: text helper not built (no OCR / semantic search)")
  ai_start
  dropdb -h 127.0.0.1 --if-exists "$DB" 2>/dev/null; createdb -h 127.0.0.1 "$DB"
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex")+"\n")' > "$STATE/master.key"; chmod 600 "$STATE/master.key"
  web
  INVITE="$(server_env; cd "$BED"; node --import tsx services/api/src/cli.ts invite --email "$EMAIL" --admin 2>/dev/null | grep -o '/invite/[A-Za-z0-9_-]*' | head -1 | cut -d/ -f3)"
  [ -n "$INVITE" ] || { echo "could not create the invitation"; exit 1; }
  helper register "$EMAIL" "$INVITE"
  TOKEN="$(helper token "$EMAIL" "Suite de tests")"
  INVITE2="$(server_env; cd "$BED"; node --import tsx services/api/src/cli.ts invite --email "$EMAIL2" 2>/dev/null | grep -o '/invite/[A-Za-z0-9_-]*' | head -1 | cut -d/ -f3)"
  TOKEN2=""; if [ -n "$INVITE2" ]; then helper register "$EMAIL2" "$INVITE2"; TOKEN2="$(helper token "$EMAIL2" "Suite de tests (membre)")"; fi
  cat > "$ENVF" <<EOT
export SPDRIVE_TEST_URL=http://127.0.0.1:$PORT
export SPDRIVE_TEST_TOKEN=$TOKEN
export SPDRIVE_TEST_SCRIPT=$SELF
export SPDRIVE_TEST_DB=postgres://127.0.0.1/$DB
export SPDRIVE_TEST_TOKEN2=$TOKEN2
export SPDRIVE_TEST_EMAIL2=$EMAIL2
export SPDRIVE_TEST_EMAIL=$EMAIL
EOT
  chmod 600 "$ENVF"
  echo "backend ready on http://127.0.0.1:$PORT (branch $(git -C "$BED" rev-parse --abbrev-ref HEAD) @ $(git -C "$BED" rev-parse --short HEAD)); environment in $ENVF" ;;
*) echo "usage: $0 start|stop|env|web-stop|web-start|token <name>|token2 <name>|ai on|off|approve <CODE>"; exit 2 ;;
esac
