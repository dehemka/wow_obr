#!/usr/bin/env bash
# ==============================================================================
# Construit le zip de l'addon et le déploie sur S3 / CloudFront.
# Cible : https://storage.dehemka.net/public/wow/addons/OneButtonRotation-<version>.zip
#         https://storage.dehemka.net/public/wow/addons/OneButtonRotation-latest.zip (alias stable)
#         https://storage.dehemka.net/public/wow/obr.zip (alias court, même contenu)
# Profil AWS : perso
#
# Usage : ./deploy.sh [--short [alias]] [--no-invalidate] [--dry-run] [--release]
#   --release        après le déploiement : commit de tout (si besoin), tag v<version>, push main + tag
#                    → GitHub Actions publie la Release (zip -forever + release.json) lue par WowUp
#   --short [alias]  crée (une seule fois) un lien court is.gd vers le zip "latest",
#                    avec un alias personnalisé optionnel (ex: --short obr-wow -> https://is.gd/obr-wow)
#   --no-invalidate  ne purge pas le cache CloudFront
#   --dry-run        affiche les commandes sans les exécuter
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON="OneButtonRotation"
TOC="$SCRIPT_DIR/$ADDON/$ADDON.toc"

S3_BUCKET="s3://storage.dehemka.net"
S3_PREFIX="public/wow/addons"
SHORT_KEY="public/wow/obr.zip"      # alias court : la policy du bucket ne sert que public/* et private/*
PUBLIC_BASE="https://storage.dehemka.net/$S3_PREFIX"
SHORT_ZIP_URL="https://storage.dehemka.net/$SHORT_KEY"
AWS_PROFILE="perso"
CLOUDFRONT_DIST_ID="E54331XHNFDHL"
SHORT_URL_FILE="$SCRIPT_DIR/dist/short_url.txt"

SHORT=0; SHORT_ALIAS=""; INVALIDATE=1; DRY=0; RELEASE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --short)         SHORT=1; if [[ -n "${2:-}" && "${2:0:2}" != "--" ]]; then SHORT_ALIAS="$2"; shift; fi ;;
    --no-invalidate) INVALIDATE=0 ;;
    --dry-run)       DRY=1 ;;
    --release)       RELEASE=1 ;;
    -h|--help)       sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

run() { if [[ $DRY -eq 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }

for bin in aws zip curl; do
  command -v "$bin" >/dev/null || { echo "❌ $bin introuvable" >&2; exit 1; }
done
[[ -f "$TOC" ]] || { echo "❌ $TOC introuvable" >&2; exit 1; }

VERSION=$(sed -n 's/^## Version: *//p' "$TOC" | tr -d '\r[:space:]')
[[ -n "$VERSION" ]] || { echo "❌ Pas de '## Version:' dans $TOC" >&2; exit 1; }
ZIP_NAME="$ADDON-$VERSION.zip"
LATEST_NAME="$ADDON-latest.zip"
ZIP_PATH="$SCRIPT_DIR/dist/$ZIP_NAME"

echo "=========================================================="
echo "🚀 Déploiement de $ADDON v$VERSION"
echo "=========================================================="
echo "Cible  : $S3_BUCKET/$S3_PREFIX/"
echo "Profil : $AWS_PROFILE"
echo "----------------------------------------------------------"

# 1. Build
echo "📦 1/4 Construction du zip..."
run "$SCRIPT_DIR/build.sh" >/dev/null
[[ $DRY -eq 1 || -f "$ZIP_PATH" ]] || { echo "❌ $ZIP_PATH non produit" >&2; exit 1; }
if [[ $DRY -eq 0 ]]; then
  unzip -tq "$ZIP_PATH" >/dev/null || { echo "❌ zip corrompu" >&2; exit 1; }
  echo "✅ $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
fi

# 2. Upload zip versionné + alias latest + version.txt
echo "☁️  2/4 Upload vers S3..."
run aws s3 cp "$ZIP_PATH" "$S3_BUCKET/$S3_PREFIX/$ZIP_NAME" \
  --profile "$AWS_PROFILE" \
  --content-type "application/zip" \
  --cache-control "public, max-age=31536000, immutable"
run aws s3 cp "$ZIP_PATH" "$S3_BUCKET/$S3_PREFIX/$LATEST_NAME" \
  --profile "$AWS_PROFILE" \
  --content-type "application/zip" \
  --cache-control "public, max-age=300"
run aws s3 cp "$ZIP_PATH" "$S3_BUCKET/$SHORT_KEY" \
  --profile "$AWS_PROFILE" \
  --content-type "application/zip" \
  --content-disposition "attachment; filename=\"$ZIP_NAME\"" \
  --cache-control "public, max-age=300"
if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] echo $VERSION | aws s3 cp - $S3_BUCKET/$S3_PREFIX/version.txt"
else
  echo "$VERSION" | aws s3 cp - "$S3_BUCKET/$S3_PREFIX/version.txt" \
    --profile "$AWS_PROFILE" \
    --content-type "text/plain; charset=utf-8" \
    --cache-control "public, max-age=300"
fi
echo "✅ Uploadé : $ZIP_NAME, $LATEST_NAME, $(basename "$SHORT_KEY"), version.txt"

# 3. Invalidation CloudFront
if [[ $INVALIDATE -eq 1 ]]; then
  echo "🔄 3/4 Invalidation CloudFront ($CLOUDFRONT_DIST_ID) sur /$S3_PREFIX/* et /$SHORT_KEY..."
  run aws cloudfront create-invalidation \
    --distribution-id "$CLOUDFRONT_DIST_ID" \
    --paths "/$S3_PREFIX/*" "/$SHORT_KEY" \
    --profile "$AWS_PROFILE" >/dev/null
  echo "✅ Cache purgé."
else
  echo "⏭️  3/4 Invalidation CloudFront ignorée."
fi

# 4. Vérification publique (CloudFront peut mettre quelques secondes)
VERSIONED_URL="$PUBLIC_BASE/$ZIP_NAME"
LATEST_URL="$PUBLIC_BASE/$LATEST_NAME"
if [[ $DRY -eq 0 ]]; then
  echo "🔎 4/4 Vérification de $VERSIONED_URL..."
  ok=0
  for i in $(seq 1 10); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -I "$VERSIONED_URL" || true)
    if [[ "$code" == "200" ]]; then ok=1; break; fi
    sleep 3
  done
  if [[ $ok -eq 1 ]]; then echo "✅ Accessible (HTTP 200)."; else echo "⚠️ Toujours pas accessible (dernier code HTTP : $code), réessaie dans une minute." >&2; fi
