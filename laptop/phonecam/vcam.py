"""Feeds phone video into the "Phone Camera" virtual webcam (Unity Capture driver)."""

import threading
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from . import CAMERA_NAME

WIDTH, HEIGHT, FPS = 1280, 720, 30
STALE_SECONDS = 1.0  # show the placeholder if no phone frame arrives for this long


def _placeholder(text: str) -> np.ndarray:
    img = Image.new("RGB", (WIDTH, HEIGHT), (17, 19, 21))
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("segoeui.ttf", 40)
        small = ImageFont.truetype("segoeui.ttf", 26)
    except OSError:
        font = small = ImageFont.load_default()
    draw.text((WIDTH / 2, HEIGHT / 2 - 24), "PhoneCam", fill=(232, 230, 227), font=font, anchor="mm")
    draw.text((WIDTH / 2, HEIGHT / 2 + 28), text, fill=(139, 144, 150), font=small, anchor="mm")
    return np.asarray(img)


class VirtualCamera:
    """Runs its own 30 fps thread and always sends a frame, so apps never freeze."""

    def __init__(self) -> None:
        self.error: str | None = None
        self.running = False
        self.fill = True  # crop to fill 16:9 (False = letterbox)
        self.mirror = False
        self.placeholder_text = "Waiting for your phone..."
        self._latest = None  # (av.VideoFrame, received_at)
        self._preview: np.ndarray | None = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._placeholders: dict[str, np.ndarray] = {}

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="vcam", daemon=True)
        self._thread.start()

    def push(self, frame) -> None:
        with self._lock:
            self._latest = (frame, time.monotonic())

    def preview(self) -> np.ndarray | None:
        with self._lock:
            return self._preview

    def convert(self, frame) -> np.ndarray:
        """Scales an av.VideoFrame to WIDTH x HEIGHT RGB (crop-to-fill or letterbox)."""
        w, h = frame.width, frame.height
        scale = max(WIDTH / w, HEIGHT / h) if self.fill else min(WIDTH / w, HEIGHT / h)
        sw = max(2, min(round(w * scale) & ~1, WIDTH if not self.fill else 10**6))
        sh = max(2, min(round(h * scale) & ~1, HEIGHT if not self.fill else 10**6))
        img = frame.reformat(width=sw, height=sh, format="rgb24").to_ndarray()
        out = np.zeros((HEIGHT, WIDTH, 3), np.uint8)
        if self.fill:
            x, y = max(0, (sw - WIDTH) // 2), max(0, (sh - HEIGHT) // 2)
            part = img[y:y + HEIGHT, x:x + WIDTH]
            out[: part.shape[0], : part.shape[1]] = part
        else:
            x, y = (WIDTH - sw) // 2, (HEIGHT - sh) // 2
            out[y:y + sh, x:x + sw] = img
        if self.mirror:
            out = np.ascontiguousarray(out[:, ::-1])
        return out

    def _placeholder_frame(self) -> np.ndarray:
        text = self.placeholder_text
        if text not in self._placeholders:
            self._placeholders[text] = _placeholder(text)
        return self._placeholders[text]

    def _run(self) -> None:
        import pyvirtualcam

        try:
            cam = pyvirtualcam.Camera(WIDTH, HEIGHT, FPS, backend="unitycapture", device=CAMERA_NAME)
        except Exception as e:  # driver not registered
            self.error = str(e)
            return
        self.running = True
        last_frame = None
        with cam:
            while not self._stop.is_set():
                with self._lock:
                    latest = self._latest
                    previous = self._preview
                out = None
                if latest and time.monotonic() - latest[1] < STALE_SECONDS:
                    frame = latest[0]
                    if frame is last_frame and previous is not None:
                        out = previous  # repeat last image until a new one arrives
                    else:
                        try:
                            out = self.convert(frame)
                        except Exception:
                            out = None
                        last_frame = frame
                if out is None:
                    out = self._placeholder_frame()
                with self._lock:
                    self._preview = out
                cam.send(out)
                cam.sleep_until_next_frame()
        self.running = False

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
