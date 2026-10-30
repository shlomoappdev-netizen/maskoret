#!/bin/bash
# Installs the automatic publishing as a background service on this Mac (every 10 minutes, and at login).
#   tools/release-agent/install.sh            install / reinstall
#   tools/release-agent/install.sh remove     stop and remove
# Log: ~/Library/Logs/maskoret-release-agent.log
set -euo pipefail

LABEL="com.shlomodavid.maskoret.release-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/maskoret-release-agent.log"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "remove" ]; then
  rm -f "$PLIST"
  echo "הפרסום האוטומטי הוסר."
  exit 0
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$DIR/release-agent.sh</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "הפרסום האוטומטי פועל. יומן: $LOG"
