#!/bin/bash
# Builds the Mac app on this Mac (instead of waiting for a GitHub macOS runner), signs it with "Maskoret Signing",
# packs maskoret-mac.dmg and uploads it to the prerelease "mac-build-<build>" in this repo. The Release workflow
# (.github/workflows/release.yml) then takes that DMG and skips its own Mac build.
#
# Usage:  tools/upload_mac_build.sh            (version and build come from version.json)
# Needs:  gh logged in, Xcode, the "Maskoret Signing" certificate in the login keychain, and a clean checkout of
#         origin/main (so the DMG is built from exactly what gets released).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git fetch -q origin main
if [ -n "$(git status --porcelain -- Maskoret Maskoret.xcodeproj version.json)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "התיקייה לא זהה ל-origin/main (יש שינויים או קומיטים שלא נדחפו). עשה git pull ונקה לפני הבנייה." >&2
  exit 1
fi

VERSION=$(python3 -c "import json;print(json.load(open('version.json'))['version'])")
BUILD=$(python3 -c "import json;print(json.load(open('version.json'))['build'])")
TAG="mac-build-$BUILD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== בונה את גרסה $VERSION (build $BUILD) למק"
xcodebuild -project Maskoret.xcodeproj -scheme Maskoret -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  -skipMacroValidation -skipPackagePluginValidation build > "$WORK/build.log" 2>&1 \
  || { grep -E "error:" "$WORK/build.log" | sort -u | head -40; tail -30 "$WORK/build.log"; exit 1; }

APP="$(ls -d "$WORK"/dd/Build/Products/Release/*.app | head -1)"
codesign --force --deep --sign "Maskoret Signing" "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|Identifier"
mkdir -p "$WORK/stage" "$WORK/out"
ditto "$APP" "$WORK/stage/$(basename "$APP")"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname "מחשבון שכר $VERSION" -srcfolder "$WORK/stage" -ov -format UDZO "$WORK/out/maskoret-mac.dmg" >/dev/null

echo "== מעלה ל-$TAG"
gh release delete "$TAG" --yes --cleanup-tag >/dev/null 2>&1 || true
gh release create "$TAG" "$WORK/out/maskoret-mac.dmg" --prerelease --target "$(git rev-parse HEAD)" \
  --title "Mac build $VERSION ($BUILD)" --notes "נבנה במק מקומית מ-$(git rev-parse --short HEAD). הפרסום לוקח אותו מכאן."
echo "הועלה. הפרסום ייקח את הקובץ הזה במקום לבנות את המק בענן."
