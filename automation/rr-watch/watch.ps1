<#
.SYNOPSIS
  Red Reactions hourly watch entry point. Run by Windows Task Scheduler (or manually for a
  dry-run test). Claude is the LAST filter, never the first: feeds -> deterministic collection
  -> deterministic relevance/noise filtering -> seen/dedup filtering -> deterministic priority
  ranking + per-run cap -> ONLY THEN, at most once, the evaluator. Most hourly runs should
  invoke Claude zero times.
.PARAMETER DryRun
  Force dry-run behavior for THIS RUN ONLY, regardless of what pilot.json says on disk. Enforced
  by computing $effectiveMode/$effectiveActive up front and passing ONLY those values into the
  evaluator's run context — and by never entering the publisher loop when this switch is set.
  pilot.json itself is never modified by -DryRun.
#>
param([switch]$DryRun)

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\collect.ps1"
. "$PSScriptRoot\filter.ps1"
. "$PSScriptRoot\prioritize.ps1"
. "$PSScriptRoot\prepare-hero.ps1"
. "$PSScriptRoot\run-claude.ps1"

$lockPath = Join-Path $RRRoot 'logs\.lock'
if (-not (Enter-RRLock -Path $lockPath)) {
  Write-Warning "[watch] Another run is already in progress. Exiting."
  exit 0
}

$logPath = Get-RRLogPath
Write-RRLog -Path $logPath -Message "$(Get-Date -Format 'yyyy-MM-dd HH:mm')`nRR WATCH RUN$(if($DryRun){' (forced -DryRun)'})"

function Add-RRQueueItem {
  param($Queue, [string]$Id, [string]$Title, [string]$Url, [string]$Source, [string]$Classification, [string]$Reason, [string]$SuggestedAngle, [string]$Status, [int]$RetryCount = 0, [string]$NextRetryAt = $null, [double]$Score = 0)
  $Queue.items = @($Queue.items) + [PSCustomObject]@{
    id = $Id; title = $Title; url = $Url; source = $Source; classification = $Classification
    reason = $Reason; suggestedAngle = $SuggestedAngle; discoveredAt = (Get-Date -Format 'o')
    lastEvaluatedAt = (Get-Date -Format 'o'); status = $Status; retryCount = $RetryCount; nextRetryAt = $NextRetryAt; score = $Score
  }
}

