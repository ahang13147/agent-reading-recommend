param(
    [string]$TaskName = 'NovelTrendDailyRefresh',
    [int]$Port = 5177,
    [string]$At = '08:30'
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'daily-refresh.ps1'
$argument = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Port $Port"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse($At))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force
