"""Screen rendering for the 320x240 Pico Display.

`UI.draw(view)` paints a whole frame from a plain dict, so it can be driven by
the app or by tools/screenshot.py with sample data:

    view = {"data": payload | None, "now": unix_time, "age_s": seconds | None,
            "wifi": bool, "mqtt": bool, "onair": bool}

`age_s` is set once the data is old enough to be worth mentioning.
"""
from picographics import PicoGraphics, DISPLAY_PICO_DISPLAY_2, PEN_RGB565

from cc.fmt import (DAYS, fmt_clock, fmt_duration, fmt_tokens, level, rolled,
                    weekday, window_view)

W, H = 320, 240
M = 10                    # outer margin
BAR_X, BAR_H = 96, 24
H5_S, D7_S = 5 * 3600, 7 * 86400


class UI:
    def __init__(self):
        g = self.g = PicoGraphics(DISPLAY_PICO_DISPLAY_2, pen_type=PEN_RGB565)
        g.set_font("bitmap8")
        p = g.create_pen
        self.bg = p(20, 19, 17)
        self.track = p(48, 45, 40)
        self.rule = p(60, 57, 52)
        self.text = p(240, 238, 230)
        self.dim = p(150, 145, 135)
        self.orange = p(217, 119, 87)
        self.amber = p(235, 175, 60)
        self.red = p(226, 78, 66)
        self.white = p(255, 255, 255)
        self.levels = (self.orange, self.amber, self.red)

    def backlight(self, value):
        self.g.set_backlight(value)

    # -- primitives ---------------------------------------------------------
    def _text(self, s, x, y, pen, scale=2):
        self.g.set_pen(pen)
        self.g.text(s, x, y, W, scale)

    def _text_right(self, s, right, y, pen, scale=2):
        self._text(s, right - self.g.measure_text(s, scale), y, pen, scale)

    def _text_centre(self, s, y, pen, scale=2):
        self._text(s, (W - self.g.measure_text(s, scale)) // 2, y, pen, scale)

    def _spark(self, cx, cy, r):
        """The Claude spark: rays through a centre point."""
        g = self.g
        g.set_pen(self.orange)
        d = int(r * 0.7)
        for dx, dy in ((r, 0), (0, r), (d, d), (d, -d)):
            g.line(cx - dx, cy - dy, cx + dx, cy + dy, 3)

    # -- sections -----------------------------------------------------------
    def _header(self, view):
        g = self.g
        self._spark(M + 10, 17, 10)
        self._text("Claude Code", M + 28, 9, self.text)
        data = view.get("data")
        age = view.get("age_s")
        if not view.get("wifi"):
            self._text_right("no wifi", W - M, 9, self.red)
        elif not view.get("mqtt"):
            self._text_right("no mqtt", W - M, 9, self.red)
        elif age is not None:
            self._text_right(fmt_duration(age) + " ago", W - M, 9, self.dim)
        elif data and view.get("now"):
            self._text_right(fmt_clock(view["now"], data.get("tz", 0)), W - M, 9, self.dim)
        g.set_pen(self.rule)
        g.rectangle(0, 34, W, 1)

    def _limit(self, y, label, win, window_s, now):
        g = self.g
        pct, remaining, elapsed = window_view(win, window_s, now)
        self._text(label, M, y, self.dim)
        if pct is None:
            self._text_right("no reading yet", W - M, y, self.dim)
        elif remaining is not None:
            self._text_right("resets " + fmt_duration(remaining), W - M, y, self.dim)
        elif win.get("reset"):
            self._text_right("window reset", W - M, y, self.dim)

        by = y + 22
        bw = W - M - BAR_X
        pen = self.levels[level(pct)]
        self._text("--" if pct is None else "%d%%" % int(pct + 0.5), M, by,
                   self.dim if pct is None else pen, 3)
        g.set_pen(self.track)
        g.rectangle(BAR_X, by, bw, BAR_H)
        if pct:
            g.set_pen(pen)
            g.rectangle(BAR_X, by, max(2, min(bw, int(bw * pct / 100))), BAR_H)
        if elapsed is not None:
            # pace marker: how far through the window we are. Fill beyond the
            # marker means usage is running ahead of an even burn.
            x = BAR_X + min(bw - 2, int(bw * elapsed))
            g.set_pen(self.text)
            g.rectangle(x, by - 3, 2, BAR_H + 6)

    def _today(self, data, now):
        g = self.g
        g.set_pen(self.rule)
        g.rectangle(0, 162, W, 1)
        today, week = rolled(data, now)
        self._text("Today", M, 171, self.dim)
        value = fmt_tokens(today.get("tok", 0))
        self._text(value, M, 192, self.text, 3)
        self._text("tok", M + g.measure_text(value, 3) + 4, 200, self.dim)
        sub = fmt_tokens(today.get("out", 0)) + " out"
        self._text(sub, M, 220, self.dim)

        # seven-day chart, today last
        if not week:
            return
        top = max(week) or 1
        bar_w, gap, base, max_h = 12, 3, 222, 44
        x0 = W - M - (len(week) * (bar_w + gap) - gap)
        wd = weekday(now, data.get("tz", 0))
        for i, v in enumerate(week):
            x = x0 + i * (bar_w + gap)
            last = i == len(week) - 1
            h = max(2, int(max_h * v / top)) if v else 1
            g.set_pen(self.orange if last else self.dim if v else self.track)
            g.rectangle(x, base - h, bar_w, h)
            day = DAYS[(wd - (len(week) - 1 - i)) % 7]
            self._text(day, x + 3, base + 5, self.text if last else self.dim, 1)
        model = data.get("model")
        if model:
            self._text_right(model, x0 - 12, 171, self.dim)

    def _waiting(self, view):
        self._text_centre("Waiting for usage data", 90, self.text)
        self._text_centre("wifi " + ("ok" if view.get("wifi") else "connecting"), 126, self.dim)
        self._text_centre("mqtt " + ("ok" if view.get("mqtt") else "connecting"), 148, self.dim)
        self._text_centre("is the host publisher running?", 190, self.dim, 1)

    # -- frames -------------------------------------------------------------
    def draw(self, view):
        g = self.g
        if view.get("onair"):
            g.set_pen(self.red)
            g.clear()
            self._text_centre("ON AIR", 88, self.white, 8)
            g.update()
            return
        g.set_pen(self.bg)
        g.clear()
        self._header(view)
        data = view.get("data")
        if not data:
            self._waiting(view)
        else:
            now = view["now"]
            self._limit(44, "5h session", data.get("h5"), H5_S, now)
            self._limit(104, "Week", data.get("d7"), D7_S, now)
            self._today(data, now)
        g.update()

    def message(self, lines, pen=None):
        """Full-screen text, used for fatal errors."""
        g = self.g
        g.set_pen(self.bg)
        g.clear()
        y = 60
        for line in lines:
            self._text(line, M, y, pen or self.text)
            y += 24
        g.update()
