Set-StrictMode -Version Latest

function Clamp-Number {
    param(
        [double]$Value,
        [double]$Min = 0,
        [double]$Max = 1
    )

    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = 0
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -eq '') {
        return $Default
    }
    return $property.Value
}

function Convert-ToNumber {
    param($Value, [double]$Default = 0)

    if ($null -eq $Value -or $Value -eq '') { return $Default }
    try { return [double]$Value } catch { return $Default }
}

function Normalize-Log {
    param(
        [double]$Value,
        [double]$Scale
    )

    if ($Value -le 0 -or $Scale -le 0) { return 0 }
    return Clamp-Number -Value ([Math]::Log(1 + $Value) / [Math]::Log(1 + $Scale))
}

function Get-DateFromSnapshot {
    param($Snapshot)

    $raw = Get-ObjectValue -Object $Snapshot -Name 'capturedAt' -Default $null
    if ($null -eq $raw) { return [datetime]::MinValue }
    return [datetime]::Parse($raw)
}

function Get-SnapshotsForBook {
    param(
        [array]$Snapshots,
        [string]$BookId
    )

    return @($Snapshots |
        Where-Object { (Get-ObjectValue -Object $_ -Name 'bookId' -Default '') -eq $BookId } |
        Sort-Object { Get-DateFromSnapshot -Snapshot $_ })
}

function Get-LatestSnapshot {
    param([array]$Snapshots)

    $ordered = @($Snapshots | Sort-Object { Get-DateFromSnapshot -Snapshot $_ })
    if ($ordered.Count -eq 0) { return $null }
    return $ordered[$ordered.Count - 1]
}

function Get-BaselineSnapshot {
    param(
        [array]$Snapshots,
        [int]$Days
    )

    $ordered = @($Snapshots | Sort-Object { Get-DateFromSnapshot -Snapshot $_ })
    if ($ordered.Count -eq 0) { return $null }

    $latest = $ordered[$ordered.Count - 1]
    $cutoff = (Get-DateFromSnapshot -Snapshot $latest).AddDays(-1 * $Days)
    $beforeCutoff = @($ordered | Where-Object { (Get-DateFromSnapshot -Snapshot $_) -le $cutoff })
    if ($beforeCutoff.Count -gt 0) {
        return $beforeCutoff[$beforeCutoff.Count - 1]
    }
    return $ordered[0]
}

function Get-MetricDelta {
    param(
        [array]$Snapshots,
        [string]$Metric,
        [int]$Days = 30,
        [bool]$CanReset = $false
    )

    $latest = Get-LatestSnapshot -Snapshots $Snapshots
    $baseline = Get-BaselineSnapshot -Snapshots $Snapshots -Days $Days
    if ($null -eq $latest -or $null -eq $baseline) {
        return [pscustomobject]@{ Delta = 0; DailyRate = 0; Confidence = 0; ResetDetected = $false; Days = 0 }
    }

    $latestDate = Get-DateFromSnapshot -Snapshot $latest
    $baselineDate = Get-DateFromSnapshot -Snapshot $baseline
    $span = [Math]::Max(1, ($latestDate - $baselineDate).TotalDays)
    $latestValue = Convert-ToNumber (Get-ObjectValue -Object $latest -Name $Metric -Default 0)
    $baselineValue = Convert-ToNumber (Get-ObjectValue -Object $baseline -Name $Metric -Default 0)
    $delta = $latestValue - $baselineValue
    $resetDetected = $false

    if ($delta -lt 0) {
        $resetDetected = $true
        if ($CanReset) {
            $delta = $latestValue
        } else {
            $delta = 0
        }
    }

    $confidence = Clamp-Number -Value ($span / [Math]::Max(1, $Days))
    if ($resetDetected -and -not $CanReset) {
        $confidence = $confidence * 0.55
    }

    return [pscustomobject]@{
        Delta = [Math]::Round($delta, 4)
        DailyRate = [Math]::Round(($delta / $span), 4)
        Confidence = [Math]::Round($confidence, 4)
        ResetDetected = $resetDetected
        Days = [Math]::Round($span, 2)
    }
}

