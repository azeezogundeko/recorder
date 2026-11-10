"""Connects to the phone like PhoneCam does and reports what media actually arrives.

    python tools/diagnose.py [phone-ip]
"""

import asyncio
import json
import logging
import re
import sys
import time
from pathlib import Path

import websockets
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from phonecam.discovery import start_discovery  # noqa: E402

logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")


async def main():
    if len(sys.argv) > 1:
        ip, port = sys.argv[1], 8080
    else:
        d = await start_discovery()
        print("discovery error:", d.error)
        for _ in range(10):
            await asyncio.sleep(0.5)
            if d.phones():
                break
        phones = d.phones()
        print("phones:", [(p.name, p.ip, p.port) for p in phones])
        if not phones:
            return
        ip, port = phones[0].ip, phones[0].port

    stats = {"video": 0, "audio": 0, "sizes": set(), "errors": []}
    async with websockets.connect(f"ws://{ip}:{port}/signal", max_size=2**22) as ws:
        await ws.send(json.dumps({"type": "hello", "client": "browser"}))
        pc = None
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=max(0.1, deadline - time.time()))
            except asyncio.TimeoutError:
                break
            msg = json.loads(raw)
            print("<-", msg["type"], {k: v for k, v in msg.items() if k != "sdp"})
            if msg["type"] != "offer":
                continue
            sdp = msg["sdp"]
            print("offer m-lines:", re.findall(r"^m=.*$", sdp, re.M))
            print("offer video codecs:", sorted(set(re.findall(r"a=rtpmap:\d+ (\w+)/90000", sdp))))
            pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))

            @pc.on("track")
            def on_track(track):
                print("track:", track.kind)

                async def consume():
                    try:
                        while True:
                            f = await track.recv()
                            stats[track.kind] += 1
                            if track.kind == "video":
                                stats["sizes"].add((f.width, f.height))
                    except Exception as e:
                        stats["errors"].append(f"{track.kind}: {e!r}")

                asyncio.ensure_future(consume())

            @pc.on("connectionstatechange")
            def on_state():
                print("connection:", pc.connectionState)

            await pc.setRemoteDescription(RTCSessionDescription(sdp, "offer"))
            await pc.setLocalDescription(await pc.createAnswer())
            ans = pc.localDescription.sdp
            print("answer video codecs:", sorted(set(re.findall(r"a=rtpmap:\d+ (\w+)/90000", ans))))
            print("answer m-lines:", re.findall(r"^m=.*$", ans, re.M))
            await ws.send(json.dumps({"type": "answer", "sdp": ans}))
            await asyncio.sleep(10)
            break
        print(f"RESULT video frames={stats['video']} audio frames={stats['audio']} "
              f"sizes={stats['sizes']} errors={stats['errors']}")
        if pc:
            await pc.close()


asyncio.run(main())
