"""Finds phones running WiFi Mic via the UDP beacon they broadcast every second."""

import asyncio
import json
import socket
import time
from dataclasses import dataclass, field

from . import DISCOVERY_PORT

EXPIRE_SECONDS = 5.0


@dataclass
class Phone:
    ip: str
    port: int
    name: str
    last_seen: float = field(default_factory=time.monotonic)

    @property
    def key(self) -> str:
        return f"{self.ip}:{self.port}"


class Discovery(asyncio.DatagramProtocol):
    def __init__(self) -> None:
        self._phones: dict[str, Phone] = {}
        self.error: str | None = None

    def connection_made(self, transport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, addr) -> None:
        try:
            msg = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return
        if msg.get("app") != "wifimic":
            return
        phone = Phone(ip=addr[0], port=int(msg.get("port", 8080)), name=str(msg.get("name", "Phone")))
        # The same beacon can arrive via several adapters; list each phone once
        # and prefer a real LAN address over loopback.
        same = f"{phone.name}|{phone.port}"
        existing = self._phones.get(same)
        if existing and existing.ip != phone.ip and not (
                existing.ip.startswith("127.") and not phone.ip.startswith("127.")):
            existing.last_seen = phone.last_seen
            return
        self._phones[same] = phone

    def phones(self) -> list[Phone]:
        now = time.monotonic()
        for key in [k for k, p in self._phones.items() if now - p.last_seen > EXPIRE_SECONDS]:
            del self._phones[key]
        return sorted(self._phones.values(), key=lambda p: p.name)


async def start_discovery() -> Discovery:
    loop = asyncio.get_running_loop()
    proto = Discovery()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", DISCOVERY_PORT))
    except OSError as e:
        proto.error = f"Can't listen for phones on UDP {DISCOVERY_PORT}: {e}"
        sock.close()
        return proto
    await loop.create_datagram_endpoint(lambda: proto, sock=sock)
    return proto
