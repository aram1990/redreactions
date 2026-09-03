<#
.SYNOPSIS
  Deterministic, non-AI hero-image preparation. Downloads and validates a hero image URL that
  the evaluator identified as coming from an acceptable official/primary source, BEFORE the
  publisher Claude is ever invoked. Publisher Claude never fetches network images itself — it
  only receives an already-downloaded, already-validated local file path. This means a
  candidate that can never get a usable hero fails fast and cheaply (no Claude call at all)
  instead of wasting a full publisher invocation that was always going to abandon partway
  through.

  Never executes downloaded content. Only ever writes to the staging directory below.
#>
. "$PSScriptRoot\lib\common.ps1"

$script:RRAcceptedHeroSourceTypes = @(
  'official-press-page', 'official-newsroom', 'official-media-kit',
  'official-trailer-thumbnail', 'evaluator-identified-official', 'other-official-promotional'
)

function Test-RRAcceptableHeroSourceType {
  param([string]$SourceType)
  if (-not $SourceType) { return $false }
  return ($RRAcceptedHeroSourceTypes -contains $SourceType)
}

function Get-RRHeroStagingDir {
  param([string]$CandidateId)
  $dir = Join-Path $RRRoot "staging\$CandidateId"
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Get-RRExtensionForMime {
  param([string]$Mime)
  switch -Regex ($Mime) {
    'image/jpeg' { return '.jpg' }
    'image/png'  { return '.png' }
    'image/webp' { return '.webp' }
    default { return $null }
  }
}

<#
.SYNOPSIS
  Downloads, validates and stages exactly one hero candidate image. Returns a result object;
  never throws for an ordinary failure (bad URL, wrong type, too small/large) — those are
  reported as Ok=$false with a Reason, which the caller queues as IMAGE_PREP_REQUIRED instead
  of ever invoking the publisher.
#>
function Invoke-RRPrepareHero {
  param(
    [string]$CandidateId,
    [string]$HeroImageUrl,
    [string]$HeroSourceUrl,
    [string]$HeroCredit,
    [string]$HeroSourceType,
    $Config,
    [string]$LogPath
  )

  $fail = { param($Reason) [PSCustomObject]@{ Ok = $false; Reason = $Reason; LocalPath = $null; Credit = $HeroCredit; SourceUrl = $HeroSourceUrl; Mime = $null; Bytes = 0 } }

  if (-not $HeroImageUrl) { return (& $fail 'No heroImageUrl identified by the evaluator') }
  if (-not (Test-RRAcceptableHeroSourceType -SourceType $HeroSourceType)) {
    return (& $fail "heroSourceType '$HeroSourceType' is not an accepted official/primary source type")
  }

  $uri = $null
  if (-not [System.Uri]::TryCreate($HeroImageUrl, [System.UriKind]::Absolute, [ref]$uri)) {
    return (& $fail "heroImageUrl is not a valid absolute URL: $HeroImageUrl")
  }
  if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
    return (& $fail "heroImageUrl scheme must be http/https, got '$($uri.Scheme)'")
  }

  Write-RRLog -Path $LogPath -Message "[hero-prep] Downloading candidate hero for $CandidateId from $HeroImageUrl (source: $HeroSourceUrl, type: $HeroSourceType, credit: $HeroCredit)"

  $stagingDir = Get-RRHeroStagingDir -CandidateId $CandidateId
  $tmpPath = Join-Path $stagingDir 'download.tmp'

  try {
    $resp = Invoke-WebRequest -Uri $uri -TimeoutSec ([int]$Config.heroDownloadTimeoutSeconds) `
      -UserAgent $Config.userAgent -UseBasicParsing -MaximumRedirection 5 -OutFile $tmpPath -PassThru `
      -ErrorAction Stop
  } catch {
    if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue }
    return (& $fail "Download failed: $($_.Exception.Message)")
  }

  $mime = ($resp.Headers['Content-Type'] | Select-Object -First 1)
  if ($mime) { $mime = ($mime -split ';')[0].Trim().ToLowerInvariant() }

  $bytes = 0
  if (Test-Path $tmpPath) { $bytes = (Get-Item $tmpPath).Length }

  # Reject HTML/error-page responses masquerading as an image (some CDNs 200 an HTML error page).
  $looksLikeHtml = $false
  if ($bytes -gt 0) {
    $head = [System.IO.File]::ReadAllBytes($tmpPath) | Select-Object -First 512
    $headText = [System.Text.Encoding]::ASCII.GetString($head)
    if ($headText -match '(?i)<html|<!doctype') { $looksLikeHtml = $true }
  }

  if ($looksLikeHtml -or ($mime -and $mime -notmatch '^image/')) {
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
    return (& $fail "Response was not an image (content-type: '$mime')")
  }
  if (-not $mime -or ($Config.heroAllowedMimeTypes -notcontains $mime)) {
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
    return (& $fail "Unsupported or missing image MIME type: '$mime'")
  }
  if ($bytes -lt [int]$Config.heroMinBytes) {
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
    return (& $fail "Image too small to be a usable hero ($bytes bytes < $($Config.heroMinBytes))")
  }
  if ($bytes -gt [int]$Config.heroMaxBytes) {
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
    return (& $fail "Image too large ($bytes bytes > $($Config.heroMaxBytes))")
  }

  # Verify it actually decodes as an image (rejects corrupt/truncated downloads).
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $img = [System.Drawing.Image]::FromFile($tmpPath)
    $w = $img.Width; $h = $img.Height
    $img.Dispose()
    if ($w -lt 200 -or $h -lt 200) {
      Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
      return (& $fail "Decoded image is too small to be a usable hero (${w}x${h})")
    }
  } catch {
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
    return (& $fail "File did not decode as a valid image: $($_.Exception.Message)")
  }

  $ext = Get-RRExtensionForMime -Mime $mime
  if (-not $ext) { Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue; return (& $fail "Could not determine a safe file extension for '$mime'") }

  $finalPath = Join-Path $stagingDir "hero$ext"
  Move-Item -Path $tmpPath -Destination $finalPath -Force

  Write-RRLog -Path $LogPath -Message "[hero-prep] OK: staged $finalPath ($bytes bytes, $mime, ${w}x${h})"

  return [PSCustomObject]@{
    Ok = $true; Reason = $null; LocalPath = $finalPath; Credit = $HeroCredit; SourceUrl = $HeroSourceUrl
    Mime = $mime; Bytes = $bytes; Width = $w; Height = $h
  }
}

function Remove-RRHeroStaging {
  param([string]$CandidateId)
  $dir = Join-Path $RRRoot "staging\$CandidateId"
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
