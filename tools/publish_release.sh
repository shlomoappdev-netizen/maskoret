#!/bin/bash
# Publishes a new version of מחשבון שכר to everyone:
#   1. builds the Mac app (Release) and packs maskoret-mac.dmg
#   2. takes the Android APK and the Windows ZIP from the להפצה folder (built by flutter_app/tool/build_android.sh
#      and by GitHub Actions)
#   3. creates a GitHub release in shlomoappdev-netizen/maskoret-releases with the three files
#   4. updates latest.json on the site — the apps check it and offer the update
#
# Usage:  tools/publish_release.sh            (version and notes come from version.json)
# Needs:  gh logged in as shlomoappdev-netizen, Xcode, and the "Maskoret Signing" certificate (optional).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="shlomoappdev-netizen/maskoret-releases"
DIST="$ROOT/להפצה"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VERSION=$(python3 -c "import json;print(json.load(open('$ROOT/version.json'))['version'])")
BUILD=$(python3 -c "import json;print(json.load(open('$ROOT/version.json'))['build'])")
TAG="v$VERSION"
echo "== מפרסם את גרסה $VERSION (build $BUILD)"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "הגרסה $TAG כבר פורסמה. העלה את build ו-version ב-version.json." >&2
  exit 1
fi

APK="$DIST/Android/מחשבון שכר.apk"
WINZIP="$DIST/Windows/מחשבון שכר - Windows.zip"
for f in "$APK" "$WINZIP"; do
  [ -f "$f" ] || { echo "חסר קובץ: $f" >&2; exit 1; }
done

# --- Mac: build, sign, DMG
DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer}"
export DEVELOPER_DIR
echo "== בונה את גרסת המק…"
xcodebuild -project "$ROOT/Maskoret.xcodeproj" -target Maskoret -configuration Release \
  SYMROOT="$WORK/sym" OBJROOT="$WORK/obj" CODE_SIGN_IDENTITY=- \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  -skipMacroValidation -skipPackagePluginValidation build >"$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log"; echo "בניית המק נכשלה" >&2; exit 1; }
APP="$(ls -d "$WORK/sym/Release/"*.app | head -1)"
if security find-identity -p codesigning | grep -qF '"Maskoret Signing"'; then
  codesign --force --sign "Maskoret Signing" "$APP"
fi
mkdir -p "$WORK/stage" "$WORK/out"
ditto "$APP" "$WORK/stage/$(basename "$APP")"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname "מחשבון שכר $VERSION" -srcfolder "$WORK/stage" -ov -format UDZO "$WORK/out/maskoret-mac.dmg" >/dev/null
cp "$WORK/out/maskoret-mac.dmg" "$DIST/מחשבון שכר.dmg"
cp "$APK" "$WORK/out/maskoret-android.apk"
cp "$WINZIP" "$WORK/out/maskoret-windows.zip"

# --- Release notes + latest.json
python3 - "$ROOT/version.json" "$WORK/out" "$REPO" "$TAG" <<'PY'
import json, sys, hashlib, os
vj, out, repo, tag = sys.argv[1:]
v = json.load(open(vj, encoding="utf-8"))
base = f"https://github.com/{repo}/releases/download/{tag}/"
def asset(name):
    p = os.path.join(out, name)
    return {"url": base + name, "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(), "size": os.path.getsize(p)}
manifest = {"version": v["version"], "build": v["build"], "date": v.get("date"), "notes": v.get("notes", []),
            "platforms": {"android": asset("maskoret-android.apk"), "windows": asset("maskoret-windows.zip"), "mac": asset("maskoret-mac.dmg")}}
json.dump(manifest, open(os.path.join(out, "latest.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
notes = f"## מחשבון שכר {v['version']}\n\n" + "\n".join("- " + n for n in v.get("notes", []))
notes += "\n\n**התקנה:** אנדרואיד — maskoret-android.apk · Windows — maskoret-windows.zip (לפתוח ולהפעיל את maskoret.exe) · Mac — maskoret-mac.dmg\n"
open(os.path.join(out, "notes.md"), "w", encoding="utf-8").write(notes)
PY

echo "== מעלה את הקבצים ל-GitHub…"
gh release create "$TAG" "$WORK/out/maskoret-android.apk" "$WORK/out/maskoret-windows.zip" "$WORK/out/maskoret-mac.dmg" \
  --repo "$REPO" --title "מחשבון שכר $VERSION" --notes-file "$WORK/out/notes.md"

echo "== מעדכן את latest.json באתר…"
git clone -q "https://github.com/$REPO.git" "$WORK/site"
cp "$WORK/out/latest.json" "$WORK/site/latest.json"
git -C "$WORK/site" add latest.json
git -C "$WORK/site" -c user.name="shlomoappdev-netizen" -c user.email="shlomoappdev@gmail.com" commit -q -m "גרסה $VERSION"
git -C "$WORK/site" push -q

echo "== פורסם: https://github.com/$REPO/releases/tag/$TAG"
echo "   האפליקציות יציעו את העדכון בבדיקה הבאה (באתר הוא מתעדכן תוך דקה-שתיים)."
