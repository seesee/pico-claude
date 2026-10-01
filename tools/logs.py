#!/usr/bin/env python3
"""Show the Pico's serial log without interrupting the running program.

    tools/logs.py [seconds]      # default: until Ctrl-C

Needs pyserial (it ships with mpremote; run with that Python if your default
one lacks it). The board is picked by USB vendor id, never by port name.
"""
import sys
import time

import serial
from serial.tools import list_ports

ports = [p.device for p in list_ports.comports() if p.vid == 0x2E8A]
if not ports:
    sys.exit("no Raspberry Pi serial device found")
limit = float(sys.argv[1]) if len(sys.argv) > 1 else None
start = time.time()
while limit is None or time.time() - start < limit:
    try:
        with serial.Serial(ports[0], 115200, timeout=0.2) as s:
            while limit is None or time.time() - start < limit:
                data = s.read(300)
                if data:
                    sys.stdout.write(data.decode(errors="replace"))
                    sys.stdout.flush()
    except (serial.SerialException, OSError):
        time.sleep(0.3)   # board is rebooting; wait for the port to come back
    except KeyboardInterrupt:
        break
