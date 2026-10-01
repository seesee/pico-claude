#!/bin/sh
# Install the usage publisher on this Mac.
#
#   host/install.sh <broker-ip> [port]     # first install
#   host/install.sh                        # update code, keep existing config
#   host/install.sh --daemon ...           # also run the publisher permanently
#
# What it does:
#   1. copies the publisher to ~/.claude/pico-claude/
#   2. wraps the Claude Code statusline command with statusline-tee.sh, which
#      captures the 5-hour / weekly limit readings and starts the publisher
#      whenever Claude Code is in use (settings.json is backed up first)
#   3. with --daemon: installs a LaunchAgent that keeps the publisher running
#      even when no Claude Code terminal is open. macOS blocks LaunchAgents
#      from the local network until you allow "python3" under
#      System Settings > Privacy & Security > Local Network.
# Undo everything with host/uninstall.sh.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/pico-claude"
LABEL="com.pico-claude.publisher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DAEMON=0
[ "$1" = "--daemon" ] && { DAEMON=1; shift; }
BROKER="$1"
PORT="${2:-1883}"
PYTHON="$(command -v python3)"

mkdir -p "$DEST"
cp "$SRC/publisher.py" "$SRC/usage.py" "$SRC/mqtt_pub.py" "$DEST/"
sed "s|^PYTHON=python3\$|PYTHON=\"$PYTHON\"|" "$SRC/statusline-tee.sh" > "$DEST/statusline-tee.sh"
chmod +x "$DEST/statusline-tee.sh"

if [ -n "$BROKER" ]; then
  printf '{\n  "broker": "%s",\n  "port": %s,\n  "topic": "claude/usage"\n}\n' "$BROKER" "$PORT" > "$DEST/config.json"
elif [ ! -f "$DEST/config.json" ]; then
  echo "usage: $0 [--daemon] <broker-ip> [port]" >&2
  exit 1
fi

"$PYTHON" "$SRC/statusline_setting.py" install "$DEST/statusline-tee.sh"

if [ "$DAEMON" = 1 ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$DEST/publisher.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$DEST/publisher.log</string>
  <key>StandardErrorPath</key><string>$DEST/publisher.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "publisher LaunchAgent $LABEL installed (log: $DEST/publisher.log)"
fi
echo "installed to $DEST"
