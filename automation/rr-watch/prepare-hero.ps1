<#
.SYNOPSIS
  Deterministic, non-AI hero-image preparation. The evaluator is no longer required to find a
  direct image-file URL: it may instead identify an official SOURCE PAGE (press page, newsroom,
  media kit, trailer page) and this script discovers the actual image itself by fetching that
  page and reading its standard sharing metadata (og:image, twitter:image, link[rel=image_src],
  JSON-LD), or — for an official trailer — deriving the standard YouTube thumbnail URL. Either
  way, Claude is never invoked for any part of hero discovery, and the publisher is never invoked
  until a real, validated local image file exists.

  Never executes downloaded content. Only ever writes to the staging directory below.
#>
. "$PSScriptRoot\lib\common.ps1"

$script:RRAcceptedHeroSourceTypes = @(
  'official-press-page', 'official-newsroom', 'official-media-kit', 'official-trailer-page',
  'official-trailer-thumbnail', 'evaluator-identified-official', 'other-official-promotional'
)
$script:RRTrailerSourceTypes = @('official-trailer-page', 'official-trailer-thumbnail')

function Test-RRAcceptableHeroSourceType {
  param([string]$SourceType)
  if (-not $SourceType) { return $false }
  return ($RRAcceptedHeroSourceTypes -contains $SourceType)
}

# Blocks generic entertainment/gaming press domains from being used as an automated
# image-extraction source, regardless of what heroSourceType the evaluator claims — see
# relevance-rules.json's nonOfficialHeroDomains. A subdomain of a blocked domain is also blocked.
function Test-RRHeroDomainAllowed {
  param([string]$Url, [string]$LogPath)
  $uri = $null
  if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
  $host_ = $uri.Host.ToLowerInvariant()
  $rules = Get-Content (Join-Path $RRRoot 'relevance-rules.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $blocked = @($rules.nonOfficialHeroDomains)
  foreach ($b in $blocked) {
    $bl = $b.ToLowerInvariant()
    if ($host_ -eq $bl -or $host_.EndsWith(".$bl")) {
      if ($LogPath) { Write-RRLog -Path $LogPath -Message "[hero-prep] Rejected '$host_' as a hero source page: matches non-official outlet domain '$bl'." }
      return $false
    }
  }
  return $true
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

function Resolve-RRAbsoluteUrl {
  param([string]$MaybeRelative, [string]$BaseUrl)
  if (-not $MaybeRelative) { return $null }
  $abs = $null
  if ([System.Uri]::TryCreate($MaybeRelative, [System.UriKind]::Absolute, [ref]$abs)) { return $abs.AbsoluteUri }
  $baseUri = $null
  if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$baseUri)) { return $null }
  $resolved = $null
  if ([System.Uri]::TryCreate($baseUri, $MaybeRelative, [ref]$resolved)) { return $resolved.AbsoluteUri }
  return $null
}

function Get-RRMetaTagContent {
  # Attribute-order-agnostic <meta> extraction: finds every <meta> tag, then checks whether it
  # carries the given attribute/value pair, then reads its content= regardless of attribute order.
  param([string]$Html, [string]$AttrName, [string]$AttrValue)
  $tags = [regex]::Matches($Html, '<meta\b[^>]*>', 'IgnoreCase')
  foreach ($t in $tags) {
    $tag = $t.Value
    $attrMatch = [regex]::Match($tag, "$AttrName\s*=\s*[""']([^""']+)[""']", 'IgnoreCase')
    if ($attrMatch.Success -and $attrMatch.Groups[1].Value -ieq $AttrValue) {
      $contentMatch = [regex]::Match($tag, "content\s*=\s*[""']([^""']*)[""']", 'IgnoreCase')
      if ($contentMatch.Success -and $contentMatch.Groups[1].Value) { return $contentMatch.Groups[1].Value }
    }
  }
  return $null
}

