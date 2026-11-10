# Installs (or removes) PhoneCam's virtual camera + microphone. Run as administrator.
# Used by the installer, the uninstaller and the app's "Repair setup" button.
param([switch]$Uninstall)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$appExe = Join-Path (Split-Path -Parent $here) 'PhoneCam.exe'
$cameraName = 'Phone Camera'
$reg64 = Join-Path $env:SystemRoot 'System32\regsvr32.exe'
$reg32 = Join-Path $env:SystemRoot 'SysWOW64\regsvr32.exe'
$dll64 = Join-Path $here 'UnityCaptureFilter64.dll'
$dll32 = Join-Path $here 'UnityCaptureFilter32.dll'

function Run($exe, $argList) {
    $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

if ($Uninstall) {
    Run $reg64 "/s /u `"$dll64`"" | Out-Null
    if (Test-Path $reg32) { Run $reg32 "/s /u `"$dll32`"" | Out-Null }
    Run 'netsh.exe' 'advfirewall firewall delete rule name="PhoneCam"' | Out-Null
    # VB-Cable is left installed: other apps may use it. Remove it from
    # "Apps > Installed apps" if you no longer need it.
    exit 0
}

$failed = 0

# 1. Virtual camera (Unity Capture DirectShow filter, MIT licence), named "Phone Camera".
if ((Run $reg64 "/s `"/i:UnityCaptureName=$cameraName`" `"$dll64`"") -ne 0) { $failed++ }
if (Test-Path $reg32) { Run $reg32 "/s `"/i:UnityCaptureName=$cameraName`" `"$dll32`"" | Out-Null }

# 2. Virtual microphone (VB-Audio Virtual Cable). Windows shows one
#    "Install this device software?" prompt; that can't be skipped for any driver.
$haveCable = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*VB-Audio Virtual Cable*' }
if (-not $haveCable) {
    $setup = Join-Path $here 'vbcable\VBCABLE_Setup_x64.exe'
    if (Test-Path $setup) {
        Run $setup '-i -h' | Out-Null
    } else {
        $failed++
    }
}

# 3. Let phones' discovery broadcasts reach PhoneCam through Windows Firewall.
if (Test-Path $appExe) {
    Run 'netsh.exe' 'advfirewall firewall delete rule name="PhoneCam"' | Out-Null
    Run 'netsh.exe' "advfirewall firewall add rule name=`"PhoneCam`" dir=in action=allow program=`"$appExe`" enable=yes profile=any" | Out-Null
}

exit $failed
