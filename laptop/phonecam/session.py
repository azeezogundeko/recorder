"""Signaling + WebRTC receive for one phone."""

import asyncio
import json
import logging

import av
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError
import websockets

log = logging.getLogger(__name__)


class PhoneSession:
    """Keeps a connection to one phone alive and feeds its media to the sinks.

    The phone sends an offer whenever it starts streaming; we answer.
    Reconnects automatically if WiFi drops.
    """

    def __init__(self, ip: str, port: int, on_video, on_audio, on_status) -> None:
        self.ip, self.port = ip, port
        self.on_video = on_video  # callable(av.VideoFrame)
        self.on_audio = on_audio  # callable(av.AudioFrame)
        self.on_status = on_status  # callable(state: str, phone_name: str | None)
        self.phone_name: str | None = None
        self._pc: RTCPeerConnection | None = None
        self._tasks: set[asyncio.Task] = set()
        self._stopped = False

    async def run(self) -> None:
        while not self._stopped:
            try:
                self.on_status("connecting", self.phone_name)
                url = f"ws://{self.ip}:{self.port}/signal"
                async with websockets.connect(url, open_timeout=5, ping_interval=5, max_size=2**22) as ws:
                    await ws.send(json.dumps({"type": "hello", "client": "laptop-app"}))
                    async for raw in ws:
                        await self._handle(ws, json.loads(raw))
            except asyncio.CancelledError:
                raise
            except Exception as e:  # network errors: retry
                log.info("signal connection lost: %s", e)
            await self._close_pc()
            if not self._stopped:
                self.on_status("disconnected", self.phone_name)
                await asyncio.sleep(1.5)

    async def _handle(self, ws, msg: dict) -> None:
        kind = msg.get("type")
        if kind == "hello":
            self.phone_name = msg.get("name")
            self.on_status("connecting" if msg.get("streaming") else "idle", self.phone_name)
        elif kind == "stopped":
            await self._close_pc()
            self.on_status("idle", self.phone_name)
        elif kind == "offer":
            await self._close_pc()
            pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
            self._pc = pc

            @pc.on("track")
            def on_track(track):
                self._spawn(self._consume(track))

            @pc.on("connectionstatechange")
            async def on_state():
                if pc is not self._pc:
                    return
                state = pc.connectionState
                if state == "connected":
                    self.on_status("live", self.phone_name)
                elif state in ("failed", "closed"):
                    self.on_status("connecting", self.phone_name)

            await pc.setRemoteDescription(RTCSessionDescription(sdp=msg["sdp"], type="offer"))
            answer = await pc.createAnswer()
            await pc.setLocalDescription(answer)  # aiortc gathers all candidates here
            await ws.send(json.dumps({"type": "answer", "sdp": pc.localDescription.sdp}))

    async def _consume(self, track) -> None:
        sink = self.on_video if track.kind == "video" else self.on_audio
        try:
            while True:
                frame = await track.recv()
                sink(frame)
        except (MediaStreamError, asyncio.CancelledError):
            pass

    def _spawn(self, coro) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _close_pc(self) -> None:
        pc, self._pc = self._pc, None
        for t in list(self._tasks):
            t.cancel()
        if pc is not None:
            await pc.close()

    async def stop(self) -> None:
        self._stopped = True
        await self._close_pc()
