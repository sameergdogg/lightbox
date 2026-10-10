#!/usr/bin/env bash
# Install (or remove) a LaunchAgent that runs `lightbox refresh` every hour, so the index
# keeps up with new photos and fills in analysis as iCloud originals download.
#
#   ./Scripts/install-agent.sh              # install and start
#   ./Scripts/install-agent.sh --uninstall
#
# Logs: ~/Library/Logs/lightbox/refresh.log.
#
# ProcessType is Standard, not Background: with Background, launchd kept the hourly spawn
# "pended" for 11+ hours (`launchctl print` showed `pended nondemand spawn = interval`).
# A refresh is usually a second of work; Nice and LowPriorityIO keep it polite. The first run asks for Photos access on
# behalf of lightbox itself (not your terminal). Approve it once.
set -euo pipefail

LABEL="com.sameer.lightbox.refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="${LIGHTBOX_BIN:-$HOME/.local/bin/lightbox}"
LOGS="$HOME/Library/Logs/lightbox"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PLIST"
  echo "removed $LABEL"
  exit 0
fi

[ -x "$BIN" ] || { echo "no lightbox at $BIN; run ./Scripts/install.sh first" >&2; exit 1; }
mkdir -p "$LOGS" "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string><string>refresh</string></array>
    <key>StartInterval</key><integer>3600</integer>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Standard</string>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOGS/refresh.log</string>
    <key>StandardErrorPath</key><string>$LOGS/refresh.log</string>
</dict>
</plist>
PLIST
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $LABEL (hourly). Log: $LOGS/refresh.log"