# Keeps the strong-overflow bucket small and high-value: drops entries older than
# config.overflowMaxAgeHours without ever invoking Claude, collapses duplicate normalized-URL/
# title+source entries (keeping the higher score), and trims to config.maxStrongOverflowQueue by
# score so genuinely high-value stories always win over older, lower-scored ones. Runs every
# watch.ps1 invocation, independent of whether the evaluator itself runs this hour.
function Invoke-RROverflowMaintenance {
  param($Queue, $Config, [string]$LogPath)
  $now = (Get-Date).ToUniversalTime()
  $maxAge = [double]$Config.overflowMaxAgeHours
  $others = @($Queue.items | Where-Object { $_.status -ne 'strong-overflow' })
  $overflow = @($Queue.items | Where-Object { $_.status -eq 'strong-overflow' })

  $fresh = @()
  $expiredCount = 0
  foreach ($o in $overflow) {
    $age = $now
    try { $age = $now - [DateTime]::Parse($o.discoveredAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $age = [TimeSpan]::Zero }
    if ($age.TotalHours -gt $maxAge) { $expiredCount++; continue }
    $fresh += $o
  }

  $groups = $fresh | Group-Object -Property { if ($_.url) { Normalize-RRUrl $_.url } else { "$($_.source)|$(($_.title -replace '\s+',' ').Trim().ToLowerInvariant())" } }
  $collapsed = @()
  $collapsedCount = 0
  foreach ($g in $groups) {
    if ($g.Group.Count -gt 1) { $collapsedCount += ($g.Group.Count - 1) }
    $best = $g.Group | Sort-Object -Property @{ Expression = { [double]$_.score } ; Descending = $true } | Select-Object -First 1
    $collapsed += $best
  }

  $capped = @($collapsed | Sort-Object -Property @{ Expression = { [double]$_.score } ; Descending = $true })
  $maxQueue = [int]$Config.maxStrongOverflowQueue
  $kept = @($capped | Select-Object -First $maxQueue)
  $trimmedCount = [Math]::Max(0, $capped.Count - $maxQueue)

  if ($LogPath -and ($expiredCount -gt 0 -or $collapsedCount -gt 0 -or $trimmedCount -gt 0)) {
    Write-RRLog -Path $LogPath -Message "Overflow queue maintenance: $expiredCount expired (stale, dropped without Claude), $collapsedCount duplicate(s) collapsed, $trimmedCount dropped for exceeding maxStrongOverflowQueue ($maxQueue). $($kept.Count) retained."
  }

  $Queue.items = @($others) + $kept
}

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

  # --- Collect (non-AI) -----------------------------------------------------
  $sources = Get-RRSources
  $enabledCount = @($sources.feeds | Where-Object { $_.enabled }).Count
  $raw = Invoke-RRCollect
  $pilot.totalFeedItemsCollected += $raw.Count

  # --- Deterministic seen/stale/dupe/non-English filter (non-AI) -----------
  $filterResult = Invoke-RRFilter -RawCandidates $raw -State $state -Config $config
  $newCandidates = @($filterResult.candidates)
  $state = $filterResult.state
  $removedByFilter = $raw.Count - $newCandidates.Count

  $pilot.totalRuns++
  $pilot.totalCandidates += $newCandidates.Count
  $pilot.lastRun = (Get-Date -Format 'o')

  Write-RRLog -Path $logPath -Message "Sources checked: $enabledCount`nFeed items collected: $($raw.Count)`nNew (unseen/fresh/dedup) candidates: $($newCandidates.Count)"

  # --- Deterministic relevance + priority scoring (non-AI) ------------------
  $prioritized = Invoke-RRPrioritize -Candidates $newCandidates -Config $config -LogPath $logPath
  $pilot.totalRemovedDeterministically += ($removedByFilter + $prioritized.RejectedCount)
  $pilot.totalStrongCandidates += $prioritized.StrongCount

  foreach ($ov in $prioritized.Overflow) {
    Add-RRQueueItem -Queue $queue -Id $ov.Candidate.id -Title $ov.Candidate.title -Url $ov.Candidate.url -Source $ov.Candidate.source `
      -Classification 'STRONG_CANDIDATE_QUEUED' -Reason 'Strong candidate, but exceeded this run''s per-run Claude batch cap; eligible for a later run (subject to overflow-queue aging/ranking).' `
      -SuggestedAngle $null -Status 'strong-overflow' -RetryCount 0 -NextRetryAt $null -Score $ov.Score
  }
  if ($prioritized.DroppedLowValueCount -gt 0) { $pilot.totalRemovedDeterministically += $prioritized.DroppedLowValueCount }

  # Age out stale overflow, collapse duplicates, and enforce the overflow cap BEFORE deciding
  # what (if anything) fills this run's leftover batch slots — so a fresh, higher-scored overflow
  # entry from this run's Invoke-RRPrioritize call can legitimately outrank and displace an older,
  # lower-scored one already sitting in the queue.
  Invoke-RROverflowMaintenance -Queue $queue -Config $config -LogPath $logPath

  # --- Merge in due retries (respecting backoff) and due strong-overflow ---
  $dueRetries = @($queue.items | Where-Object { ($_.status -eq 'pending-retry' -or $_.status -eq 'strong-overflow') -and (Test-RRRetryDue $_) } | Sort-Object -Property @{ Expression = { [double]$_.score } ; Descending = $true })
  $batch = @($prioritized.Strong)
  $remainingSlots = [Math]::Max(0, [int]$config.maxCandidatesPerClaudeRun - $batch.Count)
  if ($dueRetries.Count -gt 0 -and $remainingSlots -gt 0) {
    $toRetry = @($dueRetries | Select-Object -First $remainingSlots)
    Write-RRLog -Path $logPath -Message "Adding $($toRetry.Count) due retry/overflow candidate(s) (of $($dueRetries.Count) eligible) into this run's batch."
    $batch += ($toRetry | ForEach-Object { [PSCustomObject]@{ id=$_.id; title=$_.title; url=$_.url; source=$_.source; category=$null; publishedAt=$null; summary=$null; discoveredAt=$_.discoveredAt } })
  }
  $notDueCount = @($queue.items | Where-Object { ($_.status -eq 'pending-retry' -or $_.status -eq 'strong-overflow') -and -not (Test-RRRetryDue $_) }).Count
  if ($notDueCount -gt 0) { Write-RRLog -Path $logPath -Message "$notDueCount queued retry/overflow candidate(s) not yet due (backoff in effect)." }

  # Every id now in $batch is about to be (re-)decided this run — remove its old pending-retry /
  # strong-overflow queue rows ONCE here so every branch below can freely re-add a fresh one
  # without risk of leaving stale duplicates behind.
  $priorByIdInBatch = @{}
  foreach ($c in $batch) {
    $prior = @($queue.items | Where-Object { $_.id -eq $c.id -and ($_.status -eq 'pending-retry' -or $_.status -eq 'strong-overflow') } | Select-Object -First 1)
    if ($prior.Count -gt 0) { $priorByIdInBatch[$c.id] = $prior[0] }
  }
  $batchIds = @($batch | ForEach-Object { $_.id })
  $queue.items = @($queue.items | Where-Object { -not (($_.status -eq 'pending-retry' -or $_.status -eq 'strong-overflow') -and $batchIds -contains $_.id) })

  if ($batch.Count -eq 0) {
    $pilot.zeroClaudeRuns++
    Write-RRLog -Path $logPath -Message "Claude invoked: NO`n(no strong candidates survived deterministic filtering/priority scoring, and no due retries)"
    Save-RRState $state; Save-RRQueue $queue; Save-RRPilot $pilot
    Write-Host "[watch] No strong candidates. Claude not invoked."
    exit 0
  }

  # --- Daily evaluator Claude-call safety cap (rolling window) -------------
  $windowHours = [double]$config.evaluatorRunsWindowHours
  if (-not $pilot.evaluatorRunsWindowStart) { $pilot.evaluatorRunsWindowStart = (Get-Date).ToUniversalTime().ToString('o') }
  $windowStart = [DateTime]::Parse($pilot.evaluatorRunsWindowStart, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
  if (((Get-Date).ToUniversalTime() - $windowStart).TotalHours -ge $windowHours) {
    $pilot.evaluatorRunsWindowStart = (Get-Date).ToUniversalTime().ToString('o')
    $pilot.evaluatorRunsInWindow = 0
  }
  if ($pilot.evaluatorRunsInWindow -ge [int]$config.maxEvaluatorClaudeRunsPer24h) {
    $pilot.zeroClaudeRuns++
    Write-RRLog -Path $logPath -Message "Claude invoked: NO`nDaily evaluator Claude-call cap reached ($($pilot.evaluatorRunsInWindow)/$($config.maxEvaluatorClaudeRunsPer24h) in the current $windowHours h window). $($batch.Count) strong candidate(s) queued for a later run/window; nothing discarded."
    foreach ($c in $batch) {
      Add-RRQueueItem -Queue $queue -Id $c.id -Title $c.title -Url $c.url -Source $c.source `
        -Classification 'STRONG_CANDIDATE_QUEUED' -Reason 'Daily evaluator Claude-call cap reached' `
        -SuggestedAngle $null -Status 'strong-overflow' -RetryCount 0 -NextRetryAt $null
    }
    Save-RRState $state; Save-RRQueue $queue; Save-RRPilot $pilot
    Write-Host "[watch] Daily evaluator cap reached. Claude not invoked."
    exit 0
  }

  # --- PHASE A: evaluation (read-only, at most one call per run) -----------
  $pilot.evaluatorClaudeRuns++
  $pilot.evaluatorRunsInWindow++
  $pilot.totalCandidatesSentToClaude += $batch.Count
  $remaining0 = [Math]::Max(0, $pilot.maximumAutoPublished - $pilot.autoPublishedCount)
  $evalResult = Invoke-RREvaluator -Candidates $batch -EffectiveMode $effectiveMode -EffectiveActive $effectiveActive `
    -Remaining $remaining0 -Max $pilot.maximumAutoPublished -SoFar $pilot.autoPublishedCount -Config $config -LogPath $logPath

  if (-not $evalResult.Ok) {
    Write-RRLog -Path $logPath -Message "Claude invoked: YES (evaluator unavailable/failed: $($evalResult.FailureKind)). No publication this run."
    foreach ($c in $batch) {
      $retryCount = if ($priorByIdInBatch.ContainsKey($c.id)) { [int]$priorByIdInBatch[$c.id].retryCount + 1 } else { 0 }
      $nextRetry = Get-RRNextRetryAt -FailureKind $evalResult.FailureKind -RetryCount $retryCount -Config $config
      Add-RRQueueItem -Queue $queue -Id $c.id -Title $c.title -Url $c.url -Source $c.source `
        -Classification 'PENDING_RETRY' -Reason "Evaluator unavailable this run ($($evalResult.FailureKind))" `
        -SuggestedAngle $null -Status 'pending-retry' -RetryCount $retryCount -NextRetryAt $nextRetry
    }
    $pilot.totalFailures++
    Save-RRState $state; Save-RRQueue $queue; Save-RRPilot $pilot
    exit 0
  }

  $eval = $evalResult.Data
  Write-RRLog -Path $logPath -Message "Claude invoked: YES (evaluator, $($batch.Count) candidate(s))`n`nRESULTS"
  $counts = @{}
  foreach ($cl in $eval.classifications) {
    $counts[$cl.classification] = ($counts[$cl.classification] + 1)
    Write-RRLog -Path $logPath -Message "$($cl.classification): $($cl.title) — $($cl.reasoning)"
  }
  $pilot.totalIgnored += [int]($counts['IGNORE'])
  $pilot.totalDuplicates += [int]($counts['DUPLICATE'])

  foreach ($q in $eval.queued) {
    Add-RRQueueItem -Queue $queue -Id $q.id -Title $q.title -Url $q.url -Source $q.source `
      -Classification $q.classification -Reason $q.reason -SuggestedAngle $q.suggestedAngle -Status 'queued'
  }
  $pilot.totalQueued += @($eval.queued).Count

  $autoEligible = @($eval.autoEligible)

  # --- PHASE B: publication, gated per-candidate by PowerShell -----------
  if (-not $canPublishThisRun) {
    if ($autoEligible.Count -gt 0) {
      $why = if ($DryRun) { 'forced -DryRun for this run' } elseif ($effectiveMode -ne 'live') { 'pilot mode is dry-run' } else { 'pilot is not active' }
      Write-RRLog -Path $logPath -Message "`n$($autoEligible.Count) candidate(s) evaluated as auto-eligible, but NOT sent to the publisher ($why). Draft proposals (if any) are under logs\dry-run-*.md."
      foreach ($a in $autoEligible) {
        Add-RRQueueItem -Queue $queue -Id $a.id -Title $a.title -Url $a.url -Source $a.source `
          -Classification 'NEW_ARTICLE_AUTO_ELIGIBLE' -Reason "Auto-eligible but not published: $why" -SuggestedAngle $a.angle -Status 'queued'
        $pilot.totalQueued++
      }
    }
  } else {
    $gateClosed = $false
    foreach ($cand in $autoEligible) {
      if ($gateClosed) {
        Add-RRQueueItem -Queue $queue -Id $cand.id -Title $cand.title -Url $cand.url -Source $cand.source `
          -Classification 'QUEUE_LIMIT_REACHED' -Reason 'Publication gate closed earlier in this same run' -SuggestedAngle $cand.angle -Status 'queued'
        $pilot.totalQueued++
        continue
      }

      $fresh = Get-RRPilot
      $nowUtc = (Get-Date).ToUniversalTime()
      $notExpired = $true
      if ($fresh.pilotEndsAt) { $notExpired = ($nowUtc -lt [DateTime]::Parse($fresh.pilotEndsAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) }
      $gateOpen = ($fresh.mode -eq 'live') -and [bool]$fresh.active -and $notExpired -and ($fresh.autoPublishedCount -lt $fresh.maximumAutoPublished)

      if (-not $gateOpen) {
        $reason = if ($fresh.autoPublishedCount -ge $fresh.maximumAutoPublished) { 'QUEUE_LIMIT_REACHED' } else { 'PILOT_GATE_CLOSED' }
        Write-RRLog -Path $logPath -Message "Publication gate closed before considering '$($cand.title)' ($reason). No publisher process will start for this or any remaining auto-eligible candidate this run."
        Add-RRQueueItem -Queue $queue -Id $cand.id -Title $cand.title -Url $cand.url -Source $cand.source `
          -Classification $reason -Reason 'Fresh pilot.json re-check failed the publication gate' -SuggestedAngle $cand.angle -Status 'queued'
        $pilot.totalQueued++
        $gateClosed = $true
        continue
      }

      # --- Deterministic hero-image preparation (no AI, no publisher call yet) -----
      $hero = Invoke-RRPrepareHero -CandidateId $cand.id -HeroImageUrl $cand.heroImageUrl `
        -HeroSourceUrl $cand.heroSourceUrl -HeroCredit $cand.heroCredit -HeroSourceType $cand.heroSourceType `
        -Config $config -LogPath $logPath

      if (-not $hero.Ok) {
        Write-RRLog -Path $logPath -Message "IMAGE_PREP_REQUIRED for '$($cand.title)': $($hero.Reason). Publisher NOT invoked — no Claude call spent on a candidate that could never complete."
        Add-RRQueueItem -Queue $queue -Id $cand.id -Title $cand.title -Url $cand.url -Source $cand.source `
          -Classification 'IMAGE_PREP_REQUIRED' -Reason $hero.Reason -SuggestedAngle $cand.angle -Status 'queued'
        $pilot.totalQueued++
        continue
      }

      $remainingNow = [Math]::Max(0, $fresh.maximumAutoPublished - $fresh.autoPublishedCount)
      $pilot.publisherClaudeRuns++
      $pubResult = Invoke-RRPublisher -Candidate $cand -Remaining $remainingNow -Hero $hero -Config $config -LogPath $logPath
      Remove-RRHeroStaging -CandidateId $cand.id

      if (-not $pubResult.Ok) {
        Write-RRLog -Path $logPath -Message "Publisher unavailable/failed for '$($cand.title)' ($($pubResult.FailureKind)). Preserved for retry; stopping the publication phase for the rest of this run."
        $nextRetry = Get-RRNextRetryAt -FailureKind $pubResult.FailureKind -RetryCount 0 -Config $config
        Add-RRQueueItem -Queue $queue -Id $cand.id -Title $cand.title -Url $cand.url -Source $cand.source `
          -Classification 'PENDING_RETRY' -Reason "Publisher unavailable this run ($($pubResult.FailureKind))" -Status 'pending-retry' -RetryCount 0 -NextRetryAt $nextRetry
        $pilot.totalFailures++
        $gateClosed = $true
        continue
      }
      $pub = $pubResult.Data

      if ($pub.published -eq $true -and $pub.verified -eq $true) {
        # Increment directly on the in-memory $pilot (already known-fresh via the $gateOpen check
        # moments ago in this same single-threaded run) rather than re-reading pilot.json from
        # disk here — an earlier version re-read the whole object at this point, which silently
        # discarded every counter this run had already incremented in memory (totalRuns,
        # totalFeedItemsCollected, evaluatorClaudeRuns, etc. never made it to disk). Caught via a
        # full pipeline test with a stub publisher.
        $pilot.autoPublishedCount++
        $pilot.totalPublished++
        $pilot.publishedUrls = @($pilot.publishedUrls) + $pub.url
        Save-RRPilot $pilot
        Write-RRLog -Path $logPath -Message "`nAUTO PUBLICATION`nTitle: $($pub.title)`nSlug: $($pub.slug)`nBuild: PASS`nGit commit: $($pub.commit)`nProduction: PASS`nURL: $($pub.url)`n`nSOCIAL`nX: $($pub.x)`nFacebook: $($pub.facebook)`n`nPilot publications: $($pilot.autoPublishedCount) / $($pilot.maximumAutoPublished)"
      } else {
        $stage = if ($pub.failureStage) { $pub.failureStage } else { 'unknown' }
        Write-RRLog -Path $logPath -Message "NOT PUBLISHED: $($cand.title) [$stage] — $($pub.reason)"
        if ($stage -in @('build','git','push','verify')) { $pilot.totalFailures++ }
        Add-RRQueueItem -Queue $queue -Id $cand.id -Title $cand.title -Url $cand.url -Source $cand.source `
          -Classification 'NEW_ARTICLE_MANUAL' -Reason "Publisher declined/failed at [$stage]: $($pub.reason)" -Status 'queued'
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
