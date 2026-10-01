#!/usr/bin/env python3
"""Publish Claude Code usage to MQTT for the Pico display.

Rescans transcripts every `interval` seconds and publishes a retained JSON
message whenever something changed (and at least every `heartbeat` seconds).

Normally started on demand by statusline-tee.sh with --idle-exit, so it runs
only while Claude Code is in use and exits once the statusline goes quiet.
Only one instance runs at a time (lock file).

Config (JSON, optional): ~/.claude/pico-claude/config.json
    {"broker": "192.168.1.10", "port": 1883, "topic": "claude/usage",
     "user": null, "password": null}
"""
import argparse
import fcntl
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mqtt_pub import publish  # noqa: E402
from usage import TranscriptScanner, build_payload  # noqa: E402

STATE_DIR = os.path.expanduser("~/.claude/pico-claude")
DEFAULTS = {
    "broker": "127.0.0.1",
    "port": 1883,
    "topic": "claude/usage",
    "user": None,
    "password": None,
    "projects_dir": "~/.claude/projects",
    "interval": 10,
    "heartbeat": 60,
}


def load_config(path):
    cfg = dict(DEFAULTS)
    try:
        with open(path) as f:
            cfg.update(json.load(f))
    except FileNotFoundError:
        pass
    return cfg


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--config", default=os.path.join(STATE_DIR, "config.json"))
    ap.add_argument("--once", action="store_true", help="publish once and exit")
    ap.add_argument("--dry-run", action="store_true", help="print payload, don't publish")
    ap.add_argument("--idle-exit", type=int, metavar="SECONDS", default=0,
                    help="exit when the statusline has been quiet this long")
    args = ap.parse_args()

    cfg = load_config(args.config)
    state_dir = os.path.dirname(os.path.abspath(args.config))
    statusline = os.path.join(state_dir, "statusline.json")
    activity = os.path.join(state_dir, "activity")   # touched by statusline-tee.sh
    alive = os.path.join(state_dir, "alive")         # read by statusline-tee.sh
    scanner = TranscriptScanner(os.path.expanduser(cfg["projects_dir"]))

    looping = not (args.once or args.dry_run)
    if looping:
        lock = open(os.path.join(state_dir, "lock"), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return   # another publisher is already running
        if args.idle_exit:
            try:
                os.setsid()   # outlive the statusline command that spawned us
            except OSError:
                pass

    started = time.time()
    last_body = None
    last_sent = 0
    was_failing = False

    while True:
        now = time.time()
        payload = build_payload(scanner.scan(now), statusline, now)
        body = {k: v for k, v in payload.items() if k != "ts"}
        if args.dry_run:
            print(json.dumps(payload, indent=2))
            return
        if body != last_body or now - last_sent >= cfg["heartbeat"]:
            try:
                publish(cfg["broker"], cfg["port"], cfg["topic"],
                        json.dumps(payload, separators=(",", ":")),
                        user=cfg["user"], password=cfg["password"])
                last_body, last_sent = body, now
                if was_failing:
                    log("publishing again")
                    was_failing = False
            except OSError as e:
                if not was_failing:  # log once per outage, not every interval
                    log("publish failed: %s" % e)
                    was_failing = True
                if args.once:
                    sys.exit(1)
        if args.once:
            return
        if args.idle_exit and now - max(mtime(activity), started) > args.idle_exit:
            return
        with open(alive, "w") as f:
            f.write("%d\n" % now)
        time.sleep(cfg["interval"])


if __name__ == "__main__":
    main()
