#!/bin/sh
# Build and install the PicoClaude menu bar app on this Mac.
#
#   app/install.sh
#
# What it does:
#   1. builds and signs the app, copies it to /Applications and starts it
#   2. wraps the Claude Code statusline command with statusline-tee.sh so the
#      5-hour / weekly limit readings are captured for the app
#      (settings.json is backed up first)
#   3. removes the python publisher from ~/.claude/pico-claude if an earlier
#      agent install left one - on this Mac the app does that job
# The broker address is taken from ~/.claude/pico-claude/config.json on first
# launch if present; otherwise set it under Settings in the menu bar panel.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/../agent"
STATE="$HOME/.claude/pico-claude"

"$HERE/build.sh"

osascript -e 'quit app id "com.chriscarline.PicoClaude"' 2>/dev/null || true
sleep 1
rm -rf /Applications/PicoClaude.app
cp -R "$HERE/build/PicoClaude.app" /Applications/

mkdir -p "$STATE"
cp "$AGENT/statusline-tee.sh" "$STATE/statusline-tee.sh"
chmod +x "$STATE/statusline-tee.sh"
rm -f "$STATE/statusline.json"   # single capture file used by older versions
python3 "$AGENT/statusline_setting.py" install "$STATE/statusline-tee.sh"
# without publisher.py the shim only captures; it no longer starts python
rm -f "$STATE/publisher.py" "$STATE/usage.py" "$STATE/mqtt_pub.py" "$STATE/alive" "$STATE/lock"
pkill -f "$STATE/publisher.py" 2>/dev/null || true

open /Applications/PicoClaude.app
echo "PicoClaude is running in the menu bar."
echo "If macOS asks to let it find devices on your local network, click Allow."
