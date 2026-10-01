#!/bin/sh
# Copy the firmware in ./device to the Pico and restart it.
#   tools/deploy.sh            # code + config.json
#   tools/deploy.sh --no-config
set -e
cd "$(dirname "$0")/../device"
[ -f config.json ] || [ "$1" = "--no-config" ] || {
  echo "device/config.json missing - copy config.example.json and fill it in" >&2; exit 1; }
mpremote mkdir :cc 2>/dev/null || true
mpremote cp cc/*.py :cc/
mpremote cp main.py :main.py
[ "$1" = "--no-config" ] || mpremote cp config.json :config.json
mpremote reset
echo "deployed"
