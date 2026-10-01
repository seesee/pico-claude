"""Pure formatting helpers - no hardware imports, so they run under CPython tests."""

DAYS = "MTWTFSS"  # weekday initials, Monday first


def fmt_tokens(n):
    """Compact token count: 950, 9.9k, 123k, 9.9M, 123M, 1.2B."""
    n = int(n)
    for limit, div, suffix in ((1000000, 1000, "k"), (1000000000, 1000000, "M"),
                               (1 << 62, 1000000000, "B")):
        if n < 1000:
            return str(n)
        if n < limit:
            v = n / div
            if v < 9.95:
                return "%.1f%s" % (v, suffix)
            if v < 999.5:
                return "%d%s" % (int(v + 0.5), suffix)
    return str(n)


def fmt_duration(seconds):
    """Coarse time remaining: '3d 4h', '2h 13m', '13m', '<1m'."""
    s = int(seconds)
    if s < 60:
        return "<1m"
    m = s // 60
    if m < 60:
        return "%dm" % m
    h = m // 60
    if h < 24:
        return "%dh %02dm" % (h, m % 60)
    return "%dd %dh" % (h // 24, h % 24)


def fmt_clock(now, tz):
    """HH:MM for unix time `now` at UTC offset `tz` seconds."""
    t = (int(now) + tz) % 86400
    return "%02d:%02d" % (t // 3600, (t % 3600) // 60)


def weekday(now, tz):
    """0=Monday .. 6=Sunday for unix time `now` at UTC offset `tz` seconds."""
    return ((int(now) + tz) // 86400 + 3) % 7  # 1970-01-01 was a Thursday


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def window_view(win, window_s, now):
    """Resolve a limit window for display at time `now`.

    Returns (pct, remaining_s, elapsed_fraction). pct is None when there is no
    reading; remaining_s/elapsed are None when the reset time is unknown. Once
    the reset time has passed the window reads as 0% used.
    """
    if not win:
        return None, None, None
    pct = win.get("pct")
    reset = win.get("reset") or 0
    if not reset:
        return pct, None, None
    remaining = reset - now
    if remaining <= 0:
        return 0, None, None
    elapsed = clamp(1 - remaining / window_s, 0, 1)
    return pct, remaining, elapsed


def level(pct):
    """0 = fine, 1 = getting close, 2 = nearly out."""
    if pct is None or pct < 70:
        return 0
    return 1 if pct < 90 else 2


def rolled(data, now):
    """(today, week) from a payload, adjusted for local midnights since it was
    sent: the publisher only runs while Claude Code is in use, so an old
    payload's "today" may by now be yesterday."""
    tz = data.get("tz", 0)
    today = data.get("today") or {}
    week = list(data.get("week") or [])
    days = (int(now) + tz) // 86400 - (int(data.get("ts", now)) + tz) // 86400
    if days <= 0 or not week:
        return today, week
    n = len(week)
    return {"tok": 0, "out": 0, "msgs": 0}, (week + [0] * min(days, n))[-n:]