function Get-BayesianRatingScore {
    param($Snapshot)

    if ($null -eq $Snapshot) {
        return [pscustomobject]@{ RawRating = 0; BayesianRating = 0; Score = 0; Confidence = 0 }
    }

    $rating = Convert-ToNumber (Get-ObjectValue -Object $Snapshot -Name 'rating' -Default 0)
    $ratingCount = Convert-ToNumber (Get-ObjectValue -Object $Snapshot -Name 'ratingCount' -Default 0)
    if ($rating -le 0) {
        return [pscustomobject]@{ RawRating = 0; BayesianRating = 0; Score = 0; Confidence = 0 }
    }

    $priorRating = 8.0
    $priorVotes = 500.0
    $bayesian = (($rating * $ratingCount) + ($priorRating * $priorVotes)) / [Math]::Max(1, ($ratingCount + $priorVotes))
    $score = Clamp-Number -Value (($bayesian - 6.2) / 3.2)
    $confidence = Clamp-Number -Value ([Math]::Log(1 + $ratingCount) / [Math]::Log(1 + 20000))

    return [pscustomobject]@{
        RawRating = [Math]::Round($rating, 2)
        BayesianRating = [Math]::Round($bayesian, 3)
        Score = [Math]::Round($score, 4)
        Confidence = [Math]::Round($confidence, 4)
    }
}

function Get-RatingPulse {
    param([array]$Snapshots)

    $latest = Get-LatestSnapshot -Snapshots $Snapshots
    $baseline = Get-BaselineSnapshot -Snapshots $Snapshots -Days 30
    if ($null -eq $latest -or $null -eq $baseline) {
        return [pscustomobject]@{ Score = 0; Delta = 0; Confidence = 0 }
    }

    $latestRating = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'rating' -Default 0)
    $baselineRating = Convert-ToNumber (Get-ObjectValue -Object $baseline -Name 'rating' -Default $latestRating)
    $latestCount = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'ratingCount' -Default 0)
    $baselineCount = Convert-ToNumber (Get-ObjectValue -Object $baseline -Name 'ratingCount' -Default 0)
    $countDelta = [Math]::Max(0, $latestCount - $baselineCount)
    $ratingDelta = $latestRating - $baselineRating

    $base = Get-BayesianRatingScore -Snapshot $latest
    $deltaBoost = Clamp-Number -Value (($ratingDelta + 0.25) / 0.75)
    $voteConfidence = Clamp-Number -Value ([Math]::Log(1 + $countDelta) / [Math]::Log(1 + 1500))
    $score = Clamp-Number -Value (($base.Score * 0.72) + ($deltaBoost * $voteConfidence * 0.28))

    return [pscustomobject]@{
        Score = [Math]::Round($score, 4)
        Delta = [Math]::Round($ratingDelta, 3)
        Confidence = [Math]::Round([Math]::Max($base.Confidence, $voteConfidence), 4)
    }
}

