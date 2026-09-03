# Shared helpers for the Red Reactions watch automation.
# Dot-source this file from every entry-point script:  . "$PSScriptRoot\lib\common.ps1"

$script:RRRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $RRRoot 'config.json'))) { $RRRoot = $PSScriptRoot }
$script:RepoRoot = Split-Path -Parent $RRRoot

function Get-RRConfig { Get-Content (Join-Path $RRRoot 'config.json') -Raw | ConvertFrom-Json }
function Get-RRPilot { Get-Content (Join-Path $RRRoot 'pilot.json') -Raw | ConvertFrom-Json }
function Save-RRPilot($obj) { $obj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $RRRoot 'pilot.json') -Encoding utf8 }
function Get-RRState { Get-Content (Join-Path $RRRoot 'state.json') -Raw | ConvertFrom-Json }
function Save-RRState($obj) { $obj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $RRRoot 'state.json') -Encoding utf8 }
function Get-RRQueue { Get-Content (Join-Path $RRRoot 'queue.json') -Raw | ConvertFrom-Json }
function Save-RRQueue($obj) { $obj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $RRRoot 'queue.json') -Encoding utf8 }
function Get-RRSources { Get-Content (Join-Path $RRRoot 'sources.json') -Raw | ConvertFrom-Json }

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
      $pid_ = Get-Content $Path -Raw | ConvertFrom-Json
      $proc = Get-Process -Id $pid_.pid -ErrorAction SilentlyContinue
      if ($proc) { return $false }
    } catch {}
  }
  @{ pid = $PID; startedAt = (Get-Date -Format 'o') } | ConvertTo-Json | Set-Content $Path -Encoding utf8
  return $true
}
function Exit-RRLock { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

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
