<#
.SYNOPSIS
  Invokes Claude Code exactly once, non-interactively, with the current candidate batch and
  pilot state. Uses the owner's existing Claude Code CLI login/subscription — never the
  Anthropic API. Returns the parsed structured summary, or $null if Claude could not run
  (in which case the caller must preserve the candidates for a later retry).
#>
. "$PSScriptRoot\lib\common.ps1"

function Invoke-RRClaude {
  param([array]$Candidates, $Pilot, $Config, [string]$LogPath)

  if ($env:ANTHROPIC_API_KEY) {
    Write-RRLog -Path $LogPath -Message "WARNING: ANTHROPIC_API_KEY is set in this environment. This pilot intentionally does not use it and does not depend on it — Claude Code should use your existing subscription/login. If Claude Code falls back to metered API billing on its own, that is outside this script's control; consider unsetting the key for this session."
  }

  $claudeCmd = Get-Command $Config.claudeCommand -ErrorAction SilentlyContinue
  if (-not $claudeCmd) {
    Write-RRLog -Path $LogPath -Message "CLAUDE UNAVAILABLE: '$($Config.claudeCommand)' was not found on PATH. Candidates preserved for retry. Fix: add the Claude Code CLI to PATH or set the full path in config.json's claudeCommand."
    return $null
  }

  $remaining = [Math]::Max(0, $Pilot.maximumAutoPublished - $Pilot.autoPublishedCount)
  $context = [ordered]@{
    pilotMode          = $Pilot.mode
    pilotActive        = [bool]$Pilot.active
    remainingAutoPublish = $remaining
    maximumAutoPublished  = $Pilot.maximumAutoPublished
    autoPublishedSoFar    = $Pilot.autoPublishedCount
    repoRoot           = $RepoRoot
    candidates         = $Candidates
  }
  $contextPath = Join-Path $RRRoot ("logs\context-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  ($context | ConvertTo-Json -Depth 10) | Set-Content -Path $contextPath -Encoding utf8

  $instructions = Get-Content (Join-Path $RRRoot 'prompts\editorial-evaluation.md') -Raw
  $prompt = @"
$instructions

---
RUN CONTEXT JSON (also saved at: $contextPath):
$($context | ConvertTo-Json -Depth 10)
"@

  $stdoutPath = Join-Path $RRRoot ("logs\claude-stdout-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $stderrPath = "$stdoutPath.err"

  Write-RRLog -Path $LogPath -Message "Invoking Claude Code ($($Config.claudeCommand)) once for $($Candidates.Count) candidate(s)..."

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $claudeCmd.Source
  $argList = @()
  foreach ($a in $Config.claudeArgs) { $argList += $a }
  $argList += $prompt
  foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
  $psi.WorkingDirectory = $RepoRoot
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $null = $proc.Start()
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $completed = $proc.WaitForExit($Config.claudeTimeoutSeconds * 1000)
  if (-not $completed) {
    try { $proc.Kill($true) } catch {}
    Write-RRLog -Path $LogPath -Message "CLAUDE TIMEOUT after $($Config.claudeTimeoutSeconds)s. Candidates preserved for retry."
    return $null
  }
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  Set-Content -Path $stdoutPath -Value $stdout -Encoding utf8
  if ($stderr) { Set-Content -Path $stderrPath -Value $stderr -Encoding utf8 }

  if ($proc.ExitCode -ne 0) {
    Write-RRLog -Path $LogPath -Message "CLAUDE EXIT CODE $($proc.ExitCode). See $stdoutPath / $stderrPath. Candidates preserved for retry."
    return $null
  }

  $limitPattern = 'usage limit|rate limit|quota exceeded|out of credits|please try again later'
  if ($stdout -match $limitPattern -or $stderr -match $limitPattern) {
    Write-RRLog -Path $LogPath -Message "CLAUDE USAGE LIMIT DETECTED. No publication this run. Candidates preserved for retry. See $stdoutPath."
    return $null
  }

  $jsonMatch = [regex]::Match($stdout, '```json\s*(\{[\s\S]*?\})\s*```')
  if (-not $jsonMatch.Success) {
    Write-RRLog -Path $LogPath -Message "CLAUDE OUTPUT DID NOT CONTAIN THE REQUIRED JSON SUMMARY BLOCK. Full output at $stdoutPath. Candidates preserved for retry."
    return $null
  }
  try {
    $summary = $jsonMatch.Groups[1].Value | ConvertFrom-Json
  } catch {
    Write-RRLog -Path $LogPath -Message "CLAUDE OUTPUT JSON FAILED TO PARSE: $($_.Exception.Message). Full output at $stdoutPath. Candidates preserved for retry."
    return $null
  }

  return $summary
}