function Get-RRLinkTagHref {
  param([string]$Html, [string]$Rel)
  $tags = [regex]::Matches($Html, '<link\b[^>]*>', 'IgnoreCase')
  foreach ($t in $tags) {
    $tag = $t.Value
    $relMatch = [regex]::Match($tag, "rel\s*=\s*[""']([^""']+)[""']", 'IgnoreCase')
    if ($relMatch.Success -and $relMatch.Groups[1].Value -ieq $Rel) {
      $hrefMatch = [regex]::Match($tag, "href\s*=\s*[""']([^""']*)[""']", 'IgnoreCase')
      if ($hrefMatch.Success -and $hrefMatch.Groups[1].Value) { return $hrefMatch.Groups[1].Value }
    }
  }
  return $null
}

# Best-effort, depth-limited search for an "image" (or "imageUrl") field inside parsed JSON-LD —
# handles a string, an object with a "url", or an array of either, and a top-level "@graph".
function Find-RRJsonLdImage {
  param($Node, [int]$Depth = 0)
  if ($Depth -gt 4 -or $null -eq $Node) { return $null }
  if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string]) -and -not ($Node -is [PSCustomObject])) {
    foreach ($item in $Node) { $r = Find-RRJsonLdImage -Node $item -Depth ($Depth + 1); if ($r) { return $r } }
    return $null
  }
  if ($Node -is [PSCustomObject]) {
    foreach ($fieldName in @('image', 'imageUrl', 'thumbnailUrl')) {
      $val = $Node.PSObject.Properties[$fieldName]
      if ($val) {
        $v = $val.Value
        if ($v -is [string] -and $v) { return $v }
        if ($v -is [PSCustomObject] -and $v.url) { return $v.url }
        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
          foreach ($item in $v) {
            if ($item -is [string] -and $item) { return $item }
            if ($item -is [PSCustomObject] -and $item.url) { return $item.url }
          }
        }
      }
    }
    if ($Node.PSObject.Properties['@graph']) { $r = Find-RRJsonLdImage -Node $Node.'@graph' -Depth ($Depth + 1); if ($r) { return $r } }
  }
  return $null
}

function Get-RRJsonLdImageFromHtml {
  param([string]$Html)
  $blocks = [regex]::Matches($Html, '(?is)<script[^>]+type\s*=\s*["'']application/ld\+json["''][^>]*>(.*?)</script>')
  foreach ($b in $blocks) {
    $raw = $b.Groups[1].Value.Trim()
    if (-not $raw) { continue }
    try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    $img = Find-RRJsonLdImage -Node $parsed
    if ($img) { return $img }
  }
  return $null
}

<#
.SYNOPSIS
  Fetches an official source page and returns the highest-priority image URL from its standard
  sharing metadata, already resolved to an absolute URL. Returns $null if the page can't be
  fetched or carries no usable image metadata — never throws for that ordinary case.
