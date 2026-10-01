#!/bin/sh
# Claude Code statusline shim for pico-claude.
#
# 1. Saves the statusline JSON - the only place the 5-hour / weekly plan limits
#    are exposed - for the usage publisher, as statusline/<session>.json.
# 2. Makes sure the publisher is running while Claude Code is in use.
# 3. Hands the same input to the real statusline command given as arguments:
#
#   "statusLine": {"type": "command",
#                  "command": "~/.claude/pico-claude/statusline-tee.sh npx -y ccstatusline@latest"}
#
# None of this may ever break the statusline, so every failure is swallowed.
PYTHON=python3
input=$(cat)
dir="${PICO_CLAUDE_STATE:-$HOME/.claude/pico-claude}"
{
  mkdir -p "$dir/statusline"
  case "$input" in
    *'"rate_limits"'*)
      # one file per session: each session only knows the limits as of its own
      # last response, and the reader picks the best reading across them
      sid=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)
      printf '%s' "$input" > "$dir/statusline/.tmp.$$" &&
      mv -f "$dir/statusline/.tmp.$$" "$dir/statusline/${sid:-session}.json"
      ;;
  esac
  : > "$dir/activity"
  # the publisher writes the time to "alive" every few seconds while it runs
  now=$(date +%s)
  last=$(cat "$dir/alive" 2>/dev/null)
  if [ -f "$dir/publisher.py" ] && [ $((now - ${last:-0})) -gt 45 ]; then
    echo "$now" > "$dir/alive"   # don't spawn again from the next refresh
    "$PYTHON" "$dir/publisher.py" --config "$dir/config.json" --idle-exit 180 \
      </dev/null >>"$dir/publisher.log" 2>&1 &
  fi
} >/dev/null 2>&1
if [ $# -gt 0 ]; then
  printf '%s' "$input" | "$@"
fi
