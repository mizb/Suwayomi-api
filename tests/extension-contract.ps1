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

Assert-Contains "src/zh/jmapi/build.gradle.kts" 'name\s*=\s*"JM API"'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'versionCode\s*=\s*1'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'libVersion\s*=\s*"1\.4"'
Assert-Contains "src/zh/jmapi/build.gradle.kts" 'baseUrl\s*=\s*"http://0\.0\.0\.0:8088"'

Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'class\s+JmApi\s*:\s*HttpSource'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'parseJmId'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '\?jmid='
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" '&chapter='
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'addQueryParameter\("page"'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/JmApi.kt" 'imageUrlParse\(response: Response\)'

Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmAlbumDto'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'data class JmChapterDto'
Assert-Contains "src/zh/jmapi/src/eu/kanade/tachiyomi/extension/zh/jmapi/Dto.kt" 'fun JmAlbumEnvelope.toSManga'

Assert-Contains ".github/workflows/build-extension.yml" 'keiyoushi/extensions-source'
Assert-Contains ".github/workflows/build-extension.yml" 'actions/setup-java@v4'
Assert-Contains ".github/workflows/build-extension.yml" ':src:zh:jmapi:assembleRelease'
Assert-Contains ".github/workflows/build-extension.yml" ':src:zh:jmapi:spotlessApply'
Assert-Contains ".github/workflows/build-extension.yml" 'index.min.json'
Assert-Contains ".github/workflows/build-extension.yml" 'repo.json'
Assert-Contains ".github/workflows/build-extension.yml" '"baseUrl": "http://0\.0\.0\.0:8088"'

Assert-Contains "README.md" 'Suwayomi'
Assert-Contains "README.md" 'http://0.0.0.0:8088'
Assert-Contains "README.md" 'SIGNING_KEYSTORE_BASE64'

Write-Host "JM API extension contract checks passed."
