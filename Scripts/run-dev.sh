#!/usr/bin/env bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/run-dev.sh
# Description: Launches the development variant "SP Drive Dev" against the local TEST backend and optionally captures its own window (never the screen).
#
# Usage: Scripts/run-dev.sh [--shot out.png] [--wait seconds] [--keep] [--link] [-- extra app arguments…]
#   --link    sign the app in through the device-code flow (approved by the test account with Scripts/backend-dev.sh)
#   App arguments (development variant only): -spdSection drive|recent|shared|portals|favorites|offline|downloads|transfers|conflicts|trash|storage,
#   -spdGrid YES, -spdFolder <name>, -spdPath <a/b/c>, -spdPalette YES, -spdSearch <text>, -spdSelect <name>, -spdSelectFirst YES, -spdInspector YES, -spdSheet share|versions|portal|rename|move|newFolder
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$HOME/Library/Developer/SPDrive/DerivedData/Build/Products/Debug/SP Drive Dev.app"; BIN="$APP/Contents/MacOS/SP Drive Dev"
GC="$HOME/Library/Group Containers/3YM54G49SN.ai.spboucher.spdrive.dev"
SHOT=""; WAIT=5; KEEP=0; LINK=0; EXTRA=()
while [ $# -gt 0 ]; do case "$1" in --shot) SHOT="$2"; shift 2;; --wait) WAIT="$2"; shift 2;; --keep) KEEP=1; shift;; --link) LINK=1; shift;; --) shift; EXTRA=("$@"); break;; *) EXTRA+=("$1"); shift;; esac; done
stop() { local p; p="$(pgrep -f "$BIN" || true)"; [ -n "$p" ] && kill $p 2>/dev/null || true; }   # only the development copy is ever stopped
stop; sleep 0.6
if [ $LINK = 1 ]; then
  rm -f "$GC/devlink.txt"
  "$BIN" -spdAutoLink -ApplePersistenceIgnoreState YES ${EXTRA[@]+"${EXTRA[@]}"} > /tmp/spdrive-dev-app.log 2>&1 &
  for _ in $(seq 1 60); do [ -f "$GC/devlink.txt" ] && break; sleep 0.25; done
  [ -f "$GC/devlink.txt" ] || { echo "the app did not produce a device code"; exit 1; }
  Scripts/backend-dev.sh approve "$(cat "$GC/devlink.txt")"
else
  "$BIN" -ApplePersistenceIgnoreState YES ${EXTRA[@]+"${EXTRA[@]}"} > /tmp/spdrive-dev-app.log 2>&1 &
fi
sleep "$WAIT"
if [ -n "$SHOT" ]; then swift Scripts/window-shot.swift "SP Drive Dev" "$SHOT" | tail -1; fi
[ $KEEP = 1 ] || stop
