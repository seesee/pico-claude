"""Claude Code usage display: WiFi + MQTT in, one screen out."""
import asyncio
import gc
import json
import time

import machine
import network

from cc import config as config_mod
from cc.amqtt import Client
from cc.ui import UI

# MicroPython ports differ on the epoch; payload timestamps are unix time.
EPOCH_OFFSET = 946684800 if time.gmtime(0)[0] == 2000 else 0
BRIGHTNESS_STEPS = (0.25, 0.5, 0.75, 1.0)
BUTTON_A, BUTTON_B = 12, 13


def log(*args):
    print("[%7d]" % (time.ticks_ms() // 1000), *args)


class App:
    def __init__(self):
        self.cfg = config_mod.load()
        self.ui = UI()
        self.brightness = self.cfg["general"]["brightness"]
        self.display_on = True
        self.onair = False
        self.wifi_ok = False
        self.mqtt_ok = False
        self.ntp_ok = False
        self.data = None
        self.data_ticks = 0        # ticks_ms when data arrived
        self.dirty = True
        self.wlan = network.WLAN(network.STA_IF)

    # -- time ---------------------------------------------------------------
    def now(self):
        """Unix time. Falls back to the payload clock until NTP has synced."""
        if self.ntp_ok:
            return time.time() + EPOCH_OFFSET
        if self.data:
            return self.data["ts"] + time.ticks_diff(time.ticks_ms(), self.data_ticks) // 1000
        return 0

    def data_age(self):
        """Age of the data once it is old enough to mention, else None. The
        host only publishes while Claude Code is in use, so old is normal."""
        if not self.data:
            return None
        age = self.now() - self.data["ts"]
        return age if age > self.cfg["general"]["stale_after_s"] else None

    # -- display ------------------------------------------------------------
    def apply_backlight(self):
        self.ui.backlight(self.brightness if self.display_on else 0)

    def set_display(self, on):
        if on != self.display_on:
            log("display", "on" if on else "off")
            self.display_on = on
            self.dirty = True

    def render(self):
        self.dirty = False
        if not self.display_on:
            self.apply_backlight()
            return
        self.ui.draw({
            "data": self.data,
            "now": self.now(),
            "age_s": self.data_age(),
            "wifi": self.wifi_ok,
            "mqtt": self.mqtt_ok,
            "onair": self.onair,
        })
        self.apply_backlight()   # after drawing, so we never light a stale frame

    # -- mqtt ---------------------------------------------------------------
    def on_message(self, topic, payload):
        m = self.cfg["mqtt"]
        if topic == m["topic_usage"]:
            try:
                data = json.loads(payload)
                data["ts"] = int(data["ts"])
            except (ValueError, KeyError, TypeError):
                log("bad usage payload")
                return
            self.data = data
            self.data_ticks = time.ticks_ms()
            self.dirty = True
            return
        msg = payload.decode().strip().upper()
        log("mqtt", topic, msg)
        if topic == m["topic_on_off"]:
            if msg == "ON":
                self.set_display(True)
            elif msg == "OFF":
                self.set_display(False)
            elif msg == "ONAIR":
                self.onair = True
                self.set_display(True)
                self.dirty = True
            elif msg == "OFFAIR":
                self.onair = False
                self.set_display(True)
                self.dirty = True
        elif topic == m["topic_cmd"] and msg == "RESET":
            machine.reset()

    async def mqtt_task(self):
        m = self.cfg["mqtt"]
        delay = 2
        while True:
            if not self.wifi_ok:
                await asyncio.sleep(1)
                continue
            client = Client(m["client_id"], m["broker_ip"], m["broker_port"],
                            m.get("user"), m.get("password"))
            try:
                await client.connect()
                await client.subscribe([m["topic_on_off"], m["topic_cmd"], m["topic_usage"]])
                log("mqtt connected to", m["broker_ip"])
                self.mqtt_ok = self.dirty = True
                delay = 2
                await client.run(self.on_message)
            except Exception as e:
                log("mqtt:", repr(e))
            await client.close()
            if self.mqtt_ok:
                self.mqtt_ok = False
                self.dirty = True
            await asyncio.sleep(delay)
            delay = min(delay * 2, 30)
            gc.collect()

    # -- wifi / time --------------------------------------------------------
    async def wifi_task(self):
        w = self.cfg["wifi"]
        wlan = self.wlan
        wlan.active(True)
        wlan.config(pm=0xA11140)   # power-save off: keeps the MQTT socket responsive
        while True:
            if wlan.isconnected():
                if not self.wifi_ok:
                    log("wifi connected", wlan.ifconfig()[0])
                    self.wifi_ok = self.dirty = True
                await asyncio.sleep(5)
                continue
            if self.wifi_ok:
                log("wifi lost")
                self.wifi_ok = False
                self.dirty = True
            log("wifi connecting to", w["ssid"])
            wlan.disconnect()
            wlan.connect(w["ssid"], w["password"])
            for _ in range(40):          # up to 20s per attempt
                if wlan.isconnected():
                    break
                await asyncio.sleep_ms(500)

    async def ntp_task(self):
        import ntptime
        while True:
            if self.wifi_ok:
                try:
                    ntptime.settime()   # blocks for at most its 1s socket timeout
                    if not self.ntp_ok:
                        log("ntp synced")
                    self.ntp_ok = self.dirty = True
                    await asyncio.sleep(6 * 3600)
                    continue
                except Exception as e:
                    log("ntp:", repr(e))
                    await asyncio.sleep(15)
            await asyncio.sleep(1)

    # -- buttons ------------------------------------------------------------
    async def button_task(self):
        pin = machine.Pin
        a = pin(BUTTON_A, pin.IN, pin.PULL_UP)
        b = pin(BUTTON_B, pin.IN, pin.PULL_UP)
        was_a = was_b = False
        while True:
            is_a, is_b = not a.value(), not b.value()
            if is_a and not was_a:                    # A: display on/off
                self.set_display(not self.display_on)
            if is_b and not was_b and self.display_on:  # B: cycle brightness
                steps = BRIGHTNESS_STEPS
                self.brightness = steps[([i for i, s in enumerate(steps)
                                          if s > self.brightness + 0.01] or [0])[0]]
                self.apply_backlight()
            was_a, was_b = is_a, is_b
            await asyncio.sleep_ms(40)

    # -- main loop ----------------------------------------------------------
    async def main(self):
        self.render()
        for task in (self.wifi_task(), self.mqtt_task(), self.ntp_task(), self.button_task()):
            asyncio.create_task(task)
        last_minute = -1
        while True:
            minute = self.now() // 60     # countdowns and clock tick per minute
            if minute != last_minute:
                last_minute = minute
                self.dirty = True
            if self.dirty:
                self.render()
                gc.collect()
            await asyncio.sleep_ms(100)


def run():
    app = App()
    try:
        asyncio.run(app.main())
    except KeyboardInterrupt:
        raise
    except Exception as e:
        import sys
        sys.print_exception(e)
        try:
            app.ui.message(["Crashed:", repr(e)[:28], "", "restarting..."], app.ui.red)
        except Exception:
            pass
        time.sleep(10)
        machine.reset()
