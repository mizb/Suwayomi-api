$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Assert-File {
    param([string] $RelativePath)
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing file: $RelativePath"
    }
    return $path
}

function Assert-Contains {
    param(
        [string] $RelativePath,
        [string] $Pattern
    )
    $path = Assert-File $RelativePath
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($content -notmatch $Pattern) {
        throw "Missing pattern in ${RelativePath}: $Pattern"
    }
}

function Assert-NotContains {
    param(
        [string] $RelativePath,
        [string] $Pattern
    )
    $path = Assert-File $RelativePath
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($content -match $Pattern) {
        throw "Unexpected pattern in ${RelativePath}: $Pattern"
    }
}

function Get-ExtensionSafetyCaseSets {
    param(
        [Parameter(Mandatory = $true)][string] $SourceText,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $SourceText,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) {
        throw "Safety case-set parse failed for ${Label}: $($parseErrors.Message -join '; ')."
    }

    $caseParameters = @($ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -ceq 'Case'
    })
    if ($caseParameters.Count -ne 1) {
        throw "Safety case-set parse failed for ${Label}: expected exactly one Case parameter."
    }
    $validateSetAttributes = @($caseParameters[0].Attributes | Where-Object {
        $_.TypeName.FullName -ceq 'ValidateSet'
    })
    if ($validateSetAttributes.Count -ne 1) {
        throw "Safety case-set parse failed for ${Label}: expected exactly one ValidateSet on Case."
    }
    $validateSetCases = @($validateSetAttributes[0].PositionalArguments | ForEach-Object {
        if ($_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "Safety case-set parse failed for ${Label}: ValidateSet contains a non-literal case."
        }
        $_.Value
    })

    $caseAssignments = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ceq 'cases'
    }, $true))
    if ($caseAssignments.Count -ne 1 -or
        $caseAssignments[0].Right -isnot [System.Management.Automation.Language.IfStatementAst]
    ) {
        throw "Safety case-set parse failed for ${Label}: expected one cases = if (...) assignment."
    }
    $allIf = $caseAssignments[0].Right
    if ($allIf.Clauses.Count -ne 1 -or $allIf.ElseClause -eq $null) {
        throw "Safety case-set parse failed for ${Label}: cases assignment must contain one All branch and one else branch."
    }
    $allCases = @($allIf.Clauses[0].Item2.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true) | ForEach-Object { $_.Value })

    $caseSwitches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.SwitchStatementAst] -and
            $node.Condition.Extent.Text.Trim() -ceq '$selectedCase'
    }, $true))
    if ($caseSwitches.Count -ne 1) {
        throw "Safety case-set parse failed for ${Label}: expected exactly one switch(selectedCase)."
    }
    $switchCases = @($caseSwitches[0].Clauses | ForEach-Object {
        if ($_.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "Safety case-set parse failed for ${Label}: switch contains a non-literal case."
        }
        $_.Item1.Value
    })

    return [pscustomobject]@{
        ValidateSet = $validateSetCases
        All = $allCases
        Switch = $switchCases
    }
}

function Assert-ExtensionSafetyCaseParity {
    param(
        [Parameter(Mandatory = $true)][string] $SourceText,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $caseSets = Get-ExtensionSafetyCaseSets -SourceText $SourceText -Label $Label
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'ValidateSet'; Values = @($caseSets.ValidateSet) },
        [pscustomobject]@{ Name = 'All'; Values = @($caseSets.All) },
        [pscustomobject]@{ Name = 'switch'; Values = @($caseSets.Switch) }
    )) {
        $uniqueValues = @($entry.Values | Sort-Object -Unique)
        if ($uniqueValues.Count -ne $entry.Values.Count) {
            throw "Safety case-set mismatch: $Label $($entry.Name) contains duplicate case names."
        }
    }

    $validateCases = @($caseSets.ValidateSet | Where-Object { $_ -cne 'All' } | Sort-Object)
    if (@($caseSets.ValidateSet | Where-Object { $_ -ceq 'All' }).Count -ne 1) {
        throw "Safety case-set mismatch: $Label ValidateSet must contain exactly one All entry."
    }
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'All'; Values = @($caseSets.All | Sort-Object) },
        [pscustomobject]@{ Name = 'switch'; Values = @($caseSets.Switch | Sort-Object) }
    )) {
        $difference = @(Compare-Object -ReferenceObject $validateCases -DifferenceObject $entry.Values)
        if ($difference.Count -ne 0) {
            $details = $difference | ForEach-Object { "$($_.SideIndicator)$($_.InputObject)" }
            throw "Safety case-set mismatch: $Label ValidateSet vs $($entry.Name): $($details -join ', ')."
        }
    }
}

