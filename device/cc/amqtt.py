"""Tiny asyncio MQTT 3.1.1 client: subscribe at QoS 0 and receive.

Unlike umqtt.simple nothing here blocks the event loop, and a silent broker is
detected through PINGREQ/PINGRESP so the caller can reconnect.
Runs on MicroPython and CPython.
"""
import asyncio
import struct
import time

try:
    _ticks, _diff = time.ticks_ms, time.ticks_diff
except AttributeError:  # CPython
    def _ticks():
        return int(time.monotonic() * 1000)

    def _diff(a, b):
        return a - b


class MQTTError(Exception):
    pass


def _str(s):
    b = s.encode() if isinstance(s, str) else s
    return struct.pack("!H", len(b)) + b


def _varlen(n):
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        out.append(b | 0x80 if n else b)
        if not n:
            return bytes(out)


class Client:
    def __init__(self, client_id, host, port=1883, user=None, password=None, keepalive=60):
        self.client_id = client_id
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.keepalive = keepalive
        self._r = self._w = None
        self._last_rx = 0
        self._err = None

    async def _send(self, data):
        self._w.write(data)
        await asyncio.wait_for(self._w.drain(), 10)

    async def _read_packet(self):
        head = (await self._r.readexactly(1))[0]
        length = shift = 0
        while True:
            b = (await self._r.readexactly(1))[0]
            length |= (b & 0x7F) << shift
            if not b & 0x80:
                break
            shift += 7
        body = await self._r.readexactly(length) if length else b""
        return head >> 4, head & 0x0F, body

    async def connect(self, timeout=10):
        self._r, self._w = await asyncio.wait_for(
            asyncio.open_connection(self.host, self.port), timeout)
        flags = 0x02  # clean session
        payload = _str(self.client_id)
        if self.user:
            flags |= 0x80
            payload += _str(self.user)
            if self.password:
                flags |= 0x40
                payload += _str(self.password)
        body = _str("MQTT") + bytes([4, flags]) + struct.pack("!H", self.keepalive) + payload
        await self._send(b"\x10" + _varlen(len(body)) + body)
        ptype, _, ack = await asyncio.wait_for(self._read_packet(), timeout)
        if ptype != 2 or len(ack) < 2 or ack[1] != 0:
            raise MQTTError("connect refused")
        self._last_rx = _ticks()

    async def subscribe(self, topics):
        body = b"\x00\x01" + b"".join(_str(t) + b"\x00" for t in topics)
        await self._send(b"\x82" + _varlen(len(body)) + body)

    async def _reader(self, on_message):
        try:
            while True:
                ptype, flags, body = await self._read_packet()
                self._last_rx = _ticks()
                if ptype == 3:  # PUBLISH
                    tlen = (body[0] << 8) | body[1]
                    topic = bytes(body[2:2 + tlen]).decode()
                    start = 2 + tlen + (2 if flags & 0x06 else 0)  # skip packet id if QoS>0
                    on_message(topic, bytes(body[start:]))
        except asyncio.CancelledError:
            raise
        except Exception as e:  # EOF, reset, bad packet
            self._err = e

    async def run(self, on_message):
        """Dispatch messages until the connection fails; always raises."""
        self._err = None
        reader = asyncio.create_task(self._reader(on_message))
        ping_every = self.keepalive * 500      # ms; ping at half the keepalive
        dead_after = self.keepalive * 1500     # ms without any packet
        last_ping = _ticks()
        try:
            while self._err is None:
                await asyncio.sleep(1)
                now = _ticks()
                if _diff(now, self._last_rx) > dead_after:
                    raise MQTTError("broker silent")
                if _diff(now, last_ping) >= ping_every:
                    last_ping = now
                    await self._send(b"\xc0\x00")
            raise MQTTError("connection lost: %r" % (self._err,))
        finally:
            reader.cancel()
            await self.close()

    async def close(self):
        w, self._r, self._w = self._w, None, None
        if w:
            try:
                w.close()
                await w.wait_closed()
            except Exception:
                pass
