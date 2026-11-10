"""End-to-end check of the laptop side without a phone or drivers.

Starts the fake phone, lets PhoneCam's controller discover it, connect over
WebRTC and receive video + audio, then checks frames arrived and convert well.
"""

import asyncio
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from phonecam.gui import Controller  # noqa: E402
from phonecam.vcam import HEIGHT, WIDTH, VirtualCamera  # noqa: E402


class FakeMic:
    def __init__(self):
        self.frames = 0

    def push(self, frame):
        self.frames += 1

    def silence(self):
        pass


def main() -> int:
    phone = subprocess.Popen([sys.executable, str(ROOT / "tools" / "fake_phone.py")])
    try:
        vcam = VirtualCamera()  # not started: no driver needed, we only collect frames
        video = []
        vcam.push = video.append
        mic = FakeMic()
        ctrl = Controller(vcam, mic)
        ctrl.start()

        deadline = time.time() + 25
        while time.time() < deadline and not (len(video) > 30 and mic.frames > 50):
            time.sleep(0.25)

        print(f"discovered: {[p.name for p in ctrl.phones]}")
        print(f"state: {ctrl.state}, phone: {ctrl.phone_name}")
        print(f"video frames: {len(video)}, audio frames: {mic.frames}")
        ok = ctrl.state == "live" and len(video) > 30 and mic.frames > 50
        if video:
            f = video[-1]
            out = vcam.convert(f)
            print(f"incoming {f.width}x{f.height} -> virtual camera {out.shape[1]}x{out.shape[0]}")
            ok = ok and out.shape == (HEIGHT, WIDTH, 3)
            vcam.fill = False
            ok = ok and vcam.convert(f).shape == (HEIGHT, WIDTH, 3)
        print("PASS" if ok else "FAIL")
        return 0 if ok else 1
    finally:
        phone.terminate()


if __name__ == "__main__":
    sys.exit(main())
