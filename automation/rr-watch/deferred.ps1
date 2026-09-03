<#
.SYNOPSIS
  Deterministic (no-Claude) handling of the "auto-eligible-deferred" queue status: candidates
  Phase A already classified NEW_ARTICLE_AUTO_ELIGIBLE / TRAILER_AUTO_ELIGIBLE during a run where
  publication was withheld ONLY because of forced -DryRun, dry-run pilot mode, or an inactive
  pilot — never an actual publisher/image failure. These are kept separate from the ordinary
  manual editorial queue (status "queued") because they get a specific future behavior ordinary
  manual items do not: automatic re-entry into a later LIVE run's Phase A batch (see watch.ps1),
  so a story Claude already judged safe to auto-publish doesn't get permanently stranded behind
  the pilot flag that happened to be off at the moment it was evaluated.

  Nothing here ever invokes Claude, and nothing here ever publishes anything — this file only
  ages out, migrates, and deduplicates queue rows.
#>
. "$PSScriptRoot\lib\common.ps1"

# Matches the reason text watch.ps1 writes for the auto-eligible-but-not-published case (see the
# "$why" branch just above Add-RRQueueItem for NEW_ARTICLE_AUTO_ELIGIBLE in watch.ps1) — and
# nothing else. Deliberately does NOT match "Publisher declined/failed at [...]" reasons: those
# are real image/publisher failures from candidates that actually attempted (and failed) Phase B,
# which stay ordinary manual queue items unless independently reconsidered later.
function Test-RRDeferralReason {
  param([string]$Reason)
  if (-not $Reason) { return $false }
  return ($Reason -match '(?i)^Auto-eligible but not published:\s*(forced\s*-?DryRun|pilot mode is dry-run|pilot is not active)')
}

# One-time-per-item, idempotent migration: ordinary 'queued' NEW_ARTICLE_AUTO_ELIGIBLE rows whose
# reason shows they were only held back by dry-run/inactive-pilot circumstances move to the
# dedicated 'auto-eligible-deferred' status. Safe to call on every watch.ps1 run — already-
# migrated items no longer match (their status is no longer 'queued'), so this is a no-op once
# the backlog has been migrated once. Never touches ordinary manual items or old image/publisher
# failures (their reason never matches Test-RRDeferralReason).
function Invoke-RRDeferredMigration {
  param($Queue, [string]$LogPath)
  $migrated = 0
  foreach ($item in $Queue.items) {
    if ($item.status -eq 'queued' -and $item.classification -eq 'NEW_ARTICLE_AUTO_ELIGIBLE' -and (Test-RRDeferralReason $item.reason)) {
      $item.status = 'auto-eligible-deferred'
      $migrated++
    }
  }
  if ($LogPath -and $migrated -gt 0) {
    Write-RRLog -Path $LogPath -Message "Deferred-queue migration: $migrated auto-eligible item(s) held back only by dry-run/inactive-pilot moved from 'queued' to 'auto-eligible-deferred' (eligible for future automatic reconsideration on a live run). Ordinary manual items and old image/publisher failures were left untouched."
  }
  return $migrated
}

