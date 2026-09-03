<#
.SYNOPSIS
  Cleanly removes the hourly scheduled task. Does not touch pilot.json/queue.json/logs.
#>
param([string]$TaskName = 'RedReactions-RRWatch')

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Write-Host "No scheduled task named '$TaskName' found. Nothing to remove."; exit 0 }

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "Note: this does not disable a currently-live pilot. Run .\disable-pilot.ps1 for that."
