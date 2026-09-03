<#
.SYNOPSIS
  Deterministic, non-AI relevance + priority scoring. Runs AFTER filter.ps1 (seen/stale/dupe
  removal) and BEFORE Claude. Rejects obvious noise outright, scores everything else using
  relevance-rules.json (source tier + keyword/franchise signals + breaking-news combos), and
  returns only the strongest candidates — capped at config.maxCandidatesPerClaudeRun — so Claude
  is the FINAL filter, never the first one.

  Anything strong that doesn't fit this run's cap is split into two buckets: Overflow (score also
  clears a HIGHER retention bar — minScoreByTier + config.overflowMinScoreBonus — so it's worth
  keeping around for a later run) and Dropped (strong enough for THIS run's five, not strong
  enough to be worth carrying forward; logged, never sent to Claude). Nothing in either bucket
  costs a Claude call by existing — see watch.ps1's overflow-queue maintenance for aging/capping.
#>
. "$PSScriptRoot\lib\common.ps1"

function Get-RRRelevanceRules { Get-Content (Join-Path $RRRoot 'relevance-rules.json') -Raw -Encoding UTF8 | ConvertFrom-Json }

function Get-RRCandidateScore {
  param($Candidate, $Rules, [int]$Tier)

  $text = (("$($Candidate.title) $($Candidate.summary)") -replace '\s+', ' ').ToLowerInvariant()

  foreach ($neg in $Rules.negativeKeywords) {
    if ($text -like "*$($neg.ToLowerInvariant())*") {
      return [PSCustomObject]@{ Rejected = $true; RejectReason = "negative keyword: $neg"; Score = -1; Breaking = $false }
    }
  }

  $score = 0
  $highHits = @($Rules.positiveKeywordsHigh | Where-Object { $text -like "*$($_.ToLowerInvariant())*" })
  $mediumHits = @($Rules.positiveKeywordsMedium | Where-Object { $text -like "*$($_.ToLowerInvariant())*" })
  $franchiseHits = @($Rules.franchisesStudiosPlatforms | Where-Object { $text -like "*$($_.ToLowerInvariant())*" })

  $score += $highHits.Count * $Rules.scoring.highKeywordWeight
  $score += $mediumHits.Count * $Rules.scoring.mediumKeywordWeight
  $score += $franchiseHits.Count * $Rules.scoring.franchiseWeight
  $score += [int]($Rules.scoring.tierWeight."$Tier")

  $breaking = $false
  foreach ($combo in $Rules.breakingCombos) {
    $a = @($combo.requireAny) | Where-Object { $text -like "*$($_.ToLowerInvariant())*" }
    if ($a.Count -eq 0) { continue }
    $b = @($combo.requireAny2)
    if ($b.Count -eq 0 -or (@($b | Where-Object { $text -like "*$($_.ToLowerInvariant())*" }).Count -gt 0)) {
      $breaking = $true
      break
    }
  }
  if ($breaking) { $score += $Rules.scoring.breakingBonus }

  $minScore = [int]($Rules.scoring.minScoreByTier."$Tier")
  $passed = $score -ge $minScore

  return [PSCustomObject]@{
    Rejected = -not $passed; RejectReason = if (-not $passed) { "below tier-$Tier threshold ($score < $minScore)" } else { $null }
    Score = $score; Breaking = $breaking; MinScore = $minScore
  }
}

function Invoke-RRPrioritize {
  param([array]$Candidates, $Config, [string]$LogPath)

  $rules = Get-RRRelevanceRules
  $sources = Get-RRSources
  $tierBySource = @{}
  foreach ($f in $sources.feeds) { $tierBySource[$f.name] = [int]$f.tier }
  $overflowBonus = [int]$Config.overflowMinScoreBonus

  $scored = @()
  $rejected = 0
  foreach ($c in $Candidates) {
    $tier = if ($tierBySource.ContainsKey($c.source)) { $tierBySource[$c.source] } else { 3 }
    $r = Get-RRCandidateScore -Candidate $c -Rules $rules -Tier $tier
    if ($r.Rejected) { $rejected++; continue }
    $scored += [PSCustomObject]@{ Candidate = $c; Score = $r.Score; Breaking = $r.Breaking; Tier = $tier; OverflowMinScore = ($r.MinScore + $overflowBonus) }
  }

  $ranked = $scored | Sort-Object -Property @{Expression='Breaking';Descending=$true}, @{Expression='Score';Descending=$true}, @{Expression='Tier';Descending=$false}
  $cap = [int]$Config.maxCandidatesPerClaudeRun
  $toSend = @($ranked | Select-Object -First $cap)
  $rest = @($ranked | Select-Object -Skip $cap)

  $overflow = @($rest | Where-Object { $_.Score -ge $_.OverflowMinScore })
  $droppedLowValue = @($rest | Where-Object { $_.Score -lt $_.OverflowMinScore })

  if ($LogPath) {
    Write-RRLog -Path $LogPath -Message "Deterministic relevance filter: $($Candidates.Count) new candidate(s) -> $rejected rejected (noise/below threshold), $($scored.Count) strong, $($toSend.Count) sent to Claude this run, $($overflow.Count) strong-but-capped retained as overflow, $($droppedLowValue.Count) strong-but-capped dropped (below overflow retention bar, logged only)."
    foreach ($d in $droppedLowValue) { Write-RRLog -Path $LogPath -Message "  filtered/low-priority (not queued): [$($d.Score)/$($d.OverflowMinScore)] $($d.Candidate.title)" }
  }

  return [PSCustomObject]@{
    Strong = @($toSend | ForEach-Object { $_.Candidate })
    Overflow = @($overflow | ForEach-Object { [PSCustomObject]@{ Candidate = $_.Candidate; Score = $_.Score } })
    RejectedCount = $rejected
    StrongCount = $scored.Count
    DroppedLowValueCount = $droppedLowValue.Count
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  . "$PSScriptRoot\collect.ps1"
  . "$PSScriptRoot\filter.ps1"
  $raw = Invoke-RRCollect
  $state = Get-RRState
  $config = Get-RRConfig
  $f = Invoke-RRFilter -RawCandidates $raw -State $state -Config $config
  $p = Invoke-RRPrioritize -Candidates $f.candidates -Config $config
  $p | ConvertTo-Json -Depth 10
}
