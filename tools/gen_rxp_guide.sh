#!/usr/bin/env bash
# Construit l'addon compagnon DMK_RXP (guide RestedXP personnel) → dist/DMK_RXP.zip
# Usage : tools/gen_rxp_guide.sh [source.txt] [nom]
# Le dossier généré (private/DMK_RXP/) et le zip ne vont jamais dans le dépôt git.
# La chaîne RestedXP ne contient que [A-Za-z0-9+/=|:%], donc le long-string Lua [==[ ... ]==] est sûr.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-private/restedxp_guide.txt}"
NAME="${2:-}"
[[ -s "$SRC" ]] || { echo "❌ $SRC absent ou vide" >&2; exit 1; }
if grep -q ']==]' "$SRC"; then echo "❌ la source contient ']==]'" >&2; exit 1; fi
if [[ -z "$NAME" && -f private/restedxp_guide.name ]]; then NAME=$(<private/restedxp_guide.name); fi
NAME=${NAME:-Guide RestedXP}
NAME=${NAME//\"/\'}
ADDON=DMK_RXP
OUTDIR="private/$ADDON"
STAMP=$(date +%Y-%m-%d)
HEAD=$(head -c 40 "$SRC")
NGUIDES=$(echo "$HEAD" | sed -n 's/^\([0-9]*\)|.*/\1/p')
mkdir -p "$OUTDIR" dist

cat > "$OUTDIR/$ADDON.toc" <<TOC
## Interface: 16001, 16002, 16003, 16004, 16005
## Title: DMK RestedXP Guide
## Notes: Guide RestedXP personnel ($NGUIDES guides, export du $STAMP). RestedXP l'importe tout seul à la connexion. Onglet RestedXP de One Button Rotation pour l'état.
## Author: Eric
## Version: $STAMP
## IconTexture: 134269
## X-Guide: $NAME

$ADDON.lua
TOC

{
  echo "-- Fichier GÉNÉRÉ par tools/gen_rxp_guide.sh ($STAMP) : ne pas éditer."
  echo "-- Chaîne d'import RestedXP. RestedXP lit la globale RXPString au chargement et importe le guide"
  echo "-- tout seul si elle a changé (RXPGuides/GuideLoader.lua : LoadCachedGuides)."
  printf 'local text = [==['
  tr -d '\r\n' < "$SRC"
  printf ']==]\n'
  echo "DMK_RXP = { name = \"$NAME\", generated = \"$STAMP\", size = #text, text = text }"
  echo "if #text > 0 then RXPString = text end"
} > "$OUTDIR/$ADDON.lua"

ZIP="dist/$ADDON.zip"
rm -f "$ZIP"
( cd private && zip -q -r -X "../$ZIP" "$ADDON" )
echo "OK : $ZIP ($(du -h "$ZIP" | cut -f1), $NGUIDES guides, « $NAME »)"
