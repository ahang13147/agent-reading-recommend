param(
    [string]$Url = 'https://www.qidian.com/rank/yuepiao/',
    [string]$OutFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/inbox/qidian-raw.html')
)

$ErrorActionPreference = 'Stop'
$headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'
    'Referer' = 'https://www.qidian.com/'
}

if (-not [string]::IsNullOrWhiteSpace($env:QIDIAN_COOKIE)) {
    $headers['Cookie'] = $env:QIDIAN_COOKIE
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
$response = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 30
Set-Content -LiteralPath $OutFile -Value $response.Content -Encoding UTF8

$isProbe = $response.Content -match 'probe\.js|buid|C2WF'
[pscustomobject]@{
    ok = -not $isProbe
    url = $Url
    outFile = $OutFile
    cookieUsed = -not [string]::IsNullOrWhiteSpace($env:QIDIAN_COOKIE)
    note = if ($isProbe) {
        'The response looks like an anti-bot probe page. Use a permitted data source, manual snapshot export, or a compliant QIDIAN_COOKIE setup.'
    } else {
        'The page has been saved. Build a parser from this output and import qidian-snapshot.json.'
    }
}
