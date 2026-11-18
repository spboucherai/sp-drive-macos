#!/usr/bin/env bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/verify-release.sh
# Description: Checks the signed application and its File Provider extension: signatures, hardened runtime, sandbox and entitlements, embedded profiles, no web engine, no debug entitlement, no development switch, no secrets in the bundle.
#
# Usage: Scripts/verify-release.sh [path/to/SP Drive.app]   (exit code ≠ 0 when a check fails)
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/SP Drive.app}"; BIN="$APP/Contents/MacOS/SP Drive"; EXT="$APP/Contents/PlugIns/SPDriveFileProvider.appex"; EXTBIN="$EXT/Contents/MacOS/SPDriveFileProvider"; FAIL=0
ok() { echo "  ✓ $1"; }; ko() { echo "  ✗ $1"; FAIL=1; }
[[ -d "$APP" ]] || { echo "ERROR: $APP not found" >&2; exit 1; }
for target in "$APP" "$EXT"; do
  echo "== Signature: $(basename "$target")"
  codesign --verify --deep --strict "$target" 2>/dev/null && ok "codesign --verify --deep --strict" || ko "signature invalid"
  INFO="$(codesign -dvv "$target" 2>&1)"
  grep -q "Authority=Developer ID Application" <<<"$INFO" && ok "$(grep -m1 '^Authority=' <<<"$INFO")" || ko "not signed with Developer ID Application"
  grep -Eq "flags=.*runtime" <<<"$INFO" && ok "hardened runtime enabled" || ko "hardened runtime missing"
  grep -q "^Timestamp=" <<<"$INFO" && ok "secure timestamp present" || ko "no secure timestamp"
  grep -q "^Identifier=ai.spboucher.spdrive\(.fileprovider\)\?$" <<<"$INFO" && ok "$(grep -m1 '^Identifier=' <<<"$INFO")" || ko "unexpected identifier: $(grep -m1 '^Identifier=' <<<"$INFO")"
  ENT="$(codesign -d --entitlements :- "$target" 2>/dev/null)"
  grep -A1 "com.apple.security.app-sandbox" <<<"$ENT" | grep -q "<true/>" && ok "App Sandbox on" || ko "App Sandbox off"
  grep -q "3YM54G49SN.ai.spboucher.spdrive</string>" <<<"$ENT" && ok "app group 3YM54G49SN.ai.spboucher.spdrive" || ko "app group missing"
  grep -q "3YM54G49SN.ai.spboucher.spdrive.shared" <<<"$ENT" && ok "shared keychain group" || ko "shared keychain group missing"
  grep -q "get-task-allow" <<<"$ENT" && ko "get-task-allow present (debug entitlement)" || ok "no get-task-allow"
  for bad in com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-unsigned-executable-memory com.apple.security.cs.allow-jit com.apple.security.network.server com.apple.security.device.camera com.apple.security.files.all com.apple.developer.fileprovider.testing-mode; do
    grep -q "$bad" <<<"$ENT" && ko "unexpected entitlement $bad"; done; ok "no runtime exception, no server socket, no testing mode, no broad file access"
  [[ -f "$target/Contents/embedded.provisionprofile" ]] && ok "provisioning profile embedded" || ko "embedded.provisionprofile missing"
done
echo "== Application entitlements"
ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
grep -q "webcredentials:drive.spboucher.ai" <<<"$ENT" && ok "associated domain webcredentials:drive.spboucher.ai (passkeys)" || ko "associated domain missing (passkeys would fail)"
echo "== File Provider extension"
/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$EXT/Contents/Info.plist" 2>/dev/null | grep -q "com.apple.fileprovider-nonui" && ok "extension point com.apple.fileprovider-nonui" || ko "wrong extension point"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionFileProviderDocumentGroup' "$EXT/Contents/Info.plist" 2>/dev/null)" == "3YM54G49SN.ai.spboucher.spdrive" ]] && ok "document group = the app group" || ko "document group mismatch"
echo "== Native only"
LIBS="$(for b in "$BIN" "$EXTBIN"; do for a in $(lipo -archs "$b"); do otool -arch "$a" -L "$b"; done; done; find "$APP/Contents" -name '*.dylib' -o -name '*.framework')"
grep -Eiq "WebKit|JavaScriptCore|Electron|Chromium" <<<"$LIBS" && ko "a web engine is linked" || ok "no WebKit / JavaScriptCore / Chromium linked"
find "$APP" \( -name '*.html' -o -name '*.js' -o -name '*.css' \) | grep -q . && ko "web resources in the bundle" || ok "no HTML / JS / CSS resources"
echo "== Release, not development"
for b in "$BIN" "$EXTBIN"; do
  strings -a "$b" | grep -Eq "spdAutoLink|spdSelfTest|127\.0\.0\.1:8665|spdrive\.dev" && ko "development switch or test server in $(basename "$b")" || ok "$(basename "$b"): no development switch, no test server, no .dev identifier"
done
grep -q "NSAllowsLocalNetworking" "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist" && ko "plain-HTTP exception present" || ok "no App Transport Security exception"
echo "== Secrets"
if grep -rlaE "(sk-ant-|sk-proj-|BEGIN (EC |RSA )?PRIVATE KEY|Bearer [A-Za-z0-9_-]{40})" "$APP" >/dev/null 2>&1; then ko "something that looks like a secret is in the bundle"; else ok "no API key, private key or session token in the bundle"; fi
echo "== Bundle"
echo "  version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")) · archs $(lipo -archs "$BIN") / ext $(lipo -archs "$EXTBIN") · min macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist") · $(du -sh "$APP" | cut -f1)"
[[ -f "$APP/Contents/Resources/AppIcon.icns" || -f "$APP/Contents/Resources/Assets.car" ]] && ok "icon assets present" || ko "icon missing"
exit $FAIL
