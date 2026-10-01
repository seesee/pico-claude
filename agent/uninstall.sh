#!/bin/sh
# Stop the agent and restore the original statusline command.
# Leaves ~/.claude/pico-claude/ (config + log) in place; delete it by hand if wanted.
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/pico-claude"
if command -v systemctl >/dev/null 2>&1 && [ -f "$HOME/.config/systemd/user/pico-claude.service" ]; then
  systemctl --user disable --now pico-claude.service
  rm -f "$HOME/.config/systemd/user/pico-claude.service"
  systemctl --user daemon-reload
fi
python3 "$SRC/statusline_setting.py" uninstall "$DEST/statusline-tee.sh"
rm -f "$DEST/publisher.py" "$DEST/usage.py" "$DEST/mqtt_pub.py"   # stops on-demand starts
pkill -f "$DEST/publisher.py" 2>/dev/null || true
