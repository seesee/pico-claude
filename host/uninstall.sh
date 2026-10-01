#!/bin/sh
# Remove the LaunchAgent and restore the original statusline command.
# Leaves ~/.claude/pico-claude/ (config + log) in place; delete it by hand if wanted.
SRC="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.pico-claude.publisher"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
python3 "$SRC/statusline_setting.py" uninstall "$HOME/.claude/pico-claude/statusline-tee.sh"
