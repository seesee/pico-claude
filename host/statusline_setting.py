#!/usr/bin/env python3
"""Wrap / unwrap the Claude Code statusline command with statusline-tee.sh.

    statusline_setting.py install   /path/to/statusline-tee.sh [settings.json]
    statusline_setting.py uninstall /path/to/statusline-tee.sh [settings.json]

install turns   "command": "npx -y ccstatusline@latest"
into            "command": "/path/to/statusline-tee.sh npx -y ccstatusline@latest"
(or adds a statusline that only captures, if none is configured). Idempotent;
the first change backs settings.json up to settings.json.pico-claude.bak.
"""
import json
import os
import shutil
import sys


def wrap(settings, tee):
    """Return True if settings were changed."""
    sl = settings.get("statusLine")
    if not sl:
        settings["statusLine"] = {"type": "command", "command": tee}
        return True
    cmd = sl.get("command", "")
    if sl.get("type") != "command" or cmd.startswith(tee):
        return False
    sl["command"] = (tee + " " + cmd).strip()
    return True


def unwrap(settings, tee):
    sl = settings.get("statusLine") or {}
    cmd = sl.get("command", "")
    if not cmd.startswith(tee):
        return False
    rest = cmd[len(tee):].strip()
    if rest:
        sl["command"] = rest
    else:
        del settings["statusLine"]
    return True


def main():
    action, tee = sys.argv[1], sys.argv[2]
    path = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.claude/settings.json")
    try:
        with open(path) as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    changed = (wrap if action == "install" else unwrap)(settings, tee)
    if not changed:
        print("statusline: nothing to change")
        return
    if os.path.exists(path):
        backup = path + ".pico-claude.bak"
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    print("statusline: %s -> %s" % (action, (settings.get("statusLine") or {}).get("command")))


if __name__ == "__main__":
    main()
