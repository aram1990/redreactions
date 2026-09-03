<#
.SYNOPSIS
  Explicitly starts (or resumes) the 24-hour LIVE auto-publish pilot. Does not start any process
  itself — the already-installed hourly scheduled task performs the actual runs. Requires typed
  confirmation unless -Force is passed.
.PARAMETER Resume
  Resume the CURRENT remaining pilot window instead of starting a fresh 24h window: keeps
  pilotStartedAt/pilotEndsAt and every counter (autoPublishedCount, evaluator-call window, etc)
  exactly as they are and only flips mode/active back on. Only valid when pilot.json still has a
  pilotEndsAt in the future (e.g. the pilot was paused with disable-pilot.ps1 mid-window, as
  happened during this real test) — if that window has already expired, -Resume refuses and
  tells you to omit it, which starts a fresh 24h window instead.
#>
param([switch]$Force, [switch]$Resume)
. "$PSScriptRoot\lib\common.ps1"

$pilot = Get-RRPilot
$config = Get-RRConfig
$now = (Get-Date).ToUniversalTime()

if ($Resume) {
  if (-not $pilot.pilotEndsAt) {
    Write-Host "Cannot resume: pilot.json has no pilotEndsAt (no pilot has ever been started). Run without -Resume to start a fresh 24h window." -ForegroundColor Red
    exit 1
  }
  $ends = [DateTime]::Parse($pilot.pilotEndsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
  if ($now -ge $ends) {
    Write-Host "Cannot resume: the previous pilot window ended at $($pilot.pilotEndsAt), which is in the past. Run without -Resume to start a fresh 24h window instead — that resets autoPublishedCount and the evaluator-call window to 0." -ForegroundColor Red
    exit 1
  }

  Write-Host "==================================================================" -ForegroundColor Yellow
  Write-Host " RED REACTIONS — RESUME THE CURRENT LIVE PILOT WINDOW" -ForegroundColor Yellow
  Write-Host "==================================================================" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "This will:"
  Write-Host "  - Switch pilot.json mode back to 'live' / active: true"
  Write-Host "  - Keep the EXISTING window: started $($pilot.pilotStartedAt), still ends $($pilot.pilotEndsAt) ($([Math]::Round(($ends - $now).TotalHours,1))h remaining)"
  Write-Host "  - Keep the EXISTING counters as-is: $($pilot.autoPublishedCount)/$($pilot.maximumAutoPublished) articles published so far, $($pilot.evaluatorRunsInWindow)/$($config.maxEvaluatorClaudeRunsPer24h) evaluator calls used in the current window"
  Write-Host "  - NOT reset anything — this is a resume, not a new pilot"
  Write-Host ""
  Write-Host "Make sure the hourly task is installed (install-task.ps1) and this computer will" -ForegroundColor Yellow
  Write-Host "stay awake and logged in for the automation to actually run." -ForegroundColor Yellow
  Write-Host ""

  if (-not $Force) {
    $answer = Read-Host "Type RESUME PILOT to continue (anything else cancels)"
    if ($answer -ne 'RESUME PILOT') { Write-Host "Cancelled. No changes made."; exit 0 }
  }

  $pilot.mode = 'live'
  $pilot.active = $true
  Save-RRPilot $pilot

  Write-Host ""
  Write-Host "LIVE PILOT RESUMED. Still ends at $($pilot.pilotEndsAt) (UTC)." -ForegroundColor Green
  Write-Host "Run .\status.ps1 any time to check progress. Run .\disable-pilot.ps1 to stop immediately." -ForegroundColor Green
  exit 0
}

Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host " RED REACTIONS — ENABLE 24-HOUR LIVE AUTO-PUBLISH PILOT (FRESH WINDOW)" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host ""
if ($pilot.pilotEndsAt) {
  $ends = $null
  try { $ends = [DateTime]::Parse($pilot.pilotEndsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {}
  if ($ends -and $now -lt $ends) {
    Write-Host "NOTE: pilot.json has an existing window that hasn't expired yet (ends $($pilot.pilotEndsAt), $([Math]::Round(($ends-$now).TotalHours,1))h remaining) with $($pilot.autoPublishedCount) already published." -ForegroundColor Yellow
    Write-Host "Continuing here starts a BRAND NEW 24h window and resets those counters to 0. If you meant to resume the existing window instead, cancel and re-run with -Resume." -ForegroundColor Yellow
    Write-Host ""
  }
}
Write-Host "This will:"
Write-Host "  - Switch pilot.json mode from 'dry-run' to 'live'"
Write-Host "  - Start a FRESH 24-hour window (ends automatically at $((Get-Date).ToUniversalTime().AddHours($config.pilotDurationHours).ToString('o')))"
Write-Host "  - Reset the auto-publication counter to 0 / $($config.maxAutoPublish)"
Write-Host "  - Reset the evaluator Claude-call cap to 0 / $($config.maxEvaluatorClaudeRunsPer24h) for a fresh window"
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

$pilot.mode = 'live'
$pilot.active = $true
$pilot.pilotStartedAt = $now.ToString('o')
$pilot.pilotEndsAt = $now.AddHours($config.pilotDurationHours).ToString('o')
$pilot.autoPublishedCount = 0
$pilot.maximumAutoPublished = $config.maxAutoPublish
$pilot.evaluatorRunsWindowStart = $now.ToString('o')
$pilot.evaluatorRunsInWindow = 0
Save-RRPilot $pilot

Write-Host ""
Write-Host "LIVE PILOT ENABLED (fresh window). Ends at $($pilot.pilotEndsAt) (UTC)." -ForegroundColor Green
Write-Host "Run .\status.ps1 any time to check progress. Run .\disable-pilot.ps1 to stop immediately." -ForegroundColor Green
