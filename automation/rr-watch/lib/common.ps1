# Shared helpers for the Red Reactions watch automation.
# Dot-source this file from every entry-point script:  . "$PSScriptRoot\lib\common.ps1"

$script:RRRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $RRRoot 'config.json'))) { $RRRoot = $PSScriptRoot }
# RRRoot is .../automation/rr-watch — the actual repo root is two levels up (past automation/).
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $RRRoot)

function Get-RRConfig { Get-Content (Join-Path $RRRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
# Fills in fields added by later patches so an on-disk pilot.json from an older version doesn't
# need a manual migration — new fields simply default to 0/null the first time they're read.
function Add-RRDefaultField {
  param($Obj, [string]$Name, $Default)
  if (-not ($Obj.PSObject.Properties.Name -contains $Name)) { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Default -Force }
}
function Get-RRPilot {
  $p = Get-Content (Join-Path $RRRoot 'pilot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Add-RRDefaultField $p 'zeroClaudeRuns' 0
  Add-RRDefaultField $p 'totalFeedItemsCollected' 0
  Add-RRDefaultField $p 'totalRemovedDeterministically' 0
  Add-RRDefaultField $p 'totalStrongCandidates' 0
  Add-RRDefaultField $p 'totalCandidatesSentToClaude' 0
  Add-RRDefaultField $p 'evaluatorClaudeRuns' 0
  Add-RRDefaultField $p 'publisherClaudeRuns' 0
  Add-RRDefaultField $p 'evaluatorRunsWindowStart' $null
  Add-RRDefaultField $p 'evaluatorRunsInWindow' 0
  return $p
}
function Save-RRPilot($obj) { $obj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $RRRoot 'pilot.json') -Encoding utf8 }
function Get-RRState { Get-Content (Join-Path $RRRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Save-RRState($obj) { $obj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $RRRoot 'state.json') -Encoding utf8 }
function Get-RRQueue { Get-Content (Join-Path $RRRoot 'queue.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Save-RRQueue($obj) { $obj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $RRRoot 'queue.json') -Encoding utf8 }
function Get-RRSources { Get-Content (Join-Path $RRRoot 'sources.json') -Raw -Encoding UTF8 | ConvertFrom-Json }

function Get-RRLogPath {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
  Join-Path $RRRoot "logs\run-$stamp.log"
}

function Write-RRLog {
  param([string]$Message, [string]$Path)
  Add-Content -Path $Path -Value $Message -Encoding utf8
}

function Normalize-RRUrl {
  param([string]$Url)
  if (-not $Url) { return '' }
  $u = $Url.Trim()
  $u = $u -replace '^https?://', ''
  $u = $u -replace '^www\.', ''
  $u = $u -split '[?#]' | Select-Object -First 1
  $u = $u.TrimEnd('/')
  return $u.ToLowerInvariant()
}

function New-RRCandidateId {
  param([string]$Url, [string]$Guid)
  $basis = if ($Guid) { $Guid } else { Normalize-RRUrl $Url }
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($basis))
  -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

# Acquire a simple lock file so the hourly task never overlaps itself.
function Enter-RRLock {
  param([string]$Path)
  if (Test-Path $Path) {
    try {
      $pid_ = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
      $proc = Get-Process -Id $pid_.pid -ErrorAction SilentlyContinue
      if ($proc) { return $false }
    } catch {}
  }
  @{ pid = $PID; startedAt = (Get-Date -Format 'o') } | ConvertTo-Json | Set-Content $Path -Encoding utf8
  return $true
}
function Exit-RRLock { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

# Environment variables that could route Claude Code through metered/API billing instead of the
# owner's Claude Code subscription login. Stripped from the CHILD process only — never touched in
# this PowerShell process or persisted to the system/user environment.
$script:RRBillingEnvVars = @(
  'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_CUSTOM_HEADERS',
  'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'ANTHROPIC_VERTEX_PROJECT_ID', 'CLOUD_ML_REGION',
  'ANTHROPIC_BEDROCK_BASE_URL', 'AWS_PROFILE', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
  'AWS_SESSION_TOKEN', 'AWS_REGION', 'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_FOUNDRY_ENDPOINT'
)

# Builds a ProcessStartInfo whose environment is an explicit copy of this process's environment
# with every known billing/routing-override variable removed. Returns the psi plus the list of
# variable NAMES actually stripped (never values) so callers can log without exposing secrets.
function New-RRSafeProcessStartInfo {
  param([string]$FileName, [string]$WorkingDirectory)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.UseShellExecute = $false
  # Explicit UTF-8 (no BOM) on every child stream. .NET's Process defaults these to the console's
  # current codepage, not UTF-8 — on a non-UTF-8 Windows codepage that silently mangles anything
  # non-ASCII a child process writes/reads (the "â€”"-style mojibake seen in real run logs), even
  # though the source files and JSON on disk were correctly UTF-8 all along.
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $psi.StandardOutputEncoding = $utf8NoBom
  $psi.StandardErrorEncoding = $utf8NoBom
  $psi.StandardInputEncoding = $utf8NoBom
  # .NET pre-populates psi.Environment from this process's current environment; we then remove
  # the risky keys from that COPY, leaving the parent PowerShell process's own environment (and
  # the Windows user/system environment) completely untouched.
  $stripped = @()
  foreach ($name in $RRBillingEnvVars) {
    if ($psi.Environment.ContainsKey($name)) { $psi.Environment.Remove($name) | Out-Null; $stripped += $name }
  }
  return [PSCustomObject]@{ Psi = $psi; StrippedVarNames = $stripped }
}

# Backoff for queue items that failed rather than merely being batch-capped. usage-limit failures
# get one long, fixed backoff (repeatedly retrying a usage-limited Claude every single hour just
# burns more attempts against the same limit); everything else escalates through
# config.retryBackoffHours by retryCount, capped at the schedule's last entry.
function Get-RRNextRetryAt {
  param([string]$FailureKind, [int]$RetryCount, $Config)
  if ($FailureKind -eq 'usage-limit') {
    return (Get-Date).ToUniversalTime().AddHours([double]$Config.usageLimitBackoffHours).ToString('o')
  }
  $schedule = @($Config.retryBackoffHours)
  $idx = [Math]::Min($RetryCount, $schedule.Count - 1)
  $hours = if ($idx -ge 0 -and $schedule.Count -gt 0) { [double]$schedule[$idx] } else { 1.0 }
  return (Get-Date).ToUniversalTime().AddHours($hours).ToString('o')
}

function Test-RRRetryDue {
  param($QueueItem)
  if (-not $QueueItem.nextRetryAt) { return $true }
  try { return ((Get-Date).ToUniversalTime() -ge [DateTime]::Parse($QueueItem.nextRetryAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) }
  catch { return $true }
}

function ConvertTo-RRHashtable {
  # Converts a nested PSCustomObject (as returned by ConvertFrom-Json) into an ordered hashtable tree.
  param($InputObject)
  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
    return @($InputObject | ForEach-Object { ConvertTo-RRHashtable $_ })
  }
  if ($InputObject -is [PSCustomObject]) {
    $h = [ordered]@{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-RRHashtable $p.Value }
    return $h
  }
  return $InputObject
}
