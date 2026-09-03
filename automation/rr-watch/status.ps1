<#
.SYNOPSIS
  Prints current pilot status. With -FinalReport, writes the 24-hour pilot summary report
  (called automatically by watch.ps1 the moment the pilot expires; can also be run manually).
#>
param([switch]$FinalReport, $Pilot)

. "$PSScriptRoot\lib\common.ps1"

if (-not $Pilot) { $Pilot = Get-RRPilot }
$queue = Get-RRQueue
$queuedCount = @($queue.items | Where-Object { $_.status -eq 'queued' }).Count
$retryCount = @($queue.items | Where-Object { $_.status -eq 'pending-retry' }).Count

$latestLog = Get-ChildItem (Join-Path $RRRoot 'logs') -Filter 'run-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($FinalReport) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $reportPath = Join-Path $RRRoot "logs\final-report-$stamp.md"
  $efficiency = if ($Pilot.totalRuns -gt 0) { [Math]::Round(100 * $Pilot.totalClaudeRuns / $Pilot.totalRuns, 1) } else { 0 }
  $candidatesPerRun = if ($Pilot.totalClaudeRuns -gt 0) { [Math]::Round($Pilot.totalCandidates / $Pilot.totalClaudeRuns, 2) } else { 0 }
  $pubsPerRun = if ($Pilot.totalClaudeRuns -gt 0) { [Math]::Round($Pilot.totalPublished / $Pilot.totalClaudeRuns, 2) } else { 0 }

  $lines = @(
    "# RED REACTIONS — 24H AUTOMATION PILOT",
    "",
    "Started: $($Pilot.pilotStartedAt)",
    "Ended: $($Pilot.pilotEndsAt)",
    "Hourly watch runs: $($Pilot.totalRuns)",
    "Claude invocations: $($Pilot.totalClaudeRuns)",
    "Candidates discovered: $($Pilot.totalCandidates)",
    "Ignored: $($Pilot.totalIgnored)",
    "Duplicates: $($Pilot.totalDuplicates)",
    "Manual/queued opportunities: $queuedCount",
    "Pending retry (Claude was unavailable): $retryCount",
    "Auto-published: $($Pilot.totalPublished)",
    "Publication limit: $($Pilot.maximumAutoPublished)",
    "Build/git/deploy failures: $($Pilot.totalFailures)",
    "",
    "Published article URLs:",
    ($(if ($Pilot.publishedUrls.Count -eq 0) { "  (none)" } else { ($Pilot.publishedUrls | ForEach-Object { $i=0 } { $i++; "  $i. $_" }) -join "`n" })),
    "",
    "Estimated efficiency:",
    "  Percentage of hourly runs that needed Claude: $efficiency%",
    "  Candidates per Claude run: $candidatesPerRun",
    "  Publications per Claude run: $pubsPerRun",
    "",
    "Recommendation:",
    ($(if ($Pilot.totalFailures -eq 0 -and $Pilot.totalPublished -gt 0) { "  No build/git/deploy failures were observed and at least one article auto-published and verified. Safe to consider a controlled expansion (e.g. a longer pilot or a higher limit) after a manual quality review of the published articles." } elseif ($Pilot.totalPublished -eq 0) { "  No articles were auto-published during this pilot (either no eligible stories appeared, or Claude was unavailable). Re-run the pilot before expanding scope." } else { "  Failures were observed during this pilot. Review logs/final-report and fix root causes before expanding scope." }))
  )
  $lines -join "`n" | Set-Content -Path $reportPath -Encoding utf8
  $Pilot.lastExpiryReportPath = $reportPath
  Write-Host "[status] Final report written to $reportPath"
  return
}

Write-Host "=== Red Reactions Watch — Pilot Status ==="
Write-Host "Mode:            $($Pilot.mode)"
Write-Host "Active:          $($Pilot.active)"
Write-Host "Pilot started:   $($Pilot.pilotStartedAt)"
Write-Host "Pilot ends:      $($Pilot.pilotEndsAt)"
if ($Pilot.active -and $Pilot.pilotEndsAt) {
  try {
    $ends = [DateTime]::Parse($Pilot.pilotEndsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    $remaining = $ends.ToUniversalTime() - (Get-Date).ToUniversalTime()
    if ($remaining.TotalSeconds -gt 0) { Write-Host "Time remaining:  $($remaining.ToString('hh\:mm\:ss'))" } else { Write-Host "Time remaining:  EXPIRED (will auto-disable on next run)" }
  } catch {}
}
Write-Host ""
Write-Host "Hourly runs:             $($Pilot.totalRuns)"
Write-Host "Candidates discovered:   $($Pilot.totalCandidates)"
Write-Host "Claude invocations:      $($Pilot.totalClaudeRuns)"
Write-Host "Auto-published:          $($Pilot.autoPublishedCount) / $($Pilot.maximumAutoPublished)"
Write-Host "Remaining allowance:     $([Math]::Max(0,$Pilot.maximumAutoPublished - $Pilot.autoPublishedCount))"
Write-Host "Queued manual items:     $queuedCount"
Write-Host "Pending retry:           $retryCount"
Write-Host "Total failures:          $($Pilot.totalFailures)"
Write-Host ""
if ($latestLog) { Write-Host "Latest run log: $($latestLog.FullName)" } else { Write-Host "Latest run log: (none yet)" }
if ($Pilot.publishedUrls.Count -gt 0) {
  Write-Host ""
  Write-Host "Published URLs:"
  $Pilot.publishedUrls | ForEach-Object { Write-Host "  - $_" }
}
