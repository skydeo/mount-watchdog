#!/bin/bash
#
# setup-once.sh — one-time credential setup for the mount watchdog.
# Run this yourself in your own login session:   bash ~/Documents/drive-mounter/setup-once.sh
# It only needs your NAS password (typed at a hidden prompt, stored only in the Keychain).
# No sudo is required: the NAS is mounted Finder-style, so macOS manages the mountpoint.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
[ -f "$CONFIG_FILE" ] || { echo "missing $CONFIG_FILE (copy config.env.example -> config.env and edit)"; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG_FILE"
: "${NAS_USER:?set in config.env}" "${KEYCHAIN_SERVICE:?set in config.env}"

echo "== mount-watchdog one-time setup =="
echo "* Storing the NAS password in a dedicated Keychain item ('$KEYCHAIN_SERVICE')."
echo "  The watchdog reads it at mount time (-A lets it read non-interactively)."
echo "  Enter the NAS password for user '$NAS_USER' when prompted (typed twice, hidden):"
security add-generic-password -U -A -s "$KEYCHAIN_SERVICE" -a "$NAS_USER" -w

echo
echo "Done. Now deploy/reload the watchdog:"
echo "    bash $SCRIPT_DIR/install.sh"
