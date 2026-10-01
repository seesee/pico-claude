"""Minimal MQTT 3.1.1 publisher (QoS 0) - enough to post a retained message."""
import socket
import struct


def _varlen(n):
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        out.append(b | 0x80 if n else b)
        if not n:
            return bytes(out)


def _str(s):
    b = s.encode() if isinstance(s, str) else s
    return struct.pack("!H", len(b)) + b


def connect_packet(client_id, user=None, password=None, keepalive=60):
    flags = 0x02  # clean session
    payload = _str(client_id)
    if user is not None:
        flags |= 0x80
        payload += _str(user)
        if password is not None:
            flags |= 0x40
            payload += _str(password)
    body = _str("MQTT") + bytes([4, flags]) + struct.pack("!H", keepalive) + payload
    return b"\x10" + _varlen(len(body)) + body


def publish_packet(topic, payload, retain=False):
    if isinstance(payload, str):
        payload = payload.encode()
    body = _str(topic) + payload
    return bytes([0x30 | (1 if retain else 0)]) + _varlen(len(body)) + body


def publish(host, port, topic, payload, retain=True, client_id="pico-claude-pub",
            user=None, password=None, timeout=5):
    """Connect, publish one message, disconnect. Raises OSError on failure."""
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(connect_packet(client_id, user, password))
        ack = b""
        while len(ack) < 4:
            chunk = s.recv(4 - len(ack))
            if not chunk:
                raise OSError("broker closed connection during CONNECT")
            ack += chunk
        if ack[0] != 0x20 or ack[3] != 0:
            raise OSError("MQTT connect refused (code %d)" % ack[3])
        s.sendall(publish_packet(topic, payload, retain))
        s.sendall(b"\xe0\x00")  # DISCONNECT
