param(
    [int]$Port = 5177,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'
$Root = [System.IO.Path]::GetFullPath($Root)
$FrontendRoot = Join-Path $Root 'frontend'
$DataRoot = Join-Path $Root 'data'
$InboxRoot = Join-Path $DataRoot 'inbox'
$ModulePath = Join-Path $PSScriptRoot 'NovelScoring.psm1'

Import-Module $ModulePath -Force -DisableNameChecking
New-Item -ItemType Directory -Force -Path $DataRoot, $InboxRoot | Out-Null

function Get-DataPath {
    param([string]$Name)
    return (Join-Path $DataRoot $Name)
}

function Read-JsonData {
    param(
        [string]$Path,
        $Default
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonData {
    param(
        [string]$Path,
        $Value
    )

    $json = $Value | ConvertTo-Json -Depth 30
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-Books {
    return @(Read-JsonData -Path (Get-DataPath 'books.json') -Default @())
}

function Save-Books {
    param([array]$Books)

    $ordered = @($Books | Sort-Object id)
    Write-JsonData -Path (Get-DataPath 'books.json') -Value $ordered
}

function Get-Snapshots {
    return @(Read-JsonData -Path (Get-DataPath 'snapshots.json') -Default @())
}

function Get-Targets {
    $defaults = @(
        [pscustomobject]@{
            id = 'rank-yuepiao'
            name = '月票榜'
            url = 'https://www.qidian.com/rank/yuepiao/'
            cadence = 'daily'
            limit = 200
            enabled = $true
        },
        [pscustomobject]@{
            id = 'rank-recom'
            name = '推荐榜'
            url = 'https://www.qidian.com/rank/recom/'
            cadence = 'daily'
            limit = 200
            enabled = $true
        },
        [pscustomobject]@{
            id = 'finish'
            name = '完本库'
            url = 'https://www.qidian.com/finish/'
            cadence = 'weekly'
            limit = 300
            enabled = $true
        },
        [pscustomobject]@{
            id = 'all'
            name = '全站书库发现'
            url = 'https://www.qidian.com/all/'
            cadence = 'weekly'
            limit = 500
            enabled = $false
        }
    )

    $path = Get-DataPath 'targets.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-JsonData -Path $path -Value $defaults
        return $defaults
    }
    return @(Read-JsonData -Path $path -Default $defaults)
}

function Save-Targets {
    param([array]$Targets)
    Write-JsonData -Path (Get-DataPath 'targets.json') -Value @($Targets)
}

function Get-Settings {
    $defaults = [pscustomobject]@{
        dailyRunAt = '08:30'
        activeWindowDays = 30
        retentionMinWords = 2000000
        maxRecommendations = 20
        qidianSourceUrl = 'https://www.qidian.com/?source=m_jump'
        collectorMode = 'manual-or-cookie'
    }

    $path = Get-DataPath 'settings.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-JsonData -Path $path -Value $defaults
        return $defaults
    }
    return (Read-JsonData -Path $path -Default $defaults)
}

function Save-Snapshots {
    param([array]$Snapshots)

    $ordered = @($Snapshots | Sort-Object bookId, capturedAt)
    Write-JsonData -Path (Get-DataPath 'snapshots.json') -Value $ordered
}

function Merge-Books {
    param(
        [array]$Existing,
        [array]$Incoming
    )

    $byId = @{}
    foreach ($book in $Existing) {
        $id = [string](Get-ObjectValue -Object $book -Name 'id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($id)) { $byId[$id] = $book }
    }

    foreach ($book in $Incoming) {
        $id = [string](Get-ObjectValue -Object $book -Name 'id' -Default '')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (-not $byId.ContainsKey($id)) {
            $byId[$id] = $book
            continue
        }

        $current = $byId[$id]
        foreach ($name in @('title', 'author', 'category', 'status', 'sourceUrl', 'summary', 'dataQuality')) {
            $value = Get-ObjectValue -Object $book -Name $name -Default $null
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                $current | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
            }
        }

        $wordCount = Convert-ToNumber (Get-ObjectValue -Object $book -Name 'wordCount' -Default 0)
        if ($wordCount -gt 0) {
            $current | Add-Member -NotePropertyName 'wordCount' -NotePropertyValue ([int]$wordCount) -Force
        }
        $byId[$id] = $current
    }

    return @($byId.Values | Sort-Object id)
}

function Merge-Snapshots {
    param(
        [array]$Existing,
        [array]$Incoming
    )

    $byKey = @{}
    foreach ($snapshot in $Existing) {
        $key = "{0}|{1}" -f (Get-ObjectValue -Object $snapshot -Name 'bookId' -Default ''), (Get-ObjectValue -Object $snapshot -Name 'capturedAt' -Default '')
        if ($key -ne '|') { $byKey[$key] = $snapshot }
    }
    foreach ($snapshot in $Incoming) {
        $key = "{0}|{1}" -f (Get-ObjectValue -Object $snapshot -Name 'bookId' -Default ''), (Get-ObjectValue -Object $snapshot -Name 'capturedAt' -Default '')
        if ($key -ne '|') { $byKey[$key] = $snapshot }
    }
    return @($byKey.Values | Sort-Object bookId, capturedAt)
}

function Convert-HtmlToText {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $text = $Content -replace '<script[\s\S]*?</script>', ' '
    $text = $text -replace '<style[\s\S]*?</style>', ' '
    $text = $text -replace '<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

function Convert-MetricNumber {
    param($Value)

    if ($null -eq $Value) { return 0 }
    $text = [System.Net.WebUtility]::HtmlDecode([string]$Value)
    $text = $text -replace ',', ''
    $text = $text.Trim()
    $match = [regex]::Match($text, '([0-9]+(?:\.[0-9]+)?)')
    if (-not $match.Success) { return 0 }

    $number = [double]$match.Groups[1].Value
    $wan = [string][char]0x4E07
    $yi = [string][char]0x4EBF
    if ($text.Contains($yi)) { $number = $number * 100000000 }
    elseif ($text.Contains($wan)) { $number = $number * 10000 }
    return [Math]::Round($number, 2)
}

function Remove-Markup {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $text = $Value -replace '<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

function Get-JsonStringField {
    param(
        [string]$Text,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $pattern = '"' + [regex]::Escape($name) + '"\s*:\s*"([^"]+)"'
        $match = [regex]::Match($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) { return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value) }
    }
    return ''
}

function Get-JsonNumberField {
    param(
        [string]$Text,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $pattern = '"' + [regex]::Escape($name) + '"\s*:\s*"?([0-9]+(?:\.[0-9]+)?)(?:[^0-9"]|")'
        $match = [regex]::Match($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) { return Convert-MetricNumber $match.Groups[1].Value }
    }
    return 0
}

function Get-NearMetric {
    param(
        [string]$Text,
        [string[]]$Labels
    )

    foreach ($label in $Labels) {
        $offset = 0
        while ($offset -lt $Text.Length) {
            $index = $Text.IndexOf($label, $offset, [System.StringComparison]::OrdinalIgnoreCase)
            if ($index -lt 0) { break }

            $beforeStart = [Math]::Max(0, $index - 32)
            $before = $Text.Substring($beforeStart, $index - $beforeStart)
            $beforeMatch = [regex]::Match($before, '([0-9][0-9,]*(?:\.[0-9]+)?\s*(?:\u4E07|\u4EBF)?)\s*$')
            if ($beforeMatch.Success) { return Convert-MetricNumber $beforeMatch.Groups[1].Value }

            $afterStart = $index + $label.Length
            $afterLength = [Math]::Min(32, $Text.Length - $afterStart)
            if ($afterLength -gt 0) {
                $after = $Text.Substring($afterStart, $afterLength)
                $afterMatch = [regex]::Match($after, '^\s*(?::|\uFF1A)?\s*([0-9][0-9,]*(?:\.[0-9]+)?\s*(?:\u4E07|\u4EBF)?)')
                if ($afterMatch.Success) { return Convert-MetricNumber $afterMatch.Groups[1].Value }
            }

            $offset = $index + $label.Length
        }
    }
    return 0
}

function Get-BookTitleFromContent {
    param(
        [string]$Content,
        [string]$BookId,
        [string]$Segment
    )

    $hrefPattern = '(?is)<a[^>]+href=["''][^"'']*(?:book\.qidian\.com/info|www\.qidian\.com/book)/' + [regex]::Escape($BookId) + '[^"'']*["''][^>]*>(.*?)</a>'
    $match = [regex]::Match($Content, $hrefPattern)
    if ($match.Success) {
        $title = Remove-Markup $match.Groups[1].Value
        if (-not [string]::IsNullOrWhiteSpace($title)) { return $title }
    }

    $title = Get-JsonStringField -Text $Segment -Names @('bookName', 'bName', 'title', 'name')
    if (-not [string]::IsNullOrWhiteSpace($title)) { return $title }
    return ('Qidian book ' + $BookId)
}

function Get-StatusFromText {
    param([string]$Text)

    $finished = ([string][char]0x5B8C) + ([string][char]0x672C)
    $serial = ([string][char]0x8FDE) + ([string][char]0x8F7D)
    if ($Text.Contains($finished)) { return $finished }
    if ($Text.Contains($serial)) { return $serial }
    return $serial
}

function ConvertFrom-QidianContent {
    param(
        [string]$Content,
        [string]$CapturedAt,
        [string]$SourceUrl = ''
    )

    $bookMatches = [regex]::Matches($Content, '(?:book\.qidian\.com/info|www\.qidian\.com/book)/([0-9]{4,})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($match in $bookMatches) {
        $id = $match.Groups[1].Value
        if (-not $ids.Contains($id)) { $ids.Add($id) }
    }

    $books = @()
    $snapshots = @()
    $warnings = New-Object System.Collections.Generic.List[string]
    $textOnly = Convert-HtmlToText -Content $Content
    $monthLabel = ([string][char]0x6708) + ([string][char]0x7968)
    $recommendLabel = ([string][char]0x63A8) + ([string][char]0x8350) + ([string][char]0x7968)
    $ratingLabel = ([string][char]0x8BC4) + ([string][char]0x5206)
    $commentLabel = ([string][char]0x8BC4) + ([string][char]0x8BBA)
    $chapterLabel = ([string][char]0x7AE0)
    $wordLabel = ([string][char]0x5B57)

    foreach ($id in $ids) {
        $firstMatch = [regex]::Match($Content, '(?:book\.qidian\.com/info|www\.qidian\.com/book)/' + [regex]::Escape($id), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $start = if ($firstMatch.Success) { [Math]::Max(0, $firstMatch.Index - 1800) } else { 0 }
        $length = [Math]::Min(4200, $Content.Length - $start)
        $segment = $Content.Substring($start, $length)
        $plain = Convert-HtmlToText -Content $segment

        $title = Get-BookTitleFromContent -Content $Content -BookId $id -Segment $segment
        $author = Get-JsonStringField -Text $segment -Names @('authorName', 'author', 'aName')
        $category = Get-JsonStringField -Text $segment -Names @('catName', 'categoryName', 'category', 'cName')
        $wordCount = Get-JsonNumberField -Text $segment -Names @('wordCount', 'wordsCnt', 'wordsCount', 'cnt')
        if ($wordCount -le 0) {
            $wordPattern = '([0-9]+(?:\.[0-9]+)?\s*[\u4E07\u4EBF]?)\s*' + [regex]::Escape($wordLabel)
            $wordMatch = [regex]::Match($plain, $wordPattern)
            if ($wordMatch.Success) { $wordCount = Convert-MetricNumber $wordMatch.Groups[1].Value }
        }

        $monthTickets = Get-JsonNumberField -Text $segment -Names @('monthTicket', 'monthTickets', 'monthCount', 'mTicket')
        if ($monthTickets -le 0) { $monthTickets = Get-NearMetric -Text $plain -Labels @($monthLabel) }

        $recommendTickets = Get-JsonNumberField -Text $segment -Names @('recommendTicket', 'recommendTickets', 'recCount', 'recomCount')
        if ($recommendTickets -le 0) { $recommendTickets = Get-NearMetric -Text $plain -Labels @($recommendLabel) }

        $rating = Get-JsonNumberField -Text $segment -Names @('rating', 'score', 'bookScore')
        if ($rating -le 0) { $rating = Get-NearMetric -Text $plain -Labels @($ratingLabel) }

        $ratingCount = Get-JsonNumberField -Text $segment -Names @('ratingCount', 'scoreCount', 'rateCount')
        $chapterComments = Get-JsonNumberField -Text $segment -Names @('chapterComments', 'commentCount', 'commentsCount')
        if ($chapterComments -le 0) { $chapterComments = Get-NearMetric -Text $plain -Labels @($commentLabel) }

        $chapterCount = Get-JsonNumberField -Text $segment -Names @('chapterCount', 'chaptersCount')
        if ($chapterCount -le 0) { $chapterCount = Get-NearMetric -Text $plain -Labels @($chapterLabel) }

        $books += [pscustomobject]@{
            id = $id
            title = $title
            author = $author
            category = $category
            status = Get-StatusFromText -Text $plain
            wordCount = [int]$wordCount
            sourceUrl = if ([string]::IsNullOrWhiteSpace($SourceUrl)) { 'https://book.qidian.com/info/' + $id } else { $SourceUrl }
            tags = @()
            summary = '由半自动起点页面采集导入。'
            dataQuality = 'qidian-html'
        }

        $hasSnapshotMetric = ($monthTickets -gt 0) -or ($recommendTickets -gt 0) -or ($rating -gt 0) -or ($chapterComments -gt 0) -or ($chapterCount -gt 0)
        if ($hasSnapshotMetric) {
            $snapshots += [pscustomobject]@{
                bookId = $id
                capturedAt = $CapturedAt
                monthTickets = [int]$monthTickets
                recommendTickets = [int]$recommendTickets
                rating = [Math]::Round([double]$rating, 2)
                ratingCount = [int]$ratingCount
                chapterComments = [int]$chapterComments
                chapterCount = [int]$chapterCount
                updatedWords7d = 0
                source = 'qidian-html'
            }
        } else {
            $warnings.Add('已发现书籍 ' + $id + '，但没有解析到可用于排名的指标。')
        }
    }

    return [pscustomobject]@{
        books = @($books)
        snapshots = @($snapshots)
        warnings = @($warnings)
        discovered = $ids.Count
        textLength = $textOnly.Length
    }
}

function Import-QidianContent {
    param(
        [string]$Content,
        [string]$CapturedAt,
        [string]$SourceUrl = ''
    )

    if ([string]::IsNullOrWhiteSpace($CapturedAt)) { $CapturedAt = Get-Date -Format 'yyyy-MM-dd' }
    $parsed = ConvertFrom-QidianContent -Content $Content -CapturedAt $CapturedAt -SourceUrl $SourceUrl
    if ($parsed.books.Count -gt 0) {
        Save-Books -Books (Merge-Books -Existing (Get-Books) -Incoming $parsed.books)
    }
    if ($parsed.snapshots.Count -gt 0) {
        Save-Snapshots -Snapshots (Merge-Snapshots -Existing (Get-Snapshots) -Incoming $parsed.snapshots)
    }

    return [pscustomobject]@{
        ok = $true
        discovered = $parsed.discovered
        importedBooks = $parsed.books.Count
        importedSnapshots = $parsed.snapshots.Count
        warnings = $parsed.warnings
    }
}

function Invoke-Refresh {
    param([string]$Date = (Get-Date -Format 'yyyy-MM-dd'))

    $books = Get-Books
    $snapshots = Get-Snapshots
    $inboxFile = Join-Path $InboxRoot 'qidian-snapshot.json'
    $source = 'projected'
    $incoming = @()

    if (Test-Path -LiteralPath $inboxFile) {
        $payload = Read-JsonData -Path $inboxFile -Default @()
        if ($payload.PSObject.Properties['snapshots']) {
            $incoming = @($payload.snapshots)
        } else {
            $incoming = @($payload)
        }
        $source = 'inbox'
        Move-Item -LiteralPath $inboxFile -Destination (Join-Path $InboxRoot ("qidian-snapshot.imported.{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))) -Force
    } else {
        foreach ($book in $books) {
            $incoming += New-ProjectedSnapshot -Book $book -Snapshots $snapshots -Date $Date
        }
    }

    $merged = Merge-Snapshots -Existing $snapshots -Incoming $incoming
    Save-Snapshots -Snapshots $merged

    return [pscustomobject]@{
        ok = $true
        source = $source
        imported = $incoming.Count
        totalSnapshots = $merged.Count
        date = $Date
    }
}

function Get-RecommendationPayload {
    param([string]$Mode = 'daily')

    $books = Get-Books
    $snapshots = Get-Snapshots
    $scores = Get-NovelScores -Books $books -Snapshots $snapshots
    $items = switch ($Mode) {
        'active' { $scores.active }
        'retention' { $scores.retention }
        default { $scores.daily }
    }

    return [pscustomobject]@{
        mode = $Mode
        generatedAt = (Get-Date).ToString('s')
        items = @($items)
    }
}

function Get-BookHistoryPayload {
    param([string]$BookId)

    $book = @(Get-Books | Where-Object { (Get-ObjectValue -Object $_ -Name 'id' -Default '') -eq $BookId })[0]
    $history = @(Get-Snapshots | Where-Object { (Get-ObjectValue -Object $_ -Name 'bookId' -Default '') -eq $BookId } | Sort-Object capturedAt)
    return [pscustomobject]@{
        book = $book
        snapshots = $history
    }
}

function Get-SchemePayload {
    return [pscustomobject]@{
        metricAssumptions = @(
            '月票被视为强时间窗口信号；如果检测到月度重置，系统会把当期数值作为新的活跃度处理。',
            '推荐票按累计互动处理；如果快照出现回退，系统会保留该段数据但降低可信权重。',
            '评分会结合评分人数做贝叶斯收缩，避免少量高分样本直接支配榜单。',
            '章节评论用于衡量讨论深度和读者留存，尤其适合完本书和 200 万字以上长篇。'
        )
        activeFormula = [pscustomobject]@{
            monthMomentum = '30%'
            recommendMomentum = '22%'
            commentMomentum = '20%'
            ratingPulse = '16%'
            updateConsistency = '12%'
            note = '近期活跃榜比较快照增量，默认使用 30 日动能衡量作品是否正在起势。'
        }
        retentionFormula = [pscustomobject]@{
            bayesianRating = '30%'
            retentionIndex = '20%'
            commentDepth = '18%'
            recommendDensity = '17%'
            ratingStability = '15%'
            note = '长篇留存榜聚焦完本或 200 万字以上作品；衰减越低，说明近期互动相对历史基线越稳。'
        }
        collectionPlan = @(
            '发现阶段：从书库、分类、榜单或允许访问的数据页中识别 bookId，并加入追踪队列。',
            '快照阶段：保存月票、推荐票、评分、评分人数、章节评论、章节数和近七日更新字数。',
            '访问边界：应用不会偷取浏览器登录信息，只使用手动导入、允许的数据源或明确配置的访问凭证。',
            '输出阶段：每天生成每日推荐、近期活跃、长篇留存三张榜，前端可按题材、状态和最低字数筛选。'
        )
    }
}

function Get-CollectorStatus {
    $cookieEnabled = -not [string]::IsNullOrWhiteSpace($env:QIDIAN_COOKIE)
    $inboxFile = Join-Path $InboxRoot 'qidian-snapshot.json'
    return [pscustomobject]@{
        qidianUrl = 'https://www.qidian.com/?source=m_jump'
        cookieConfigured = $cookieEnabled
        inboxWaiting = (Test-Path -LiteralPath $inboxFile)
        mode = if ($cookieEnabled) { 'cookie-header-ready' } else { 'manual-inbox-or-demo-projection' }
        note = '匿名访问起点可能返回风控页；正式采集应使用允许的数据源、低频访问和快照导入，不绕过访问控制。'
    }
}

function Send-Json {
    param(
        $Context,
        $Value,
        [int]$StatusCode = 200
    )

    $json = $Value | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers['Access-Control-Allow-Origin'] = '*'
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Text {
    param(
        $Context,
        [string]$Text,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Get-RequestBody {
    param($Request)

    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

function Get-MimeType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        default { return 'application/octet-stream' }
    }
}

function Send-StaticFile {
    param($Context, [string]$Path)

    $relative = $Path.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }
    $relative = $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $frontendFull = [System.IO.Path]::GetFullPath($FrontendRoot)
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $FrontendRoot $relative))
    if (-not $fullPath.StartsWith($frontendFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text -Context $Context -Text 'Forbidden' -StatusCode 403
        return
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Send-Text -Context $Context -Text 'Not found' -StatusCode 404
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = Get-MimeType -Path $fullPath
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Handle-Api {
    param($Context)

    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod.ToUpperInvariant()

    if ($method -eq 'OPTIONS') {
        $Context.Response.Headers['Access-Control-Allow-Origin'] = '*'
        $Context.Response.Headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
        $Context.Response.Headers['Access-Control-Allow-Headers'] = 'content-type'
        Send-Text -Context $Context -Text ''
        return
    }

    switch -Regex ($path) {
        '^/api/health$' {
            Send-Json -Context $Context -Value ([pscustomobject]@{ ok = $true; app = 'novel-trend-tracker'; time = (Get-Date).ToString('s') })
            return
        }
        '^/api/books$' {
            Send-Json -Context $Context -Value ([pscustomobject]@{ items = @(Get-Books) })
            return
        }
        '^/api/targets$' {
            if ($method -eq 'GET') {
                Send-Json -Context $Context -Value ([pscustomobject]@{ items = @(Get-Targets) })
                return
            }
            if ($method -eq 'POST') {
                $body = Get-RequestBody -Request $request
                $payload = $body | ConvertFrom-Json
                $targets = @()
                if ($payload.PSObject.Properties['items']) { $targets = @($payload.items) } else { $targets = @($payload) }
                Save-Targets -Targets $targets
                Send-Json -Context $Context -Value ([pscustomobject]@{ ok = $true; items = @(Get-Targets) })
                return
            }
        }
        '^/api/recommendations$' {
            $mode = $request.QueryString['mode']
            if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'daily' }
            Send-Json -Context $Context -Value (Get-RecommendationPayload -Mode $mode)
            return
        }
        '^/api/books/([^/]+)/history$' {
            $bookId = [uri]::UnescapeDataString($Matches[1])
            Send-Json -Context $Context -Value (Get-BookHistoryPayload -BookId $bookId)
            return
        }
        '^/api/scheme$' {
            Send-Json -Context $Context -Value (Get-SchemePayload)
            return
        }
        '^/api/collector/status$' {
            Send-Json -Context $Context -Value (Get-CollectorStatus)
            return
        }
        '^/api/settings$' {
            if ($method -eq 'GET') {
                Send-Json -Context $Context -Value (Get-Settings)
                return
            }
            if ($method -eq 'POST') {
                $body = Get-RequestBody -Request $request
                $settings = $body | ConvertFrom-Json
                Write-JsonData -Path (Get-DataPath 'settings.json') -Value $settings
                Send-Json -Context $Context -Value ([pscustomobject]@{ ok = $true; settings = $settings })
                return
            }
        }
        '^/api/track/refresh$' {
            if ($method -ne 'POST') {
                Send-Json -Context $Context -StatusCode 405 -Value ([pscustomobject]@{ ok = $false; error = 'Method not allowed' })
                return
            }
            $date = $request.QueryString['date']
            if ([string]::IsNullOrWhiteSpace($date)) { $date = (Get-Date -Format 'yyyy-MM-dd') }
            Send-Json -Context $Context -Value (Invoke-Refresh -Date $date)
            return
        }
        '^/api/import/snapshots$' {
            if ($method -ne 'POST') {
                Send-Json -Context $Context -StatusCode 405 -Value ([pscustomobject]@{ ok = $false; error = 'Method not allowed' })
                return
            }
            $body = Get-RequestBody -Request $request
            $payload = $body | ConvertFrom-Json
            $incoming = if ($payload.PSObject.Properties['snapshots']) { @($payload.snapshots) } else { @($payload) }
            $merged = Merge-Snapshots -Existing (Get-Snapshots) -Incoming $incoming
            Save-Snapshots -Snapshots $merged
            Send-Json -Context $Context -Value ([pscustomobject]@{ ok = $true; imported = $incoming.Count; totalSnapshots = $merged.Count })
            return
        }
        '^/api/import/qidian-html$' {
            if ($method -ne 'POST') {
                Send-Json -Context $Context -StatusCode 405 -Value ([pscustomobject]@{ ok = $false; error = 'Method not allowed' })
                return
            }
            $body = Get-RequestBody -Request $request
            $payload = $body | ConvertFrom-Json
            $content = [string](Get-ObjectValue -Object $payload -Name 'html' -Default '')
            if ([string]::IsNullOrWhiteSpace($content)) {
                $content = [string](Get-ObjectValue -Object $payload -Name 'text' -Default '')
            }
            $capturedAt = [string](Get-ObjectValue -Object $payload -Name 'capturedAt' -Default (Get-Date -Format 'yyyy-MM-dd'))
            $sourceUrl = [string](Get-ObjectValue -Object $payload -Name 'sourceUrl' -Default '')
            Send-Json -Context $Context -Value (Import-QidianContent -Content $content -CapturedAt $capturedAt -SourceUrl $sourceUrl)
            return
        }
        '^/api/export/snapshots$' {
            Send-Json -Context $Context -Value ([pscustomobject]@{ snapshots = @(Get-Snapshots) })
            return
        }
        default {
            Send-Json -Context $Context -StatusCode 404 -Value ([pscustomobject]@{ ok = $false; error = 'API route not found' })
            return
        }
    }
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Novel Trend Tracker is running at $prefix"
Write-Host "Press Ctrl+C to stop."

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $path = $context.Request.Url.AbsolutePath
            if ($path.StartsWith('/api/')) {
                Handle-Api -Context $context
            } else {
                Send-StaticFile -Context $context -Path $path
            }
        } catch {
            Send-Json -Context $context -StatusCode 500 -Value ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
        }
    }
} finally {
    $listener.Stop()
}

