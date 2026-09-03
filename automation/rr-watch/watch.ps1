<#
.SYNOPSIS
  Red Reactions hourly watch entry point. Run by Windows Task Scheduler (or manually for a
  dry-run test). Does cheap, non-AI collection + filtering first; only invokes Claude Code if
  genuinely new candidates survive filtering. Never runs Claude continuously — one process,
  one batch, one exit.
.PARAMETER DryRun
  Force dry-run behavior for this run regardless of pilot.json (does not change pilot.json).
  Useful for manual testing.
#>
param([switch]$DryRun)

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\collect.ps1"
. "$PSScriptRoot\filter.ps1"
. "$PSScriptRoot\run-claude.ps1"

$lockPath = Join-Path $RRRoot 'logs\.lock'
if (-not (Enter-RRLock -Path $lockPath)) {
  Write-Warning "[watch] Another run is already in progress. Exiting."
  exit 0
}

$logPath = Get-RRLogPath
Write-RRLog -Path $logPath -Message "$(Get-Date -Format 'yyyy-MM-dd HH:mm')`nRR WATCH RUN"

try {
  $config = Get-RRConfig
  $pilot = Get-RRPilot
  $state = Get-RRState
  $queue = Get-RRQueue

  # --- Pilot expiry check -------------------------------------------------
  if ($pilot.active -and $pilot.mode -eq 'live' -and $pilot.pilotEndsAt) {
    $ends = [DateTime]::Parse($pilot.pilotEndsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    if ((Get-Date).ToUniversalTime() -ge $ends.ToUniversalTime()) {
      Write-RRLog -Path $logPath -Message "PILOT EXPIRED at $($pilot.pilotEndsAt). Disabling live publishing."
      $pilot.active = $false
      $pilot.mode = 'dry-run'
      & "$PSScriptRoot\status.ps1" -FinalReport -Pilot $pilot | Out-Null
    }
  }

  if ($DryRun) { $effectiveMode = 'dry-run'; $effectiveActive = $false } else { $effectiveMode = $pilot.mode; $effectiveActive = $pilot.active }

  # --- Collect + filter (non-AI) ------------------------------------------
  $sources = Get-RRSources
  $enabledCount = @($sources.feeds | Where-Object { $_.enabled }).Count
  $raw = Invoke-RRCollect
  $filterResult = Invoke-RRFilter -RawCandidates $raw -State $state -Config $config
  $newCandidates = @($filterResult.candidates)
  $state = $filterResult.state

  $pilot.totalRuns++
  $pilot.totalCandidates += $newCandidates.Count
  $pilot.lastRun = (Get-Date -Format 'o')

  Write-RRLog -Path $logPath -Message "Sources checked: $enabledCount`nFeed items collected: $($raw.Count)`nPreviously seen (this run's new-vs-seen after filtering): $($raw.Count - $newCandidates.Count)`nNew candidates: $($newCandidates.Count)"

  # Merge in anything previously preserved because Claude was unavailable.
  $pending = @($queue.items | Where-Object { $_.status -eq 'pending-retry' })
  if ($pending.Count -gt 0) {
    Write-RRLog -Path $logPath -Message "Retrying $($pending.Count) previously preserved candidate(s) alongside this batch."
    $newCandidates += ($pending | ForEach-Object { [PSCustomObject]@{ id=$_.id; title=$_.title; url=$_.url; source=$_.source; category=$_.category; publishedAt=$_.publishedAt; summary=$_.summary; discoveredAt=$_.discoveredAt } })
  }

  if ($newCandidates.Count -eq 0) {
    Write-RRLog -Path $logPath -Message "Claude invoked: NO`n(no genuinely new candidates)"
    Save-RRState $state; Save-RRPilot $pilot
    Write-Host "[watch] No new candidates. Claude not invoked."
    exit 0
  }

  # --- Claude invocation (single, gated) ----------------------------------
  $pilot.totalClaudeRuns++
  $summary = Invoke-RRClaude -Candidates $newCandidates -Pilot $pilot -Config $config -LogPath $logPath

  if (-not $summary) {
    Write-RRLog -Path $logPath -Message "Claude invoked: YES (unavailable/failed — see above). No publication this run."
    # Preserve every candidate from this batch as pending-retry, avoiding duplicates.
    $existingIds = @($queue.items | ForEach-Object { $_.id })
    foreach ($c in $newCandidates) {
      if ($existingIds -notcontains $c.id) {
        $queue.items = @($queue.items) + [PSCustomObject]@{
          id=$c.id; title=$c.title; url=$c.url; source=$c.source; classification='PENDING_RETRY'
          reason='Claude unavailable this run'; discoveredAt=$c.discoveredAt; lastEvaluatedAt=(Get-Date -Format 'o')
          status='pending-retry'
        }
      }
    }
    $pilot.totalFailures++
    Save-RRState $state; Save-RRQueue $queue; Save-RRPilot $pilot
    exit 0
  }

  Write-RRLog -Path $logPath -Message "Claude invoked: YES`n`nRESULTS"

  # --- Apply classification tallies ---------------------------------------
  $counts = @{}
  foreach ($cl in $summary.classifications) {
    $counts[$cl.classification] = ($counts[$cl.classification] + 1)
    Write-RRLog -Path $logPath -Message "$($cl.classification): $($cl.title) — $($cl.reasoning)"
  }
  $pilot.totalIgnored += [int]($counts['IGNORE'])
  $pilot.totalDuplicates += [int]($counts['DUPLICATE'])

  # --- Queue everything Claude flagged for manual/queued handling ---------
  $queue.items = @($queue.items | Where-Object { $_.status -ne 'pending-retry' -or ($newCandidates.id -notcontains $_.id) })
  foreach ($q in $summary.queued) {
    $queue.items = @($queue.items) + [PSCustomObject]@{
      id=$q.id; title=$q.title; url=$q.url; source=$q.source; classification=$q.classification
      reason=$q.reason; suggestedAngle=$q.suggestedAngle; discoveredAt=(Get-Date -Format 'o')
      lastEvaluatedAt=(Get-Date -Format 'o'); status='queued'
    }
  }
  $pilot.totalQueued += @($summary.queued).Count

  # --- Publications (only meaningful in live mode; Claude enforces gating) -
  $capRemaining = [Math]::Max(0, $pilot.maximumAutoPublished - $pilot.autoPublishedCount)
  $published = @(@($summary.published) | Select-Object -First $capRemaining)
  if (@($summary.published).Count -gt $capRemaining) {
    Write-RRLog -Path $logPath -Message "WARNING: Claude reported more publications than the remaining allowance. Only the first $capRemaining are being counted; investigate the discrepancy."
  }
  foreach ($p in $published) {
    $pilot.autoPublishedCount++
    $pilot.totalPublished++
    $pilot.publishedUrls = @($pilot.publishedUrls) + $p.url
    Write-RRLog -Path $logPath -Message "`nAUTO PUBLICATION`nTitle: $($p.title)`nSlug: $($p.slug)`nBuild: PASS`nGit commit: $($p.commit)`nProduction: $(if($p.verified){'PASS'}else{'FAIL'})`nURL: $($p.url)`n`nSOCIAL`nX: $($p.x)`nFacebook: $($p.facebook)`n`nPilot publications: $($pilot.autoPublishedCount) / $($pilot.maximumAutoPublished)"
  }

  foreach ($f in $summary.failures) {
    $pilot.totalFailures++
    Write-RRLog -Path $logPath -Message "FAILURE [$($f.stage)] $($f.title): $($f.reason)"
  }

  if ($summary.notes) { Write-RRLog -Path $logPath -Message "`nNOTES: $($summary.notes)" }

  Save-RRState $state
  Save-RRQueue $queue
  Save-RRPilot $pilot
  Write-Host "[watch] Run complete. See $logPath"
}
finally {
  Exit-RRLock -Path $lockPath
}
