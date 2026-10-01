"""Tests for the hardware-free device modules (run under CPython)."""
import asyncio
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "device"))

from cc import amqtt  # noqa: E402
from cc.fmt import (fmt_clock, fmt_duration, fmt_tokens, level, rolled,  # noqa: E402
                    weekday, window_view)


class Fmt(unittest.TestCase):
    def test_tokens(self):
        cases = {0: "0", 950: "950", 1000: "1.0k", 9940: "9.9k", 9960: "10k",
                 123456: "123k", 999600: "1.0M", 18140015: "18M", 1234567: "1.2M",
                 2500000000: "2.5B"}
        for n, want in cases.items():
            self.assertEqual(fmt_tokens(n), want, n)

    def test_duration(self):
        cases = {5: "<1m", 60: "1m", 59 * 60: "59m", 3600: "1h 00m",
                 2 * 3600 + 13 * 60: "2h 13m", 3 * 86400 + 4 * 3600 + 5: "3d 4h"}
        for s, want in cases.items():
            self.assertEqual(fmt_duration(s), want, s)

    def test_clock_and_weekday(self):
        now = 1790868600  # Thu 2026-10-01 15:30 UTC
        self.assertEqual(fmt_clock(now, 3600), "16:30")
        self.assertEqual(weekday(now, 3600), 3)
        self.assertEqual(weekday(now + 9 * 3600, 3600), 4)   # past local midnight

    def test_level(self):
        self.assertEqual([level(p) for p in (None, 0, 69.9, 70, 89.9, 90, 100)],
                         [0, 0, 0, 1, 1, 2, 2])


class WindowView(unittest.TestCase):
    def test_no_reading(self):
        self.assertEqual(window_view(None, 100, 0), (None, None, None))

    def test_active_window(self):
        pct, remaining, elapsed = window_view({"pct": 40, "reset": 1000}, 400, 900)
        self.assertEqual((pct, remaining), (40, 100))
        self.assertAlmostEqual(elapsed, 0.75)

    def test_reset_passed_reads_zero(self):
        self.assertEqual(window_view({"pct": 80, "reset": 1000}, 400, 1001), (0, None, None))

    def test_unknown_reset(self):
        self.assertEqual(window_view({"pct": 12, "reset": 0}, 400, 5), (12, None, None))


class Rolled(unittest.TestCase):
    DATA = {"ts": 1790868600, "tz": 3600,   # Thu 16:30 local
            "today": {"tok": 7, "out": 2, "msgs": 1}, "week": [1, 2, 3, 4, 5, 6, 7]}

    def test_same_day_unchanged(self):
        today, week = rolled(self.DATA, self.DATA["ts"] + 7 * 3600)   # 23:30
        self.assertEqual((today["tok"], week), (7, [1, 2, 3, 4, 5, 6, 7]))

    def test_after_midnight_shifts(self):
        today, week = rolled(self.DATA, self.DATA["ts"] + 8 * 3600)   # 00:30 Fri
        self.assertEqual((today["tok"], week), (0, [2, 3, 4, 5, 6, 7, 0]))

    def test_many_days_later(self):
        _, week = rolled(self.DATA, self.DATA["ts"] + 30 * 86400)
        self.assertEqual(week, [0] * 7)


class FakeBroker:
    """Just enough MQTT broker to exercise the client."""

    def __init__(self, publish=(), silent=False):
        self.publish, self.silent, self.subscribed = publish, silent, None

    async def handle(self, r, w):
        await r.readexactly(2 + (await self._peek_len(r)))
        w.write(b"\x20\x02\x00\x00")                       # CONNACK
        head = await r.readexactly(2)
        self.subscribed = await r.readexactly(head[1])
        w.write(b"\x90\x03\x00\x01\x00")                   # SUBACK
        for pkt in self.publish:
            w.write(pkt)
        await w.drain()
        if self.silent:
            await asyncio.sleep(30)
        w.close()

    async def _peek_len(self, r):
        return (await r.readexactly(2))[1] - 2


async def run_client(broker, keepalive=60):
    server = await asyncio.start_server(broker.handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    got = []
    c = amqtt.Client("t", "127.0.0.1", port, keepalive=keepalive)
    await c.connect()
    await c.subscribe(["a/b", "c"])
    try:
        await c.run(lambda t, p: got.append((t, p)))
    except amqtt.MQTTError as e:
        return got, str(e)
    finally:
        server.close()


class AsyncMqtt(unittest.TestCase):
    def test_receives_messages_then_reports_disconnect(self):
        big = b"x" * 300
        body = b"\x00\x03a/b" + big
        pkts = [b"\x31\x05\x00\x01chi",                    # retained flag set
                b"\x30" + amqtt._varlen(len(body)) + body]  # multi-byte length
        broker = FakeBroker(pkts)
        got, err = asyncio.run(run_client(broker))
        self.assertEqual(got, [("c", b"hi"), ("a/b", big)])
        self.assertIn("connection lost", err)
        self.assertEqual(broker.subscribed, b"\x00\x01\x00\x03a/b\x00\x00\x01c\x00")

    def test_silent_broker_detected(self):
        got, err = asyncio.run(run_client(FakeBroker(silent=True), keepalive=1))
        self.assertEqual(got, [])
        self.assertIn("silent", err)


if __name__ == "__main__":
    unittest.main()