Assert-Contains "src/zh/jmapi/build.gradle.kts" 'name\s*=\s*"JM API"'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'versionCode\s*=\s*15'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'libVersion\s*=\s*"1\.4"'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'import\s+io\.github\.keiyoushi\.gradle\.api\.ContentWarning'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'baseUrl\s*=\s*"http://127\.0\.0\.1:8088"'

Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'class\s+JmApi\s*:\s*HttpSource'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'ConfigurableSource'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'getPreferences\(\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'private\s+val\s+preferences'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'supportsLatest\s*=\s*true'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'setupPreferenceScreen'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'API_BASE_URL_PREF'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'DISABLE_API_PREFETCH_PREF'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'DEFAULT_API_BASE_URL\s*=\s*"http://127\.0\.0\.1:8088"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'DEFAULT_DISABLE_API_PREFETCH\s*=\s*false'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'normalizeApiBaseUrl'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '0\.0\.0\.0'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'hostForSafetyCheck\s*=\s*parsed\.host\.trimEnd\(''\.''\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'UNSPECIFIED_IPV4_REGEX\.matches\(hostForSafetyCheck\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'Regex\("""0\+\(\?:\\\.0\+\)\{0,3\}"""\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'apiBaseUrl'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("list", "promote"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("list", "weekly"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("list", "popular"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("search"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("order"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'getFilterList'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortFilter'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'data\s+class\s+SortOption'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("\u6700\u65b0", "new", "mr"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("\u6700\u591a\u6d4f\u89c8", "mv", "mv"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("\u6700\u591a\u70b9\u8d5e", "tf", "tf"\)'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("Latest"'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'Most images'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'Enter a JM ID, album URL, or title'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'queryParameter\("list"\)'

$jmApiSource = Get-Content -LiteralPath (Join-Path $root "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt") -Raw -Encoding UTF8

foreach ($localizedText in @(
    '"\u6392\u5e8f"',
    '"JM API \u5730\u5740"',
    '"\u7981\u7528 API \u9884\u53d6"'
)) {
    if ($jmApiSource -notmatch $localizedText) {
        throw "Missing Chinese extension UI text: $localizedText"
    }
}
foreach ($staleText in @(
    '"Sort"',
    '"API base URL"',
    '"Disable API prefetch"'
)) {
    if ($jmApiSource.Contains($staleText)) {
        throw "English extension UI text must be localized: $staleText"
    }
}

Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'private\s+data\s+class\s+ApiEndpoint\s*\([\s\S]*?val\s+rawPreference:\s*String[\s\S]*?val\s+baseUrl:\s*HttpUrl[\s\S]*?val\s+basePath:\s*String'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '@Volatile[\s\S]*?ApiEndpoint\?'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'rawPreference\s*==\s*raw'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'parsed\.query\s*!=\s*null'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'parsed\.fragment\s*!=\s*null'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'parsed\.username\.isNotEmpty\(\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'parsed\.password\.isNotEmpty\(\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'rawUserInfo\s*!=\s*null'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '0\.0\.0\.0'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '"::"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'pathSegments[\s\S]*?dropLastWhile'

$getMangaUrlBody = [regex]::Match(
    $jmApiSource,
    'override fun getMangaUrl\([^)]*\):\s*String(?<body>[\s\S]*?)(?=\n    override fun getChapterUrl)'
).Groups['body'].Value
$getChapterUrlBody = [regex]::Match(
    $jmApiSource,
    'override fun getChapterUrl\([^)]*\):\s*String(?<body>[\s\S]*?)(?=\n    private fun pageImageUrl)'
).Groups['body'].Value
if ([string]::IsNullOrWhiteSpace($getMangaUrlBody) -or
    $getMangaUrlBody -notmatch 'newBuilder\(\)' -or
    $getMangaUrlBody -notmatch 'addQueryParameter\("jmid"') {
    throw 'getMangaUrl must use the normalized HttpUrl builder'
}
if ([string]::IsNullOrWhiteSpace($getChapterUrlBody) -or
    $getChapterUrlBody -notmatch 'newBuilder\(\)' -or
    $getChapterUrlBody -notmatch 'addQueryParameter\("jmid"' -or
    $getChapterUrlBody -notmatch 'addQueryParameter\("chapter"') {
    throw 'getChapterUrl must use the normalized HttpUrl builder'
}
if ($jmApiSource -match '"\$\{apiBaseUrl\(\)\}/\?') {
    throw 'Display URLs must not use string concatenation'
}

Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'applyApiPrefetchPreference'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'setQueryParameter\("prefetch",\s*"0"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'removeAllQueryParameters\("prefetch"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'isDecodedPageUrl'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'normalizedPathSegments'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'normalizedPathSegments\(url\)\s*==\s*normalizedPathSegments\(endpoint\.baseUrl\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'imageRequest\([\s\S]*?applyApiPrefetchPreference'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'maybeDisableApiPrefetch'

Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'JM_PREFIX_REGEX\s*=\s*Regex\("""\(\?i\)JM\(\\d\{1,20\}\)\(\?!\\d\)"""\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'QUERY_ID_REGEX[\s\S]*?\\d\{1,20\}[\s\S]*?\(\?=\[&#\]\|\$\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'PATH_ID_REGEX[\s\S]*?\\d\{1,20\}[\s\S]*?\(\?!\\d\)[\s\S]*?\(\?=\[/\?#\]\|\$\)'

$queryIdRegex = [regex]'[?&](?:jmid|id)=(\d{1,20})(?=[&#]|$)'
foreach ($invalidQueryId in @(
    '?jmid=123abc', '?id=456.7', '?jmid=123%34', '?jmid=123456789012345678901'
)) {
    if ($queryIdRegex.IsMatch($invalidQueryId)) {
        throw "QUERY_ID_REGEX accepted a non-complete query value: $invalidQueryId"
    }
}
foreach ($validQueryId in @('?jmid=123', '?id=456&x=1', '?jmid=789#fragment')) {
    if (-not $queryIdRegex.IsMatch($validQueryId)) {
        throw "QUERY_ID_REGEX rejected a complete query value: $validQueryId"
    }
}

$pathIdRegex = [regex]'/(?:(?:album|photo)s?)/(\d{1,20})(?!\d)(?=[/?#]|$)'
foreach ($invalidPathId in @('/album/123abc', '/photo/456.7', '/albums/123456789012345678901')) {
    if ($pathIdRegex.IsMatch($invalidPathId)) {
        throw "PATH_ID_REGEX accepted a non-complete path value: $invalidPathId"
    }
}
foreach ($validPathId in @('/album/123', '/photos/456/', '/album/789?from=library', '/photo/987#reader')) {
    if (-not $pathIdRegex.IsMatch($validPathId)) {
        throw "PATH_ID_REGEX rejected a complete path value: $validPathId"
    }
}

$pageParseBody = [regex]::Match(
    $jmApiSource,
    'override fun pageListParse\([\s\S]*?(?<body>val data[\s\S]*?)\n    override fun imageUrlParse'
).Groups['body'].Value
if ([string]::IsNullOrWhiteSpace($pageParseBody) -or
    $pageParseBody -notmatch 'firstOrNull\s*\{\s*it\.photoId\s*==\s*requestedChapter\s*\}' -or
    $pageParseBody -notmatch 'requestedChapter') {
    throw 'pageListParse must select the requested chapter and identify it in errors'
}
if ($pageParseBody -match 'chapters\.firstOrNull\(\)') {
    throw 'pageListParse must not silently use the first returned chapter'
}
if ($pageParseBody -notmatch 'imageUrl\s*=\s*pageImageUrl\(data\.album\.albumId,\s*chapter\.photoId,\s*pageNumber\)') {
    throw 'pageListParse must rebuild every image URL from the configured API endpoint'
}
if ($pageParseBody -match 'chapter\.images\.getOrNull\([^)]*\)\?\.url') {
    throw 'pageListParse must not trust an absolute image URL from the API payload'
}

$requestBody = [regex]::Match(
    $jmApiSource,
    'override fun searchMangaRequest\([\s\S]*?(?<body>val trimmedQuery[\s\S]*?)\n    override fun searchMangaParse'
).Groups['body'].Value
if ([string]::IsNullOrWhiteSpace($requestBody)) {
    throw 'Could not isolate searchMangaRequest body'
}

$sharedSearchBuilder = [regex]::Match(
    $requestBody,
    'val builder\s*=\s*apiEndpoint\(\)\.baseUrl\.newBuilder\(\)[\s\S]*?(?=\n\s*val jmId\s*=)'
).Value
if ([string]::IsNullOrWhiteSpace($sharedSearchBuilder)) {
    throw 'Could not isolate the shared search request builder'
}
if ($sharedSearchBuilder -match 'addQueryParameter\("page"') {
    throw 'Shared search builder must not leak page into the direct JM ID branch'
}

$emptyBranch = [regex]::Match(
    $requestBody,
    'trimmedQuery\.isEmpty\(\)\s*->[\s\S]*?(?=\n\s*jmId\s*!=\s*null\s*->)'
).Value
$idBranch = [regex]::Match(
    $requestBody,
    'jmId\s*!=\s*null\s*->[\s\S]*?(?=\n\s*else\s*->)'
).Value
$titleBranch = [regex]::Match(
    $requestBody,
    'else\s*->[\s\S]*?\.build\(\)'
).Value

if ($emptyBranch -notmatch 'addQueryParameter\("list",\s*"popular"\)' -or
    $emptyBranch -notmatch 'addQueryParameter\("page",\s*page\.toString\(\)\)' -or
    $emptyBranch -notmatch 'selectedSort\.catalogOrder' -or
    $emptyBranch -match 'addQueryParameter\("search"') {
    throw 'Empty query must use list=popular with page, catalogOrder, and no search parameter'
}
if ($idBranch -notmatch 'addQueryParameter\("jmid",\s*jmId\)' -or
    $idBranch -match 'addQueryParameter\("page"' -or
    $idBranch -match 'addQueryParameter\("order"') {
    throw 'JM ID branch must use only format+jmid without page or order parameters'
}
if ($titleBranch -notmatch 'addQueryParameter\("search",\s*trimmedQuery\)' -or
    $titleBranch -notmatch 'addQueryParameter\("page",\s*page\.toString\(\)\)' -or
    $titleBranch -notmatch 'selectedSort\.searchOrder') {
    throw 'Title branch must use search with page and searchOrder'
}

$parseBody = [regex]::Match(
    $jmApiSource,
    'override fun searchMangaParse\([\s\S]*?(?<body>= when \{[\s\S]*?)\n    override fun mangaDetailsRequest'
).Groups['body'].Value
if ([string]::IsNullOrWhiteSpace($parseBody)) {
    throw 'Could not isolate searchMangaParse body'
}
foreach ($pattern in @(
    'queryParameter\("search"\).*parseList\(\)',
    'queryParameter\("list"\).*parseList\(\)',
    'queryParameter\("jmid"\)',
    'parseData<JmAlbumEnvelope>',
    'Unsupported JM API search response'
)) {
    if ($parseBody -notmatch $pattern) {
        throw "Missing search parser dispatch pattern: $pattern"
    }
}
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'parseJmId'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("jmid"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("chapter"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("page"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'setQueryParameter\("prefetch",\s*"0"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'isApiPrefetchDisabled'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'isSameApiEndpoint'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'if \(!isSameApiEndpoint\(parsed\)\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'if \(isApiPrefetchDisabled\(\)\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'imageUrlParse\(response: Response\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'sort\.toFloatOrNull\(\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'chapterReadingOrder'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'asReversed\(\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'mapIndexed'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'readingOrder\.size\s*-\s*index'

Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmAlbumDto'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'val image: String = ""'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmChapterDto'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmListEnvelope'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmListEnvelope\s*\([\s\S]*?val total: Long = 0L'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmListEnvelope\s*\([\s\S]*?val total: Int = 0'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmListItemDto'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'val likes: Long = 0L'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" '@SerialName\("total_views"\) val totalViews: Long = 0L'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'val likes: Int'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" '@SerialName\("total_views"\) val totalViews: Int'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'fun JmAlbumEnvelope.toSManga'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'fun\s+JmAlbumEnvelope\.toSManga\(\):\s*SManga'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'toSManga\(baseUrl:\s*String\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'fun JmListItemDto.toSManga'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'thumbnail_url = image.takeIf'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'chapterNumber: Float'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'chapter_number = chapterNumber'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'chapter_number\s*=\s*sort\.toFloatOrNull'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'parseChapterIds'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'Invalid JM chapter URL'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" '\\d\{1,20\}'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'parts\[1\]\s+to\s+parts\[2\]'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'trimEnd\(''\/''\)'

$dtoText = Get-Content -LiteralPath (Join-Path $root "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt") -Raw -Encoding UTF8
foreach ($localizedDtoText in @('\u6d4f\u89c8\uff1a', '\u70b9\u8d5e\uff1a', '\u8bc4\u8bba\uff1a', '\u7ae0\u8282\uff1a', '\u7b2c')) {
    if ($dtoText -notmatch $localizedDtoText) {
        throw "Missing Chinese DTO text: $localizedDtoText"
    }
}
foreach ($englishDtoText in @('"Views:', '"Likes:', '"Comments:', '"Chapters:', '"Chapter ')) {
    if ($dtoText.Contains($englishDtoText)) {
        throw "English DTO text must be localized: $englishDtoText"
    }
}

Assert-Contains ".github/workflows/build-extension.yml" 'keiyoushi/extensions-source'
Assert-Contains ".github/workflows/build-extension.yml" 'actions/setup-java@v4'
Assert-Contains ".github/workflows/build-extension.yml" ':src:zh:jmapi:assembleRelease'
Assert-Contains ".github/workflows/build-extension.yml" ':src:zh:jmapi:spotlessApply'
Assert-Contains ".github/workflows/build-extension.yml" 'index.min.json'
Assert-Contains ".github/workflows/build-extension.yml" 'index.json'
Assert-Contains ".github/workflows/build-extension.yml" 'repo.json'
Assert-Contains ".github/workflows/build-extension.yml" '"baseUrl": "http://127\.0\.0\.1:8088"'
Assert-Contains ".github/workflows/build-extension.yml" 'peaceiris/actions-gh-pages@v4'
Assert-Contains ".github/workflows/build-extension.yml" 'publish_branch: repo'
Assert-Contains ".github/workflows/build-extension.yml" 'AAPT2.*dump badging'
Assert-Contains ".github/workflows/build-extension.yml" 'MANIFEST_VERSION_CODE'
Assert-Contains ".github/workflows/build-extension.yml" 'MANIFEST_VERSION_NAME'
Assert-Contains ".github/workflows/build-extension.yml" 'mapfile -t APK_SOURCES'
Assert-Contains ".github/workflows/build-extension.yml" '\$\{#APK_SOURCES\[@\]\}.*-ne 1'
Assert-Contains ".github/workflows/build-extension.yml" 'LIB_VERSION.*numeric dotted notation'
Assert-Contains ".github/workflows/build-extension.yml" 'VERSION_CODE.*positive decimal integer'
Assert-Contains ".github/workflows/build-extension.yml" 'basename -- "\$\{APK_NAME\}"'
Assert-Contains ".github/workflows/build-extension.yml" 'APK_FINAL="dist/apk/\$\{APK_NAME\}"'
Assert-Contains ".github/workflows/build-extension.yml" 'cp "\$\{APK_SOURCE\}" "\$\{APK_FINAL\}"[\s\S]*?dump badging "\$\{APK_FINAL\}"'
Assert-Contains ".github/workflows/build-extension.yml" 'dump badging "\$\{APK_FINAL\}"[\s\S]*?verify --print-certs "\$\{APK_FINAL\}"'
Assert-NotContains ".github/workflows/build-extension.yml" 'dump badging "\$\{APK_SOURCE\}"'
Assert-NotContains ".github/workflows/build-extension.yml" 'verify --print-certs "\$\{APK_SOURCE\}"'

Assert-Contains "README.md" 'Suwayomi'
Assert-Contains "README.md" 'http://127.0.0.1:8088'
Assert-Contains "README.md" 'http://jmcomic-api:8088'
Assert-Contains "README.md" 'prefetch=0'
Assert-Contains "README.md" '\u7981\u7528 API \u9884\u53d6'
Assert-Contains "README.md" 'SIGNING_KEYSTORE_BASE64'
Assert-Contains "README.md" 'Popular.*original homepage recommendations'
Assert-Contains "README.md" 'Latest.*original weekly picks'
Assert-Contains "README.md" 'tachiyomi-zh\.jmapi-v1\.4\.15\.apk'
Assert-Contains "README.md" '2026\.07\.17\.1'
Assert-Contains "docs/apk-optimization-design.md" '1\.4\.15'
Assert-Contains "docs/apk-optimization-design.md" 'versionCode\s*=\s*15'
Assert-Contains "docs/apk-optimization-design.md" 'Popular.*promote'
Assert-Contains "docs/apk-optimization-design.md" 'Latest.*weekly'
Assert-Contains "docs/apk-optimization-design.md" 'junction.*\u7269\u7406\u8def\u5f84'
Assert-Contains "docs/apk-optimization-design.md" 'settings\.gradle\.kts.*\u539f\u59cb\u5b57\u8282'
Assert-Contains "docs/apk-optimization-design.md" 'libVersion.*\u6570\u5b57\u70b9\u53f7'
Assert-Contains "docs/ai-delivery-prompt.md" 'v1\.4\.15'
Assert-Contains "docs/ai-delivery-prompt.md" 'versionCode 15'
Assert-Contains "docs/ai-delivery-prompt.md" 'junction.*\u7269\u7406\u8def\u5f84'
Assert-Contains "docs/ai-delivery-prompt.md" 'D:\\jm\\jmcomic-api-main'
Assert-NotContains "docs/ai-delivery-prompt.md" 'D:\\jm\\jm-boom-master\\jmcomic-api-main'

foreach ($scriptPath in @('scripts/build-with-keiyoushi.ps1', 'scripts/generate-repo-metadata.ps1')) {
    Assert-File $scriptPath | Out-Null
}
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'D:\\jm\\keiyoushi'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'Resolve-Path'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'GetPathRoot'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'KeiyoushiRoot must name a non-root directory'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'loadIndividualExtension\("zh",\s*"jmapi"\)'
Assert-Contains "scripts/build-with-keiyoushi.ps1" ':src:zh:jmapi:spotlessApply'
Assert-Contains "scripts/build-with-keiyoushi.ps1" ':src:zh:jmapi:assembleRelease'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'ReadAllBytes\(\$settingsPath\)'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'try\s*\{\s*\[System\.IO\.File\]::WriteAllText\(\$settingsPath,\s*\$isolatedSettings'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'finally\s*\{[\s\S]*?\[System\.IO\.File\]::WriteAllBytes\(\$settingsPath,\s*\$originalSettingsBytes'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'Assert-SeparateTrees\s+-Left\s+\$sourceExtension\s+-Right\s+\$expectedTarget'
Assert-Contains "scripts/build-with-keiyoushi.ps1" '\$cloneStage'
Assert-Contains "scripts/build-with-keiyoushi.ps1" '\$targetStage'
Assert-Contains "scripts/build-with-keiyoushi.ps1" '\$targetBackup'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'plannedTargetParent[\s\S]*?Assert-JmApiPhysicalPathEquals[\s\S]*?New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$expectedTargetParent'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$cloneStage[\s\S]*?-RequireNew[\s\S]*?git clone'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$targetStage[\s\S]*?-RequireNew[\s\S]*?Get-ChildItem\s+-LiteralPath\s+\$sourceExtension[\s\S]*?Copy-Item'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$cloneParent'
Assert-NotContains "scripts/build-with-keiyoushi.ps1" 'New-Item\s+-ItemType\s+Directory\s+-Path\s+\$expectedTargetParent\s+-Force'
Assert-Contains "scripts/build-with-keiyoushi.ps1" 'Staged extension build output cleanup'
Assert-Contains "scripts/build-with-keiyoushi.ps1" '\$releaseApks\.Count\s+-ne\s+1[\s\S]*?\$buildSucceeded\s*=\s*\$true'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'param\([\s\S]*?\$ApkPath[\s\S]*?\$OutputDir'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'GetPathRoot'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'apksigner'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'certificate SHA-256 digest'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'index\.min\.json'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'index\.json'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'repo\.json'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'signingKeyFingerprint'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'requiredValues\.GetEnumerator\(\)'
Assert-Contains "scripts/generate-repo-metadata.ps1" '\$stagingOutput'
Assert-Contains "scripts/generate-repo-metadata.ps1" '\$outputBackup'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'Assert-OutputTreeSafe\s+-OutputTree\s+\$resolvedOutput\s+-ProtectedPath\s+\$resolvedProject'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'Assert-OutputTreeSafe\s+-OutputTree\s+\$resolvedOutput\s+-ProtectedPath\s+\$resolvedApk'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'Move-ExactDirectory\s+`[\s\S]*?-Source\s+\$stagingOutput\s+`[\s\S]*?-Destination\s+\$resolvedOutput'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'finally\s*\{[\s\S]*?Repository metadata staging cleanup'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'libVersion must use numeric dotted notation'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'GetFileName\(\$apkName\)\s*-cne\s*\$apkName'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'Assert-JmApiDirectChildPath'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'Find-Aapt2'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'APK manifest does not match build\.gradle\.kts'
Assert-Contains "scripts/generate-repo-metadata.ps1" '\[System\.IO\.FileShare\]::Read'
Assert-Contains "scripts/generate-repo-metadata.ps1" '\$validatedApkSha256[\s\S]*?\$postValidationApkSha256'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'Copy-VerifiedApkInput[\s\S]*?Staged APK SHA-256 did not match the validated APK'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$outputParent'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$stagingOutput[\s\S]*?-BeforeCreateHook\s+\$stageCreationAdapter'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$apkOutput[\s\S]*?-RequireNew'
Assert-Contains "scripts/generate-repo-metadata.ps1" 'New-JmApiSafeDirectoryPath\s+`[\s\S]*?-Path\s+\$iconOutput[\s\S]*?-RequireNew'
Assert-NotContains "scripts/generate-repo-metadata.ps1" 'New-Item\s+-ItemType\s+Directory\s+-Path\s+\$outputParent\s+-Force'
Assert-File "scripts/path-safety.ps1" | Out-Null
Assert-Contains "scripts/path-safety.ps1" 'GetFinalPathNameByHandleW'
Assert-Contains "scripts/path-safety.ps1" 'Get-JmApiPhysicalPath'
Assert-Contains "scripts/path-safety.ps1" 'Remove-JmApiTreeEntryWithoutFollowingReparsePoints'
Assert-Contains "scripts/path-safety.ps1" '\[System\.IO\.Directory\]::Move'
Assert-Contains "scripts/path-safety.ps1" 'Automatic rollback also failed'
Assert-Contains "scripts/path-safety.ps1" 'OpenPathEntryWithoutDeleteSharing\(\$Destination\)[\s\S]*?Assert-JmApiSafeInternalTree[\s\S]*?\$destinationIdentityHandle\.Dispose\(\)[\s\S]*?Undo-JmApiSafeDirectoryMove'
Assert-Contains "scripts/path-safety.ps1" '\$identityAcquisitionFailure[\s\S]*?\$destinationIdentityHandle\.Dispose\(\)[\s\S]*?Undo-JmApiSafeDirectoryMove[\s\S]*?post-move identity acquisition failed'
Assert-Contains "scripts/path-safety.ps1" 'function\s+New-JmApiSafeDirectoryPath[\s\S]*?OpenPathEntryWithoutDeleteSharing\(\$existingAncestor\)[\s\S]*?New-Item\s+-ItemType\s+Directory\s+-Path\s+\$child[\s\S]*?stable parent recheck'
Assert-Contains "scripts/path-safety.ps1" '\$plannedTargetPhysical\s*=\s*Get-JmApiPhysicalPath\s+\$target[\s\S]*?outside ExpectedPhysicalPath before creation[\s\S]*?New-Item\s+-ItemType\s+Directory'
Assert-NotContains "scripts/path-safety.ps1" 'Move-Item'
Assert-NotContains "scripts/path-safety.ps1" 'Remove-Item[^\r\n]*-Recurse'

$parityGateDriftFixture = @'
[CmdletBinding()]
param(
    [ValidateSet('All', 'Alpha', 'Beta')]
    [string] $Case = 'All'
)
$cases = if ($Case -eq 'All') {
    @('Alpha')
} else {
    @($Case)
}
foreach ($selectedCase in $cases) {
    switch ($selectedCase) {
        'Alpha' { Invoke-Alpha }
        'Beta' { Invoke-Beta }
        default { throw 'unknown' }
    }
}
'@
$parityDriftRejected = $false
try {
    Assert-ExtensionSafetyCaseParity `
        -SourceText $parityGateDriftFixture `
        -Label 'Synthetic safety parity drift'
} catch {
    if ($_.Exception.Message -match '^Safety case-set mismatch:') {
        $parityDriftRejected = $true
    } else {
        throw
    }
}
if (-not $parityDriftRejected) {
    throw 'Safety case-set parity gate self-test accepted an All-list omission.'
}

$safetyContract = Get-Content -LiteralPath (Join-Path $root 'tests\extension-safety-contract.ps1') -Raw -Encoding UTF8
Assert-ExtensionSafetyCaseParity `
    -SourceText $safetyContract `
    -Label 'extension-safety-contract.ps1'

$buildAliasRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("jmapi-build-alias-" + [guid]::NewGuid().ToString("N"))
$buildAliasSource = Join-Path $buildAliasRoot "src\zh\jmapi"
$buildAliasMarker = Join-Path $buildAliasSource "source-marker.txt"
try {
    New-Item -ItemType Directory -Path $buildAliasSource -Force | Out-Null
    [System.IO.File]::WriteAllText($buildAliasMarker, "must-survive")
    $aliasRejected = $false
    try {
        & (Join-Path $root "scripts\build-with-keiyoushi.ps1") `
            -KeiyoushiRoot $buildAliasRoot `
            -SourceRoot $buildAliasRoot `
            -JavaHome $buildAliasRoot `
            -AndroidSdkRoot $buildAliasRoot | Out-Null
    } catch {
        $aliasRejected = $true
    }
    if (-not $aliasRejected) {
        throw "Build helper accepted an overlapping source and Keiyoushi tree."
    }
    if (-not (Test-Path -LiteralPath $buildAliasMarker -PathType Leaf)) {
        throw "Build helper deleted its source before rejecting an overlapping tree."
    }
} finally {
    if (Test-Path -LiteralPath $buildAliasRoot) {
        Remove-Item -LiteralPath $buildAliasRoot -Recurse -Force
    }
}

$buildRollbackRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("jmapi-build-rollback-" + [guid]::NewGuid().ToString("N"))
$buildRollbackSource = Join-Path $buildRollbackRoot "source"
$buildRollbackKeiyoushi = Join-Path $buildRollbackRoot "keiyoushi"
$buildRollbackSourceExtension = Join-Path $buildRollbackSource "src\zh\jmapi"
$buildRollbackTarget = Join-Path $buildRollbackKeiyoushi "src\zh\jmapi"
$buildRollbackOldMarker = Join-Path $buildRollbackTarget "old-target-marker.txt"
try {
    New-Item -ItemType Directory -Path (Join-Path $buildRollbackSourceExtension "build\outputs\apk\release") -Force | Out-Null
    New-Item -ItemType Directory -Path $buildRollbackTarget -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $buildRollbackRoot "jdk\bin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $buildRollbackRoot "sdk") -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $buildRollbackSourceExtension "source-marker.txt"), "new-source")
    [System.IO.File]::WriteAllText((Join-Path $buildRollbackSourceExtension "build\outputs\apk\release\stale.apk"), "stale")
    [System.IO.File]::WriteAllText($buildRollbackOldMarker, "old-target")
    [System.IO.File]::WriteAllText((Join-Path $buildRollbackKeiyoushi "settings.gradle.kts"), "loadAllIndividualExtensions()`r`n")
    [System.IO.File]::WriteAllText((Join-Path $buildRollbackKeiyoushi "gradlew.bat"), "@exit /b 0`r`n")
    [System.IO.File]::WriteAllText((Join-Path $buildRollbackRoot "jdk\bin\java.exe"), "fixture")

    $missingArtifactRejected = $false
    try {
        & (Join-Path $root "scripts\build-with-keiyoushi.ps1") `
            -KeiyoushiRoot $buildRollbackKeiyoushi `
            -SourceRoot $buildRollbackSource `
            -JavaHome (Join-Path $buildRollbackRoot "jdk") `
            -AndroidSdkRoot (Join-Path $buildRollbackRoot "sdk") | Out-Null
    } catch {
        $missingArtifactRejected = $true
    }
    if (-not $missingArtifactRejected) {
        throw "Build helper accepted a stale source APK when Gradle produced no release artifact."
    }
    if (-not (Test-Path -LiteralPath $buildRollbackOldMarker -PathType Leaf)) {
        throw "Build helper did not restore the previous target after artifact validation failed."
    }
} finally {
    if (Test-Path -LiteralPath $buildRollbackRoot) {
        Remove-Item -LiteralPath $buildRollbackRoot -Recurse -Force
    }
}

$readme = Get-Content -LiteralPath (Join-Path $root "README.md") -Raw -Encoding UTF8
if ($readme -match 'tachiyomi-zh\.jmapi-v1\.4\.(?:[1-9]|1[0-4])\.apk') {
    throw "README contains stale APK version before v1.4.15"
}

$dto = Get-Content -LiteralPath (Join-Path $root "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt") -Raw -Encoding UTF8
if ($dto -match 'thumbnail_url\s*=.*page=1') {
    throw "Detail thumbnail must use album cover, not decoded page 1"
}

& (Join-Path $PSScriptRoot 'extension-safety-contract.ps1') -Case All

Write-Host "JM API extension contract checks passed."
