# pico-claude

A Raspberry Pi Pico 2 W with a Pimoroni Pico Display (320x240 LCD) that shows
Claude Code usage: the 5-hour session limit, the weekly limit, and today's
token count with a seven-day chart.

![normal](docs/screen.png) ![near the limit](docs/screen-hot.png)

Each limit bar shows the percentage used and when the window resets. The white
marker on a bar is the pace line: how far through the window you are. Fill
past the marker means you are burning faster than an even pace. Bars turn
amber at 70% and red at 90%.

## How it works

```
Claude Code ──statusline JSON──► statusline-tee.sh ──► your normal statusline
                                    │ saves rate limits, starts publisher
~/.claude/projects/*.jsonl ──► publisher.py ──MQTT (retained) claude/usage──► Pico
Home Assistant etc. ─────────────MQTT unicorn/control/onoff ON|OFF─────────► Pico
```

* **Host** (`host/`, Python stdlib only). Token counts come from the Claude
  Code transcripts. The plan limits are only exposed in the JSON that Claude
  Code passes to the statusline command, so a small shim wraps the existing
  statusline command, saves that JSON, and passes it through unchanged. The
  shim also starts the publisher, which exits again after three minutes
  without statusline activity.
* **Device** (`device/`, MicroPython). Subscribes to the usage topic and the
  control topics, and redraws when data arrives or the minute changes.

The publisher only runs while Claude Code is open in a terminal on this Mac.
In between, the Pico keeps the last reading, counts the reset timers down
itself, rolls "Today" over at midnight, and shows the age of the data in the
header (for example `47m ago`) once it is older than 15 minutes.

## MQTT

| Topic | Payload | Effect |
|---|---|---|
| `unicorn/control/onoff` | `ON` / `OFF` | backlight on / off (same topic as unicorn_wrangler) |
| `unicorn/control/onoff` | `ONAIR` / `OFFAIR` | full-screen ON AIR banner / back to usage |
| `unicorn/control/cmd` | `RESET` | reboot the Pico |
| `claude/usage` | JSON, retained | usage data from the host |

Topic names can be changed in `device/config.json` (`mqtt.topic_*`).

Usage payload:

```json
{"v":1, "ts":1790868907, "tz":3600,
 "h5":{"pct":4.0, "reset":1790886000, "ts":1790868907},
 "d7":{"pct":1.0, "reset":1791342000, "ts":1790868907},
 "today":{"tok":2715421, "out":63204, "msgs":28},
 "week":[0,89991,0,0,17777385,0,2715421], "model":"Fable 5.1"}
```

`h5` / `d7` are `null` until Claude Code has reported limits (Pro/Max plans
only, after the first response in a session). `tok` counts input, output and
cache tokens, like ccusage's total; `week` is oldest first, today last.

## Buttons

* **A** toggles the display on and off.
* **B** cycles brightness.

## Setup

Device (needs Pimoroni MicroPython firmware and `mpremote`):

```sh
cp device/config.example.json device/config.json   # set wifi + broker
tools/deploy.sh
```

Host:

```sh
host/install.sh <broker-ip>     # copies to ~/.claude/pico-claude, wraps the statusline
host/uninstall.sh               # restores the original statusline command
```

`install.sh` edits `statusLine.command` in `~/.claude/settings.json` and keeps
a backup at `settings.json.pico-claude.bak`. Restart running Claude Code
sessions if the statusline does not pick the change up.

`host/install.sh --daemon <broker-ip>` additionally installs a LaunchAgent so
the publisher runs all the time. macOS blocks LaunchAgents from the local
network (`No route to host` in `~/.claude/pico-claude/publisher.log`) until
python3 is allowed under System Settings > Privacy & Security > Local Network.

## Development

```sh
python3 -m unittest discover -s tests     # host + hardware-free device code
tools/screenshot.py --all                 # render sample scenes on the Pico -> screenshots/
tools/screenshot.py --live                # run the real app for 20s and capture it
python3 host/publisher.py --dry-run       # print the payload
tools/logs.py                             # follow the serial log (needs pyserial)
```

`tools/screenshot.py` runs the code from `./device` on the board without
copying it, and reads the frame back from the display framebuffer, so the PNG
is exactly what the panel shows.

Layout:

```
device/main.py        entry point
device/cc/app.py      wifi, mqtt, ntp, buttons, render loop
device/cc/ui.py       drawing
device/cc/amqtt.py    small asyncio MQTT client (non-blocking, reconnects)
device/cc/fmt.py      formatting and time-window logic (pure, tested)
host/usage.py         transcript scanning and aggregation
host/publisher.py     publish loop
host/statusline-tee.sh  statusline shim
```
