<#
.SYNOPSIS
  Run ONCE before the first real watch/dry-run test. Fetches every currently enabled feed and
  marks every item currently in those feeds as already-seen, WITHOUT invoking Claude, classifying
  anything, or writing/committing anything. This stops the first scheduled run from dumping up to
  candidateMaxAgeHours worth of backlog into a single (costly) Claude invocation. After this,
  watch.ps1 will only ever see genuinely new items that appear after the baseline timestamp.
.PARAMETER Force
  Required to re-baseline while a live pilot is currently active, since doing so would silently
  make the watcher blind to candidates the owner may already be expecting it to evaluate.
#>
param([switch]$Force)
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\collect.ps1"

$pilot = Get-RRPilot
if ($pilot.mode -eq 'live' -and $pilot.active -and -not $Force) {
  Write-Host "Refusing to re-baseline: the live pilot is currently ACTIVE." -ForegroundColor Red
  Write-Host "Re-baselining now would silently drop candidates the active pilot may still need to evaluate."
  Write-Host "Pass -Force only if you deliberately want to reset the seen-set during a live pilot."
  exit 1
}

Write-Host "=== Red Reactions Watch — Baseline Initialization ===" -ForegroundColor Cyan
$sources = Get-RRSources
$state = Get-RRState
$seen = @{}
if ($state.seen) { foreach ($p in $state.seen.PSObject.Properties) { $seen[$p.Name] = $p.Value } }
$seenUrls = New-Object System.Collections.Generic.HashSet[string]
foreach ($v in $seen.Values) {
  $u = if ($v -is [PSCustomObject]) { $v.url } elseif ($v -is [System.Collections.IDictionary]) { $v['url'] } else { $null }
  if ($u) { $n = Normalize-RRUrl $u; if ($n) { $seenUrls.Add($n) | Out-Null } }
}

$totalBefore = $seen.Count
$perSource = @{}
$totalMarked = 0

foreach ($feed in $sources.feeds) {
  if (-not $feed.enabled) { continue }
  $items = Get-RRFeedItems -Feed $feed -Config (Get-RRConfig)
  $count = 0
  foreach ($it in $items) {
    if (-not $it.url -and -not $it.guid) { continue }
    $id = New-RRCandidateId -Url $it.url -Guid $it.guid
    $normUrl = Normalize-RRUrl $it.url
    if (-not $seen.ContainsKey($id) -and -not ($normUrl -and $seenUrls.Contains($normUrl))) {
      $seen[$id] = @{ title = $it.title; url = $it.url; firstSeenAt = (Get-Date -Format 'o'); baselined = $true }
      if ($normUrl) { $seenUrls.Add($normUrl) | Out-Null }
      $count++
      $totalMarked++
    }
  }
  $perSource[$feed.name] = $count
  Write-Host ("  {0,-32} {1,4} item(s) baselined" -f $feed.name, $count)
}

$state.seen = $seen
$state | Add-Member -NotePropertyName 'baselinedAt' -NotePropertyValue (Get-Date -Format 'o') -Force
Save-RRState $state

Write-Host ""
Write-Host "Total feed items baselined this run: $totalMarked" -ForegroundColor Green
Write-Host "Total seen-set size now: $($seen.Count) (was $totalBefore)"
Write-Host ""
Write-Host "Claude was NOT invoked. No classification, no article, no commit, no push occurred."
Write-Host "From here on, only items that appear in these feeds AFTER this baseline will be treated as new."
Write-Host ""
Write-Host "Next: .\automation\rr-watch\run-pilot.ps1 -DryRun"
