"""PhoneCam entry point."""

import ctypes
import logging
import sys

from phonecam.gui import App


def already_running() -> bool:
    # Only one PhoneCam may own the virtual camera at a time.
    ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\PhoneCamSingleInstance")
    return ctypes.windll.kernel32.GetLastError() == 183  # ERROR_ALREADY_EXISTS


def main() -> None:
    logging.basicConfig(level=logging.WARNING)
    if already_running():
        ctypes.windll.user32.MessageBoxW(None, "PhoneCam is already running.", "PhoneCam", 0x40)
        return
    App(start_minimized="--minimized" in sys.argv).run()


if __name__ == "__main__":
    main()
