"""Pretends to be the WiFi Mic phone app (beacon + signaling + test video/audio).

Use it to test PhoneCam without a phone:
    python tools/fake_phone.py
"""

import asyncio
import fractions
import json
import math
import socket
import sys
import time
from pathlib import Path

import numpy as np
import websockets
from aiortc import MediaStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from av import AudioFrame, VideoFrame

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from phonecam import DISCOVERY_PORT  # noqa: E402

PORT = 18090


class TestVideo(MediaStreamTrack):
    """Portrait 720x1280 frames with a moving bar, like a phone held upright."""

    kind = "video"

    def __init__(self):
        super().__init__()
        self._n = 0
        self._start = time.time()

    async def recv(self):
        self._n += 1
        await asyncio.sleep(max(0, self._start + self._n / 30 - time.time()))
        img = np.zeros((1280, 720, 3), np.uint8)
        img[:, :, 0] = np.linspace(40, 200, 720, dtype=np.uint8)
        y = (self._n * 12) % 1280
        img[y:y + 80, :, :] = 255
        frame = VideoFrame.from_ndarray(img, format="rgb24")
        frame.pts, frame.time_base = self._n * 3000, fractions.Fraction(1, 90000)
        return frame


class TestAudio(MediaStreamTrack):
    """440 Hz tone, 20 ms frames at 48 kHz mono."""

    kind = "audio"

    def __init__(self):
        super().__init__()
        self._t = 0
        self._start = time.time()

    async def recv(self):
        n = 960
        await asyncio.sleep(max(0, self._start + self._t / 48000 - time.time()))
        t = (np.arange(n) + self._t) / 48000
        pcm = (np.sin(2 * math.pi * 440 * t) * 8000).astype(np.int16).reshape(1, -1)
        frame = AudioFrame.from_ndarray(pcm, format="s16", layout="mono")
        frame.sample_rate, frame.pts, frame.time_base = 48000, self._t, fractions.Fraction(1, 48000)
        self._t += n
        return frame


async def handle(ws):
    await ws.send(json.dumps({"type": "hello", "name": "Fake Phone", "streaming": True}))
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    pc.addTrack(TestVideo())
    pc.addTrack(TestAudio())
    await pc.setLocalDescription(await pc.createOffer())
    await ws.send(json.dumps({"type": "offer", "sdp": pc.localDescription.sdp}))
    try:
        async for raw in ws:
            msg = json.loads(raw)
            if msg["type"] == "answer":
                await pc.setRemoteDescription(RTCSessionDescription(msg["sdp"], "answer"))
                print("answer received; streaming")
    finally:
        await pc.close()


async def beacon():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    payload = json.dumps({"app": "wifimic", "v": 1, "name": "Fake Phone", "port": PORT}).encode()
    while True:
        for target in ("255.255.255.255", "127.0.0.1"):
            try:
                sock.sendto(payload, (target, DISCOVERY_PORT))
            except OSError:
                pass
        await asyncio.sleep(1)


async def main():
    async with websockets.serve(handle, "0.0.0.0", PORT):
        print(f"fake phone on ws://127.0.0.1:{PORT}/signal")
        await beacon()


if __name__ == "__main__":
    asyncio.run(main())
