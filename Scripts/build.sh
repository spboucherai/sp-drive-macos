#!/usr/bin/env bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/build.sh
# Description: Generates the Xcode project and builds the app with its File Provider extension (errors only on the console).
#
# Usage: Scripts/build.sh [Debug|Release] [lines]     Debug = the development variant "SP Drive Dev".
# Products go outside ~/Desktop (the system services that load the extension cannot read there).
set -uo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"; DD="$HOME/Library/Developer/SPDrive/DerivedData"; mkdir -p Build "$DD"
[[ -d Build/profiles ]] || { echo "profiles missing: run Scripts/provision.py"; exit 1; }
xcodegen generate --quiet
xcodebuild -project SPDrive.xcodeproj -scheme SPDrive -configuration "$CONFIG" -derivedDataPath "$DD" build 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > Build/build.log
grep -E "error:|warning: unre|BUILD" Build/build.log | sed -E "s#$PWD/##" | grep -v "^ *|" | sort -u | cut -c1-300 | head -"${2:-50}"
grep -q "BUILD SUCCEEDED" Build/build.log
