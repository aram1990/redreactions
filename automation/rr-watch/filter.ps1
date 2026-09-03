<#
.SYNOPSIS
  Cheap, deterministic, non-AI filtering. Removes anything Claude does not need to see:
  already-seen URLs/GUIDs, stale items, exact repeated headlines within the batch, and
  obviously non-English/garbage titles. Everything that survives is a genuinely new candidate.
#>
. "$PSScriptRoot\lib\common.ps1"

function Test-RRLooksEnglish {
  param([string]$Title)
  if (-not $Title) { return $false }
  $letters = ($Title.ToCharArray() | Where-Object { [char]::IsLetter($_) })
  if ($letters.Count -eq 0) { return $false }
  $ascii = ($letters | Where-Object { [int][char]$_ -lt 256 })
  return (($ascii.Count / $letters.Count) -gt 0.85)
}

function Invoke-RRFilter {
  param([array]$RawCandidates, $State, $Config)

  $seen = $State.seen
  if ($seen -isnot [System.Collections.IDictionary] -and $seen -isnot [PSCustomObject]) { $seen = [PSCustomObject]@{} }
  $seenHash = @{}
  if ($seen) { foreach ($p in $seen.PSObject.Properties) { $seenHash[$p.Name] = $p.Value } }

  $maxAge = [TimeSpan]::FromHours($Config.candidateMaxAgeHours)
  $now = Get-Date

  $newOnes = @()
  $seenTitlesThisBatch = New-Object System.Collections.Generic.HashSet[string]

  foreach ($c in $RawCandidates) {
    if (-not $c.url -and -not $c.guid) { continue }
    $id = New-RRCandidateId -Url $c.url -Guid $c.guid
    if ($seenHash.ContainsKey($id)) { continue }

    $normTitle = ($c.title -replace '\s+', ' ').Trim().ToLowerInvariant()
    if (-not $normTitle) { continue }
    if ($seenTitlesThisBatch.Contains($normTitle)) { continue }

    if ($c.publishedAt) {
      try {
        $pub = [DateTime]::Parse($c.publishedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        if (($now.ToUniversalTime() - $pub) -gt $maxAge) { continue }
      } catch { }
    }

    if (-not (Test-RRLooksEnglish -Title $c.title)) { continue }

    $seenTitlesThisBatch.Add($normTitle) | Out-Null
    $seenHash[$id] = @{ title = $c.title; url = $c.url; firstSeenAt = (Get-Date -Format 'o') }

    $newOnes += [PSCustomObject]@{
      id = $id; title = $c.title; url = $c.url; source = $c.source; category = $c.category
      publishedAt = $c.publishedAt; summary = $c.summary; discoveredAt = (Get-Date -Format 'o')
    }
  }

  $State.seen = $seenHash
  return [PSCustomObject]@{ candidates = $newOnes; state = $State }
}

if ($MyInvocation.InvocationName -ne '.') {
  $raw = Invoke-RRCollect
  $state = Get-RRState
  $config = Get-RRConfig
  $result = Invoke-RRFilter -RawCandidates $raw -State $state -Config $config
  $result.candidates | ConvertTo-Json -Depth 10
}
