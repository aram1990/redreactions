<#
.SYNOPSIS
  Registers an hourly Windows Scheduled Task that runs watch.ps1. Safe to run multiple times
  (re-registers). Does not enable the live pilot by itself — watch.ps1 stays in dry-run/report
  mode until enable-pilot.ps1 is run separately.

  Only ever reports success once Register-ScheduledTask has actually succeeded AND the task can
  be read back with Get-ScheduledTask — a prior version of this script printed a green "Installed"
  message even when Windows Task Scheduler had rejected the trigger outright (an invalid
  ~[TimeSpan]::MaxValue repetition duration). That is fixed below: a bounded, valid duration is
  used, and every failure path prints failure and exits non-zero instead.
#>
param([string]$TaskName = 'RedReactions-RRWatch', [int]$RepetitionDurationDays = 2)

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$watchScript = Join-Path $PSScriptRoot 'watch.ps1'

if (-not (Test-Path $watchScript)) { Write-Host "watch.ps1 not found at $watchScript" -ForegroundColor Red; exit 1 }

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

# A repetition duration must be a bounded, Task-Scheduler-representable TimeSpan. [TimeSpan]::MaxValue
# (~10,675,199 days) is NOT valid here and Windows silently rejects the trigger/registration call
# built from it. Days$RepetitionDurationDays (default 2 — more than enough for this pilot) keeps the
# task safely within supported range; re-run this script (or increase -RepetitionDurationDays) to
# extend watch-mode scheduling further, since the task naturally stops repeating once its duration
# elapses from StartBoundary.
$repetitionDuration = New-TimeSpan -Days $RepetitionDurationDays
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration $repetitionDuration

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
  -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -RestartCount 0

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

try {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
} catch {
  Write-Host "FAILED to register scheduled task '$TaskName': $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

# Never trust the registration call alone — verify the task actually exists and carries the
# repetition we asked for before claiming success.
$verify = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $verify) {
  Write-Host "FAILED: Register-ScheduledTask reported no error, but '$TaskName' cannot be read back with Get-ScheduledTask. Treating this as a failed install." -ForegroundColor Red
  exit 1
}
$verifiedRepetition = $verify.Triggers[0].Repetition
if (-not $verifiedRepetition -or -not $verifiedRepetition.Interval) {
  Write-Host "FAILED: '$TaskName' was registered, but its trigger has no repetition interval — it would only ever run once. Treating this as a failed install." -ForegroundColor Red
  exit 1
}

Write-Host "Installed scheduled task '$TaskName' — runs watch.ps1 hourly via $shellExe." -ForegroundColor Green
Write-Host "Verified via Get-ScheduledTask: repeats every $($verifiedRepetition.Interval) for $($verifiedRepetition.Duration)."
Write-Host "It runs only while $env:USERNAME is logged on to this machine, and 'IgnoreNew' means a run"
Write-Host "already in progress blocks a new one from starting (belt-and-braces alongside watch.ps1's own lock file)."
Write-Host ""
Write-Host "This installs WATCH-MODE scheduling only. Live auto-publishing still requires running"
Write-Host ".\enable-pilot.ps1 separately, and it auto-disables 24 hours later regardless of this task."
Write-Host "The task itself stops repeating after $RepetitionDurationDays day(s) — re-run this script"
Write-Host "(optionally with a different -RepetitionDurationDays) to keep watch-mode scheduling going."
Write-Host ""
Write-Host "Remove with: .\remove-task.ps1"
