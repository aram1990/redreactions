<#
.SYNOPSIS
  Non-AI collection step. Fetches every enabled RSS/Atom feed in sources.json and
  returns a flat array of raw candidate objects. No filtering/dedup happens here.
#>
. "$PSScriptRoot\lib\common.ps1"

function Get-RRFeedItems {
  param($Feed, $Config)
  $items = @()
  try {
    $resp = Invoke-WebRequest -Uri $Feed.url -TimeoutSec $Config.httpTimeoutSeconds -UserAgent $Config.userAgent -UseBasicParsing
    [xml]$xml = $resp.Content
  } catch {
    Write-Warning "[collect] Failed to fetch '$($Feed.name)': $($_.Exception.Message)"
    return @()
  }

  # RSS 2.0
  $rssItems = $xml.SelectNodes('//channel/item')
  if ($rssItems -and $rssItems.Count -gt 0) {
    foreach ($it in $rssItems) {
      $titleNode = $it.SelectSingleNode('title'); $title = if ($titleNode) { $titleNode.InnerText.Trim() } else { '' }
      $linkNode = $it.SelectSingleNode('link'); $link = if ($linkNode) { $linkNode.InnerText.Trim() } else { '' }
      $guidNode = $it.SelectSingleNode('guid'); $guid = if ($guidNode) { $guidNode.InnerText.Trim() } else { '' }
      $pubNode = $it.SelectSingleNode('pubDate'); $pub = if ($pubNode) { $pubNode.InnerText.Trim() } else { '' }
      $descNode = $it.SelectSingleNode('description'); $desc = if ($descNode) { $descNode.InnerText.Trim() } else { '' }
      $items += [PSCustomObject]@{
        title = $title; url = $link; guid = $guid; publishedAt = $pub; summary = $desc
        source = $Feed.name; category = $Feed.category
      }
    }
    return $items
  }

  # Atom (YouTube feeds etc.)
  $nsMgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $nsMgr.AddNamespace('a', 'http://www.w3.org/2005/Atom')
  $atomItems = $xml.SelectNodes('//a:feed/a:entry', $nsMgr)
  foreach ($it in $atomItems) {
    $title = ($it.SelectSingleNode('a:title', $nsMgr).InnerText)
    $linkNode = $it.SelectSingleNode('a:link[@rel="alternate"]', $nsMgr)
    if (-not $linkNode) { $linkNode = $it.SelectSingleNode('a:link', $nsMgr) }
    $link = if ($linkNode) { $linkNode.GetAttribute('href') } else { '' }
    $id = ($it.SelectSingleNode('a:id', $nsMgr).InnerText)
    $pub = try { ($it.SelectSingleNode('a:published', $nsMgr).InnerText) } catch { '' }
    $desc = try { ($it.SelectSingleNode('a:summary', $nsMgr).InnerText) } catch { '' }
    $items += [PSCustomObject]@{
      title = $title; url = $link; guid = $id; publishedAt = $pub; summary = $desc
      source = $Feed.name; category = $Feed.category
    }
  }
  return $items
}

function Invoke-RRCollect {
  $config = Get-RRConfig
  $sources = Get-RRSources
  $all = @()
  foreach ($feed in $sources.feeds) {
    if (-not $feed.enabled) { continue }
    $all += Get-RRFeedItems -Feed $feed -Config $config
  }
  return ,$all
}

if ($MyInvocation.InvocationName -ne '.') {
  Invoke-RRCollect | ConvertTo-Json -Depth 10
}
