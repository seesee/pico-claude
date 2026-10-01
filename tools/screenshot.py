#!/usr/bin/env python3
"""Render a UI frame on the real Pico with sample data and save it as a PNG.

Runs the device code straight from ./device via `mpremote mount`, so nothing
needs to be copied to the board first. The frame is read back from the
PicoGraphics framebuffer, so the PNG is exactly what the panel shows.

    tools/screenshot.py normal            # -> screenshots/normal.png
    tools/screenshot.py --list
    tools/screenshot.py --live            # run the real app for 20s -> screenshots/live.png
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOW = 1790868600  # fixed so screenshots are reproducible (Thu 2026-10-01 16:30 +01:00)

BASE = {"v": 1, "ts": NOW, "tz": 3600,
        "h5": {"pct": 37.4, "reset": NOW + 2 * 3600 + 13 * 60, "ts": NOW},
        "d7": {"pct": 61.0, "reset": NOW + 3 * 86400 + 4 * 3600, "ts": NOW},
        "today": {"tok": 18140015, "out": 104118, "msgs": 412},
        "week": [5200000, 89991, 0, 12400000, 17777385, 9100000, 18140015],
        "model": "Fable 5.1"}


def scene(**over):
    view = {"data": dict(BASE), "now": NOW, "age_s": None, "wifi": True, "mqtt": True}
    data = over.pop("data", {})
    view.update(over)
    if data is None:
        view["data"] = None
    else:
        view["data"].update(data)
    return view


SCENES = {
    "normal": scene(),
    "hot": scene(data={"h5": {"pct": 93.0, "reset": NOW + 41 * 60, "ts": NOW},
                       "d7": {"pct": 78.2, "reset": NOW + 20 * 3600, "ts": NOW}}),
    "full": scene(data={"h5": {"pct": 100.0, "reset": NOW + 30, "ts": NOW}}),
    "nolimits": scene(data={"h5": None, "d7": None, "today": {"tok": 950, "out": 12, "msgs": 1},
                            "week": [0, 0, 0, 0, 0, 0, 950]}),
    "reset": scene(data={"h5": {"pct": 80.0, "reset": NOW - 60, "ts": NOW - 4000}}),
    "stale": scene(age_s=47 * 60),
    "nextday": scene(now=NOW + 86400 + 3600, age_s=25 * 3600),
    "nomqtt": scene(mqtt=False),
    "waiting": scene(data=None, mqtt=False),
    "onair": scene(onair=True),
}

SNIPPET = """
import json, binascii
from cc.ui import UI
ui = UI()
ui.backlight(0.75)
ui.draw(json.loads(%r))
mv = memoryview(ui.g)
print("<<<")
for i in range(0, len(mv), 3072):
    print(binascii.b2a_base64(mv[i:i + 3072]).decode(), end="")
print(">>>")
"""


LIVE = """
import asyncio, binascii
from cc.app import App
app = App()
try:
    asyncio.run(asyncio.wait_for(app.main(), 20))
except asyncio.TimeoutError:
    pass
mv = memoryview(app.ui.g)
print("<<<")
for i in range(0, len(mv), 3072):
    print(binascii.b2a_base64(mv[i:i + 3072]).decode(), end="")
print(">>>")
"""


def capture(view, out):
    code = LIVE if view is None else SNIPPET % json.dumps(view)
    res = subprocess.run(["mpremote", "mount", os.path.join(ROOT, "device"), "exec", code],
                         capture_output=True, text=True, timeout=120)
    if "<<<" not in res.stdout:
        sys.exit("device error:\n" + res.stdout + res.stderr)
    b64 = res.stdout.split("<<<")[1].split(">>>")[0]
    raw = base64.b64decode("".join(b64.split()))
    img = _rgb565(raw)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    return out


def _rgb565(raw):
    """Big-endian RGB565 framebuffer -> PIL image."""
    px = bytearray(320 * 240 * 3)
    for i in range(320 * 240):
        v = (raw[2 * i] << 8) | raw[2 * i + 1]
        px[3 * i] = (v >> 11) * 255 // 31
        px[3 * i + 1] = ((v >> 5) & 63) * 255 // 63
        px[3 * i + 2] = (v & 31) * 255 // 31
    return Image.frombytes("RGB", (320, 240), bytes(px))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("scenes", nargs="*", default=["normal"])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--live", action="store_true", help="run the app with real wifi/mqtt")
    args = ap.parse_args()
    if args.live:
        print(capture(None, os.path.join(ROOT, "screenshots", "live.png")))
        return
    if args.list:
        print("\n".join(SCENES))
        return
    for name in (SCENES if args.all else args.scenes):
        print(capture(SCENES[name], os.path.join(ROOT, "screenshots", name + ".png")))
        time.sleep(0.5)


if __name__ == "__main__":
    main()
