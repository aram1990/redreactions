<#
.SYNOPSIS
  Registers an hourly Windows Scheduled Task that runs watch.ps1. Safe to run multiple times
  (re-registers). Does not enable the live pilot by itself — watch.ps1 stays in dry-run/report
  mode until enable-pilot.ps1 is run separately.
#>
param([string]$TaskName = 'RedReactions-RRWatch')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$watchScript = Join-Path $PSScriptRoot 'watch.ps1'

if (-not (Test-Path $watchScript)) { throw "watch.ps1 not found at $watchScript" }

# Prefer pwsh.exe (PowerShell 7+) when it's actually installed, since it's the currently
# supported runtime; otherwise fall back to Windows PowerShell 5.1's powershell.exe, which the
# scripts in this folder are written to run correctly under (no PS7-only syntax is used anywhere
# in automation/rr-watch). Whichever one Task Scheduler will use is exactly the same executable
# preflight.ps1 reports, so run that first if you want to confirm before installing.
$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwshCmd) { $shellExe = $pwshCmd.Source } else { $shellExe = 'powershell.exe' }

$action = New-ScheduledTaskAction -Execute $shellExe `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$watchScript`"" `
  -WorkingDirectory $repoRoot

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
  -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -RestartCount 0

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' — runs watch.ps1 hourly via $shellExe." -ForegroundColor Green
Write-Host "It runs only while $env:USERNAME is logged on to this machine, and 'IgnoreNew' means a run"
Write-Host "already in progress blocks a new one from starting (belt-and-braces alongside watch.ps1's own lock file)."
Write-Host ""
Write-Host "This installs WATCH-MODE scheduling only. Live auto-publishing still requires running"
Write-Host ".\enable-pilot.ps1 separately, and it auto-disables 24 hours later regardless of this task."
Write-Host ""
Write-Host "Remove with: .\remove-task.ps1"
