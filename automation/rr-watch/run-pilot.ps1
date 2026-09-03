<#
.SYNOPSIS
  Manual convenience wrapper: run one watch cycle right now instead of waiting for the
  scheduled task. Forwards to watch.ps1. Pass -DryRun to force dry-run behavior regardless
  of pilot.json (recommended for a first manual test).
#>
param([switch]$DryRun)
& "$PSScriptRoot\watch.ps1" @PSBoundParameters
