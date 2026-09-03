<#
.SYNOPSIS
  Explicitly starts the 24-hour LIVE auto-publish pilot. Does not start any process itself —
  the already-installed hourly scheduled task performs the actual runs. Requires typed
  confirmation unless -Force is passed.
#>
param([switch]$Force)
. "$PSScriptRoot\lib\common.ps1"

$pilot = Get-RRPilot
$config = Get-RRConfig

Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host " RED REACTIONS — ENABLE 24-HOUR LIVE AUTO-PUBLISH PILOT" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "This will:"
Write-Host "  - Switch pilot.json mode from 'dry-run' to 'live'"
Write-Host "  - Start a 24-hour window (ends automatically at $((Get-Date).ToUniversalTime().AddHours($config.pilotDurationHours).ToString('o')))"
Write-Host "  - Reset the auto-publication counter to 0 / $($config.maxAutoPublish)"
Write-Host "  - Allow the hourly scheduled task (if installed) to have Claude Code write,"
Write-Host "    commit, push, and deploy up to $($config.maxAutoPublish) strictly-eligible articles unattended."
Write-Host "  - Social copy is still only ever drafted, never auto-posted."
Write-Host ""
Write-Host "Make sure the hourly task is installed (install-task.ps1) and this computer will" -ForegroundColor Yellow
Write-Host "stay awake and logged in for the automation to actually run." -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
  $answer = Read-Host "Type START PILOT to continue (anything else cancels)"
  if ($answer -ne 'START PILOT') { Write-Host "Cancelled. No changes made."; exit 0 }
}

$now = (Get-Date).ToUniversalTime()
$pilot.mode = 'live'
$pilot.active = $true
$pilot.pilotStartedAt = $now.ToString('o')
$pilot.pilotEndsAt = $now.AddHours($config.pilotDurationHours).ToString('o')
$pilot.autoPublishedCount = 0
$pilot.maximumAutoPublished = $config.maxAutoPublish
Save-RRPilot $pilot

Write-Host ""
Write-Host "LIVE PILOT ENABLED. Ends at $($pilot.pilotEndsAt) (UTC)." -ForegroundColor Green
Write-Host "Run .\status.ps1 any time to check progress. Run .\disable-pilot.ps1 to stop immediately." -ForegroundColor Green
