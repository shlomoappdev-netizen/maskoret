#!/bin/bash
# Automatic publishing for מחשבון שכר. Runs on the owner's Mac every 10 minutes (launchd, see install.sh) — the Mac
# build is signed with the "Maskoret Signing" certificate, which lives only in this Mac's Keychain.
#
# A version is released when, on main of shlomoappdev-netizen/maskoret:
#   * version.json has "ready": true and a build newer than the one on the site (latest.json), and
#   * the "Flutter app" GitHub Actions run of that commit succeeded (it builds the Windows setup + ZIP and the APK).
# Then it checks out that exact commit in a clean folder (never the working copy, which may hold unfinished work),
# downloads the Windows/Android files, runs tools/publish_release.sh (Mac build, GitHub release, latest.json,
# changelog.json) and shows a notification. Log: ~/Library/Logs/maskoret-release-agent.log
set -uo pipefail

CODE_REPO="shlomoappdev-netizen/maskoret"
SITE="https://shlomoappdev-netizen.github.io/maskoret-releases/latest.json"
WORK="$HOME/Library/Caches/maskoret-release"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() {
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
    -e 'end run' "מחשבון שכר · פרסום גרסה" "$1" >/dev/null 2>&1 || true
}

CODE_TOKEN="$(gh auth token -u shlomoappdev-netizen 2>/dev/null)" || { log "no gh token for shlomoappdev-netizen"; exit 0; }
SITE_TOKEN="$(gh auth token -u shlomoappdev-netizen 2>/dev/null)" || { log "no gh token for shlomoappdev-netizen"; exit 0; }

# What main asks for, and what the site has.
SHA="$(GH_TOKEN="$CODE_TOKEN" gh api "repos/$CODE_REPO/commits/main" --jq .sha 2>/dev/null)" || { log "offline"; exit 0; }
WANT="$(GH_TOKEN="$CODE_TOKEN" gh api "repos/$CODE_REPO/contents/version.json?ref=$SHA" --jq .content 2>/dev/null | base64 -d)" \
  || { log "cannot read version.json"; exit 0; }
read -r VERSION BUILD READY < <(python3 -c 'import json,sys; v=json.loads(sys.argv[1]); print(v["version"], v["build"], str(v.get("ready", False)).lower())' "$WANT")
PUBLISHED="$(curl -fsS -m 20 "$SITE?t=$(date +%s)" | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"])' 2>/dev/null)" \
  || { log "cannot read the site"; exit 0; }

[ "$READY" = "true" ] || exit 0
[ "$BUILD" -gt "$PUBLISHED" ] || exit 0

# Already tried this commit and failed: wait for a new commit instead of failing every 10 minutes.
STATE="$WORK/failed-$SHA"
[ -f "$STATE" ] && exit 0

RUN="$(GH_TOKEN="$CODE_TOKEN" gh run list --repo "$CODE_REPO" --workflow flutter-app.yml --commit "$SHA" \
  --json databaseId,status,conclusion --jq '.[0] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null)"
read -r RUN_ID RUN_STATUS RUN_RESULT <<<"$RUN"
if [ -z "${RUN_ID:-}" ] || [ "$RUN_STATUS" != "completed" ]; then
  log "$VERSION ($BUILD) waits for the GitHub build of ${SHA:0:7}"
  exit 0
fi
if [ "$RUN_RESULT" != "success" ]; then
  log "GitHub build of ${SHA:0:7} failed ($RUN_RESULT) — not publishing"
  mkdir -p "$WORK" && touch "$STATE"
  notify "בניית $VERSION ב-GitHub נכשלה — הגרסה לא פורסמה"
  exit 0
fi

log "== releasing $VERSION ($BUILD) from ${SHA:0:7}"
notify "מפרסם את גרסה $VERSION…"
mkdir -p "$WORK"
SRC="$WORK/src"
rm -rf "$SRC"
git -c credential.helper= -c "credential.helper=!f() { echo username=x-access-token; echo password=$CODE_TOKEN; }; f" \
  clone -q "https://github.com/$CODE_REPO.git" "$SRC" && git -C "$SRC" checkout -q "$SHA" || { log "clone failed"; exit 0; }

DL="$WORK/artifacts"
rm -rf "$DL" && mkdir -p "$DL"
GH_TOKEN="$CODE_TOKEN" gh run download "$RUN_ID" --repo "$CODE_REPO" --dir "$DL" || { log "artifact download failed"; exit 0; }
DIST="$SRC/להפצה"
mkdir -p "$DIST/Android" "$DIST/Windows"
cp "$(find "$DL" -name '*.apk' | head -1)" "$DIST/Android/מחשבון שכר.apk"
cp "$DL/maskoret-windows/maskoret-windows.zip" "$DIST/Windows/מחשבון שכר - Windows.zip"
cp "$DL/maskoret-windows/maskoret-windows-setup.exe" "$DIST/Windows/מחשבון שכר - התקנה.exe"

if GH_TOKEN="$SITE_TOKEN" "$SRC/tools/publish_release.sh"; then
  log "== published $VERSION ($BUILD)"
  notify "גרסה $VERSION פורסמה — כל המכשירים יקבלו אותה"
else
  log "publish_release.sh failed for $VERSION"
  touch "$STATE"
  notify "פרסום $VERSION נכשל — פרטים ביומן"
fi
