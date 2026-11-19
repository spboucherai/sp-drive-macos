#!/usr/bin/env bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/seed-next.sh
# Description: Adds to the TEST account what the 2.0 interface needs to be looked at and measured: real images (so thumbnails exist), a real PDF, text documents, nested folders, a folder of 1,000 small files, and a real version conflict. Synthetic content only; local test backend only.
#
# Usage: Scripts/seed-next.sh [--thousand] [--collab] [--conflict]
set -euo pipefail
cd "$(dirname "$0")/.."
. /tmp/spdrive-backend-dev/env
export SPDRIVE_URL="$SPDRIVE_TEST_URL" SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN"
CLI="$(swift build --show-bin-path)/spdrive-cli"; [ -x "$CLI" ] || swift build -q --product spdrive-cli
api() { curl -fsS -X "$1" "$SPDRIVE_URL/api/v1$2" -H "Authorization: Bearer $SPDRIVE_TOKEN" -H 'content-type: application/json' -d "${3:-{\}}"; }
ROOT="$(api GET /sync/cursor '' | sed -E 's/.*"rootId":"([^"]+)".*/\1/')"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
find_or_make() { "$CLI" find "$1" "$2" 2>/dev/null | cut -f2 | grep . || "$CLI" mkdir "$1" "$2" | cut -f2; }

if ! "$CLI" find "$ROOT" "Atelier" >/dev/null 2>&1; then
  A="$("$CLI" mkdir "$ROOT" "Atelier" | cut -f2)"; P="$("$CLI" mkdir "$A" "Photos de chantier" | cut -f2)"; D="$("$CLI" mkdir "$A" "Dossiers clients" | cut -f2)"
  N="$("$CLI" mkdir "$D" "Maison Laurier" | cut -f2)"; "$CLI" mkdir "$N" "Plans" >/dev/null; "$CLI" mkdir "$N" "Devis" >/dev/null; "$CLI" mkdir "$N" "Correspondance" >/dev/null
  # real images drawn here (gradients and shapes): the server can make real thumbnails of them
  python3 - "$T" <<'PY'
import sys, struct, zlib, math
out = sys.argv[1]
def png(path, w, h, f):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w): raw.extend(f(x / w, y / h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))
def c(v): return max(0, min(255, int(v)))
scenes = {
 "Façade nord": lambda x, y: (c(60 + 150 * y), c(90 + 120 * y), c(200 - 60 * y)) if y < 0.55 else ((c(150 + 60 * math.sin(x * 40)), c(110), c(80)) if abs(x - 0.5) < 0.3 else (c(70), c(120 + 40 * x), c(60))),
 "Toiture": lambda x, y: (c(200 - 120 * abs(x - 0.5) * 2 - 80 * y), c(80 + 60 * y), c(70 + 40 * x)) if y > abs(x - 0.5) * 1.1 else (c(120 + 100 * y), c(170 + 60 * y), c(235)),
 "Escalier": lambda x, y: (c(230 - 25 * int((x + y) * 9)), c(215 - 22 * int((x + y) * 9)), c(190 - 18 * int((x + y) * 9))),
 "Cuisine": lambda x, y: (c(245 - 90 * (int(x * 6) % 2)), c(240 - 60 * (int(y * 4) % 2)), c(225 - 110 * ((int(x * 6) + int(y * 4)) % 2))),
 "Jardin": lambda x, y: (c(40 + 60 * math.sin(x * 9) ** 2), c(120 + 100 * (1 - y) * math.cos(y * 5) ** 2), c(50 + 40 * y)),
 "Plan de masse": lambda x, y: (c(250), c(250), c(246)) if (int(x * 24) % 6 and int(y * 18) % 6) else (c(90), c(100), c(190)),
}
for name, f in scenes.items(): png(f"{out}/{name}.png", 720, 480, f)
PY
  for f in "$T"/*.png; do n="$(basename "$f" .png)"; sips -s format jpeg -s formatOptions 82 "$f" --out "$T/$n.jpg" >/dev/null; "$CLI" put "$T/$n.jpg" "$P" >/dev/null; done
  "$CLI" put "$T/Plan de masse.png" "$N" >/dev/null
  # a real one-page PDF
  python3 - "$T/Devis 2027-014.pdf" <<'PY'
import sys
lines = ["Devis 2027-014", "", "Maison Laurier - renovation de la cuisine", "Demolition ............ 1 800 $", "Armoires .............. 9 400 $", "Comptoir quartz ....... 3 150 $", "Total ................ 14 350 $"]
stream = "BT /F1 16 Tf 72 720 Td 20 TL " + " ".join("(%s) Tj T*" % l.replace("(", "\\(").replace(")", "\\)") for l in lines) + " ET"
objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream), "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
pdf = "%PDF-1.4\n"; offs = []
for i, o in enumerate(objs): offs.append(len(pdf)); pdf += "%d 0 obj\n%s\nendobj\n" % (i + 1, o)
x = len(pdf); pdf += "xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + "".join("%010d 00000 n \n" % o for o in offs) + "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
open(sys.argv[1], "w").write(pdf)
PY
  "$CLI" put "$T/Devis 2027-014.pdf" "$N" >/dev/null
  printf '# Compte rendu de chantier\n\n- Dalle coulée lundi\n- Charpente livrée jeudi\n- Prochaine visite : le 4 décembre\n' > "$T/n.md"; "$CLI" put "$T/n.md" "$N" "Compte rendu de chantier.md" >/dev/null
  printf 'poste;montant\ndémolition;1800\narmoires;9400\ncomptoir;3150\n' > "$T/b.csv"; "$CLI" put "$T/b.csv" "$N" "Budget cuisine.csv" >/dev/null
  printf 'Bonjour,\nVoici le calendrier révisé.\n' > "$T/l.txt"; L="$("$CLI" put "$T/l.txt" "$N" "Lettre au client.txt" | cut -f2)"
  printf 'Bonjour,\nVoici le calendrier révisé, avec la livraison du 4 décembre.\n' > "$T/l.txt"; "$CLI" putversion "$T/l.txt" "$L" >/dev/null
  api PATCH "/folders/$N" '{"starred":true}' >/dev/null
  api POST /shares "{\"folderId\":\"$P\",\"label\":\"Pour l’architecte\"}" >/dev/null
  echo "seeded: Atelier ($A)"
else echo "Atelier already seeded"; fi

for arg in "$@"; do case "$arg" in
--thousand)
  if ! "$CLI" find "$ROOT" "Mille fichiers" >/dev/null 2>&1; then
    M="$("$CLI" mkdir "$ROOT" "Mille fichiers" | cut -f2)"; mkdir "$T/k"
    for i in $(seq -w 1 1000); do printf 'pièce %s\n' "$i" > "$T/k/Pièce $i.txt"; done
    ls "$T/k" | xargs -P 8 -I{} "$CLI" put "$T/k/{}" "$M" >/dev/null
    echo "seeded: Mille fichiers ($M), $("$CLI" ls "$M" | wc -l | tr -d ' ') items"
  else echo "Mille fichiers already seeded"; fi ;;
--collab)
  # the SECOND test account shares two folders with the app's account (editor, and deposit-only), so that
  # "Partagés avec moi" has something real to browse; and the app's account gets a smart collection
  [ -n "${SPDRIVE_TEST_TOKEN2:-}" ] || { echo "no second account in the test backend"; exit 1; }
  api2() { curl -fsS -X "$1" "$SPDRIVE_URL/api/v1$2" -H "Authorization: Bearer $SPDRIVE_TEST_TOKEN2" -H 'content-type: application/json' -d "${3:-{\}}"; }
  ROOT2="$(api2 GET /sync/cursor '' | sed -E 's/.*"rootId":"([^"]+)".*/\1/')"
  if ! api GET /shared-with-me '' | grep -q "Studio partagé"; then
    E="$(SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN2" "$CLI" mkdir "$ROOT2" "Équipe design" | cut -f2)"
    printf '# Charte graphique\n\nCouleur principale : violet. Typographie : New York pour les titres.\n' > "$T/charte.md"; SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN2" "$CLI" put "$T/charte.md" "$E" "Charte graphique.md" >/dev/null
    printf 'lot;échéance\nmaquettes;2026-12-04\nicônes;2026-12-11\n' > "$T/plan.csv"; SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN2" "$CLI" put "$T/plan.csv" "$E" "Planning.csv" >/dev/null
    SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN2" "$CLI" mkdir "$E" "Maquettes" >/dev/null
    api2 POST "/folders/$E/members" "{\"email\":\"$SPDRIVE_TEST_EMAIL\",\"role\":\"editor\",\"workspaceName\":\"Studio partagé\"}" >/dev/null
    B="$(SPDRIVE_TOKEN="$SPDRIVE_TEST_TOKEN2" "$CLI" mkdir "$ROOT2" "Boîte de dépôt" | cut -f2)"
    api2 POST "/folders/$B/members" "{\"email\":\"$SPDRIVE_TEST_EMAIL\",\"role\":\"uploader\"}" >/dev/null
    echo "seeded: two folders shared with $SPDRIVE_TEST_EMAIL"
  else echo "shares already seeded"; fi
  if ! api GET /collections '' | grep -q "Images du chantier"; then
    api POST /collections '{"name":"Images du chantier","icon":"photo","color":"blue","rule":{"match":"all","conditions":[{"field":"kind","op":"is","value":"image"}],"sort":{"by":"updated","dir":"desc"}}}' >/dev/null
    api POST /collections '{"name":"Modifiés ce mois-ci","icon":"clock","color":"violet","rule":{"match":"all","conditions":[{"field":"modified","op":"within","value":30},{"field":"kind","op":"isNot","value":"video"}],"sort":{"by":"updated","dir":"desc"}}}' >/dev/null
    echo "seeded: two collections"
  fi ;;
--conflict)
  # a real conflict: the app's test account edits a file from an old version while "another device" already replaced it
  A="$(find_or_make "$ROOT" "Atelier")"
  printf 'Planning v1\n' > "$T/p.txt"; F="$("$CLI" put "$T/p.txt" "$A" "Planning $(date +%H%M%S).txt")"; ID="$(echo "$F" | cut -f2)"
  echo "conflict-base	$ID" ;;
esac; done
