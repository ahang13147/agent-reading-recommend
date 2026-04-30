Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'backend/NovelScoring.psm1') -Force -DisableNameChecking

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Read-JsonArray {
    param([string]$Path)
    return @(Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$books = Read-JsonArray -Path (Join-Path $root 'data/books.json')
$snapshots = Read-JsonArray -Path (Join-Path $root 'data/snapshots.json')
$scores = Get-NovelScores -Books $books -Snapshots $snapshots
$booksWithHistory = @($books | Where-Object {
    $bookId = $_.id
    @($snapshots | Where-Object { $_.bookId -eq $bookId }).Count -ge 3
})
$booksForScoredChecks = if ($booksWithHistory.Count -gt 0) { $booksWithHistory } else { $books }
$scoresWithHistory = Get-NovelScores -Books $booksForScoredChecks -Snapshots $snapshots

Assert-True ($books.Count -ge 5) 'books should load'
Assert-True ($snapshots.Count -ge 12) 'snapshot history should load'
Assert-True ($booksWithHistory.Count -ge 4) 'at least four books should have enough history for scored checks'
Assert-True ($scores.daily.Count -eq $books.Count) 'daily score count should match books'
Assert-True ($scoresWithHistory.active[0].Score -gt 0) 'active score should be positive for books with history'
Assert-True ($scoresWithHistory.retention[0].Score -gt 0) 'retention score should be positive for books with history'
Assert-True (($scoresWithHistory.retention | Where-Object { $_.Eligible }).Count -ge 4) 'long or finished books should be retention eligible'

foreach ($groupName in @('daily', 'active', 'retention')) {
    foreach ($item in $scoresWithHistory.$groupName) {
        Assert-True (-not [double]::IsNaN([double]$item.Score)) "$groupName score should not be NaN"
        Assert-True ([double]$item.Score -ge 0 -and [double]$item.Score -le 100) "$groupName score should stay in 0-100"
    }
}

$projection = New-ProjectedSnapshot -Book $booksForScoredChecks[0] -Snapshots $snapshots -Date '2026-05-01'
Assert-True ($projection.bookId -eq $booksForScoredChecks[0].id) 'projected snapshot should preserve book id'
Assert-True ($projection.capturedAt -eq '2026-05-01') 'projected snapshot should use requested date'

[pscustomobject]@{
    ok = $true
    books = $books.Count
    booksWithHistory = $booksWithHistory.Count
    snapshots = $snapshots.Count
    dailyTop = $scoresWithHistory.daily[0].Book.title
    activeTop = $scoresWithHistory.active[0].Book.title
    retentionTop = $scoresWithHistory.retention[0].Book.title
}
