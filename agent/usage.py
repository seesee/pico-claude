"""Collect Claude Code usage from local transcripts and the statusline capture.

Pure stdlib. Two sources:

* ``~/.claude/projects/**/*.jsonl`` - every assistant message carries a
  ``usage`` block, which gives token counts per hour and model.
* ``statusline.json`` - the JSON Claude Code hands to the statusline command,
  saved by ``statusline-tee.sh``. It is the only documented place the plan
  limits (5-hour and 7-day ``used_percentage`` / ``resets_at``) are exposed.
"""
import glob
import json
import os
import time

DAY = 86400
KEEP_DAYS = 8  # a little more than the 7 days we chart


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


def hour_buckets(entries, now):
    """Token usage per (UTC hour, model): rows of [hour, model, tok, out, msgs].

    `hour` is unix time // 3600. Hourly buckets let the aggregator cut days in
    its own timezone, whatever this host's clock is set to.
    """
    buckets = {}
    for ts, model, i, o, cc, cr in entries.values():
        if ts > now + 60:
            continue
        b = buckets.setdefault((int(ts // 3600), model), [0, 0, 0])
        b[0] += i + o + cc + cr
        b[1] += o
        b[2] += 1
    return [[h, m] + v for (h, m), v in sorted(buckets.items())]


def read_limits(statusline_path, now):
    """Extract plan limits from the captured statusline JSON.

    Returns {"h5": {...}|None, "d7": {...}|None}; "ts" is when the reading was
    captured, so the aggregator can pick the newest across hosts. A window
    whose reset time has passed is reported as 0%.
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


def build_report(entries, statusline_path, host, now=None):
    """This host's report, published to <prefix>/<host> for the aggregator."""
    now = now or time.time()
    report = {"v": 2, "host": host, "ts": int(now)}
    report.update(read_limits(statusline_path, now))
    report["hours"] = hour_buckets(entries, now)
    return report
