<#
.SYNOPSIS
  Run this BEFORE the first baseline/dry-run and again before enabling the live pilot. Reports
  the runtime that will actually execute the scheduled task, confirms the Claude Code CLI is
  reachable, and performs one harmless, read-only, non-interactive Claude invocation with all
  known billing/routing-override environment variables stripped from its process only — to build
  confidence it is authenticating via the owner's Claude Code subscription/login, not a metered
  API key. Prints no secret values. Modifies nothing (no files, no git, no push).
#>
. "$PSScriptRoot\lib\common.ps1"

Write-Host "=== Red Reactions Watch — Preflight ===" -ForegroundColor Cyan
Write-Host ""

$config = Get-RRConfig
$report = [ordered]@{}

# --- PowerShell runtime -----------------------------------------------------
$report.powershellExe = (Get-Process -Id $PID).Path
$report.powershellVersion = $PSVersionTable.PSVersion.ToString()
$report.powershellEdition = $PSVersionTable.PSEdition
Write-Host "PowerShell executable: $($report.powershellExe)"
Write-Host "PowerShell version:    $($report.powershellVersion) ($($report.powershellEdition))"

$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$report.pwshAvailable = [bool]$pwshCmd
$report.pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { $null }
Write-Host "pwsh.exe (PowerShell 7+) available: $($report.pwshAvailable)$(if($pwshCmd){" -> $($pwshCmd.Source)"})"
Write-Host ""

# --- Git ---------------------------------------------------------------------
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
$report.gitPath = if ($gitCmd) { $gitCmd.Source } else { $null }
$report.gitVersion = if ($gitCmd) { (& git --version) } else { $null }
Write-Host "Git: $($report.gitPath) ($($report.gitVersion))"

# --- Node ----------------------------------------------------------------------
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$report.nodePath = if ($nodeCmd) { $nodeCmd.Source } else { $null }
$report.nodeVersion = if ($nodeCmd) { (& node --version) } else { $null }
Write-Host "Node: $($report.nodePath) ($($report.nodeVersion))"

Write-Host "Repo root: $RepoRoot"
Write-Host ""

# --- Claude CLI ----------------------------------------------------------------
$claudeCmd = Get-Command $config.claudeCommand -ErrorAction SilentlyContinue
$report.claudePath = if ($claudeCmd) { $claudeCmd.Source } else { $null }
if (-not $claudeCmd) {
  Write-Host "Claude CLI: NOT FOUND on PATH as '$($config.claudeCommand)'." -ForegroundColor Red
  Write-Host ""
  Write-Host "RESULT: FAIL. Live pilot must stay disabled until the Claude Code CLI is reachable." -ForegroundColor Red
  $report.result = 'FAIL'
  ($report | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $RRRoot 'logs\preflight-last.json') -Encoding utf8
  exit 1
}
Write-Host "Claude CLI: $($report.claudePath)"

$verSi = New-RRSafeProcessStartInfo -FileName $claudeCmd.Source -WorkingDirectory $RepoRoot
foreach ($a in @('--version')) { $verSi.Psi.ArgumentList.Add($a) }
try {
  $verProc = [System.Diagnostics.Process]::Start($verSi.Psi)
  try { $verProc.StandardInput.Close() } catch { }
  $verOut = $verProc.StandardOutput.ReadToEnd()
  $verProc.WaitForExit(10000) | Out-Null
  $report.claudeVersion = $verOut.Trim()
} catch { $report.claudeVersion = "(could not determine: $($_.Exception.Message))" }
Write-Host "Claude version: $($report.claudeVersion)"
Write-Host ""

if ($report.pwshAvailable) {
  Write-Host "Runtime the scheduled task will use: pwsh.exe (PowerShell 7+, preferred when present)" -ForegroundColor Yellow
} else {
  Write-Host "Runtime the scheduled task will use: powershell.exe (Windows PowerShell 5.1 — pwsh.exe not found)" -ForegroundColor Yellow
}
Write-Host ""

# --- Billing-safety: env stripping proof (names only, never values) ------------
$presentBillingVars = @($RRBillingEnvVars | Where-Object { [System.Environment]::GetEnvironmentVariable($_) })
if ($presentBillingVars.Count -gt 0) {
  Write-Host "NOTE: the following billing/routing environment variables are set in THIS shell (values never shown):" -ForegroundColor Yellow
  $presentBillingVars | ForEach-Object { Write-Host "  - $_" }
  Write-Host "They will be stripped from Claude's child process only, every run. Nothing outside that child process is changed."
} else {
  Write-Host "No known billing/routing-override environment variables are set in this shell."
}
Write-Host ""

# --- Harmless, read-only Claude invocation --------------------------------------
Write-Host "Running one harmless, read-only Claude Code invocation (no file writes, no git, no push)..."
$sentinel = 'RR-PREFLIGHT-OK'
$prompt = "Reply with exactly this text and nothing else, on a single line: $sentinel"
$safe = New-RRSafeProcessStartInfo -FileName $claudeCmd.Source -WorkingDirectory $RepoRoot
$argList = @('-p', '--permission-mode', 'plan')
foreach ($a in $argList) { $safe.Psi.ArgumentList.Add($a) }

if ($safe.StrippedVarNames.Count -gt 0) {
  Write-Host "Stripped from Claude's child process environment: $($safe.StrippedVarNames -join ', ')"
} else {
  Write-Host "Nothing needed stripping — no billing/routing-override variables were present."
}

$ok = $false
try {
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $safe.Psi
  $null = $proc.Start()
  try { $proc.StandardInput.Write($prompt); $proc.StandardInput.Close() } catch { }
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $completed = $proc.WaitForExit(($config.claudeTimeoutSeconds) * 1000)
  if (-not $completed) { try { $proc.Kill($true) } catch {}; throw "Timed out after $($config.claudeTimeoutSeconds)s" }
  $out = $outTask.Result
  $err = $errTask.Result
  if ($proc.ExitCode -eq 0 -and $out -match [regex]::Escape($sentinel)) {
    $ok = $true
    Write-Host "Claude responded correctly with no API key/Bedrock/Vertex/Foundry variables available to it." -ForegroundColor Green
  } else {
    Write-Host "Claude invocation did not return the expected sentinel. Exit code: $($proc.ExitCode)" -ForegroundColor Red
    if ($err) { Write-Host "stderr (first 500 chars): $($err.Substring(0, [Math]::Min(500,$err.Length)))" }
  }
} catch {
  Write-Host "Preflight Claude invocation failed: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

$report.claudePreflightOk = $ok
if ($ok) {
  Write-Host "RESULT: PASS." -ForegroundColor Green
  $report.result = 'PASS'
} else {
  Write-Host "RESULT: FAIL. Do not enable the live pilot until this passes." -ForegroundColor Red
  $report.result = 'FAIL'
}
Write-Host ""
Write-Host "IMPORTANT MANUAL CHECK (this script cannot do this for you):" -ForegroundColor Yellow
Write-Host "  Run 'claude' interactively, then run the '/status' slash command inside it, and confirm" -ForegroundColor Yellow
Write-Host "  the authenticated account shown is your Claude subscription login — not an API key." -ForegroundColor Yellow

($report | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $RRRoot 'logs\preflight-last.json') -Encoding utf8
if (-not $ok) { exit 1 }
