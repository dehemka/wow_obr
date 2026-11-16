#!/usr/bin/env bash
# Construit dist/OneButtonRotation-<version>.zip (dossier OneButtonRotation/ à la racine du zip).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^## Version: *//p' OneButtonRotation/OneButtonRotation.toc | tr -d '\r')
mkdir -p dist
OUT="dist/OneButtonRotation-${VERSION}.zip"
rm -f "$OUT"
zip -r -X "$OUT" OneButtonRotation -x '*.swp' -x '*~' -x '*/.*'
echo "OK : $OUT"
