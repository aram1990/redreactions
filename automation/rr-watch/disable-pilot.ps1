<#
.SYNOPSIS
  Emergency stop: immediately disables live auto-publishing. Watch/report mode keeps working
  (the hourly task can keep running for classification/queueing) but no more auto-publication
  can happen until enable-pilot.ps1 is run again. Does not touch counters or history.
#>
. "$PSScriptRoot\lib\common.ps1"

$pilot = Get-RRPilot
$pilot.mode = 'dry-run'
$pilot.active = $false
Save-RRPilot $pilot

Write-Host "LIVE PILOT DISABLED. Mode is now 'dry-run' and pilot is inactive." -ForegroundColor Green
Write-Host "The hourly task (if installed) will keep collecting/classifying/queueing but will not publish, commit, or push."
