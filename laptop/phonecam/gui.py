"""PhoneCam window: finds the phone, shows a preview and the Loom/Zoom device names."""

import asyncio
import ctypes
import logging
import sys
import threading
import tkinter as tk
from ctypes import wintypes
from pathlib import Path
from tkinter import ttk

from PIL import Image, ImageTk

from . import APP_NAME, CAMERA_NAME
from .discovery import start_discovery
from .session import PhoneSession
from .vcam import VirtualCamera
from .vmic import VirtualMic

log = logging.getLogger(__name__)

BG, PANEL, TEXT, MUTED, ACCENT, WARN, ERR = (
    "#111315", "#1a1d20", "#e8e6e3", "#8b9096", "#3ddc97", "#e6b24a", "#ff6b6b")
PREVIEW_W, PREVIEW_H = 416, 234

STATUS_TEXT = {
    "searching": ("Looking for your phone...", WARN),
    "connecting": ("Connecting to {name}...", WARN),
    "idle": ("Connected to {name} - press Start on the phone", WARN),
    "live": ("Live from {name}", ACCENT),
    "disconnected": ("Lost {name} - reconnecting...", WARN),
}


def drivers_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent / "drivers"
    return Path(__file__).resolve().parent.parent / "build" / "drivers"


def run_elevated_and_wait(exe: str, params: str) -> int | None:
    """Runs a program as administrator (UAC prompt) and waits. Returns exit code."""

    class SHELLEXECUTEINFOW(ctypes.Structure):
        _fields_ = [
            ("cbSize", wintypes.DWORD), ("fMask", ctypes.c_ulong), ("hwnd", wintypes.HWND),
            ("lpVerb", wintypes.LPCWSTR), ("lpFile", wintypes.LPCWSTR),
            ("lpParameters", wintypes.LPCWSTR), ("lpDirectory", wintypes.LPCWSTR),
            ("nShow", ctypes.c_int), ("hInstApp", wintypes.HINSTANCE), ("lpIDList", ctypes.c_void_p),
            ("lpClass", wintypes.LPCWSTR), ("hkeyClass", wintypes.HKEY), ("dwHotKey", wintypes.DWORD),
            ("hIconOrMonitor", wintypes.HANDLE), ("hProcess", wintypes.HANDLE)]

    info = SHELLEXECUTEINFOW()
    info.cbSize = ctypes.sizeof(info)
    info.fMask = 0x00000040  # SEE_MASK_NOCLOSEPROCESS
    info.lpVerb, info.lpFile, info.lpParameters, info.nShow = "runas", exe, params, 0
    if not ctypes.windll.shell32.ShellExecuteExW(ctypes.byref(info)):
        return None  # user said no to UAC
    ctypes.windll.kernel32.WaitForSingleObject(info.hProcess, 0xFFFFFFFF)
    code = wintypes.DWORD()
    ctypes.windll.kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
    ctypes.windll.kernel32.CloseHandle(info.hProcess)
    return code.value


class Controller:
    """Async side: discovery + the active phone session. Lives on its own thread."""

    def __init__(self, vcam: VirtualCamera, vmic: VirtualMic) -> None:
        self.vcam, self.vmic = vcam, vmic
        self.loop = asyncio.new_event_loop()
        self.phones = []
        self.discovery_error: str | None = None
        self.state, self.phone_name = "searching", None
        self.manual_target: tuple[str, int] | None = None
        self.chosen_key: str | None = None
        self._session: PhoneSession | None = None
        self._session_task: asyncio.Task | None = None
        self._target: tuple[str, int] | None = None

    def start(self) -> None:
        threading.Thread(target=self._thread_main, name="asyncio", daemon=True).start()

    def _thread_main(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self._main())

    def _on_status(self, state: str, name: str | None) -> None:
        self.state, self.phone_name = state, name or self.phone_name
        if state != "live":
            self.vmic.silence()
        self.vcam.placeholder_text = {
            "idle": "Press Start on your phone",
            "live": "Waiting for video...",
        }.get(state, "Waiting for your phone...")

    async def _main(self) -> None:
        discovery = await start_discovery()
        self.discovery_error = discovery.error
        while True:
            self.phones = discovery.phones()
            target = self._pick_target()
            if target != self._target:
                await self._switch(target)
            await asyncio.sleep(0.5)

    def _pick_target(self) -> tuple[str, int] | None:
        if self.manual_target:
            return self.manual_target
        if not self.phones:
            # Keep the current phone while its beacon briefly drops out.
            return self._target if self.state in ("live", "idle", "connecting") else None
        for p in self.phones:
            if p.key == self.chosen_key:
                return (p.ip, p.port)
        if self._target and any((p.ip, p.port) == self._target for p in self.phones):
            return self._target
        p = self.phones[0]
        return (p.ip, p.port)

    async def _switch(self, target) -> None:
        if self._session:
            await self._session.stop()
        if self._session_task:
            self._session_task.cancel()
        self._session = self._session_task = None
        self._target = target
        self.vmic.silence()
        if target is None:
            self.state, self.phone_name = "searching", None
            self.vcam.placeholder_text = "Waiting for your phone..."
            return
        self.phone_name = next((p.name for p in self.phones if (p.ip, p.port) == target), target[0])
        self._session = PhoneSession(target[0], target[1], self.vcam.push, self.vmic.push, self._on_status)
        self._session_task = asyncio.ensure_future(self._session.run())


