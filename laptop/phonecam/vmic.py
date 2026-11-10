"""Plays phone audio into VB-Cable so apps can pick "CABLE Output" as a microphone."""

import collections
import threading

import av
import numpy as np
import sounddevice as sd

RATE = 48000
CHANNELS = 2
TARGET_LATENCY = 0.06  # seconds buffered before playback (re)starts
MAX_LATENCY = 0.25  # drop old audio beyond this to stay in sync with video


def find_cable_device() -> tuple[int, str] | None:
    """Returns (device index, host API name) for VB-Cable's playback side."""
    apis = sd.query_hostapis()
    candidates = []
    for idx, dev in enumerate(sd.query_devices()):
        if dev["max_output_channels"] < 1 or "CABLE Input" not in dev["name"]:
            continue
        api = apis[dev["hostapi"]]["name"]
        rank = {"Windows WASAPI": 0, "Windows DirectSound": 1, "MME": 2}.get(api, 3)
        candidates.append((rank, idx, api))
    if not candidates:
        return None
    _, idx, api = min(candidates)
    return idx, api


class VirtualMic:
    def __init__(self) -> None:
        self.error: str | None = None
        self.level = 0.0  # 0..1 for the meter
        self._buf: collections.deque[np.ndarray] = collections.deque()
        self._buffered = 0
        self._primed = False
        self._lock = threading.Lock()
        self._resampler = av.AudioResampler(format="s16", layout="stereo", rate=RATE)
        self._stream: sd.OutputStream | None = None

    @property
    def running(self) -> bool:
        return self._stream is not None

    def start(self) -> None:
        found = find_cable_device()
        if found is None:
            self.error = "VB-Cable not found"
            return
        idx, api = found
        attempts = [{"extra_settings": sd.WasapiSettings(auto_convert=True)}, {}] if api == "Windows WASAPI" else [{}]
        for kw in attempts:
            try:
                stream = sd.OutputStream(
                    device=idx, samplerate=RATE, channels=CHANNELS, dtype="int16",
                    latency="low", callback=self._callback, **kw)
                stream.start()
                self._stream = stream
                self.error = None
                return
            except Exception as e:
                self.error = str(e)

    def push(self, frame) -> None:
        for out in self._resampler.resample(frame):
            pcm = out.to_ndarray().reshape(-1, CHANNELS)
            if len(pcm):
                rms = float(np.sqrt(np.mean((pcm.astype(np.float32) / 32768) ** 2)))
                self.level = min(1.0, rms * 4)
            with self._lock:
                self._buf.append(pcm)
                self._buffered += len(pcm)
                while self._buffered > MAX_LATENCY * RATE and len(self._buf) > 1:
                    self._buffered -= len(self._buf.popleft())

    def _callback(self, outdata, frames, _time, _status) -> None:
        with self._lock:
            if not self._primed and self._buffered < TARGET_LATENCY * RATE:
                outdata.fill(0)
                return
            self._primed = True
            filled = 0
            while filled < frames and self._buf:
                chunk = self._buf[0]
                n = min(frames - filled, len(chunk))
                outdata[filled:filled + n] = chunk[:n]
                filled += n
                self._buffered -= n
                if n == len(chunk):
                    self._buf.popleft()
                else:
                    self._buf[0] = chunk[n:]
            if filled < frames:  # underrun: pad with silence and re-buffer
                outdata[filled:] = 0
                self._primed = False

    def silence(self) -> None:
        with self._lock:
            self._buf.clear()
            self._buffered = 0
            self._primed = False
        self.level = 0.0

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None