function Get-TrendScoreForBook {
    param(
        [Parameter(Mandatory = $true)]$Book,
        [array]$Snapshots
    )

    $bookId = [string](Get-ObjectValue -Object $Book -Name 'id' -Default '')
    $bookSnapshots = Get-SnapshotsForBook -Snapshots $Snapshots -BookId $bookId
    $latest = Get-LatestSnapshot -Snapshots $bookSnapshots
    if ($null -eq $latest) {
        return [pscustomobject]@{
            Book = $Book
            Score = 0
            Components = [pscustomobject]@{}
            LatestSnapshot = $null
            Reason = 'No snapshots yet'
        }
    }

    $monthTickets = Get-MetricDelta -Snapshots $bookSnapshots -Metric 'monthTickets' -Days 30 -CanReset $true
    $recommendTickets = Get-MetricDelta -Snapshots $bookSnapshots -Metric 'recommendTickets' -Days 30 -CanReset $false
    $comments = Get-MetricDelta -Snapshots $bookSnapshots -Metric 'chapterComments' -Days 30 -CanReset $false
    $chapters = Get-MetricDelta -Snapshots $bookSnapshots -Metric 'chapterCount' -Days 30 -CanReset $false
    $ratingPulse = Get-RatingPulse -Snapshots $bookSnapshots
    $updatedWords7d = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'updatedWords7d' -Default 0)

    $monthMomentum = Normalize-Log -Value ($monthTickets.DailyRate * 30) -Scale 35000
    $recommendMomentum = Normalize-Log -Value ($recommendTickets.DailyRate * 30) -Scale 80000
    $commentBase = $comments.DailyRate * 30
    if ($chapters.Delta -gt 0) {
        $commentBase = $commentBase + (($comments.Delta / [Math]::Max(1, $chapters.Delta)) * 18)
    }
    $commentMomentum = Normalize-Log -Value $commentBase -Scale 60000
    $updateConsistency = Normalize-Log -Value $updatedWords7d -Scale 65000

    $dataConfidence = Clamp-Number -Value (($monthTickets.Confidence + $recommendTickets.Confidence + $comments.Confidence + $ratingPulse.Confidence) / 4)
    $score = 100 * (
        ($monthMomentum * 0.30) +
        ($recommendMomentum * 0.22) +
        ($commentMomentum * 0.20) +
        ($ratingPulse.Score * 0.16) +
        ($updateConsistency * 0.12)
    )
    $score = $score * (0.72 + (0.28 * $dataConfidence))

    $reasonParts = New-Object System.Collections.Generic.List[string]
    if ($monthMomentum -ge 0.66) { $reasonParts.Add('Strong monthly-ticket momentum') }
    if ($recommendMomentum -ge 0.62) { $reasonParts.Add('Fast recommendation growth') }
    if ($commentMomentum -ge 0.58) { $reasonParts.Add('Active chapter discussion') }
    if ($ratingPulse.Score -ge 0.72) { $reasonParts.Add('Stable rating reputation') }
    if ($updateConsistency -ge 0.58) { $reasonParts.Add('Stable recent updates') }
    if ($reasonParts.Count -eq 0) { $reasonParts.Add('Balanced signals') }

    return [pscustomobject]@{
        Book = $Book
        Score = [Math]::Round($score, 2)
        Components = [pscustomobject]@{
            monthMomentum = [Math]::Round($monthMomentum * 100, 2)
            recommendMomentum = [Math]::Round($recommendMomentum * 100, 2)
            commentMomentum = [Math]::Round($commentMomentum * 100, 2)
            ratingPulse = [Math]::Round($ratingPulse.Score * 100, 2)
            updateConsistency = [Math]::Round($updateConsistency * 100, 2)
            confidence = [Math]::Round($dataConfidence * 100, 2)
        }
        LatestSnapshot = $latest
        Reason = ($reasonParts -join ' / ')
    }
}

function Test-RetentionEligible {
    param($Book)

    $status = [string](Get-ObjectValue -Object $Book -Name 'status' -Default '')
    $wordCount = Convert-ToNumber (Get-ObjectValue -Object $Book -Name 'wordCount' -Default 0)
    $hasChineseFinishedMark = $status.Contains([string][char]0x5B8C)
    return $hasChineseFinishedMark -or ($status -match 'completed|complete|finished') -or ($wordCount -ge 2000000)
}