class App:
    def __init__(self, start_minimized: bool = False) -> None:
        self.vcam = VirtualCamera()
        self.vmic = VirtualMic()
        self.vcam.start()
        self.vmic.start()
        self.ctrl = Controller(self.vcam, self.vmic)
        self.ctrl.start()

        self.root = tk.Tk()
        self.root.title(APP_NAME)
        self.root.configure(bg=BG)
        self.root.resizable(False, False)
        icon = drivers_dir().parent / "phonecam.ico"
        if icon.exists():
            self.root.iconbitmap(str(icon))
        self._build()
        self._photo = None
        self._repairing = False
        self.root.protocol("WM_DELETE_WINDOW", self.quit)
        if start_minimized:
            self.root.iconify()
        self._tick()

    # ---------- layout ----------

    def _build(self) -> None:
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("TCombobox", fieldbackground=PANEL, background=PANEL, foreground=TEXT, arrowcolor=TEXT)
        style.configure("Meter.Horizontal.TProgressbar", troughcolor="#0c0e10", background=ACCENT,
                        bordercolor=PANEL, lightcolor=ACCENT, darkcolor=ACCENT)
        pad = {"padx": 16}

        tk.Label(self.root, text=APP_NAME, bg=BG, fg=TEXT, font=("Segoe UI Semibold", 16)).pack(anchor="w", pady=(14, 0), **pad)
        self.status = tk.Label(self.root, text="", bg=BG, fg=WARN, font=("Segoe UI", 10))
        self.status.pack(anchor="w", **pad)

        self.canvas = tk.Label(self.root, bg="#000", width=PREVIEW_W, height=PREVIEW_H)
        self.canvas.pack(pady=(10, 6), **pad)
        self.meter = ttk.Progressbar(self.root, style="Meter.Horizontal.TProgressbar", maximum=100, length=PREVIEW_W)
        self.meter.pack(**pad)
        tk.Label(self.root, text="Mic level", bg=BG, fg=MUTED, font=("Segoe UI", 8)).pack(anchor="w", **pad)

        # Phone picker
        row = tk.Frame(self.root, bg=BG)
        row.pack(fill="x", pady=(10, 0), **pad)
        tk.Label(row, text="Phone", bg=BG, fg=MUTED, font=("Segoe UI", 9), width=8, anchor="w").pack(side="left")
        self.phone_var = tk.StringVar()
        self.phone_box = ttk.Combobox(row, textvariable=self.phone_var, state="readonly", width=34)
        self.phone_box.pack(side="left")
        self.phone_box.bind("<<ComboboxSelected>>", self._on_pick)

        row2 = tk.Frame(self.root, bg=BG)
        row2.pack(fill="x", pady=(6, 0), **pad)
        tk.Label(row2, text="or IP", bg=BG, fg=MUTED, font=("Segoe UI", 9), width=8, anchor="w").pack(side="left")
        self.ip_var = tk.StringVar()
        ip_entry = tk.Entry(row2, textvariable=self.ip_var, bg=PANEL, fg=TEXT, insertbackground=TEXT,
                            relief="flat", width=24)
        ip_entry.pack(side="left", ipady=3)
        ip_entry.bind("<Return>", lambda _e: self._connect_ip())
        self._button(row2, "Connect", self._connect_ip).pack(side="left", padx=(6, 0))
        self._button(row2, "Auto", self._auto).pack(side="left", padx=(6, 0))

        # Video options
        row3 = tk.Frame(self.root, bg=BG)
        row3.pack(fill="x", pady=(8, 0), **pad)
        tk.Label(row3, text="Video", bg=BG, fg=MUTED, font=("Segoe UI", 9), width=8, anchor="w").pack(side="left")
        self.fill_var = tk.BooleanVar(value=True)
        self.mirror_var = tk.BooleanVar(value=False)
        for text, value in (("Fill frame", True), ("Show whole image", False)):
            tk.Radiobutton(row3, text=text, value=value, variable=self.fill_var, command=self._apply_opts,
                           bg=BG, fg=TEXT, selectcolor=PANEL, activebackground=BG, activeforeground=TEXT,
                           font=("Segoe UI", 9)).pack(side="left")
        tk.Checkbutton(row3, text="Mirror", variable=self.mirror_var, command=self._apply_opts,
                       bg=BG, fg=TEXT, selectcolor=PANEL, activebackground=BG, activeforeground=TEXT,
                       font=("Segoe UI", 9)).pack(side="left")

        # Setup + how to use
        box = tk.Frame(self.root, bg=PANEL, padx=12, pady=10)
        box.pack(fill="x", pady=(14, 16), **pad)
        tk.Label(box, text="In Loom, Zoom, Meet or Teams choose:", bg=PANEL, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w")
        self.cam_line = tk.Label(box, text="", bg=PANEL, fg=TEXT, font=("Segoe UI", 10), anchor="w", justify="left")
        self.cam_line.pack(anchor="w", pady=(4, 0))
        self.mic_line = tk.Label(box, text="", bg=PANEL, fg=TEXT, font=("Segoe UI", 10), anchor="w", justify="left")
        self.mic_line.pack(anchor="w")
        self.repair_btn = self._button(box, "Repair setup", self._repair)

    def _button(self, parent, text, command) -> tk.Button:
        return tk.Button(parent, text=text, command=command, bg="#23272b", fg=TEXT, activebackground="#2b3035",
                         activeforeground=TEXT, relief="flat", padx=10, pady=2, font=("Segoe UI", 9), cursor="hand2")

    # ---------- actions ----------

    def _apply_opts(self) -> None:
        self.vcam.fill = self.fill_var.get()
        self.vcam.mirror = self.mirror_var.get()

    def _on_pick(self, _e=None) -> None:
        idx = self.phone_box.current()
        if 0 <= idx < len(self.ctrl.phones):
            self.ctrl.manual_target = None
            self.ctrl.chosen_key = self.ctrl.phones[idx].key

    def _connect_ip(self) -> None:
        text = self.ip_var.get().strip().removeprefix("http://").rstrip("/")
        if not text:
            return
        host, _, port = text.partition(":")
        self.ctrl.manual_target = (host, int(port) if port.isdigit() else 8080)

    def _auto(self) -> None:
        self.ip_var.set("")
        self.ctrl.manual_target = None
        self.ctrl.chosen_key = None

    def _repair(self) -> None:
        if self._repairing:
            return
        script = drivers_dir() / "setup_drivers.ps1"
        if not script.exists():
            self.status.configure(text=f"Setup script missing: {script}", fg=ERR)
            return
        self._repairing = True
        self.repair_btn.configure(text="Repairing...", state="disabled")

        def work():
            run_elevated_and_wait("powershell.exe",
                                  f'-NoProfile -ExecutionPolicy Bypass -File "{script}"')
            self.root.after(0, self._after_repair)

        threading.Thread(target=work, daemon=True).start()

    def _after_repair(self) -> None:
        self._repairing = False
        self.repair_btn.configure(text="Repair setup", state="normal")
        if not self.vcam.running:
            self.vcam = VirtualCamera()
            self._apply_opts()
            self.vcam.start()
            self.ctrl.vcam = self.vcam
        if not self.vmic.running:
            self.vmic = VirtualMic()
            self.vmic.start()
            self.ctrl.vmic = self.vmic
        if self.ctrl._session:
            self.ctrl._session.on_video = self.vcam.push
            self.ctrl._session.on_audio = self.vmic.push

    # ---------- refresh loop ----------

    def _tick(self) -> None:
        c = self.ctrl
        if c.discovery_error and c.state == "searching":
            self.status.configure(text=c.discovery_error + " - type the phone's IP below.", fg=ERR)
        else:
            text, color = STATUS_TEXT.get(c.state, STATUS_TEXT["searching"])
            self.status.configure(text=text.format(name=c.phone_name or "phone"), fg=color)

        names = [f"{p.name}  ({p.ip})" for p in c.phones] or ["No phones found yet"]
        if tuple(self.phone_box["values"]) != tuple(names):
            self.phone_box["values"] = names
        current = next((i for i, p in enumerate(c.phones) if (p.ip, p.port) == c._target), None)
        self.phone_var.set(names[current] if current is not None else names[0] if not c.phones else "")

        frame = self.vcam.preview()
        if frame is not None:
            img = Image.fromarray(frame).resize((PREVIEW_W, PREVIEW_H), Image.BILINEAR)
            self._photo = ImageTk.PhotoImage(img)
            self.canvas.configure(image=self._photo, width=PREVIEW_W, height=PREVIEW_H)
        self.meter["value"] = self.vmic.level * 100 if c.state == "live" else 0

        cam_ok = self.vcam.running
        mic_ok = self.vmic.running
        self.cam_line.configure(
            text=f"Camera  ->  {CAMERA_NAME}" if cam_ok or not self.vcam.error else
            "Camera  ->  driver missing (click Repair setup)",
            fg=TEXT if cam_ok or not self.vcam.error else ERR)
        self.mic_line.configure(
            text="Microphone  ->  CABLE Output (VB-Audio Virtual Cable)" if mic_ok else
            "Microphone  ->  VB-Cable missing (click Repair setup)",
            fg=TEXT if mic_ok else ERR)
        broken = (self.vcam.error and not cam_ok) or not mic_ok
        if broken and not self.repair_btn.winfo_ismapped():
            self.repair_btn.pack(anchor="w", pady=(8, 0))
        elif not broken and self.repair_btn.winfo_ismapped():
            self.repair_btn.pack_forget()

        self.root.after(100, self._tick)

    def quit(self) -> None:
        self.vcam.stop()
        self.vmic.stop()
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()