# Deterministic queue maintenance for the deferred bucket, mirroring watch.ps1's overflow-queue
# maintenance: ages out anything past config.autoEligibleDeferredMaxAgeHours (measured from
# discoveredAt — i.e. the original candidate age, not merely time-since-deferred, since these are
# meant to be breaking-news/trailer items that go stale) without ever invoking Claude, and
# collapses duplicate normalized-URL/title+source rows (keeping the most recently
# (re-)discovered/evaluated one, since deferred items don't carry a meaningful relevance score to
# rank by). Runs every watch.ps1 invocation, independent of whether the evaluator runs this hour.
function Invoke-RRDeferredMaintenance {
  param($Queue, $Config, [string]$LogPath)
  $now = (Get-Date).ToUniversalTime()
  $maxAge = [double]$Config.autoEligibleDeferredMaxAgeHours
  $others = @($Queue.items | Where-Object { $_.status -ne 'auto-eligible-deferred' })
  $deferred = @($Queue.items | Where-Object { $_.status -eq 'auto-eligible-deferred' })

  $fresh = @()
  $expiredCount = 0
  foreach ($d in $deferred) {
    $age = [TimeSpan]::Zero
    try { $age = $now - [DateTime]::Parse($d.discoveredAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $age = [TimeSpan]::Zero }
    if ($age.TotalHours -gt $maxAge) {
      $expiredCount++
      # Preserved as manual/expired history rather than deleted outright — never re-entered into
      # an evaluator batch automatically again, and explicitly NOT counted as an ordinary manual
      # queue item by anything that only checks status == 'queued'.
      $d.status = 'auto-eligible-expired'
      $d.reason = "$($d.reason) [expired: exceeded autoEligibleDeferredMaxAgeHours ($maxAge h) without a live run reconfirming it]"
      $others += $d
      continue
    }
    $fresh += $d
  }

  $groups = $fresh | Group-Object -Property { Get-RRStoryKey $_ }
  $collapsed = @()
  $collapsedCount = 0
  foreach ($g in $groups) {
    if ($g.Group.Count -gt 1) { $collapsedCount += ($g.Group.Count - 1) }
    $best = $g.Group | Sort-Object -Property @{ Expression = { [DateTime]::Parse($_.lastEvaluatedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } ; Descending = $true } | Select-Object -First 1
    $collapsed += $best
  }

  if ($LogPath -and ($expiredCount -gt 0 -or $collapsedCount -gt 0)) {
    Write-RRLog -Path $LogPath -Message "Deferred queue maintenance: $expiredCount expired (exceeded ${maxAge}h, dropped from automatic consideration without Claude), $collapsedCount duplicate(s) collapsed. $($collapsed.Count) retained as auto-eligible-deferred."
  }

  $Queue.items = @($others) + $collapsed
}

# Returns non-expired auto-eligible-deferred queue rows reshaped to the same candidate shape
# batch/retry candidates already use (id/title/url/source/category/publishedAt/summary/
# discoveredAt) so they can be merged straight into a Phase A batch. Oldest-discovered first
# (FIFO) — no other "due" concept applies to this status (no retry backoff; age-based expiry is
# handled separately by Invoke-RRDeferredMaintenance, which must run before this is called so
# nothing already past the age limit is offered here).
function Get-RRDueDeferredCandidates {
  param($Queue)
  $items = @($Queue.items | Where-Object { $_.status -eq 'auto-eligible-deferred' } | Sort-Object -Property discoveredAt)
  return @($items | ForEach-Object {
    [PSCustomObject]@{ id = $_.id; title = $_.title; url = $_.url; source = $_.source; category = $null; publishedAt = $null; summary = $null; discoveredAt = $_.discoveredAt }
  })
}

# Pure batch-building step, factored out of watch.ps1 so it's directly unit-testable without
# running the full collect/filter/evaluator pipeline. $Batch is whatever watch.ps1 has already
# assembled from fresh strong candidates + due retries/overflow (both always take priority — this
# only ever ADDS to $Batch, never removes or reorders what's already in it). Returns unchanged
# when $CanPublish is false (a forced -DryRun or a dry-run/inactive pilot would just re-defer the
# same candidates identically, spending a Claude call for nothing) or when the batch is already at
# config.maxCandidatesPerClaudeRun. Deduplicates every due deferred candidate against everything
# already in $Batch via Get-RRStoryKey — see watch.ps1's call site for why a colliding deferred
# duplicate is simply skipped rather than merged.
function Merge-RRDeferredIntoBatch {
  param([array]$Batch, $Queue, $Config, [bool]$CanPublish, [string]$LogPath)
  if (-not $CanPublish) { return $Batch }
  $remainingSlots = [Math]::Max(0, [int]$Config.maxCandidatesPerClaudeRun - $Batch.Count)
  if ($remainingSlots -le 0) { return $Batch }

  $batchKeys = New-Object System.Collections.Generic.HashSet[string]
  foreach ($b in $Batch) { $batchKeys.Add((Get-RRStoryKey $b)) | Out-Null }
  $dueDeferred = @(Get-RRDueDeferredCandidates -Queue $Queue | Where-Object { -not $batchKeys.Contains((Get-RRStoryKey $_)) })
  if ($dueDeferred.Count -eq 0) { return $Batch }

  $toAdd = @($dueDeferred | Select-Object -First $remainingSlots)
  if ($LogPath) {
    Write-RRLog -Path $LogPath -Message "Adding $($toAdd.Count) auto-eligible-deferred candidate(s) (of $($dueDeferred.Count) eligible) into this run's batch for Phase A reconfirmation."
  }
  return @($Batch + $toAdd)
}
