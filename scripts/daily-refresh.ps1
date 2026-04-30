param(
    [int]$Port = 5177,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
)

$ErrorActionPreference = 'Stop'
$uri = "http://localhost:$Port/api/track/refresh?date=$([uri]::EscapeDataString($Date))"
Invoke-RestMethod -Method Post -Uri $uri -Body '{}' -ContentType 'application/json'
