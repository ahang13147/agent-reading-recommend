param(
    [string]$Owner = 'ahang13147',
    [string]$Repo = 'agent-reading-recommend',
    [string]$Branch = 'main',
    [string]$PublishDir = (Join-Path (Split-Path -Parent $PSScriptRoot) '.publish-agent-reading-recommend'),
    [string]$Message = 'Initial novel trend tracker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Token {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        return $env:GITHUB_TOKEN
    }

    $secure = Read-Host 'Paste a GitHub fine-grained token with Contents: Read and write' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Invoke-GitHubJson {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [switch]$Allow404
    )

    $uri = "https://api.github.com/repos/$Owner/$Repo$Path"
    $headers = @{
        Authorization = "Bearer $script:Token"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'novel-trend-tracker-uploader'
    }

    try {
        if ($null -eq $Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        }

        $json = $Body | ConvertTo-Json -Depth 20
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json -ContentType 'application/json'
    } catch {
        $response = $_.Exception.Response
        if ($Allow404 -and $null -ne $response -and [int]$response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

if (-not (Test-Path -LiteralPath $PublishDir -PathType Container)) {
    throw "Publish directory not found: $PublishDir"
}

$script:Token = Get-Token
if ([string]::IsNullOrWhiteSpace($script:Token)) {
    throw 'GitHub token is empty.'
}

$files = @(Get-ChildItem -LiteralPath $PublishDir -Recurse -File | Sort-Object FullName)
if ($files.Count -eq 0) {
    throw "No files found in publish directory: $PublishDir"
}

$tree = @()
foreach ($file in $files) {
    $relative = $file.FullName.Substring($PublishDir.Length).TrimStart('\', '/') -replace '\\', '/'
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $blob = Invoke-GitHubJson -Method Post -Path '/git/blobs' -Body @{
        content = [Convert]::ToBase64String($bytes)
        encoding = 'base64'
    }

    $tree += @{
        path = $relative
        mode = '100644'
        type = 'blob'
        sha = $blob.sha
    }
    Write-Host "Prepared $relative"
}

$treeResult = Invoke-GitHubJson -Method Post -Path '/git/trees' -Body @{ tree = $tree }
$ref = Invoke-GitHubJson -Method Get -Path "/git/ref/heads/$Branch" -Allow404
$parents = @()
if ($null -ne $ref) {
    $parents = @($ref.object.sha)
}

$commit = Invoke-GitHubJson -Method Post -Path '/git/commits' -Body @{
    message = $Message
    tree = $treeResult.sha
    parents = $parents
}

if ($null -eq $ref) {
    Invoke-GitHubJson -Method Post -Path '/git/refs' -Body @{
        ref = "refs/heads/$Branch"
        sha = $commit.sha
    } | Out-Null
} else {
    Invoke-GitHubJson -Method Patch -Path "/git/refs/heads/$Branch" -Body @{
        sha = $commit.sha
        force = $false
    } | Out-Null
}

[pscustomobject]@{
    ok = $true
    repo = "$Owner/$Repo"
    branch = $Branch
    commit = $commit.sha
    files = $files.Count
    url = "https://github.com/$Owner/$Repo/tree/$Branch"
}
