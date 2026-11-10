# WiFi Mic + PhoneCam

Use your Android phone as a **webcam and microphone** for Loom, Zoom, Meet or Teams on a Windows laptop, over WiFi.

- `lib/` – **WiFi Mic**, the Flutter phone app (Android).
- `laptop/` – **PhoneCam**, the Windows companion app + installer.

## Use it

1. Install `build/app/outputs/flutter-apk/app-release.apk` on the phone.
2. Run `laptop/dist/PhoneCam-Setup.exe` on the laptop (one time). Approve the Windows driver prompt.
3. Put both on the same WiFi (or connect the laptop to the phone's hotspot).
4. Open **WiFi Mic** on the phone and **PhoneCam** on the laptop. They find each other and start automatically.
5. In Loom pick **Camera: Phone Camera** and **Microphone: CABLE Output (VB-Audio Virtual Cable)**. Loom remembers this.

Phone controls: camera + mic or mic only, 720p/1080p, front/back switch, flashlight, pinch to zoom, mic mute.

No laptop app? Open the address shown on the phone in any browser to watch and record.

## Build

Phone: `flutter build apk --release`

Laptop: `laptop\build.ps1` (needs Python 3.12 and Inno Setup 6) → `laptop\dist\PhoneCam-Setup.exe`

Test the laptop side without a phone: `laptop\.venv\Scripts\python laptop\tools\selftest.py`

## How it works

The phone sends camera + mic over WebRTC (hardware-encoded, low delay) and announces itself on UDP port 47800.
PhoneCam receives it, writes video into the "Phone Camera" virtual webcam (Unity Capture driver, MIT) and audio into VB-Audio Virtual Cable.

## Third-party drivers

- Unity Capture – MIT licence.
- VB-Audio Virtual Cable – donationware by VB-Audio. Fine for personal use; ask VB-Audio for a licence before distributing the installer to others.
