<#
.SYNOPSIS
  Prints current pilot status, including token-usage/efficiency stats. With -FinalReport, writes
  the 24-hour pilot summary report (called automatically by watch.ps1 the moment the pilot
  expires; can also be run manually).
#>
param([switch]$FinalReport, $Pilot)

. "$PSScriptRoot\lib\common.ps1"

if (-not $Pilot) { $Pilot = Get-RRPilot }
$queue = Get-RRQueue
$queuedCount = @($queue.items | Where-Object { $_.status -eq 'queued' }).Count
$retryCount = @($queue.items | Where-Object { $_.status -eq 'pending-retry' }).Count
$overflowCount = @($queue.items | Where-Object { $_.status -eq 'strong-overflow' }).Count
$deferredCount = @($queue.items | Where-Object { $_.status -eq 'auto-eligible-deferred' }).Count
$imagePrepCount = @($queue.items | Where-Object { $_.classification -eq 'IMAGE_PREP_REQUIRED' }).Count

$latestLog = Get-ChildItem (Join-Path $RRRoot 'logs') -Filter 'run-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$totalClaudeCalls = $Pilot.evaluatorClaudeRuns + $Pilot.publisherClaudeRuns

if ($FinalReport) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $reportPath = Join-Path $RRRoot "logs\final-report-$stamp.md"
  $zeroPct = if ($Pilot.totalRuns -gt 0) { [Math]::Round(100 * $Pilot.zeroClaudeRuns / $Pilot.totalRuns, 1) } else { 0 }
  $filteredPct = if ($Pilot.totalFeedItemsCollected -gt 0) { [Math]::Round(100 * $Pilot.totalRemovedDeterministically / $Pilot.totalFeedItemsCollected, 1) } else { 0 }
  $avgCandidatesPerCall = if ($Pilot.evaluatorClaudeRuns -gt 0) { [Math]::Round($Pilot.totalCandidatesSentToClaude / $Pilot.evaluatorClaudeRuns, 2) } else { 0 }
  $pubsPerCall = if ($Pilot.publisherClaudeRuns -gt 0) { [Math]::Round($Pilot.totalPublished / $Pilot.publisherClaudeRuns, 2) } else { 0 }

  $lines = @(
    "# RED REACTIONS — 24H AUTOMATION PILOT",
    "",
    "Started: $($Pilot.pilotStartedAt)",
    "Ended: $($Pilot.pilotEndsAt)",
    "",
    "## Token-usage / efficiency",
    "Hourly watch runs: $($Pilot.totalRuns)",
    "Runs with ZERO Claude usage: $($Pilot.zeroClaudeRuns) ($zeroPct%)",
    "Raw feed items scanned: $($Pilot.totalFeedItemsCollected)",
    "Removed deterministically (no Claude): $($Pilot.totalRemovedDeterministically) ($filteredPct%)",
    "Strong candidates found: $($Pilot.totalStrongCandidates)",
    "Candidates actually sent to Claude: $($Pilot.totalCandidatesSentToClaude)",
    "Evaluator Claude calls: $($Pilot.evaluatorClaudeRuns)",
    "Publisher Claude calls: $($Pilot.publisherClaudeRuns)",
    "Average candidates per evaluator call: $avgCandidatesPerCall",
    "Publications per publisher call: $pubsPerCall",
    "",
    "## Editorial outcomes",
    "Ignored: $($Pilot.totalIgnored)",
    "Duplicates: $($Pilot.totalDuplicates)",
    "Manual/queued opportunities: $queuedCount",
    "Pending retry (Claude was unavailable): $retryCount",
    "Strong candidates awaiting a later batch: $overflowCount",
    "Auto-eligible deferred (awaiting a live run's Phase A reconfirmation): $deferredCount",
    "Blocked on image preparation (no publisher call spent): $imagePrepCount",
    "Auto-published: $($Pilot.totalPublished)",
    "Publication limit: $($Pilot.maximumAutoPublished)",
    "Build/git/deploy failures: $($Pilot.totalFailures)",
    "",
    "Published article URLs:",
    ($(if ($Pilot.publishedUrls.Count -eq 0) { "  (none)" } else { ($Pilot.publishedUrls | ForEach-Object { $i=0 } { $i++; "  $i. $_" }) -join "`n" })),
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
Write-Host "--- Token usage ---"
Write-Host "Hourly runs:                $($Pilot.totalRuns)"
Write-Host "Zero-Claude runs:           $($Pilot.zeroClaudeRuns)"
Write-Host "Feed items scanned:         $($Pilot.totalFeedItemsCollected)"
Write-Host "Removed deterministically:  $($Pilot.totalRemovedDeterministically)"
Write-Host "Strong candidates found:    $($Pilot.totalStrongCandidates)"
Write-Host "Sent to Claude:             $($Pilot.totalCandidatesSentToClaude)"
Write-Host "Evaluator Claude calls:     $($Pilot.evaluatorClaudeRuns) (cap: $($Pilot.evaluatorRunsInWindow) used in current window)"
Write-Host "Publisher Claude calls:     $($Pilot.publisherClaudeRuns)"
Write-Host ""
Write-Host "--- Editorial ---"
Write-Host "Auto-published:          $($Pilot.autoPublishedCount) / $($Pilot.maximumAutoPublished)"
Write-Host "Remaining allowance:     $([Math]::Max(0,$Pilot.maximumAutoPublished - $Pilot.autoPublishedCount))"
Write-Host "Queued manual items:     $queuedCount"
Write-Host "Pending retry:           $retryCount"
Write-Host "Strong, awaiting batch:  $overflowCount"
Write-Host "Auto-eligible deferred:  $deferredCount (awaiting a live run's Phase A reconfirmation)"
Write-Host "Image-prep blocked:      $imagePrepCount"
Write-Host "Total failures:          $($Pilot.totalFailures)"
Write-Host ""
if ($latestLog) { Write-Host "Latest run log: $($latestLog.FullName)" } else { Write-Host "Latest run log: (none yet)" }
if ($Pilot.publishedUrls.Count -gt 0) {
  Write-Host ""
  Write-Host "Published URLs:"
  $Pilot.publishedUrls | ForEach-Object { Write-Host "  - $_" }
}