function Get-RetentionScoreForBook {
    param(
        [Parameter(Mandatory = $true)]$Book,
        [array]$Snapshots
    )

    $bookId = [string](Get-ObjectValue -Object $Book -Name 'id' -Default '')
    $bookSnapshots = Get-SnapshotsForBook -Snapshots $Snapshots -BookId $bookId
    $latest = Get-LatestSnapshot -Snapshots $bookSnapshots
    $eligible = Test-RetentionEligible -Book $Book

    if ($null -eq $latest) {
        return [pscustomobject]@{
            Book = $Book
            Eligible = $eligible
            Score = 0
            DecayIndex = 1
            Components = [pscustomobject]@{}
            LatestSnapshot = $null
            Reason = 'No snapshots yet'
        }
    }

    $wordCount = Convert-ToNumber (Get-ObjectValue -Object $Book -Name 'wordCount' -Default 0)
    $chapterCount = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'chapterCount' -Default 1)
    $chapterComments = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'chapterComments' -Default 0)
    $recommendTickets = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'recommendTickets' -Default 0)
    $monthly = Get-MetricDelta -Snapshots $bookSnapshots -Metric 'monthTickets' -Days 30 -CanReset $true
    $recommendRecent = Get-MetricDelta -Snapshots $bookSnapshots -Metric 'recommendTickets' -Days 30 -CanReset $false
    $commentsRecent = Get-MetricDelta -Snapshots $bookSnapshots -Metric 'chapterComments' -Days 30 -CanReset $false
    $rating = Get-BayesianRatingScore -Snapshot $latest

    $first = $bookSnapshots[0]
    $firstDate = Get-DateFromSnapshot -Snapshot $first
    $latestDate = Get-DateFromSnapshot -Snapshot $latest
    $totalDays = [Math]::Max(1, ($latestDate - $firstDate).TotalDays)
    $firstRecommend = Convert-ToNumber (Get-ObjectValue -Object $first -Name 'recommendTickets' -Default 0)
    $firstComments = Convert-ToNumber (Get-ObjectValue -Object $first -Name 'chapterComments' -Default 0)
    $allTimeDaily = (($recommendTickets - $firstRecommend) + (($chapterComments - $firstComments) * 0.35)) / $totalDays
    $recentDaily = $recommendRecent.DailyRate + ($monthly.DailyRate * 1.8) + ($commentsRecent.DailyRate * 0.35)
    $retentionRatio = Clamp-Number -Value ($recentDaily / [Math]::Max(1, $allTimeDaily * 0.85)) -Max 1.25
    $retentionIndex = Clamp-Number -Value ($retentionRatio / 1.25)
    $decayIndex = Clamp-Number -Value (1 - $retentionIndex)

    $commentDepth = Normalize-Log -Value ($chapterComments / [Math]::Max(1, $chapterCount)) -Scale 120
    $recommendDensity = Normalize-Log -Value ($recommendTickets / [Math]::Max(0.2, ($wordCount / 1000000))) -Scale 250000
    $ratingStability = 1
    $baseline90 = Get-BaselineSnapshot -Snapshots $bookSnapshots -Days 90
    if ($null -ne $baseline90) {
        $latestRating = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'rating' -Default 0)
        $baselineRating = Convert-ToNumber (Get-ObjectValue -Object $baseline90 -Name 'rating' -Default $latestRating)
        $ratingStability = Clamp-Number -Value (1 - ([Math]::Abs($latestRating - $baselineRating) / 1.6))
    }

    $score = 100 * (
        ($rating.Score * 0.30) +
        ($retentionIndex * 0.20) +
        ($commentDepth * 0.18) +
        ($recommendDensity * 0.17) +
        ($ratingStability * 0.15)
    )

    if (-not $eligible) {
        $score = $score * 0.78
    }

    $reasonParts = New-Object System.Collections.Generic.List[string]
    if ($rating.Score -ge 0.72) { $reasonParts.Add('Strong long-term rating') }
    if ($retentionIndex -ge 0.62) { $reasonParts.Add('Low 30-day decay') }
    if ($commentDepth -ge 0.58) { $reasonParts.Add('High comment depth') }
    if ($recommendDensity -ge 0.58) { $reasonParts.Add('High recommendations per million words') }
    if ($reasonParts.Count -eq 0) { $reasonParts.Add('Moderate retention signals') }

    return [pscustomobject]@{
        Book = $Book
        Eligible = $eligible
        Score = [Math]::Round($score, 2)
        DecayIndex = [Math]::Round($decayIndex, 4)
        Components = [pscustomobject]@{
            bayesianRating = [Math]::Round($rating.Score * 100, 2)
            retentionIndex = [Math]::Round($retentionIndex * 100, 2)
            commentDepth = [Math]::Round($commentDepth * 100, 2)
            recommendDensity = [Math]::Round($recommendDensity * 100, 2)
            ratingStability = [Math]::Round($ratingStability * 100, 2)
        }
        LatestSnapshot = $latest
        Reason = ($reasonParts -join ' / ')
    }
}

