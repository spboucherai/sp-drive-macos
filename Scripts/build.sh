#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : SP Drive pour macOS
# File             : Scripts/build.sh
# Module           : Scripts
# Repository       : https://git.spboucher.ai/sp-drive-macos
# Created          : 2026-11-18
# Last Modified    : 2026-11-18
#
# Author           : Simon-Pierre Boucher
# Position         : Professor of Finance
# Institution      : Université du Québec en Outaouais (UQO)
# Organization     : SP Boucher
# Website          : https://spboucher.ai
# Git              : https://git.spboucher.ai
#
# Preferred Contact: support@spboucher.ai
# Technical Contact: dev@spboucher.ai
# Security/Admin   : admin@spboucher.ai
#
# Copyright (c) 2026
# Simon-Pierre Boucher
# All rights reserved where applicable. This file is governed by the
# applicable project license, copyright notices and relevant law.
# Existing third-party rights and notices remain unaffected.
#
# License          : None specified (no license file in this repository)
#
# Do not embed credentials, private keys, access tokens,
# certificates or confidential personal information.
#
# =============================================================================
# END OF SP BOUCHER SOURCE HEADER
# =============================================================================

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
