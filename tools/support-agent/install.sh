#!/bin/bash
# Installs the support agent as a background service on this Mac: it starts at login and restarts if it stops.
#   tools/support-agent/install.sh            install / reinstall
#   tools/support-agent/install.sh remove     stop and remove
# Log: ~/Library/Logs/maskoret-support-agent.log
set -euo pipefail

LABEL="com.shlomodavid.maskoret.support-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/maskoret-support-agent.log"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "remove" ]; then
  rm -f "$PLIST"
  echo "סוכן התמיכה הוסר."
  exit 0
fi

NODE="$(command -v node)"
[ -d "$DIR/node_modules" ] || (cd "$DIR" && npm install --silent)
security find-generic-password -s maskoret-support-agent -a token -w >/dev/null \
  || { echo "חסר הטוקן של הסוכן ב-Keychain (maskoret-support-agent)." >&2; exit 1; }

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$NODE</string><string>$DIR/agent.mjs</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "סוכן התמיכה פועל. יומן: $LOG"
