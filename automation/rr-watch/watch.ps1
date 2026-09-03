<#
.SYNOPSIS
  Red Reactions hourly watch entry point. Run by Windows Task Scheduler (or manually for a
  dry-run test). Does cheap, non-AI collection + filtering first; only invokes Claude Code if
  genuinely new candidates survive filtering. Never runs Claude continuously — one evaluator
  process per batch, plus at most one publisher process per individually-gated article.
.PARAMETER DryRun
  Force dry-run behavior for THIS RUN ONLY, regardless of what pilot.json says on disk. This is
  enforced by computing $effectiveMode/$effectiveActive up front and passing ONLY those values
  into the evaluator's run context (never the raw pilot object) — and by never entering the
  publisher loop at all when this switch is set. pilot.json itself is never modified by -DryRun.
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
Write-RRLog -Path $logPath -Message "$(Get-Date -Format 'yyyy-MM-dd HH:mm')`nRR WATCH RUN$(if($DryRun){' (forced -DryRun)'})"

try {
  $config = Get-RRConfig
  $pilot = Get-RRPilot
  $state = Get-RRState
  $queue = Get-RRQueue

  # --- Pilot expiry check (always against the real on-disk state) --------
  if ($pilot.active -and $pilot.mode -eq 'live' -and $pilot.pilotEndsAt) {
    $ends = [DateTime]::Parse($pilot.pilotEndsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    if ((Get-Date).ToUniversalTime() -ge $ends.ToUniversalTime()) {
      Write-RRLog -Path $logPath -Message "PILOT EXPIRED at $($pilot.pilotEndsAt). Disabling live publishing."
      $pilot.active = $false
      $pilot.mode = 'dry-run'
      Save-RRPilot $pilot
      & "$PSScriptRoot\status.ps1" -FinalReport -Pilot $pilot | Out-Null
    }
  }

  # --- Effective mode for THIS RUN. -DryRun always wins over pilot.json. -
  if ($DryRun) { $effectiveMode = 'dry-run'; $effectiveActive = $false }
  else { $effectiveMode = $pilot.mode; $effectiveActive = [bool]$pilot.active }
  $canPublishThisRun = ($effectiveMode -eq 'live' -and $effectiveActive -and -not $DryRun)

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

  Write-RRLog -Path $logPath -Message "Sources checked: $enabledCount`nFeed items collected: $($raw.Count)`nNew candidates: $($newCandidates.Count)"

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

  # --- PHASE A: evaluation (read-only) -------------------------------------
  $pilot.totalClaudeRuns++
  $remaining0 = [Math]::Max(0, $pilot.maximumAutoPublished - $pilot.autoPublishedCount)
  $eval = Invoke-RREvaluator -Candidates $newCandidates -EffectiveMode $effectiveMode -EffectiveActive $effectiveActive `
    -Remaining $remaining0 -Max $pilot.maximumAutoPublished -SoFar $pilot.autoPublishedCount -Config $config -LogPath $logPath

  if (-not $eval) {
    Write-RRLog -Path $logPath -Message "Claude invoked: YES (evaluator unavailable/failed — see above). No publication this run."
    $existingIds = @($queue.items | ForEach-Object { $_.id })
    foreach ($c in $newCandidates) {
      if ($existingIds -notcontains $c.id) {
        $queue.items = @($queue.items) + [PSCustomObject]@{
          id=$c.id; title=$c.title; url=$c.url; source=$c.source; classification='PENDING_RETRY'
          reason='Evaluator unavailable this run'; discoveredAt=$c.discoveredAt; lastEvaluatedAt=(Get-Date -Format 'o')
          status='pending-retry'
        }
      }
    }
    $pilot.totalFailures++
    Save-RRState $state; Save-RRQueue $queue; Save-RRPilot $pilot
    exit 0
  }

  Write-RRLog -Path $logPath -Message "Claude invoked: YES (evaluator)`n`nRESULTS"
  $counts = @{}
  foreach ($cl in $eval.classifications) {
    $counts[$cl.classification] = ($counts[$cl.classification] + 1)
    Write-RRLog -Path $logPath -Message "$($cl.classification): $($cl.title) — $($cl.reasoning)"
  }
  $pilot.totalIgnored += [int]($counts['IGNORE'])
  $pilot.totalDuplicates += [int]($counts['DUPLICATE'])

  $queue.items = @($queue.items | Where-Object { $_.status -ne 'pending-retry' -or ($newCandidates.id -notcontains $_.id) })
  foreach ($q in $eval.queued) {
    $queue.items = @($queue.items) + [PSCustomObject]@{
      id=$q.id; title=$q.title; url=$q.url; source=$q.source; classification=$q.classification
      reason=$q.reason; suggestedAngle=$q.suggestedAngle; discoveredAt=(Get-Date -Format 'o')
      lastEvaluatedAt=(Get-Date -Format 'o'); status='queued'
    }
  }
  $pilot.totalQueued += @($eval.queued).Count

  $autoEligible = @($eval.autoEligible)

  # --- PHASE B: publication, gated per-candidate by PowerShell -----------
  if (-not $canPublishThisRun) {
    if ($autoEligible.Count -gt 0) {
      $why = if ($DryRun) { 'forced -DryRun for this run' } elseif ($effectiveMode -ne 'live') { 'pilot mode is dry-run' } else { 'pilot is not active' }
      Write-RRLog -Path $logPath -Message "`n$($autoEligible.Count) candidate(s) evaluated as auto-eligible, but NOT sent to the publisher ($why). Draft proposals (if any) are under logs\dry-run-*.md."
      foreach ($a in $autoEligible) {
        $queue.items = @($queue.items) + [PSCustomObject]@{
          id=$a.id; title=$a.title; url=$a.url; source=$a.source; classification='NEW_ARTICLE_AUTO_ELIGIBLE'
          reason="Auto-eligible but not published: $why"; suggestedAngle=$a.angle; discoveredAt=(Get-Date -Format 'o')
          lastEvaluatedAt=(Get-Date -Format 'o'); status='queued'
        }
        $pilot.totalQueued++
      }
    }
  } else {
    $gateClosed = $false
    foreach ($cand in $autoEligible) {
      if ($gateClosed) {
        $queue.items = @($queue.items) + [PSCustomObject]@{
          id=$cand.id; title=$cand.title; url=$cand.url; source=$cand.source; classification='QUEUE_LIMIT_REACHED'
          reason='Publication gate closed earlier in this same run'; suggestedAngle=$cand.angle; discoveredAt=(Get-Date -Format 'o')
          lastEvaluatedAt=(Get-Date -Format 'o'); status='queued'
        }
        $pilot.totalQueued++
        continue
      }

      # Re-read pilot.json fresh from disk and re-check every gate immediately before invoking.
      $fresh = Get-RRPilot
      $nowUtc = (Get-Date).ToUniversalTime()
      $notExpired = $true
      if ($fresh.pilotEndsAt) { $notExpired = ($nowUtc -lt [DateTime]::Parse($fresh.pilotEndsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) }
      $gateOpen = ($fresh.mode -eq 'live') -and [bool]$fresh.active -and $notExpired -and ($fresh.autoPublishedCount -lt $fresh.maximumAutoPublished)

      if (-not $gateOpen) {
        $reason = if ($fresh.autoPublishedCount -ge $fresh.maximumAutoPublished) { 'QUEUE_LIMIT_REACHED' } else { 'PILOT_GATE_CLOSED' }
        Write-RRLog -Path $logPath -Message "Publication gate closed before considering '$($cand.title)' ($reason). No publisher process will start for this or any remaining auto-eligible candidate this run."
        $queue.items = @($queue.items) + [PSCustomObject]@{
          id=$cand.id; title=$cand.title; url=$cand.url; source=$cand.source; classification=$reason
          reason='Fresh pilot.json re-check failed the publication gate'; suggestedAngle=$cand.angle; discoveredAt=(Get-Date -Format 'o')
          lastEvaluatedAt=(Get-Date -Format 'o'); status='queued'
        }
        $pilot.totalQueued++
        $gateClosed = $true
        continue
      }

      $remainingNow = [Math]::Max(0, $fresh.maximumAutoPublished - $fresh.autoPublishedCount)
      $pilot.totalClaudeRuns++
      $pubResult = Invoke-RRPublisher -Candidate $cand -Remaining $remainingNow -Config $config -LogPath $logPath

      if (-not $pubResult) {
        Write-RRLog -Path $logPath -Message "Publisher unavailable/failed for '$($cand.title)'. Preserved for retry; stopping the publication phase for the rest of this run."
        $queue.items = @($queue.items) + [PSCustomObject]@{
          id=$cand.id; title=$cand.title; url=$cand.url; source=$cand.source; classification='PENDING_RETRY'
          reason='Publisher unavailable this run'; discoveredAt=(Get-Date -Format 'o'); lastEvaluatedAt=(Get-Date -Format 'o')
          status='pending-retry'
        }
        $pilot.totalFailures++
        $gateClosed = $true
        continue
      }

      if ($pubResult.published -eq $true -and $pubResult.verified -eq $true) {
        # Re-read once more immediately before writing the increment, to keep the window between
        # gate-check and counter-update as small as this single-process design allows.
        $fresh2 = Get-RRPilot
        $fresh2.autoPublishedCount++
        $fresh2.totalPublished++
        $fresh2.publishedUrls = @($fresh2.publishedUrls) + $pubResult.url
        Save-RRPilot $fresh2
        $pilot = $fresh2
        Write-RRLog -Path $logPath -Message "`nAUTO PUBLICATION`nTitle: $($pubResult.title)`nSlug: $($pubResult.slug)`nBuild: PASS`nGit commit: $($pubResult.commit)`nProduction: PASS`nURL: $($pubResult.url)`n`nSOCIAL`nX: $($pubResult.x)`nFacebook: $($pubResult.facebook)`n`nPilot publications: $($fresh2.autoPublishedCount) / $($fresh2.maximumAutoPublished)"
      } else {
        $stage = if ($pubResult.failureStage) { $pubResult.failureStage } else { 'unknown' }
        Write-RRLog -Path $logPath -Message "NOT PUBLISHED: $($cand.title) [$stage] — $($pubResult.reason)"
        if ($stage -in @('build','git','push','verify')) { $pilot.totalFailures++ }
        $queue.items = @($queue.items) + [PSCustomObject]@{
          id=$cand.id; title=$cand.title; url=$cand.url; source=$cand.source; classification='NEW_ARTICLE_MANUAL'
          reason="Publisher declined/failed at [$stage]: $($pubResult.reason)"; discoveredAt=(Get-Date -Format 'o')
          lastEvaluatedAt=(Get-Date -Format 'o'); status='queued'
        }
        $pilot.totalQueued++
      }
    }
  }

  if ($eval.notes) { Write-RRLog -Path $logPath -Message "`nNOTES: $($eval.notes)" }

  Save-RRState $state
  Save-RRQueue $queue
  Save-RRPilot $pilot
  Write-Host "[watch] Run complete. See $logPath"
}
finally {
  Exit-RRLock -Path $lockPath
}
