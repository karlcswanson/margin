# Runs one Margin workspace daemon on Windows: a scheduled task that starts it
# when you log on and starts it again if it stops.
#
# Once, in daemon\ (Python 3.11 or newer):
#   py -3 -m venv .venv
#   .venv\Scripts\pip install -e .            # pywinpty and psutil come with it on Windows
#   .venv\Scripts\margind token               # a device token for the TOML's `tokens`
#   copy workspaces\main.example.toml workspaces\main.toml   # then edit it
#
# Then, per workspace (no admin needed):
#   powershell -ExecutionPolicy Bypass -File deploy\windows\install-workspace.ps1 -Name main
# and pair the iPad with the link (or QR code) from:
#   .venv\Scripts\margind pair -c workspaces\main.toml --url https://<this computer>:8787
#
# A logon task (not a service) runs as you, so Claude Code sees your normal
# login, git credentials and PATH. Output goes to %USERPROFILE%\.margin\logs\.
# Windows Firewall asks about python.exe the first time the daemon listens on
# a network address (any `bind` other than 127.0.0.1).
# Remove it with:  Unregister-ScheduledTask -TaskName "Margin main"
#
# The task runs this same script with -Run, which keeps margind going.

param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$Run
)

$daemon = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$exe    = Join-Path $daemon ".venv\Scripts\margind.exe"
$cfg    = Join-Path $daemon "workspaces\$Name.toml"
if (-not (Test-Path $exe)) { throw "margind not installed: $exe (see the top of this script)" }
if (-not (Test-Path $cfg)) { throw "config not found: $cfg" }

if ($Run) {
    $logs = Join-Path $env:USERPROFILE ".margin\logs"
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $env:PYTHONUTF8 = "1"        # files and pipes as UTF-8, as on macOS/Linux
    while ($true) {
        Start-Process -FilePath $exe -ArgumentList @("serve", "-c", "`"$cfg`"") -WorkingDirectory $daemon `
            -NoNewWindow -Wait `
            -RedirectStandardError (Join-Path $logs "$Name.log") `
            -RedirectStandardOutput (Join-Path $logs "$Name.out.log")
        Start-Sleep -Seconds 5   # it stopped: start it again
    }
}

$ps       = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Name `"$Name`" -Run"
$action   = New-ScheduledTaskAction -Execute $ps -Argument $taskArgs -WorkingDirectory $daemon
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName "Margin $Name" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName "Margin $Name"
Write-Host "Started 'Margin $Name'. Log: $(Join-Path $env:USERPROFILE ".margin\logs\$Name.log")"
