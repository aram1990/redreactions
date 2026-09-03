<#
.SYNOPSIS
  Deterministically (no Claude) builds a lightweight index of existing published articles from
  MDX frontmatter, so the evaluator can do duplicate/update triage against a small index instead
  of grepping/reading hundreds of article files on every hourly run. Regenerated fresh before
  every evaluator invocation — cheap (regex over frontmatter blocks only, not article bodies).
#>
. "$PSScriptRoot\lib\common.ps1"

function Get-RRFrontmatterField {
  param([string]$Frontmatter, [string]$Field)
  $m = [regex]::Match($Frontmatter, "(?m)^$Field\s*:\s*""([^""]*)""")
  if ($m.Success) { return $m.Groups[1].Value }
  $m = [regex]::Match($Frontmatter, "(?m)^$Field\s*:\s*(.+)$")
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return $null
}

function Get-RRFrontmatterArray {
  # Handles both inline `field: ["a", "b"]` and YAML block-list `field:\n  - "a"\n  - "b"` styles.
  # Returns via the comma operator (`return ,$x`) — a bare `return @($x)` still gets flattened
  # back to a scalar by PowerShell when the array has exactly one element, since function output
  # is a pipeline and a 1-item array is unrolled at that boundary regardless of how it was built.
  param([string]$Frontmatter, [string]$Field)
  $inline = [regex]::Match($Frontmatter, "(?m)^$Field\s*:\s*\[(.*?)\]")
  if ($inline.Success) {
    $items = @([regex]::Matches($inline.Groups[1].Value, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
    return ,$items
  }
  $block = [regex]::Match($Frontmatter, "(?m)^$Field\s*:\s*\r?\n((?:\s*-\s*.+\r?\n?)+)")
  if ($block.Success) {
    $items = @([regex]::Matches($block.Groups[1].Value, '(?m)^\s*-\s*"?([^"\r\n]*?)"?\s*$') | ForEach-Object { $_.Groups[1].Value })
    return ,$items
  }
  return ,@()
}

function Build-RRContentIndex {
  $articlesDir = Join-Path $RepoRoot 'src\content\articles'
  if (-not (Test-Path $articlesDir)) { return @() }
  $files = Get-ChildItem $articlesDir -Filter '*.mdx' -File
  $index = @()
  foreach ($f in $files) {
    $raw = Get-Content $f.FullName -Raw -Encoding UTF8
    $m = [regex]::Match($raw, '(?s)^---\s*(.*?)\s*---')
    if (-not $m.Success) { continue }
    $fm = $m.Groups[1].Value

    $slug = Get-RRFrontmatterField -Frontmatter $fm -Field 'slug'
    if (-not $slug) { $slug = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
    $draft = Get-RRFrontmatterField -Frontmatter $fm -Field 'draft'
    if ($draft -eq 'true') { continue }

    $index += [PSCustomObject]@{
      slug = $slug
      title = Get-RRFrontmatterField -Frontmatter $fm -Field 'title'
      contentType = Get-RRFrontmatterField -Frontmatter $fm -Field 'contentType'
      topics = Get-RRFrontmatterArray -Frontmatter $fm -Field 'topics'
      franchise = Get-RRFrontmatterField -Frontmatter $fm -Field 'franchise'
      publishedAt = Get-RRFrontmatterField -Frontmatter $fm -Field 'publishedAt'
    }
  }
  return $index
}

function Save-RRContentIndex {
  $index = Build-RRContentIndex
  $path = Join-Path $RRRoot 'content-index.json'
  ($index | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $path -Encoding utf8
  return [PSCustomObject]@{ Path = $path; Count = $index.Count }
}

if ($MyInvocation.InvocationName -ne '.') {
  $r = Save-RRContentIndex
  Write-Host "Content index written to $($r.Path) ($($r.Count) published article(s))"
}
