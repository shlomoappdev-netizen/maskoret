#!/bin/bash
# Builds the Android APK on this Mac (instead of a GitHub runner), checks it's signed with the app's permanent key,
# and uploads it to the prerelease "android-build-<build>" in this repo. The Release workflow
# (.github/workflows/release.yml) then takes that APK and skips its own Android build. Without an upload the
# cloud builds Android as before.
#
# Usage:  tools/upload_android_build.sh        (version and build come from version.json)
# Needs:  gh logged in, Flutter, the Android SDK, flutter_app/android/key.properties + maskoret-release.jks
#         (never committed), and a clean checkout of origin/main (so the APK is built from what gets released).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The certificate every published APK is signed with (an installed app only accepts updates signed the same way).
EXPECTED_CERT=b927742dcbb788399e27d59b1e9a181a7c10c1660aed8b45b4511fbdb8351be6

git fetch -q origin main
if [ -n "$(git status --porcelain -- flutter_app rates version.json)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "התיקייה לא זהה ל-origin/main (יש שינויים או קומיטים שלא נדחפו). עשה git pull ונקה לפני הבנייה." >&2
  exit 1
fi
if [ ! -f flutter_app/android/key.properties ]; then
  echo "חסר flutter_app/android/key.properties — בלי מפתח החתימה הקבוע אי אפשר לבנות גרסה לפרסום." >&2
  exit 1
fi

if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
APKSIGNER="$(ls -d "$SDK"/build-tools/*/apksigner | sort -V | tail -1)"

VERSION=$(python3 -c "import json;print(json.load(open('version.json'))['version'])")
BUILD=$(python3 -c "import json;print(json.load(open('version.json'))['build'])")
TAG="android-build-$BUILD"

echo "== בונה את גרסה $VERSION (build $BUILD) לאנדרואיד"
cd flutter_app
flutter pub get >/dev/null
flutter build apk --release --build-name "$VERSION" --build-number "$BUILD"
APK="$PWD/build/app/outputs/flutter-apk/app-release.apk"
cd "$ROOT"

CERT=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | grep -m1 "certificate SHA-256 digest" | awk '{print $NF}')
if [ "$CERT" != "$EXPECTED_CERT" ]; then
  echo "ה-APK לא חתום במפתח הקבוע (קיבלתי: ${CERT:-אין חתימה}). לא מעלה." >&2
  exit 1
fi
echo "   חתום במפתח הקבוע ✓"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$APK" "$WORK/maskoret-android.apk"

echo "== מעלה ל-$TAG"
gh release delete "$TAG" --yes --cleanup-tag >/dev/null 2>&1 || true
gh release create "$TAG" "$WORK/maskoret-android.apk" --prerelease --target "$(git rev-parse HEAD)" \
  --title "Android build $VERSION ($BUILD)" --notes "נבנה במק מקומית מ-$(git rev-parse --short HEAD). הפרסום לוקח אותו מכאן."
echo "הועלה. הפרסום ייקח את הקובץ הזה במקום לבנות את אנדרואיד בענן."