fi

# Lien court (optionnel, créé une seule fois et mémorisé dans dist/short_url.txt)
SHORT_URL=""
if [[ -f "$SHORT_URL_FILE" ]]; then
  SHORT_URL=$(<"$SHORT_URL_FILE")
elif [[ $SHORT -eq 1 && $DRY -eq 0 ]]; then
  echo "🔗 Création du lien court is.gd vers $LATEST_URL..."
  args=(-s -G "https://is.gd/create.php" -A "deploy-obr/1.0" --data-urlencode "url=$LATEST_URL" -d "format=simple")
  [[ -n "$SHORT_ALIAS" ]] && args+=(--data-urlencode "shorturl=$SHORT_ALIAS")
  resp=$(curl "${args[@]}" || true)
  if [[ "$resp" == https://is.gd/* ]]; then
    SHORT_URL="$resp"
    mkdir -p "$(dirname "$SHORT_URL_FILE")"
    echo "$SHORT_URL" > "$SHORT_URL_FILE"
    echo "✅ Lien court créé et mémorisé dans $SHORT_URL_FILE"
  else
    echo "⚠️ is.gd a refusé : ${resp:-pas de réponse}" >&2
  fi
elif [[ $SHORT -eq 1 ]]; then
  echo "  [dry-run] curl is.gd/create.php url=$LATEST_URL${SHORT_ALIAS:+ shorturl=$SHORT_ALIAS}"
fi

# Release GitHub (optionnel) : commit, tag v<version>, push → workflow .github/workflows/release.yml
if [[ $RELEASE -eq 1 ]]; then
  echo "🏷️  Release GitHub v$VERSION..."
  if git -C "$SCRIPT_DIR" rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "⚠️ Le tag v$VERSION existe déjà : monte '## Version:' dans le .toc avant de refaire une release." >&2
  else
    if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]]; then
      run git -C "$SCRIPT_DIR" add -A
      run git -C "$SCRIPT_DIR" commit -q -m "v$VERSION"
    fi
    run git -C "$SCRIPT_DIR" tag -a "v$VERSION" -m "OneButtonRotation v$VERSION"
    run git -C "$SCRIPT_DIR" push origin HEAD "v$VERSION"
    echo "✅ Tag v$VERSION poussé : https://github.com/dehemka/wow_obr/actions"
  fi
fi

echo "----------------------------------------------------------"
echo "🎉 Déploiement terminé."
echo "🌐 Version  : $VERSIONED_URL"
echo "🌐 Latest   : $LATEST_URL"
echo "🌐 Court    : $SHORT_ZIP_URL"
[[ -n "$SHORT_URL" ]] && echo "🔗 is.gd    : $SHORT_URL"
echo "=========================================================="
