#!/bin/sh
# Install the usage agent on a host that runs Claude Code (Linux or macOS).
#
#   agent/install.sh <broker-ip> [port]    # first install
#   agent/install.sh                       # update code, keep existing config
#   agent/install.sh --daemon ...          # Linux: also run as a systemd user service
#
# What it does:
#   1. copies the agent to ~/.claude/pico-claude/
#   2. wraps the Claude Code statusline command with statusline-tee.sh, which
#      captures the 5-hour / weekly limit readings and starts the publisher
#      whenever Claude Code is in use (settings.json is backed up first)
#   3. with --daemon: keeps the publisher running all the time, so usage from
#      headless runs (claude -p) is reported without waiting for a terminal
#      session
# The host reports to the MQTT topic claude/hosts/<hostname>.
# On the Mac that runs the PicoClaude menu bar app, use app/install.sh instead.
# Undo everything with agent/uninstall.sh.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/pico-claude"
UNIT="$HOME/.config/systemd/user/pico-claude.service"
DAEMON=0
[ "$1" = "--daemon" ] && { DAEMON=1; shift; }
BROKER="$1"
PORT="${2:-1883}"
PYTHON="$(command -v python3)" || { echo "python3 not found" >&2; exit 1; }

mkdir -p "$DEST"
cp "$SRC/publisher.py" "$SRC/usage.py" "$SRC/mqtt_pub.py" "$DEST/"
sed "s|^PYTHON=python3\$|PYTHON=\"$PYTHON\"|" "$SRC/statusline-tee.sh" > "$DEST/statusline-tee.sh"
chmod +x "$DEST/statusline-tee.sh"

if [ -n "$BROKER" ]; then
  printf '{\n  "broker": "%s",\n  "port": %s\n}\n' "$BROKER" "$PORT" > "$DEST/config.json"
elif [ ! -f "$DEST/config.json" ]; then
  echo "usage: $0 [--daemon] <broker-ip> [port]" >&2
  exit 1
fi

"$PYTHON" "$SRC/statusline_setting.py" install "$DEST/statusline-tee.sh"

if [ "$DAEMON" = 1 ]; then
  command -v systemctl >/dev/null || { echo "--daemon needs systemd" >&2; exit 1; }
  mkdir -p "$(dirname "$UNIT")"
  cat > "$UNIT" <<UNIT
[Unit]
Description=pico-claude usage publisher
After=network-online.target

[Service]
ExecStart=$PYTHON $DEST/publisher.py
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now pico-claude.service
  echo "systemd user service pico-claude enabled (journalctl --user -u pico-claude)"
  echo "to keep it running while logged out: sudo loginctl enable-linger $USER"
fi
echo "installed to $DEST"
