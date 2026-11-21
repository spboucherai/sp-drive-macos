#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : SP Drive pour macOS
# File             : Scripts/seed-demo.sh
# Description      : Fills the TEST account of the local backend with a small
#                    demonstration library (folders, documents, versions, a
#                    favourite, a share link, a deposit link, a trashed file)
#                    for visual checks. Synthetic content only.
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

set -euo pipefail
cd "$(dirname "$0")/.."
. /tmp/spdrive-backend-dev/env
export SPDRIVE_URL="$SPDRIVE_TEST_URL" SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN"
CLI="$(swift build --show-bin-path)/spdrive-cli"; [ -x "$CLI" ] || swift build -q --product spdrive-cli
api() { curl -fsS -X "$1" "$SPDRIVE_URL/api/v1$2" -H "Authorization: Bearer $SPDRIVE_TOKEN" -H 'content-type: application/json' -d "${3:-{\}}"; }
ROOT="$(api GET /sync/cursor '' | sed -E 's/.*"rootId":"([^"]+)".*/\1/')"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
if "$CLI" find "$ROOT" "Démo" >/dev/null 2>&1; then echo "already seeded"; exit 0; fi
D="$("$CLI" mkdir "$ROOT" "Démo" | cut -f2)"; S="$("$CLI" mkdir "$D" "Photos" | cut -f2)"; "$CLI" mkdir "$D" "Contrats" >/dev/null
printf 'Rapport trimestriel\nversion 1\n' > "$T/r.txt"; F="$("$CLI" put "$T/r.txt" "$D" "Rapport trimestriel.txt" | cut -f2)"
printf 'Rapport trimestriel\nversion 2, plus complète\n' > "$T/r.txt"; "$CLI" putversion "$T/r.txt" "$F" >/dev/null
printf 'Rapport trimestriel\nversion 3\n' > "$T/r.txt"; "$CLI" putversion "$T/r.txt" "$F" >/dev/null
printf '%%PDF-1.4\n%% synthetic test document\n' > "$T/b.pdf"; P="$("$CLI" put "$T/b.pdf" "$D" "Budget 2027.pdf" | cut -f2)"
head -c 3500000 /dev/urandom > "$T/v.mov"; "$CLI" put "$T/v.mov" "$D" "Présentation.mov" >/dev/null
printf 'a,b\n1,2\n' > "$T/c.csv"; "$CLI" put "$T/c.csv" "$D" "Données.csv" >/dev/null
printf 'notes' > "$T/n.md"; N="$("$CLI" put "$T/n.md" "$D" "Notes de réunion.md" | cut -f2)"
head -c 900000 /dev/urandom > "$T/p.jpg"; "$CLI" put "$T/p.jpg" "$S" "Chantier.jpg" >/dev/null
printf 'vieux' > "$T/o.txt"; O="$("$CLI" put "$T/o.txt" "$D" "Ancien brouillon.txt" | cut -f2)"; "$CLI" trash file "$O" >/dev/null
api PATCH "/files/$P" '{"starred":true}' >/dev/null; api PATCH "/folders/$S" '{"starred":true}' >/dev/null
api POST /shares "{\"fileId\":\"$P\",\"label\":\"Pour le comité\",\"password\":\"demo-1234\",\"maxDownloads\":5}" >/dev/null
api POST /shares "{\"folderId\":\"$S\",\"label\":\"Photos du chantier\",\"canDownload\":false}" >/dev/null
api POST /requests "{\"folderId\":\"$D\",\"title\":\"Dépôt des pièces justificatives\",\"maxFileBytes\":52428800}" >/dev/null
echo "seeded: Démo ($D)"
