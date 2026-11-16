#!/usr/bin/env bash
# Génère OneButtonRotation/data/RestedXP_Guide.lua à partir d'une chaîne d'import RestedXP.
# Usage : tools/gen_rxp_guide.sh [source.txt] [sortie.lua] [nom]
#   source.txt absent ou vide → fichier Lua « vide » (l'onglet RestedXP dit qu'aucun guide n'est embarqué).
# La chaîne RestedXP ne contient que [A-Za-z0-9+/=|:%], donc le long-string Lua [==[ ... ]==] est sûr.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-private/restedxp_guide.txt}"
OUT="${2:-OneButtonRotation/data/RestedXP_Guide.lua}"
NAME="${3:-}"
if [[ -z "$NAME" && -f private/restedxp_guide.name ]]; then NAME=$(<private/restedxp_guide.name); fi
NAME=${NAME:-Guide RestedXP}
NAME=${NAME//\"/\'}

{
  echo "-- Fichier GÉNÉRÉ par tools/gen_rxp_guide.sh : ne pas éditer, ne pas commiter."
  echo "-- Chaîne d'import RestedXP embarquée. RestedXP lit la globale RXPString au chargement"
  echo "-- et importe le guide tout seul si elle a changé (voir GuideLoader.lua : LoadCachedGuides)."
  echo "local ADDON_NAME, ns = ..."
  if [[ -s "$SRC" ]]; then
    if grep -q ']==]' "$SRC"; then echo "❌ la source contient ']==]'" >&2; exit 1; fi
    printf 'local text = [==['
    tr -d '\r\n' < "$SRC"
    printf ']==]\n'
    echo "ns.RestedXPGuide = { name = \"$NAME\", generated = \"$(date +%Y-%m-%d)\", size = #text, text = text }"
    echo "if #text > 0 then RXPString = text end"
    echo "ns.loadedFiles = (ns.loadedFiles or \"\") .. \", RXPGuide\""
  else
    echo "ns.RestedXPGuide = nil -- aucun guide embarqué dans cette construction"
  fi
} > "$OUT"
echo "OK : $OUT ($(du -h "$OUT" | cut -f1))"
