#!/bin/bash
#
# install.sh — deploy the watchdog (script + config), generate the LaunchAgent plist from
# $HOME, and (re)load it. Safe to re-run after editing mount-watchdog.sh or config.env.
# No sudo needed.
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_DIR="$HOME/Library/Application Support/mount-watchdog"   # NOT under ~/Documents: TCC blocks launchd there
UID_NUM="$(id -u)"

# --- load site config (provides AGENT_LABEL) ---
CONFIG_FILE="$SRC_DIR/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: $CONFIG_FILE not found." >&2
  echo "       cp config.env.example config.env  &&  \$EDITOR config.env" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG_FILE"
: "${AGENT_LABEL:?set AGENT_LABEL in config.env}"

PLIST_DST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

# --- deploy script + config to the non-TCC location ---
mkdir -p "$LIVE_DIR" "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
chmod 700 "$LIVE_DIR"
install -m 700 "$SRC_DIR/mount-watchdog.sh" "$LIVE_DIR/mount-watchdog.sh"
install -m 600 "$CONFIG_FILE"               "$LIVE_DIR/config.env"

# --- generate the LaunchAgent plist from $HOME (no hardcoded user path) ---
cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key> <array><string>$LIVE_DIR/mount-watchdog.sh</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>StartInterval</key>    <integer>60</integer>
    <key>ProcessType</key>      <string>Background</string>
    <key>LowPriorityIO</key>    <true/>
    <key>StandardOutPath</key>  <string>$HOME/Library/Logs/mount-watchdog.out.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/mount-watchdog.err.log</string>
</dict>
</plist>
PLIST
chmod 644 "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null

# --- (re)load the agent in the GUI domain ---
launchctl bootout "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"
launchctl enable "gui/$UID_NUM/$AGENT_LABEL"

echo "Installed and loaded $AGENT_LABEL."
echo "  script: $LIVE_DIR/mount-watchdog.sh"
echo "  config: $LIVE_DIR/config.env"
echo "  plist:  $PLIST_DST"
echo "  log:    $HOME/Library/Logs/mount-watchdog.log"
echo "Kick a run now with:  launchctl kickstart -k gui/$UID_NUM/$AGENT_LABEL"
