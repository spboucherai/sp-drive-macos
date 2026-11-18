#!/usr/bin/env bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/finder-scenario.sh
# Description: The validation scenario through the real Finder location of the development variant, against the local TEST backend: browse, download, edit, sync back, conflict, offline edits and additions, extension restart, reconnection, no data loss. Every check reads the server or the disk; nothing is simulated.
#
# Requires: Scripts/backend-dev.sh start · the dev app signed in (Scripts/run-dev.sh --link --keep) · the location "SP Drive Dev"
# turned on by the person in System Settings › General › Login Items & Extensions › File Providers.
# Not covered here (cannot be scripted): a real restart of the Mac — the extension and the app are killed and restarted instead.
set -uo pipefail
cd "$(dirname "$0")/.."
. /tmp/spdrive-backend-dev/env
export SPDRIVE_URL="$SPDRIVE_TEST_URL" SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN"
CLI="$(swift build --show-bin-path)/spdrive-cli"; [ -x "$CLI" ] || swift build -q --product spdrive-cli
FP="$HOME/Library/CloudStorage/SPDriveDev-Dev"
APPBIN="$HOME/Library/Developer/SPDrive/DerivedData/Build/Products/Debug/SP Drive Dev.app/Contents/MacOS/SP Drive Dev"
PASS=0; FAIL=0
ok() { echo "  PASS  $1"; PASS=$((PASS+1)); }; ko() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }
# waits until a command succeeds (the system syncs on its own schedule)
until_ok() { local t="$1"; shift; local end=$((SECONDS+t)); while [ $SECONDS -lt $end ]; do if eval "$*" >/dev/null 2>&1; then return 0; fi; sleep 1; done; return 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
srv_id() { "$CLI" find "$1" "$2" 2>/dev/null | cut -f2; }          # identifier of a named child on the server
srv_field() { "$CLI" find "$1" "$2" 2>/dev/null | cut -f"$3"; }
app_running() { pgrep -f "$APPBIN" >/dev/null; }
stop_app() { local p; p="$(pgrep -f "$APPBIN" || true)"; [ -n "$p" ] && kill $p 2>/dev/null; sleep 1; }
start_app() { "$APPBIN" -ApplePersistenceIgnoreState YES >/tmp/spdrive-dev-app.log 2>&1 & sleep 4; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "== 0. Preconditions"
fileproviderctl dump ai.spboucher.spdrive.dev.fileprovider 2>/dev/null | grep -Eq "enabled: +yes" || { echo "  the location is not turned on in System Settings: nothing can be validated"; exit 2; }
check "the Finder location exists" '[ -d "$FP" ]'
app_running || start_app
ROOT="$(curl -fsS "$SPDRIVE_URL/api/v1/sync/cursor" -H "Authorization: Bearer $SPDRIVE_TOKEN" | sed -E 's/.*"rootId":"([^"]+)".*/\1/')"
NAME="Scénario $(date +%H%M%S)"

echo "== 1. A folder made on another device appears in the Finder; its file downloads intact"
D="$("$CLI" mkdir "$ROOT" "$NAME" | cut -f2)"
printf 'contenu créé sur le serveur\n' > "$T/a.txt"; "$CLI" put "$T/a.txt" "$D" "note.txt" >/dev/null
head -c 20000000 /dev/urandom > "$T/big.bin"; "$CLI" put "$T/big.bin" "$D" "gros.bin" >/dev/null
check "folder listed by the Finder location" 'until_ok 60 "[ -d \"$FP/$NAME\" ]"'   # by path: the file system hands names back decomposed (NFD)
L="$FP/$NAME"
check "its files listed" 'until_ok 60 "[ -e \"$L/note.txt\" ] && [ -e \"$L/gros.bin\" ]"'
check "small file read through the Finder = server content" '[ "$(cat "$L/note.txt" 2>/dev/null)" = "contenu créé sur le serveur" ]'
check "20 MB file read through the Finder has the server SHA-256" '[ "$(sha "$L/gros.bin")" = "$(sha "$T/big.bin")" ]'

echo "== 2. A file edited in the Finder is sent back as a new version"
printf 'ligne ajoutée sur ce Mac\n' >> "$L/note.txt"
F="$(srv_id "$D" note.txt)"
check "server has version 2" 'until_ok 90 "[ \"\$(srv_field \"$D\" note.txt 4)\" = 2 ]"'
check "server content = edited content" '[ "$("$CLI" cat "$F")" = "$(cat "$L/note.txt")" ]'

echo "== 3. Create, rename, move in the Finder"
printf 'créé dans le Finder\n' > "$L/nouveau.txt"; mkdir "$L/Sous-dossier"
check "new file on the server" 'until_ok 90 "[ -n \"\$(srv_id \"$D\" nouveau.txt)\" ]"'
check "new folder on the server" 'until_ok 90 "[ -n \"\$(srv_id \"$D\" Sous-dossier)\" ]"'
mv "$L/nouveau.txt" "$L/renommé.txt"
check "rename on the server" 'until_ok 90 "[ -n \"\$(srv_id \"$D\" renommé.txt)\" ] && [ -z \"\$(srv_id \"$D\" nouveau.txt)\" ]"'
S="$(srv_id "$D" Sous-dossier)"; mv "$L/renommé.txt" "$L/Sous-dossier/"
check "move on the server" 'until_ok 90 "[ -n \"\$(srv_id \"$S\" renommé.txt)\" ]"'

echo "== 4. Conflict: the file changes on another device, then is edited here from the old version"
stop_app                                        # nobody tells the system about the server change
printf 'version écrite par un autre appareil\n' > "$T/other.txt"; "$CLI" putversion "$T/other.txt" "$F" >/dev/null
printf 'version écrite sur ce Mac sans connaître l’autre\n' > "$L/note.txt"
check "a conflict copy appears on the server" 'until_ok 120 "\"$CLI\" ls \"$D\" | cut -f7 | grep -q \"^note (conflit \""'
check "the other device’s version was NOT overwritten" '[ "$("$CLI" cat "$F")" = "version écrite par un autre appareil" ]'
C="$("$CLI" ls "$D" | awk -F'\t' '$7 ~ /^note \(conflit / {print $2; exit}')"
check "this Mac’s version is preserved in the copy" '[ "$("$CLI" cat "$C")" = "version écrite sur ce Mac sans connaître l’autre" ]'
start_app
check "the Finder shows both files, the original with the server content" 'until_ok 120 "[ \"\$(cat \"$L/note.txt\")\" = \"version écrite par un autre appareil\" ] && ls \"$L\" | grep -q \"^note (conflit \""'

echo "== 5. Offline: edits and additions wait on this Mac, survive a restart of the extension and of the app, then sync"
cat "$L/gros.bin" >/dev/null                     # make sure the files are on this Mac
Scripts/backend-dev.sh web-stop
printf 'modifié hors ligne\n' >> "$L/Sous-dossier/renommé.txt"
printf 'ajouté hors ligne\n' > "$L/ajout hors ligne.txt"; mkdir "$L/Dossier hors ligne"; printf 'x\n' > "$L/Dossier hors ligne/dedans.txt"
head -c 1000 /dev/urandom >> "$L/gros.bin"; BIGSHA="$(sha "$L/gros.bin")"
sleep 6
stop_app; EXTPID="$(pgrep -f SPDriveFileProvider.appex || true)"; [ -n "$EXTPID" ] && kill $EXTPID 2>/dev/null   # "restart"
sleep 2
check "offline changes still on this Mac after the restart" '[ "$(cat "$L/ajout hors ligne.txt")" = "ajouté hors ligne" ] && [ -f "$L/Dossier hors ligne/dedans.txt" ] && [ "$(sha "$L/gros.bin")" = "$BIGSHA" ] && grep -q "modifié hors ligne" "$L/Sous-dossier/renommé.txt"'
Scripts/backend-dev.sh web-start
start_app
check "file added offline reaches the server" 'until_ok 240 "[ -n \"\$(srv_id \"$D\" \"ajout hors ligne.txt\")\" ]"'
check "folder and file created offline reach the server" 'until_ok 240 "O=\$(srv_id \"$D\" \"Dossier hors ligne\"); [ -n \"\$O\" ] && [ -n \"\$(srv_id \"\$O\" dedans.txt)\" ]"'
G="$(srv_id "$D" gros.bin)"
check "20 MB file edited offline reaches the server intact" 'until_ok 240 "\"$CLI\" get \"$G\" \"$T/back.bin\" >/dev/null && [ \"\$(sha \"$T/back.bin\")\" = \"$BIGSHA\" ]"'
R="$(srv_id "$S" renommé.txt)"
check "small file edited offline reaches the server" 'until_ok 240 "\"$CLI\" cat \"$R\" | grep -q \"modifié hors ligne\""'

echo "== 6. Deleting in the Finder moves to the trash of SP Drive (never destroys)"
rm "$L/ajout hors ligne.txt"
A="$(curl -fsS "$SPDRIVE_URL/api/v1/trash" -H "Authorization: Bearer $SPDRIVE_TOKEN")"
check "deleted file is in the server trash" 'until_ok 120 "curl -fsS \"$SPDRIVE_URL/api/v1/trash\" -H \"Authorization: Bearer $SPDRIVE_TOKEN\" | grep -q \"ajout hors ligne.txt\""'
"$CLI" restore file "$(curl -fsS "$SPDRIVE_URL/api/v1/trash" -H "Authorization: Bearer $SPDRIVE_TOKEN" | python3 -c 'import json,sys; print(next(f["id"] for f in json.load(sys.stdin)["files"] if f["name"]=="ajout hors ligne.txt"))')" >/dev/null 2>&1
check "restored on the server, it comes back in the Finder" 'until_ok 120 "[ -e \"$L/ajout hors ligne.txt\" ]"'

echo "== Result: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