#>
function Find-RRHeroImageFromPage {
  param([string]$PageUrl, $Config, [string]$LogPath)

  try {
    $resp = Invoke-WebRequest -Uri $PageUrl -TimeoutSec ([int]$Config.heroDownloadTimeoutSeconds) `
      -UserAgent $Config.userAgent -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
  } catch {
    Write-RRLog -Path $LogPath -Message "[hero-prep] Could not fetch source page '$PageUrl': $($_.Exception.Message)"
    return $null
  }
  $contentType = ($resp.Headers['Content-Type'] | Select-Object -First 1)
  if ($contentType -and $contentType -notmatch '(?i)text/html') {
    Write-RRLog -Path $LogPath -Message "[hero-prep] Source page '$PageUrl' did not return HTML (content-type: $contentType)."
    return $null
  }
  $html = $resp.Content

  $candidate = Get-RRMetaTagContent -Html $html -AttrName 'property' -AttrValue 'og:image'
  $via = 'og:image'
  if (-not $candidate) { $candidate = Get-RRMetaTagContent -Html $html -AttrName 'name' -AttrValue 'twitter:image'; $via = 'twitter:image (name)' }
  if (-not $candidate) { $candidate = Get-RRMetaTagContent -Html $html -AttrName 'property' -AttrValue 'twitter:image'; $via = 'twitter:image (property)' }
  if (-not $candidate) { $candidate = Get-RRLinkTagHref -Html $html -Rel 'image_src'; $via = 'link[rel=image_src]' }
  if (-not $candidate) { $candidate = Get-RRJsonLdImageFromHtml -Html $html; $via = 'JSON-LD' }

  if (-not $candidate) {
    Write-RRLog -Path $LogPath -Message "[hero-prep] No og:image/twitter:image/image_src/JSON-LD image metadata found on '$PageUrl'."
    return $null
  }

  $absolute = Resolve-RRAbsoluteUrl -MaybeRelative $candidate -BaseUrl $PageUrl
  if (-not $absolute) {
    Write-RRLog -Path $LogPath -Message "[hero-prep] Found a candidate image via $via ('$candidate') but could not resolve it to an absolute URL against '$PageUrl'."
    return $null
  }

  $pageHost = ([System.Uri]$PageUrl).Host
  $imgHost = ([System.Uri]$absolute).Host
  Write-RRLog -Path $LogPath -Message "[hero-prep] Found hero image via $via on '$pageHost': '$absolute' (image host: '$imgHost'). CDN hosts commonly differ from the page host — that alone is not a rejection reason."
  return $absolute
}

# Standard YouTube ID patterns: watch?v=ID, youtu.be/ID, /embed/ID, /shorts/ID.
function Get-RRYouTubeVideoId {
  param([string]$Url)
  if (-not $Url) { return $null }
  $patterns = @(
    'youtube\.com/watch\?[^ ]*v=([A-Za-z0-9_-]{11})',
    'youtu\.be/([A-Za-z0-9_-]{11})',
    'youtube\.com/embed/([A-Za-z0-9_-]{11})',
    'youtube\.com/shorts/([A-Za-z0-9_-]{11})'
  )
  foreach ($p in $patterns) {
    $m = [regex]::Match($Url, $p, 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}

<#
.SYNOPSIS
  Downloads, validates and stages exactly one candidate image URL. Shared by the direct-URL path,
  the page-metadata-discovery path, and the YouTube-thumbnail-fallback path. Never throws for an
  ordinary failure (bad URL, wrong type, too small/large, doesn't decode) — returns Ok=$false with
  a Reason instead.
#>
function Save-RRValidatedImage {
  param([string]$CandidateId, [string]$ImageUrl, $Config, [string]$LogPath)

  $fail = { param($Reason) [PSCustomObject]@{ Ok = $false; Reason = $Reason; LocalPath = $null; Mime = $null; Bytes = 0 } }

  $uri = $null
  if (-not [System.Uri]::TryCreate($ImageUrl, [System.UriKind]::Absolute, [ref]$uri)) {
    return (& $fail "Image URL is not a valid absolute URL: $ImageUrl")
  }
  if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
    return (& $fail "Image URL scheme must be http/https, got '$($uri.Scheme)'")
  }

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

  Write-RRLog -Path $LogPath -Message "[hero-prep] OK: staged $finalPath ($bytes bytes, $mime, ${w}x${h}) from $ImageUrl"

  return [PSCustomObject]@{ Ok = $true; Reason = $null; LocalPath = $finalPath; Mime = $mime; Bytes = $bytes; Width = $w; Height = $h }
}

<#
.SYNOPSIS
  Full hero-prep flow for one candidate. Tries, in order: (1) a direct heroImageUrl if the
  evaluator already provided one; (2) discovering an image from heroSourcePageUrl's own sharing
  metadata (og:image / twitter:image / image_src / JSON-LD), deterministically, no Claude; (3) a
  derived official YouTube thumbnail when the source type is a trailer type and a YouTube video
  URL is available. Returns Ok=$false with a Reason — never throws — when nothing usable is found,
  which the caller must treat as IMAGE_PREP_REQUIRED and NOT invoke the publisher.
#>
function Invoke-RRPrepareHero {
  param(
    [string]$CandidateId,
    [string]$HeroImageUrl,
    [string]$HeroSourceUrl,
    [string]$HeroSourcePageUrl,
    [string]$HeroCredit,
    [string]$HeroSourceType,
    [string]$CandidateUrl,
    $Config,
    [string]$LogPath
  )

  $resolvedSourceUrl = if ($HeroSourceUrl) { $HeroSourceUrl } else { $HeroSourcePageUrl }
  $fail = { param($Reason) [PSCustomObject]@{ Ok = $false; Reason = $Reason; LocalPath = $null; Credit = $HeroCredit; SourceUrl = $resolvedSourceUrl; Mime = $null; Bytes = 0 } }
  $ok = { param($Saved) [PSCustomObject]@{ Ok = $true; Reason = $null; LocalPath = $Saved.LocalPath; Credit = $HeroCredit; SourceUrl = $resolvedSourceUrl; Mime = $Saved.Mime; Bytes = $Saved.Bytes; Width = $Saved.Width; Height = $Saved.Height } }

  if (-not (Test-RRAcceptableHeroSourceType -SourceType $HeroSourceType)) {
    return (& $fail "heroSourceType '$HeroSourceType' is not an accepted official/primary source type")
  }

  # 1) A direct image URL, if the evaluator already knows one confidently.
  if ($HeroImageUrl) {
    Write-RRLog -Path $LogPath -Message "[hero-prep] Candidate ${CandidateId}: using evaluator-provided direct heroImageUrl."
    $saved = Save-RRValidatedImage -CandidateId $CandidateId -ImageUrl $HeroImageUrl -Config $Config -LogPath $LogPath
    if ($saved.Ok) { return (& $ok $saved) }
    Write-RRLog -Path $LogPath -Message "[hero-prep] Direct heroImageUrl failed ($($saved.Reason)); falling back to source-page discovery if available."
  }

  # 2) Discover from the official source page's own sharing metadata.
  if ($HeroSourcePageUrl) {
    if (-not (Test-RRHeroDomainAllowed -Url $HeroSourcePageUrl -LogPath $LogPath)) {
      if (-not $HeroImageUrl) { return (& $fail "heroSourcePageUrl '$HeroSourcePageUrl' is on a non-official/general-outlet domain; automated image extraction is not allowed from it") }
    } else {
      $discovered = Find-RRHeroImageFromPage -PageUrl $HeroSourcePageUrl -Config $Config -LogPath $LogPath
      if ($discovered) {
        $saved = Save-RRValidatedImage -CandidateId $CandidateId -ImageUrl $discovered -Config $Config -LogPath $LogPath
        if ($saved.Ok) { return (& $ok $saved) }
        Write-RRLog -Path $LogPath -Message "[hero-prep] Discovered image '$discovered' failed validation: $($saved.Reason)"
      }
    }
  }

  # 3) Official trailer thumbnail fallback, derived deterministically from a YouTube video URL.
  if ($HeroSourceType -in $RRTrailerSourceTypes) {
    $videoUrl = if ($CandidateUrl -and (Get-RRYouTubeVideoId -Url $CandidateUrl)) { $CandidateUrl } elseif ($HeroSourcePageUrl -and (Get-RRYouTubeVideoId -Url $HeroSourcePageUrl)) { $HeroSourcePageUrl } else { $null }
    $videoId = Get-RRYouTubeVideoId -Url $videoUrl
    if ($videoId) {
      foreach ($quality in @('maxresdefault', 'hqdefault')) {
        $thumbUrl = "https://img.youtube.com/vi/$videoId/$quality.jpg"
        Write-RRLog -Path $LogPath -Message "[hero-prep] Trying official-trailer-thumbnail fallback for video $videoId ($quality)."
        $saved = Save-RRValidatedImage -CandidateId $CandidateId -ImageUrl $thumbUrl -Config $Config -LogPath $LogPath
        if ($saved.Ok) {
          Write-RRLog -Path $LogPath -Message "[hero-prep] official-trailer-thumbnail fallback succeeded ($quality) for video $videoId."
          return (& $ok $saved)
        }
      }
      Write-RRLog -Path $LogPath -Message "[hero-prep] official-trailer-thumbnail fallback exhausted for video $videoId; no usable thumbnail found."
    }
  }

  return (& $fail "No usable hero image: no valid direct URL, no extractable metadata image on the official source page, and no official trailer thumbnail available")
}

function Remove-RRHeroStaging {
  param([string]$CandidateId)
  $dir = Join-Path $RRRoot "staging\$CandidateId"
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
