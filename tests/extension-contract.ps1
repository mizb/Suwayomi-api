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

Assert-Contains "src/zh/jmapi/build.gradle.kts" 'name\s*=\s*"JM API"'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'versionCode\s*=\s*9'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'libVersion\s*=\s*"1\.4"'
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
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'apiBaseUrl'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("list", "promote"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("list", "weekly"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("list", "popular"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("search"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("order"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'getFilterList'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortFilter'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'data\s+class\s+SortOption'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("Latest", "new", "mr"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("Most views", "mv", "mv"\)'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'SortOption\("Highest likes", "tf", "tf"\)'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'Most images'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'Enter a JM ID, album URL, or title'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'queryParameter\("list"\)'

$jmApiSource = Get-Content -LiteralPath (Join-Path $root "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt") -Raw -Encoding UTF8
$requestBody = [regex]::Match(
    $jmApiSource,
    'override fun searchMangaRequest\([\s\S]*?(?<body>val trimmedQuery[\s\S]*?)\n    override fun searchMangaParse'
).Groups['body'].Value
if ([string]::IsNullOrWhiteSpace($requestBody)) {
    throw 'Could not isolate searchMangaRequest body'
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
    $emptyBranch -notmatch 'selectedSort\.catalogOrder' -or
    $emptyBranch -match 'addQueryParameter\("search"') {
    throw 'Empty query must use list=popular with catalogOrder and no search parameter'
}
if ($idBranch -notmatch 'addQueryParameter\("jmid",\s*jmId\)' -or
    $idBranch -match 'addQueryParameter\("order"') {
    throw 'JM ID branch must use jmid without an order parameter'
}
if ($titleBranch -notmatch 'addQueryParameter\("search",\s*trimmedQuery\)' -or
    $titleBranch -notmatch 'selectedSort\.searchOrder') {
    throw 'Title branch must use search with searchOrder'
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
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '\?jmid='
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '&chapter='
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("page"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'prefetch=0'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'isApiPrefetchDisabled'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'maybeDisableApiPrefetch'
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
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmListItemDto'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'fun JmAlbumEnvelope.toSManga'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'fun JmListItemDto.toSManga'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'thumbnail_url = image.takeIf'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'chapterNumber: Float'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'chapter_number = chapterNumber'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'chapter_number\s*=\s*sort\.toFloatOrNull'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'parseChapterIds'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'Invalid JM chapter URL'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" '\\d\{1,20\}'
Assert-NotContains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'parts\[1\]\s+to\s+parts\[2\]'

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

Assert-Contains "README.md" 'Suwayomi'
Assert-Contains "README.md" 'http://127.0.0.1:8088'
Assert-Contains "README.md" 'http://jmcomic-api:8088'
Assert-Contains "README.md" 'prefetch=0'
Assert-Contains "README.md" 'Disable API prefetch'
Assert-Contains "README.md" 'SIGNING_KEYSTORE_BASE64'
Assert-Contains "README.md" 'Popular.*original homepage recommendations'
Assert-Contains "README.md" 'Latest.*original weekly picks'
Assert-Contains "README.md" 'tachiyomi-zh\.jmapi-v1\.4\.9\.apk'
Assert-Contains "docs/apk-optimization-design.md" '1\.4\.9'
Assert-Contains "docs/apk-optimization-design.md" 'versionCode\s*=\s*9'
Assert-Contains "docs/apk-optimization-design.md" 'Popular.*promote'
Assert-Contains "docs/apk-optimization-design.md" 'Latest.*weekly'
Assert-Contains "docs/ai-delivery-prompt.md" 'v1\.4\.9'
Assert-Contains "docs/ai-delivery-prompt.md" 'versionCode 9'

$readme = Get-Content -LiteralPath (Join-Path $root "README.md") -Raw -Encoding UTF8
if ($readme -match 'tachiyomi-zh\.jmapi-v1\.4\.[12345678]\.apk') {
    throw "README contains stale APK version before v1.4.9"
}

$dto = Get-Content -LiteralPath (Join-Path $root "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt") -Raw -Encoding UTF8
if ($dto -match 'thumbnail_url\s*=.*page=1') {
    throw "Detail thumbnail must use album cover, not decoded page 1"
}

Write-Host "JM API extension contract checks passed."
