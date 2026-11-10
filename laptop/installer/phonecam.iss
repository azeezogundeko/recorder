; PhoneCam installer (Inno Setup 6). Built by build.ps1 - don't run directly.
#define AppName "PhoneCam"
#define AppVersion "1.0.0"

[Setup]
AppId={{6C1E2A7B-5B7E-4C2B-9A55-3F1D2E8C4B90}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=PhoneCam
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=PhoneCam-Setup
SetupIconFile=..\build\phonecam.ico
UninstallDisplayIcon={app}\PhoneCam.exe
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UsedUserAreasWarning=no
CloseApplications=yes

[Tasks]
Name: "autostart"; Description: "Start PhoneCam automatically when I sign in to Windows"
Name: "desktopicon"; Description: "Create a desktop shortcut"

[Files]
Source: "..\dist\PhoneCam\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
Source: "..\build\drivers\*"; DestDir: "{app}\drivers"; Flags: recursesubdirs ignoreversion
Source: "..\build\phonecam.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\PhoneCam.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\PhoneCam.exe"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\PhoneCam.exe"; Parameters: "--minimized"; Tasks: autostart

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\drivers\setup_drivers.ps1"""; StatusMsg: "Setting up the Phone Camera and virtual microphone (approve the driver prompt if Windows asks)..."; Flags: runhidden waituntilterminated
Filename: "{app}\PhoneCam.exe"; Description: "Open PhoneCam now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\drivers\setup_drivers.ps1"" -Uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveDrivers"
