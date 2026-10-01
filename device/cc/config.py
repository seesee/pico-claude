"""config.json loader. Sections mirror the old unicorn_wrangler config so the
same wifi/mqtt settings carry over."""
import json

_DEFAULTS = {
    "wifi": {"ssid": "", "password": ""},
    "mqtt": {
        "broker_ip": "127.0.0.1",
        "broker_port": 1883,
        "client_id": "pico_claude",
        "user": None,
        "password": None,
        "topic_on_off": "unicorn/control/onoff",
        "topic_cmd": "unicorn/control/cmd",
        "topic_usage": "claude/usage",
    },
    "general": {"brightness": 0.75, "stale_after_s": 900},
}


def load(filename="config.json"):
    cfg = {k: dict(v) for k, v in _DEFAULTS.items()}
    try:
        with open(filename) as f:
            loaded = json.load(f)
    except (OSError, ValueError) as e:
        print("config: using defaults (%s)" % e)
        return cfg
    for section, values in loaded.items():
        if isinstance(values, dict):
            cfg.setdefault(section, {}).update(values)
    return cfg
