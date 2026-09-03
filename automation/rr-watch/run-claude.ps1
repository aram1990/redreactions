<#
.SYNOPSIS
  Two-phase, gated Claude Code invocation. Uses the owner's existing Claude Code CLI
  login/subscription only — every child process has ANTHROPIC_API_KEY and every known
  Bedrock/Vertex/Foundry routing variable stripped from ITS OWN environment before it starts
  (the parent PowerShell process and Windows user/system environment are never touched, and no
  secret value is ever logged).

  Phase A (Invoke-RREvaluator) runs in Claude Code's restricted "plan" permission mode: it can
  read/search the repo and do research, but has no file-write, git, or bash-with-side-effects
  capability — it can only classify and recommend. It never has publish capability, in dry-run
  OR live mode.

  Phase B (Invoke-RRPublisher) is only ever called by watch.ps1 once per candidate, and only
  after watch.ps1 has freshly re-read pilot.json and re-checked mode/active/expiry/remaining-cap
  immediately beforehand. It is given exactly one candidate and cannot see or act on any other.
#>
. "$PSScriptRoot\lib\common.ps1"

function Test-RRClaudeAvailable {
  param($Config, [string]$LogPath)
  if ($env:ANTHROPIC_API_KEY) {
    Write-RRLog -Path $LogPath -Message "NOTE: ANTHROPIC_API_KEY is present in this shell's environment. It will be stripped from Claude's child process on every invocation below (value never logged); this pilot never uses it and never falls back to it."
  }
  $claudeCmd = Get-Command $Config.claudeCommand -ErrorAction SilentlyContinue
  if (-not $claudeCmd) {
    Write-RRLog -Path $LogPath -Message "CLAUDE UNAVAILABLE: '$($Config.claudeCommand)' was not found on PATH. Candidates preserved for retry. Fix: add the Claude Code CLI to PATH, or set the full path in config.json's claudeCommand, then re-run .\preflight.ps1."
    return $null
  }
  return $claudeCmd
}

function Invoke-RRClaudeProcess {
  # Shared low-level runner: builds a safe (env-stripped) child process, PIPES the prompt via
  # stdin (never as a CLI argument — a multi-KB prompt as a literal argument can exceed the
  # ~8191-character command-line limit enforced by the cmd.exe shim that npm installs on Windows
  # for the claude executable, and stdin is also Claude Code's documented headless input path:
  # `... | claude -p`), waits with a timeout, and returns raw stdout/stderr/exit code.
  param([string]$ClaudeExe, [array]$Args, [string]$Prompt, [int]$TimeoutSeconds, [string]$WorkingDirectory, [string]$LogPath)

  $safe = New-RRSafeProcessStartInfo -FileName $ClaudeExe -WorkingDirectory $WorkingDirectory
  foreach ($a in $Args) { $safe.Psi.ArgumentList.Add($a) }
  if ($safe.StrippedVarNames.Count -gt 0) {
    Write-RRLog -Path $LogPath -Message "Stripped from Claude child process env (names only): $($safe.StrippedVarNames -join ', ')"
  }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $safe.Psi
  $null = $proc.Start()
  try { $proc.StandardInput.Write($Prompt); $proc.StandardInput.Close() }
  catch { Write-RRLog -Path $LogPath -Message "NOTE: could not write full prompt to Claude's stdin (child process may have exited early): $($_.Exception.Message)" }
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $completed = $proc.WaitForExit($TimeoutSeconds * 1000)
  if (-not $completed) {
    try { $proc.Kill($true) } catch {}
    return [PSCustomObject]@{ TimedOut = $true; ExitCode = $null; Stdout = $null; Stderr = $null }
  }
  return [PSCustomObject]@{ TimedOut = $false; ExitCode = $proc.ExitCode; Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result }
}

function Get-RRJsonBlock {
  param([string]$Stdout)
  $m = [regex]::Match($Stdout, '```json\s*(\{[\s\S]*?\})\s*```')
  if (-not $m.Success) { return $null }
  try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch { return $null }
}

$script:RRLimitPattern = 'usage limit|rate limit|quota exceeded|out of credits|please try again later'

