"""Collect Claude Code usage from local transcripts and the statusline capture.

Pure stdlib. Two sources:

* ``~/.claude/projects/**/*.jsonl`` - every assistant message carries a
  ``usage`` block, which gives token counts per hour and model.
* ``statusline/<session>.json`` - the JSON Claude Code hands to the statusline
  command, saved per session by ``statusline-tee.sh``. It is the only
  documented place the plan limits (5-hour and 7-day ``used_percentage`` /
  ``resets_at``) are exposed.
"""
import glob
import json
import os
import time

DAY = 86400
KEEP_DAYS = 8  # a little more than the 7 days we chart
SAME_WINDOW = 120  # reset times this close together are the same limit window


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


def best_window(windows, now):
    """The reading to believe out of several of the same limit window.

    Every session shows the percentage from its own last response, and an idle
    session keeps re-saving that stale figure, so capture time says nothing
    about which reading is current. Usage only grows until the window resets:
    the latest window wins, and within it the highest percentage. Capture time
    only breaks ties. If every window has expired the result reads 0%.
    """
    windows = [w for w in windows if w]
    live = [w for w in windows if w["reset"] > now]
    if live:
        latest = max(w["reset"] for w in live)
        return max((w for w in live if w["reset"] >= latest - SAME_WINDOW),
                   key=lambda w: (w["pct"], w["ts"]))
    unknown = [w for w in windows if not w["reset"]]
    if unknown:
        return max(unknown, key=lambda w: w["ts"])
    if windows:
        return {"pct": 0.0, "reset": 0, "ts": max(w["ts"] for w in windows)}
    return None


def read_limits(statusline_dir, now):
    """Extract plan limits from the statusline JSON captured for each session.

    Returns {"h5": {...}|None, "d7": {...}|None}, each the best reading across
    sessions (see best_window); "ts" is when that reading was last captured.
    Captures older than KEEP_DAYS are deleted.
    """
    found = {"h5": [], "d7": []}
    for path in glob.glob(os.path.join(statusline_dir, "*.json")):
        try:
            captured = os.stat(path).st_mtime
            if captured < now - KEEP_DAYS * DAY:
                os.unlink(path)
                continue
            with open(path) as f:
                limits = json.load(f).get("rate_limits") or {}
        except (OSError, ValueError, AttributeError):
            continue
        for key, name in (("h5", "five_hour"), ("d7", "seven_day")):
            w = limits.get(name)
            if not isinstance(w, dict) or w.get("used_percentage") is None:
                continue
            found[key].append({"pct": round(float(w["used_percentage"]), 1),
                               "reset": int(w.get("resets_at") or 0), "ts": int(captured)})
    return {key: best_window(windows, now) for key, windows in found.items()}


def build_report(entries, statusline_dir, host, now=None):
    """This host's report, published to <prefix>/<host> for the aggregator."""
    now = now or time.time()
    report = {"v": 2, "host": host, "ts": int(now)}
    report.update(read_limits(statusline_dir, now))
    report["hours"] = hour_buckets(entries, now)
    return report
