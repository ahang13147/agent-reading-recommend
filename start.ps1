param(
    [int]$Port = 5177
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $root 'backend/server.ps1'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $server -Port $Port -Root $root
