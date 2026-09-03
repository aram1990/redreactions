<#
.SYNOPSIS
  Deterministic, non-AI relevance + priority scoring. Runs AFTER filter.ps1 (seen/stale/dupe
  removal) and BEFORE Claude. Rejects obvious noise outright, scores everything else using
  relevance-rules.json (source tier + keyword/franchise signals + breaking-news combos), and
  returns only the strongest candidates — capped at config.maxCandidatesPerClaudeRun — so Claude
  is the FINAL filter, never the first one. Anything that scores but doesn't fit in this run's
  cap is returned separately so the caller can queue it for a later run, never discarded.
#>
. "$PSScriptRoot\lib\common.ps1"

function Get-RRRelevanceRules { Get-Content (Join-Path $RRRoot 'relevance-rules.json') -Raw | ConvertFrom-Json }

function Test-RRKeywordMatch {
  param([string]$Text, [array]$Keywords)
  foreach ($k in $Keywords) { if ($Text -like "*$k*") { return $true } }
  return $false
}

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
    Score = $score; Breaking = $breaking
  }
}

function Invoke-RRPrioritize {
  param([array]$Candidates, $Config, [string]$LogPath)

  $rules = Get-RRRelevanceRules
  $sources = Get-RRSources
  $tierBySource = @{}
  foreach ($f in $sources.feeds) { $tierBySource[$f.name] = [int]$f.tier }

  $scored = @()
  $rejected = 0
  foreach ($c in $Candidates) {
    $tier = if ($tierBySource.ContainsKey($c.source)) { $tierBySource[$c.source] } else { 3 }
    $r = Get-RRCandidateScore -Candidate $c -Rules $rules -Tier $tier
    if ($r.Rejected) { $rejected++; continue }
    $scored += [PSCustomObject]@{ Candidate = $c; Score = $r.Score; Breaking = $r.Breaking; Tier = $tier }
  }

  $ranked = $scored | Sort-Object -Property @{Expression='Breaking';Descending=$true}, @{Expression='Score';Descending=$true}, @{Expression='Tier';Descending=$false}
  $cap = [int]$Config.maxCandidatesPerClaudeRun
  $toSend = @($ranked | Select-Object -First $cap)
  $overflow = @($ranked | Select-Object -Skip $cap)

  if ($LogPath) {
    Write-RRLog -Path $LogPath -Message "Deterministic relevance filter: $($Candidates.Count) new candidate(s) -> $rejected rejected (noise/below threshold), $($scored.Count) strong, $($toSend.Count) sent to Claude this run, $($overflow.Count) strong-but-capped (queued for a later run)."
  }

  return [PSCustomObject]@{
    Strong = @($toSend | ForEach-Object { $_.Candidate })
    Overflow = @($overflow | ForEach-Object { $_.Candidate })
    RejectedCount = $rejected
    StrongCount = $scored.Count
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