function Get-NovelScores {
    param(
        [array]$Books,
        [array]$Snapshots
    )

    $trend = @()
    $retention = @()
    foreach ($book in $Books) {
        $trend += Get-TrendScoreForBook -Book $book -Snapshots $Snapshots
        $retention += Get-RetentionScoreForBook -Book $book -Snapshots $Snapshots
    }

    $daily = @()
    foreach ($trendItem in $trend) {
        $bookId = Get-ObjectValue -Object $trendItem.Book -Name 'id' -Default ''
        $retentionItem = @($retention | Where-Object { (Get-ObjectValue -Object $_.Book -Name 'id' -Default '') -eq $bookId })[0]
        $retentionWeight = if ($retentionItem.Eligible) { 0.42 } else { 0.18 }
        $trendWeight = 1 - $retentionWeight
        $score = ($trendItem.Score * $trendWeight) + ($retentionItem.Score * $retentionWeight)
        $daily += [pscustomobject]@{
            Book = $trendItem.Book
            Score = [Math]::Round($score, 2)
            TrendScore = $trendItem.Score
            RetentionScore = $retentionItem.Score
            DecayIndex = $retentionItem.DecayIndex
            Reason = ($trendItem.Reason + '; ' + $retentionItem.Reason)
            LatestSnapshot = $trendItem.LatestSnapshot
        }
    }

    return [pscustomobject]@{
        daily = @($daily | Sort-Object Score -Descending)
        active = @($trend | Sort-Object Score -Descending)
        retention = @($retention | Sort-Object Score -Descending)
    }
}

function New-ProjectedSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Book,
        [array]$Snapshots,
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
    )

    $bookId = [string](Get-ObjectValue -Object $Book -Name 'id' -Default '')
    $bookSnapshots = Get-SnapshotsForBook -Snapshots $Snapshots -BookId $bookId
    $latest = Get-LatestSnapshot -Snapshots $bookSnapshots
    if ($null -eq $latest) {
        return [pscustomobject]@{
            bookId = $bookId
            capturedAt = $Date
            monthTickets = 0
            recommendTickets = 0
            rating = 8.0
            ratingCount = 0
            chapterComments = 0
            chapterCount = 0
            updatedWords7d = 0
            source = 'projected'
        }
    }

    $seed = [Math]::Abs($bookId.GetHashCode()) % 11
    $wordCount = Convert-ToNumber (Get-ObjectValue -Object $Book -Name 'wordCount' -Default 1000000)
    $statusText = [string](Get-ObjectValue -Object $Book -Name 'status' -Default '')
    $isFinished = $statusText.Contains([string][char]0x5B8C) -or ($statusText -match 'completed|finished')
    $pace = if ($isFinished) { 0.08 } elseif ($wordCount -gt 2000000) { 0.55 } else { 1.0 }
    $monthTickets = [int]((Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'monthTickets' -Default 0)) + ((80 + ($seed * 23)) * $pace))
    $recommendTickets = [int]((Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'recommendTickets' -Default 0)) + ((120 + ($seed * 37)) * (0.6 + $pace)))
    $chapterComments = [int]((Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'chapterComments' -Default 0)) + ((28 + ($seed * 9)) * (0.45 + $pace)))
    $chapterCount = [int](Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'chapterCount' -Default 0))
    $updatedWords7d = [int](Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'updatedWords7d' -Default 0))
    if (-not $isFinished -and (($seed % 3) -ne 0)) {
        $chapterCount += 1
        $updatedWords7d = [Math]::Max($updatedWords7d, 4500 + ($seed * 900))
    }

    $rating = Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'rating' -Default 8.0)
    $ratingNudge = (($seed - 5) / 1000.0)
    $rating = Clamp-Number -Value ($rating + $ratingNudge) -Min 5 -Max 9.9

    return [pscustomobject]@{
        bookId = $bookId
        capturedAt = $Date
        monthTickets = $monthTickets
        recommendTickets = $recommendTickets
        rating = [Math]::Round($rating, 2)
        ratingCount = [int]((Convert-ToNumber (Get-ObjectValue -Object $latest -Name 'ratingCount' -Default 0)) + [Math]::Max(1, $seed * 3))
        chapterComments = $chapterComments
        chapterCount = $chapterCount
        updatedWords7d = $updatedWords7d
        source = 'projected'
    }
}

Export-ModuleMember -Function @(
    'Clamp-Number',
    'Get-ObjectValue',
    'Normalize-Log',
    'Get-MetricDelta',
    'Get-NovelScores',
    'Get-TrendScoreForBook',
    'Get-RetentionScoreForBook',
    'New-ProjectedSnapshot',
    'Test-RetentionEligible'
)