function Invoke-RREvaluator {
  <#
    Phase A. $EffectiveMode/$EffectiveActive are computed by the CALLER (watch.ps1) and are what
    actually goes into the run context — NOT read from pilot.json again here — so a forced
    -DryRun always reaches Claude as pilotMode="dry-run"/pilotActive=false regardless of what
    pilot.json says on disk.
  #>
  param([array]$Candidates, [string]$EffectiveMode, [bool]$EffectiveActive, [int]$Remaining, [int]$Max, [int]$SoFar, $Config, [string]$LogPath)

  $claudeCmd = Test-RRClaudeAvailable -Config $Config -LogPath $LogPath
  if (-not $claudeCmd) { return $null }

  $context = [ordered]@{
    phase = 'evaluation'
    pilotMode = $EffectiveMode
    pilotActive = $EffectiveActive
    remainingAutoPublish = $Remaining
    maximumAutoPublished = $Max
    autoPublishedSoFar = $SoFar
    repoRoot = $RepoRoot
    candidates = $Candidates
  }
  $contextPath = Join-Path $RRRoot ("logs\context-eval-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  ($context | ConvertTo-Json -Depth 10) | Set-Content -Path $contextPath -Encoding utf8

  $instructions = Get-Content (Join-Path $RRRoot 'prompts\editorial-evaluation.md') -Raw
  $prompt = "$instructions`n`n---`nRUN CONTEXT JSON (also saved at: $contextPath):`n$($context | ConvertTo-Json -Depth 10)"

  Write-RRLog -Path $LogPath -Message "PHASE A: invoking evaluator (read-only 'plan' mode) for $($Candidates.Count) candidate(s)..."
  $result = Invoke-RRClaudeProcess -ClaudeExe $claudeCmd.Source -Args $Config.claudeEvaluatorArgs -Prompt $prompt `
    -TimeoutSeconds $Config.claudeTimeoutSeconds -WorkingDirectory $RepoRoot -LogPath $LogPath

  $stdoutPath = Join-Path $RRRoot ("logs\claude-eval-stdout-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  if ($result.TimedOut) {
    Write-RRLog -Path $LogPath -Message "EVALUATOR TIMEOUT after $($Config.claudeTimeoutSeconds)s. Candidates preserved for retry."
    return $null
  }
  Set-Content -Path $stdoutPath -Value $result.Stdout -Encoding utf8
  if ($result.Stderr) { Set-Content -Path "$stdoutPath.err" -Value $result.Stderr -Encoding utf8 }

  if ($result.ExitCode -ne 0) {
    Write-RRLog -Path $LogPath -Message "EVALUATOR EXIT CODE $($result.ExitCode). See $stdoutPath. Candidates preserved for retry."
    return $null
  }
  if ($result.Stdout -match $RRLimitPattern -or $result.Stderr -match $RRLimitPattern) {
    Write-RRLog -Path $LogPath -Message "CLAUDE USAGE LIMIT DETECTED during evaluation. Candidates preserved for retry. No API/Bedrock/Vertex fallback will be attempted. See $stdoutPath."
    return $null
  }
  $summary = Get-RRJsonBlock -Stdout $result.Stdout
  if (-not $summary) {
    Write-RRLog -Path $LogPath -Message "EVALUATOR OUTPUT DID NOT CONTAIN THE REQUIRED JSON SUMMARY BLOCK. Full output at $stdoutPath. Candidates preserved for retry."
    return $null
  }
  return $summary
}

function Invoke-RRPublisher {
  <#
    Phase B. Handles exactly ONE candidate. The caller (watch.ps1) must have re-read pilot.json
    and re-verified mode==live, active==true, not-expired, and remaining-cap > 0 IMMEDIATELY
    before calling this — this function does not re-derive those checks itself, by design, so
    that the gate is visibly and solely PowerShell's responsibility.
  #>
  param($Candidate, [int]$Remaining, $Config, [string]$LogPath)

  $claudeCmd = Test-RRClaudeAvailable -Config $Config -LogPath $LogPath
  if (-not $claudeCmd) { return $null }

  $context = [ordered]@{
    phase = 'publication'
    remainingAutoPublish = $Remaining
    repoRoot = $RepoRoot
    candidate = $Candidate
  }
  $contextPath = Join-Path $RRRoot ("logs\context-pub-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Candidate.id)
  ($context | ConvertTo-Json -Depth 10) | Set-Content -Path $contextPath -Encoding utf8

  $instructions = Get-Content (Join-Path $RRRoot 'prompts\publish-single-article.md') -Raw
  $prompt = "$instructions`n`n---`nRUN CONTEXT JSON (also saved at: $contextPath):`n$($context | ConvertTo-Json -Depth 10)"

  Write-RRLog -Path $LogPath -Message "PHASE B: invoking publisher for exactly one candidate: $($Candidate.title)"
  $result = Invoke-RRClaudeProcess -ClaudeExe $claudeCmd.Source -Args $Config.claudePublisherArgs -Prompt $prompt `
    -TimeoutSeconds $Config.publisherTimeoutSeconds -WorkingDirectory $RepoRoot -LogPath $LogPath

  $stdoutPath = Join-Path $RRRoot ("logs\claude-pub-stdout-{0}-{1}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Candidate.id)
  if ($result.TimedOut) {
    Write-RRLog -Path $LogPath -Message "PUBLISHER TIMEOUT after $($Config.publisherTimeoutSeconds)s for '$($Candidate.title)'. Treated as not-published; candidate preserved for retry."
    return $null
  }
  Set-Content -Path $stdoutPath -Value $result.Stdout -Encoding utf8
  if ($result.Stderr) { Set-Content -Path "$stdoutPath.err" -Value $result.Stderr -Encoding utf8 }

  if ($result.ExitCode -ne 0) {
    Write-RRLog -Path $LogPath -Message "PUBLISHER EXIT CODE $($result.ExitCode) for '$($Candidate.title)'. See $stdoutPath. Treated as not-published; preserved for retry."
    return $null
  }
  if ($result.Stdout -match $RRLimitPattern -or $result.Stderr -match $RRLimitPattern) {
    Write-RRLog -Path $LogPath -Message "CLAUDE USAGE LIMIT DETECTED during publication of '$($Candidate.title)'. No API/Bedrock/Vertex fallback attempted. Preserved for retry."
    return $null
  }
  $result_json = Get-RRJsonBlock -Stdout $result.Stdout
  if (-not $result_json) {
    Write-RRLog -Path $LogPath -Message "PUBLISHER OUTPUT DID NOT CONTAIN THE REQUIRED JSON BLOCK for '$($Candidate.title)'. Full output at $stdoutPath. Treated as not-published; preserved for retry."
    return $null
  }
  return $result_json
}
