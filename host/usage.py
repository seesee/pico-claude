"""Collect Claude Code usage from local transcripts and the statusline capture.

Pure stdlib. Two sources:

* ``~/.claude/projects/**/*.jsonl`` - every assistant message carries a
  ``usage`` block, which gives token counts per day.
* ``statusline.json`` - the JSON Claude Code hands to the statusline command,
  saved by ``statusline-tee.sh``. It is the only documented place the plan
  limits (5-hour and 7-day ``used_percentage`` / ``resets_at``) are exposed.
"""
import glob
import json
import os
import re
import time

DAY = 86400
KEEP_DAYS = 8  # a little more than the 7 days we chart


def pretty_model(model_id):
    """claude-fable-5-1 -> 'Fable 5.1', claude-haiku-4-5-20251001 -> 'Haiku 4.5'."""
    if not model_id:
        return ""
    parts = [p for p in model_id.split("-") if p and p != "claude"]
    parts = [p for p in parts if not re.fullmatch(r"\d{8}", p)]
    words = [p for p in parts if not p.isdigit()]
    nums = [p for p in parts if p.isdigit()]
    name = " ".join(w.capitalize() for w in words)
    if nums:
        name = (name + " " + ".".join(nums)).strip()
    return name


def parse_ts(s):
    """ISO-8601 'Z' timestamp -> epoch seconds (float), or None."""
    try:
        from datetime import datetime
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def parse_line(line):
    """Return (key, entry) for an assistant usage line, else None.

    entry = (ts, model, input, output, cache_create, cache_read)
    """
    if '"usage"' not in line:
        return None
    try:
        d = json.loads(line)
    except ValueError:
        return None
    if d.get("type") != "assistant":
        return None
    msg = d.get("message") or {}
    usage = msg.get("usage")
    model = msg.get("model")
    if not isinstance(usage, dict) or not model or model == "<synthetic>":
        return None
    ts = parse_ts(d.get("timestamp") or "")
    if ts is None:
        return None
    key = "%s:%s" % (msg.get("id"), d.get("requestId"))
    return key, (
        ts,
        model,
        int(usage.get("input_tokens") or 0),
        int(usage.get("output_tokens") or 0),
        int(usage.get("cache_creation_input_tokens") or 0),
        int(usage.get("cache_read_input_tokens") or 0),
    )


class TranscriptScanner:
    """Incrementally reads transcript files, remembering offsets between scans."""

    def __init__(self, projects_dir):
        self.projects_dir = projects_dir
        self.offsets = {}   # path -> bytes consumed
        self.entries = {}   # dedup key -> entry

    def scan(self, now=None):
        now = now or time.time()
        cutoff = now - KEEP_DAYS * DAY
        pattern = os.path.join(self.projects_dir, "**", "*.jsonl")
        for path in glob.iglob(pattern, recursive=True):
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_mtime < cutoff:
                self.offsets.pop(path, None)
                continue
            offset = self.offsets.get(path, 0)
            if st.st_size < offset:      # truncated / rewritten
                offset = 0
            if st.st_size == offset:
                continue
            try:
                with open(path, "rb") as f:
                    f.seek(offset)
                    data = f.read()
            except OSError:
                continue
            # only consume whole lines; a partial trailing line is re-read later
            end = data.rfind(b"\n") + 1
            self.offsets[path] = offset + end
            for raw in data[:end].splitlines():
                parsed = parse_line(raw.decode("utf-8", "replace"))
                if parsed and parsed[1][0] >= cutoff:
                    # a message is logged once per content block; the last
                    # line has the final output token count, so overwrite
                    self.entries[parsed[0]] = parsed[1]
        for key in [k for k, e in self.entries.items() if e[0] < cutoff]:
            del self.entries[key]
        return self.entries


def local_midnight(now):
    lt = time.localtime(now)
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))


def utc_offset(now):
    return int(time.localtime(now).tm_gmtoff)


def aggregate(entries, now):
    """Summarise entries into today's totals, a 7-day series and top model."""
    midnight = local_midnight(now)
    # day boundaries, oldest first; index 6 is today. mktime handles DST.
    lt = time.localtime(now)
    starts = [
        time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday - back, 0, 0, 0, 0, 0, -1))
        for back in range(6, -1, -1)
    ]
    week = [0] * 7
    tok = out = msgs = 0
    by_model = {}
    for ts, model, i, o, cc, cr in entries.values():
        if ts < starts[0] or ts > now + 60:
            continue
        total = i + o + cc + cr
        idx = 6
        while idx > 0 and ts < starts[idx]:
            idx -= 1
        week[idx] += total
        if ts >= midnight:
            tok += total
            out += o
            msgs += 1
            by_model[model] = by_model.get(model, 0) + o
    top = max(by_model, key=by_model.get) if by_model else ""
    return {
        "today": {"tok": tok, "out": out, "msgs": msgs},
        "week": week,
        "model": pretty_model(top),
    }


def read_limits(statusline_path, now):
    """Extract plan limits from the captured statusline JSON.

    Returns {"h5": {...}|None, "d7": {...}|None}. A window whose reset time has
    passed is reported as 0% (the limit has reset; we have no newer reading).
    """
    result = {"h5": None, "d7": None}
    try:
        captured = os.stat(statusline_path).st_mtime
        with open(statusline_path) as f:
            limits = json.load(f).get("rate_limits") or {}
    except (OSError, ValueError, AttributeError):
        return result
    for key, name in (("h5", "five_hour"), ("d7", "seven_day")):
        w = limits.get(name)
        if not isinstance(w, dict) or w.get("used_percentage") is None:
            continue
        pct = round(float(w["used_percentage"]), 1)
        reset = int(w.get("resets_at") or 0)
        if reset and reset <= now:
            pct, reset = 0.0, 0
        result[key] = {"pct": pct, "reset": reset, "ts": int(captured)}
    return result


def build_payload(entries, statusline_path, now=None):
    now = now or time.time()
    payload = {"v": 1, "ts": int(now), "tz": utc_offset(now)}
    payload.update(read_limits(statusline_path, now))
    payload.update(aggregate(entries, now))
    return payload
