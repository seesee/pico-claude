import json
import os
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))

import mqtt_pub  # noqa: E402
import statusline_setting  # noqa: E402
import usage  # noqa: E402


def line(ts, mid, out=10, model="claude-fable-5-1", req="r1", inp=1, cc=2, cr=3):
    return json.dumps({
        "type": "assistant", "requestId": req,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + ".000Z",
        "message": {"id": mid, "model": model, "usage": {
            "input_tokens": inp, "output_tokens": out,
            "cache_creation_input_tokens": cc, "cache_read_input_tokens": cr}},
    }) + "\n"


class PrettyModel(unittest.TestCase):
    def test_names(self):
        self.assertEqual(usage.pretty_model("claude-fable-5-1"), "Fable 5.1")
        self.assertEqual(usage.pretty_model("claude-haiku-4-5-20251001"), "Haiku 4.5")
        self.assertEqual(usage.pretty_model(""), "")


class ParseLine(unittest.TestCase):
    def test_skips_synthetic_and_non_assistant(self):
        self.assertIsNone(usage.parse_line(line(1000, "m", model="<synthetic>")))
        self.assertIsNone(usage.parse_line('{"type":"user","usage":1}'))
        self.assertIsNone(usage.parse_line('{"usage": broken'))

    def test_extracts_tokens(self):
        key, e = usage.parse_line(line(1000, "m1", out=7))
        self.assertEqual(key, "m1:r1")
        self.assertEqual(e, (1000.0, "claude-fable-5-1", 1, 7, 2, 3))


class Scanner(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        os.makedirs(os.path.join(self.dir.name, "proj", "sub"))
        self.path = os.path.join(self.dir.name, "proj", "a.jsonl")
        self.now = time.time()

    def tearDown(self):
        self.dir.cleanup()

    def test_incremental_dedup_and_partial_lines(self):
        s = usage.TranscriptScanner(self.dir.name)
        with open(self.path, "w") as f:
            f.write(line(self.now - 10, "m1", out=5))
            f.write(line(self.now - 9, "m1", out=50))        # same message, final count
            f.write(line(self.now - 8, "m2", out=1)[:-20])   # partial write, no newline
        entries = s.scan(self.now)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries["m1:r1"][3], 50)
        with open(self.path, "w") as f:                      # complete the partial line
            f.write(line(self.now - 10, "m1", out=5))
            f.write(line(self.now - 9, "m1", out=50))
            f.write(line(self.now - 8, "m2", out=1))
        self.assertEqual(len(s.scan(self.now)), 2)
        self.assertEqual(len(s.scan(self.now)), 2)           # nothing new, still 2

    def test_nested_files_and_old_entries_dropped(self):
        with open(os.path.join(self.dir.name, "proj", "sub", "b.jsonl"), "w") as f:
            f.write(line(self.now - 5, "n1"))
            f.write(line(self.now - 20 * usage.DAY, "old"))
        s = usage.TranscriptScanner(self.dir.name)
        self.assertEqual(list(s.scan(self.now)), ["n1:r1"])


class Aggregate(unittest.TestCase):
    def test_today_week_and_model(self):
        now = time.mktime((2026, 10, 1, 16, 0, 0, 0, 0, -1))
        entries = {
            "a": (now - 3600, "claude-fable-5-1", 1, 100, 2, 3),          # today
            "b": (now - 7200, "claude-haiku-4-5-20251001", 1, 5, 0, 0),   # today
            "c": (now - 2 * usage.DAY, "claude-fable-5-1", 10, 10, 10, 10),
            "d": (now - 30 * usage.DAY, "claude-fable-5-1", 9, 9, 9, 9),  # outside
        }
        agg = usage.aggregate(entries, now)
        self.assertEqual(agg["today"], {"tok": 112, "out": 105, "msgs": 2})
        self.assertEqual(agg["week"], [0, 0, 0, 0, 40, 0, 112])
        self.assertEqual(agg["model"], "Fable 5.1")

    def test_empty(self):
        agg = usage.aggregate({}, time.time())
        self.assertEqual(agg["week"], [0] * 7)
        self.assertEqual(agg["model"], "")


class Limits(unittest.TestCase):
    def write(self, obj):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(obj, f)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_reads_windows(self):
        p = self.write({"rate_limits": {
            "five_hour": {"used_percentage": 23.46, "resets_at": 2000},
            "seven_day": {"used_percentage": 41, "resets_at": 9000}}})
        r = usage.read_limits(p, 1000)
        self.assertEqual((r["h5"]["pct"], r["h5"]["reset"]), (23.5, 2000))
        self.assertEqual((r["d7"]["pct"], r["d7"]["reset"]), (41.0, 9000))

    def test_expired_window_reads_zero(self):
        p = self.write({"rate_limits": {"five_hour": {"used_percentage": 90, "resets_at": 500}}})
        r = usage.read_limits(p, 1000)
        self.assertEqual((r["h5"]["pct"], r["h5"]["reset"]), (0.0, 0))
        self.assertIsNone(r["d7"])

    def test_missing_or_bad_file(self):
        self.assertEqual(usage.read_limits("/nonexistent", 1), {"h5": None, "d7": None})
        self.assertEqual(usage.read_limits(self.write([1, 2]), 1), {"h5": None, "d7": None})


class MqttPackets(unittest.TestCase):
    def test_publish_packet(self):
        self.assertEqual(mqtt_pub.publish_packet("a/b", "hi", retain=True),
                         b"\x31\x07\x00\x03a/bhi")

    def test_long_payload_length_encoding(self):
        pkt = mqtt_pub.publish_packet("t", "x" * 200)
        self.assertEqual(pkt[:3], b"\x30\xcb\x01")   # 203 = 0xCB 0x01 varint

    def test_connect_packet(self):
        self.assertEqual(mqtt_pub.connect_packet("c"),
                         b"\x10\x0d\x00\x04MQTT\x04\x02\x00\x3c\x00\x01c")


class StatuslineSetting(unittest.TestCase):
    TEE = "/x/statusline-tee.sh"

    def test_wrap_and_unwrap_round_trip(self):
        s = {"statusLine": {"type": "command", "command": "npx -y ccstatusline@latest", "padding": 0}}
        self.assertTrue(statusline_setting.wrap(s, self.TEE))
        self.assertEqual(s["statusLine"]["command"], self.TEE + " npx -y ccstatusline@latest")
        self.assertFalse(statusline_setting.wrap(s, self.TEE))     # idempotent
        self.assertTrue(statusline_setting.unwrap(s, self.TEE))
        self.assertEqual(s["statusLine"],
                         {"type": "command", "command": "npx -y ccstatusline@latest", "padding": 0})

    def test_no_existing_statusline(self):
        s = {}
        statusline_setting.wrap(s, self.TEE)
        self.assertEqual(s["statusLine"]["command"], self.TEE)
        statusline_setting.unwrap(s, self.TEE)
        self.assertNotIn("statusLine", s)


if __name__ == "__main__":
    unittest.main()
