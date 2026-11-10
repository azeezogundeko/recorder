# Builds dist\PhoneCam-Setup.exe: the one installer for the laptop.
# Needs: Python 3.12 and Inno Setup 6 (winget install JRSoftware.InnoSetup).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Test-Path .venv)) {
    py -3.12 -m venv .venv
    .venv\Scripts\python -m pip install --upgrade pip
    .venv\Scripts\pip install -r requirements.txt
}
$py = Resolve-Path .venv\Scripts\python.exe

# --- third-party drivers bundled into the installer ---
$drivers = 'build\drivers'
New-Item -ItemType Directory -Force $drivers | Out-Null

# Unity Capture virtual camera filter (MIT licence).
$uc = 'https://github.com/schellingb/UnityCapture/raw/master'
foreach ($f in 'UnityCaptureFilter64.dll', 'UnityCaptureFilter32.dll') {
    if (-not (Test-Path "$drivers\$f")) { Invoke-WebRequest "$uc/Install/$f" -OutFile "$drivers\$f" }
}
if (-not (Test-Path "$drivers\UnityCapture-README.md")) {
    # Licence (MIT for the filter) is stated in the README.
    Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/schellingb/UnityCapture/master/README.md" -OutFile "$drivers\UnityCapture-README.md"
}

# VB-Audio Virtual Cable (donationware - see vb-audio.com/Cable for licensing).
if (-not (Test-Path "$drivers\vbcable\VBCABLE_Setup_x64.exe")) {
    Invoke-WebRequest 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack46.zip' -OutFile build\vbcable.zip
    Expand-Archive build\vbcable.zip -DestinationPath "$drivers\vbcable" -Force
}

Copy-Item installer\setup_drivers.ps1 $drivers -Force
& $py tools\make_icon.py build\phonecam.ico

# --- app exe ---
# Native tools log to stderr; don't let PowerShell treat that as failure.
$ErrorActionPreference = 'Continue'
& $py -m PyInstaller --noconfirm --clean --windowed --name PhoneCam `
    --icon "$PSScriptRoot\build\phonecam.ico" `
    --collect-all aiortc --collect-binaries av --collect-binaries pylibsrtp `
    --collect-all pyvirtualcam --collect-all sounddevice `
    --hidden-import pyvirtualcam._native_windows_unity_capture `
    --distpath dist --workpath build\pyinstaller --specpath build `
    main.py
if ($LASTEXITCODE -ne 0) { throw 'PyInstaller failed' }

# --- installer ---
$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found. Install it: winget install JRSoftware.InnoSetup' }
& $iscc installer\phonecam.iss
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
Write-Host "`nDone: $(Resolve-Path dist\PhoneCam-Setup.exe)"

