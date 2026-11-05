#!/bin/bash
# Builds the iPhone app (Release) from this checkout and reinstalls it on the connected iPhone.
# Free signing expires after 7 days — run this to renew it.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer}"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_DIR="$HOME/Library/Caches/maskoret-iphone-build"
BUNDLE_ID=com.shlomodavid.maskoret

echo "▶ מחפש אייפון מחובר…"
JSON="$(mktemp)"
UDID=""
# Over Wi-Fi the tunnel comes up on demand, so the first listing may miss it.
for _ in 1 2 3 4 5; do
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  UDID="$(/usr/bin/python3 -c '
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devs:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    # "disconnected" is a reachable iPhone whose tunnel opens on demand; "unavailable" is out of reach.
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical" \
            and conn.get("tunnelState") in ("connected", "disconnected"):
        print(hw["udid"]); break
' "$JSON")"
  [ -n "$UDID" ] && break
  sleep 3
done
rm -f "$JSON"
if [ -z "$UDID" ]; then
  echo "✖ לא נמצא אייפון מחובר. חבר בכבל (או באותה רשת Wi‑Fi), בטל נעילה ונסה שוב."
  exit 1
fi
echo "  נמצא: $UDID"

if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "▶ מושך את הגרסה האחרונה…"
  git pull --ff-only -q || echo "  (לא הצלחתי למשוך — בונה ממה שיש בתיקייה)"
fi

VERSION=$(/usr/bin/python3 -c "import json;print(json.load(open('version.json'))['version'])")
echo "▶ בונה את גרסה $VERSION (Release) — זה לוקח כמה דקות…"
xcodebuild -project Maskoret.xcodeproj -scheme MaskoretiOS \
  -configuration Release -destination "platform=iOS,id=$UDID" \
  -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates \
  -skipMacroValidation -skipPackagePluginValidation -quiet build

APP="$(ls -d "$BUILD_DIR"/Build/Products/Release-iphoneos/*.app | head -1)"
echo "▶ מתקין על האייפון…"
xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null

echo "▶ פותח את האפליקציה…"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 \
  || echo "  (לא נפתחה אוטומטית — אם האייפון נעול, פתח ידנית)"

echo "✔ מחשבון שכר $VERSION הותקנה מחדש. החתימה תקפה ל‑7 ימים."
