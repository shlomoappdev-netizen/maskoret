#!/bin/bash
# Builds the Android App Bundle (.aab) for Google Play on this Mac, and checks it before it is uploaded by hand:
#   - the same version/build as version.json;
#   - signed with the app's permanent key (the same certificate as the APK on the site, so someone who installed
#     from the site can move to Play — the key is uploaded to Play as the app signing key);
#   - without REQUEST_INSTALL_PACKAGES (an app from Play may not update itself; the Play build has no self-update).
# The APK on the site, CI and tools/upload_android_build.sh are not affected: only --dart-define=STORE=play makes
# this build different (flutter_app/android/app/src/play/AndroidManifest.xml and Updater.fromPlayStore).
#
# Usage:  tools/build_play_bundle.sh        (uploads nothing; prints where the .aab is)
# Needs:  Flutter, the Android SDK, flutter_app/android/key.properties + maskoret-release.jks (never committed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The certificate every published APK is signed with (as in upload_android_build.sh).
EXPECTED_CERT=b927742dcbb788399e27d59b1e9a181a7c10c1660aed8b45b4511fbdb8351be6

if [ ! -f flutter_app/android/key.properties ]; then
  echo "חסר flutter_app/android/key.properties — בלי מפתח החתימה הקבוע אי אפשר לבנות ל-Google Play." >&2
  exit 1
fi
if [ -n "$(git status --porcelain -- flutter_app version.json)" ]; then
  echo "אזהרה: יש שינויים שלא נשמרו ב-flutter_app או ב-version.json — הקובץ ייבנה מהם." >&2
fi

if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
KEYTOOL="${JAVA_HOME:+$JAVA_HOME/bin/}keytool"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
AAPT2="$(ls -d "$SDK"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)"

VERSION=$(python3 -c "import json;print(json.load(open('version.json'))['version'])")
BUILD=$(python3 -c "import json;print(json.load(open('version.json'))['build'])")

echo "== בונה את גרסה $VERSION (build $BUILD) ל-Google Play"
cd flutter_app
flutter pub get >/dev/null
flutter build appbundle --release --dart-define=STORE=play --build-name "$VERSION" --build-number "$BUILD"
AAB="$PWD/build/app/outputs/bundle/release/app-release.aab"
cd "$ROOT"

# Signed with the permanent key.
CERT=$("$KEYTOOL" -printcert -jarfile "$AAB" 2>/dev/null | grep -m1 "SHA256:" | awk '{print $NF}' | tr -d ':' | tr 'A-F' 'a-f')
if [ "$CERT" != "$EXPECTED_CERT" ]; then
  echo "ה-AAB לא חתום במפתח הקבוע (קיבלתי: ${CERT:-אין חתימה})." >&2
  exit 1
fi
echo "   חתום במפתח הקבוע ✓"

# No install permission: not in the bundle's manifest at all (its strings are stored as is in the proto file).
if unzip -p "$AAB" base/manifest/AndroidManifest.xml | LC_ALL=C grep -aq REQUEST_INSTALL_PACKAGES; then
  echo "במניפסט של ה-AAB יש REQUEST_INSTALL_PACKAGES — Google Play ידחה את זה." >&2
  exit 1
fi
if [ -n "$AAPT2" ] && "$AAPT2" dump xmltree "$AAB" --file base/manifest/AndroidManifest.xml >/dev/null 2>&1; then
  MANIFEST=$("$AAPT2" dump xmltree "$AAB" --file base/manifest/AndroidManifest.xml)
  if grep -q REQUEST_INSTALL_PACKAGES <<<"$MANIFEST"; then
    echo "במניפסט של ה-AAB יש REQUEST_INSTALL_PACKAGES — Google Play ידחה את זה." >&2
    exit 1
  fi
  TARGET=$(grep -m1 "targetSdkVersion" <<<"$MANIFEST" | grep -oE '[0-9]+' | tail -1 || true)
  echo "   targetSdk ${TARGET:-?}"
fi
echo "   בלי REQUEST_INSTALL_PACKAGES ✓"
echo "   ABIs: $(unzip -l "$AAB" | grep -oE 'base/lib/[^/]+' | sort -u | sed 's#base/lib/##' | tr '\n' ' ')"

OUT="$ROOT/flutter_app/build/play/maskoret-$VERSION-$BUILD.aab"
mkdir -p "$(dirname "$OUT")"
cp "$AAB" "$OUT"
echo "== מוכן ($(du -h "$OUT" | cut -f1 | tr -d ' ')):"
echo "$OUT"
