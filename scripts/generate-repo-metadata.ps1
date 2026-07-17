[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ApkPath,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir,

    [string] $ProjectRoot = '',
    [string] $Website = '',
    [scriptblock] $BeforeStageCreationHook = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $scriptRoot
}
. (Join-Path $scriptRoot 'path-safety.ps1')

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [AllowEmptyString()][string] $Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    return Get-JmApiFullPath $Path
}

function Assert-ExactPath {
    param(
        [Parameter(Mandatory = $true)][string] $Actual,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Label
    )

    Assert-JmApiPhysicalPathEquals -Actual $Actual -Expected $Expected -Label $Label
}

function Assert-OutputTreeSafe {
    param(
        [Parameter(Mandatory = $true)][string] $OutputTree,
        [Parameter(Mandatory = $true)][string] $ProtectedPath,
        [Parameter(Mandatory = $true)][string] $Label
    )

    Assert-JmApiOutputTreeSafe -OutputTree $OutputTree -ProtectedPath $ProtectedPath -Label $Label
}

function Remove-ExactTree {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Remove-JmApiSafeTree `
        -Path $Path `
        -ExpectedPhysicalPath (Get-FullPath $Expected) `
        -ExpectedPhysicalParent (Get-FullPath (Split-Path -Parent (Get-FullPath $Expected))) `
        -Label $Label
}

function Move-ExactDirectory {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $sourceParent = Get-FullPath (Split-Path -Parent (Get-FullPath $Source))
    $destinationParent = Get-FullPath (Split-Path -Parent (Get-FullPath $Destination))
    if (-not [string]::Equals(
        $sourceParent,
        $destinationParent,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Label must remain within one verified physical parent. Source '$sourceParent', destination '$destinationParent'."
    }
    Move-JmApiSafeDirectory `
        -Source $Source `
        -ExpectedSourcePhysicalPath (Get-FullPath $Source) `
        -Destination $Destination `
        -ExpectedDestinationPhysicalPath (Get-FullPath $Destination) `
        -ExpectedPhysicalParent $sourceParent `
        -Label $Label
}

function Get-RequiredMatch {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $Pattern,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
        throw "Could not read $Label from build.gradle.kts."
    }
    return $match.Groups[1].Value.Trim()
}

function Find-ApkSigner {
    $command = Get-Command 'apksigner.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command 'apksigner' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -ne $command) {
        return $command.Source
    }

    $sdkRoots = @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        'D:\jm\.tools\android-sdk'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $candidates = foreach ($sdkRoot in $sdkRoots) {
        $buildTools = Join-Path $sdkRoot 'build-tools'
        if (Test-Path -LiteralPath $buildTools -PathType Container) {
            Get-ChildItem -LiteralPath $buildTools -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidate = Join-Path $_.FullName 'apksigner.bat'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    [pscustomobject]@{
                        Path = $candidate
                        Version = try { [version]$_.Name } catch { [version]'0.0' }
                    }
                }
            }
        }
    }

    $selected = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        throw 'Android build-tools apksigner was not found. Set ANDROID_HOME or install Android build-tools.'
    }
    return (Resolve-Path -LiteralPath $selected.Path).ProviderPath
}

function Find-Aapt2 {
    foreach ($name in @('aapt2.exe', 'aapt2')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return Get-JmApiPhysicalPath $command.Source
        }
    }

    $sdkRoots = @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        'D:\jm\.tools\android-sdk'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $candidates = foreach ($sdkRoot in $sdkRoots) {
        $buildTools = Join-Path $sdkRoot 'build-tools'
        if (Test-Path -LiteralPath $buildTools -PathType Container) {
            Get-ChildItem -LiteralPath $buildTools -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                foreach ($leaf in @('aapt2.exe', 'aapt2')) {
                    $candidate = Join-Path $_.FullName $leaf
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        [pscustomobject]@{
                            Path = $candidate
                            Version = try { [version]$_.Name } catch { [version]'0.0' }
                        }
                    }
                }
            }
        }
    }

    $selected = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        throw 'Android build-tools aapt2 was not found; APK manifest identity cannot be verified.'
    }
    return Get-JmApiPhysicalPath $selected.Path
}

function Get-SourceId {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $digest = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('jm api/zh/1'))
        [UInt64] $value = 0
        for ($index = 0; $index -lt 8; $index++) {
            $value = ($value -shl 8) -bor [UInt64]$digest[$index]
        }
        $value = $value -band ([UInt64]::MaxValue -shr 1)
        return $value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    } finally {
        $md5.Dispose()
    }
}

function Get-StreamSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Stream] $Stream
    )

    if (-not $Stream.CanRead -or -not $Stream.CanSeek) {
        throw 'APK SHA-256 binding requires a readable, seekable stream.'
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        $digest = $sha256.ComputeHash($Stream)
        $Stream.Position = 0
        return [System.BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Copy-VerifiedApkInput {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream] $InputStream,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )

    $destinationStream = New-Object System.IO.FileStream(
        $Destination,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::Read
    )
    try {
        $InputStream.Position = 0
        $InputStream.CopyTo($destinationStream)
        $destinationStream.Flush($true)
        $stagedSha256 = Get-StreamSha256 -Stream $destinationStream
        if ($stagedSha256 -cne $ExpectedSha256) {
            throw "Staged APK SHA-256 did not match the validated APK. Expected '$ExpectedSha256', got '$stagedSha256'."
        }
    } finally {
        $destinationStream.Dispose()
        $InputStream.Position = 0
    }
}

$resolvedApk = Get-JmApiPhysicalPath $ApkPath
if (-not (Test-Path -LiteralPath $resolvedApk -PathType Leaf)) {
    throw "APK was not found at '$ApkPath'."
}

$resolvedProject = Get-JmApiPhysicalPath $ProjectRoot
if (-not (Test-Path -LiteralPath $resolvedProject -PathType Container)) {
    throw "ProjectRoot was not found at '$ProjectRoot'."
}
$gradlePath = Join-Path $resolvedProject 'src\zh\jmapi\build.gradle.kts'
$iconPath = Join-Path $resolvedProject 'src\zh\jmapi\res\mipmap-xxxhdpi\ic_launcher.png'
if (-not (Test-Path -LiteralPath $gradlePath -PathType Leaf)) {
    throw "Build configuration was not found at '$gradlePath'."
}
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw "Extension icon was not found at '$iconPath'."
}

$gradle = [System.IO.File]::ReadAllText($gradlePath)
$versionCodeText = Get-RequiredMatch -Text $gradle -Pattern 'versionCode\s*=\s*(\d+)' -Label 'versionCode'
$libVersion = Get-RequiredMatch -Text $gradle -Pattern 'libVersion\s*=\s*"([^"]+)"' -Label 'libVersion'
$baseUrl = Get-RequiredMatch -Text $gradle -Pattern 'baseUrl\s*=\s*"([^"]+)"' -Label 'baseUrl'
if ($versionCodeText -notmatch '^[1-9][0-9]*$') {
    throw "Repository metadata versionCode must use positive decimal digits; got '$versionCodeText'."
}
$versionCode = 0
if (-not [int]::TryParse(
    $versionCodeText,
    [System.Globalization.NumberStyles]::None,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$versionCode
)) {
    throw "Repository metadata versionCode is outside the supported 32-bit range: '$versionCodeText'."
}
$numericDottedVersionPattern = '^(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))+$'
if ($libVersion -notmatch $numericDottedVersionPattern) {
    throw "Repository metadata libVersion must use numeric dotted notation; got '$libVersion'."
}
$version = "$libVersion.$versionCodeText"
if ($version -notmatch $numericDottedVersionPattern) {
    throw "Repository metadata version must use numeric dotted notation; got '$version'."
}
$packageName = 'eu.kanade.tachiyomi.extension.zh.jmapi'
$apkName = "tachiyomi-zh.jmapi-v$version.apk"
if ($apkName -notmatch '^tachiyomi-zh\.jmapi-v[0-9]+(?:\.[0-9]+)+\.apk$' -or
    [System.IO.Path]::GetFileName($apkName) -cne $apkName
) {
    throw "Repository metadata APK name is unsafe: '$apkName'."
}
$sourceId = Get-SourceId

$requestedOutput = Get-FullPath $OutputDir
$plannedOutput = Get-JmApiPhysicalPath $requestedOutput
$requestedOutputRoot = [System.IO.Path]::GetPathRoot($requestedOutput)
$plannedOutputRoot = [System.IO.Path]::GetPathRoot($plannedOutput)
if ([string]::Equals($requestedOutput, $requestedOutputRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    [string]::Equals($plannedOutput, $plannedOutputRoot, [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw "Repository metadata OutputDir must name a non-root directory: '$requestedOutput'."
}
Assert-OutputTreeSafe -OutputTree $plannedOutput -ProtectedPath $resolvedProject -Label 'ProjectRoot'
Assert-OutputTreeSafe -OutputTree $plannedOutput -ProtectedPath $resolvedApk -Label 'APK input'
Assert-OutputTreeSafe -OutputTree $plannedOutput -ProtectedPath $gradlePath -Label 'Build configuration input'
Assert-OutputTreeSafe -OutputTree $plannedOutput -ProtectedPath $iconPath -Label 'Icon input'
if (Test-Path -LiteralPath $requestedOutput -PathType Leaf) {
    throw "Repository metadata OutputDir is an existing file: '$requestedOutput'."
}
if ((Test-Path -LiteralPath $requestedOutput) -and (Test-JmApiReparsePoint $requestedOutput)) {
    throw "Repository metadata OutputDir must not itself be a reparse point: '$requestedOutput'."
}
$plannedOutputParent = Split-Path -Parent $plannedOutput
$outputLeaf = Split-Path -Leaf $plannedOutput
if ([string]::IsNullOrWhiteSpace($plannedOutputParent) -or [string]::IsNullOrWhiteSpace($outputLeaf)) {
    throw "Repository metadata OutputDir must name a non-root directory: '$plannedOutput'."
}

$apkInputStream = New-Object System.IO.FileStream(
    $resolvedApk,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
)
$originalProcessDirectory = [Environment]::CurrentDirectory
$processDirectoryRelocated = $false
try {
$validatedApkSha256 = Get-StreamSha256 -Stream $apkInputStream

$apksigner = Find-ApkSigner
$signerLines = & $apksigner verify --print-certs $resolvedApk 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "apksigner could not verify '$resolvedApk' (exit $LASTEXITCODE): $($signerLines -join [Environment]::NewLine)"
}
$signerText = $signerLines -join [Environment]::NewLine
$fingerprintMatch = [regex]::Match(
    $signerText,
    'certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
if (-not $fingerprintMatch.Success) {
    throw 'apksigner output did not contain the signer SHA-256 fingerprint.'
}
$fingerprint = [regex]::Replace($fingerprintMatch.Groups[1].Value, '[^0-9A-Fa-f]', '').ToLowerInvariant()
if ($fingerprint.Length -ne 64) {
    throw "APK signing fingerprint must contain 64 hexadecimal characters; got '$fingerprint'."
}

$aapt2 = Find-Aapt2
$badgingLines = & $aapt2 dump badging $resolvedApk 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "aapt2 could not inspect '$resolvedApk' (exit $LASTEXITCODE): $($badgingLines -join [Environment]::NewLine)"
}
$packageLine = @($badgingLines | ForEach-Object { [string]$_ } | Where-Object {
    $_ -match '^package:\s'
} | Select-Object -First 1)
if ($packageLine.Count -ne 1) {
    throw "aapt2 output did not contain exactly one APK package line for '$resolvedApk'."
}
$manifestPackageMatch = [regex]::Match($packageLine[0], "(?:^|\s)name='([^']*)'")
$manifestVersionCodeMatch = [regex]::Match($packageLine[0], "(?:^|\s)versionCode='([^']*)'")
$manifestVersionNameMatch = [regex]::Match($packageLine[0], "(?:^|\s)versionName='([^']*)'")
if (-not $manifestPackageMatch.Success -or -not $manifestVersionCodeMatch.Success -or
    -not $manifestVersionNameMatch.Success
) {
    throw "aapt2 package line omitted package/version identity: '$($packageLine[0])'."
}
$manifestPackage = $manifestPackageMatch.Groups[1].Value
$manifestVersionCode = $manifestVersionCodeMatch.Groups[1].Value
$manifestVersionName = $manifestVersionNameMatch.Groups[1].Value
if ($manifestPackage -cne $packageName -or
    $manifestVersionCode -cne $versionCodeText -or
    $manifestVersionName -cne $version
) {
    throw "APK manifest does not match build.gradle.kts. " +
        "Expected package='$packageName', versionCode='$versionCodeText', versionName='$version'; " +
        "got package='$manifestPackage', versionCode='$manifestVersionCode', versionName='$manifestVersionName'."
}
$postValidationApkSha256 = Get-StreamSha256 -Stream $apkInputStream
if ($postValidationApkSha256 -cne $validatedApkSha256) {
    throw "APK SHA-256 changed during signature/manifest validation. Expected '$validatedApkSha256', got '$postValidationApkSha256'."
}

if ([string]::IsNullOrWhiteSpace($Website)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL) -and
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
        $Website = "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)"
    } else {
        $Website = 'https://github.com'
    }
}

$requiredValues = [ordered]@{
    apk = $apkName
    version = $version
    code = $versionCodeText
    baseUrl = $baseUrl
    package = $packageName
    fingerprint = $fingerprint
}
foreach ($requiredValue in $requiredValues.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredValue.Value)) {
        throw "Repository metadata field '$($requiredValue.Key)' must not be empty."
    }
}
if ($versionCode -le 0) {
    throw 'Repository metadata version code must be positive.'
}

$index = @(
    [ordered]@{
        name = 'Tachiyomi: JM API'
        pkg = $packageName
        apk = $apkName
        lang = 'zh'
        code = $versionCode
        version = $version
        nsfw = 1
        sources = @(
            [ordered]@{
                name = 'JM API'
                lang = 'zh'
                id = $sourceId
                baseUrl = $baseUrl
            }
        )
    }
)
$repo = [ordered]@{
    index_v2 = $null
    meta = [ordered]@{
        name = 'JM API Extensions'
        shortName = 'JM API'
        website = $Website
        signingKeyFingerprint = $fingerprint
    }
}

$indexJson = ConvertTo-Json -InputObject $index -Depth 8
$repoJson = ConvertTo-Json -InputObject $repo -Depth 8

$outputParent = $plannedOutputParent
$comparison = [System.StringComparison]::OrdinalIgnoreCase
$separator = [System.IO.Path]::DirectorySeparatorChar
$currentProcessDirectory = Get-JmApiPhysicalPath $originalProcessDirectory
$currentDirectoryLocksTransaction =
    [string]::Equals($currentProcessDirectory, $outputParent, $comparison) -or
    [string]::Equals($currentProcessDirectory, $plannedOutput, $comparison) -or
    $currentProcessDirectory.StartsWith($plannedOutput + $separator, $comparison)
if ($currentDirectoryLocksTransaction) {
    $parkingCandidates = @(
        $scriptRoot,
        [System.IO.Path]::GetTempPath(),
        $env:SystemRoot,
        [System.IO.Path]::GetPathRoot($scriptRoot)
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath $_ -PathType Container)
    } | Select-Object -Unique

    foreach ($parkingCandidate in $parkingCandidates) {
        $parkingPhysical = Get-JmApiPhysicalPath $parkingCandidate
        if ([string]::Equals($parkingPhysical, $outputParent, $comparison) -or
            [string]::Equals($parkingPhysical, $plannedOutput, $comparison) -or
            $parkingPhysical.StartsWith($plannedOutput + $separator, $comparison)
        ) {
            continue
        }
        [Environment]::CurrentDirectory = $parkingPhysical
        $processDirectoryRelocated = $true
        break
    }
    if (-not $processDirectoryRelocated) {
        throw "Could not park the process current directory outside the repository metadata transaction tree."
    }
}
$outputParent = New-JmApiSafeDirectoryPath `
    -Path $outputParent `
    -ExpectedPhysicalPath $outputParent `
    -Label 'Repository metadata output parent'
$outputParent = Get-JmApiPhysicalPath $outputParent
$resolvedOutput = Join-Path $outputParent $outputLeaf
Assert-JmApiPhysicalPathEquals -Actual $resolvedOutput -Expected $plannedOutput -Label 'Repository metadata OutputDir recheck'
Assert-OutputTreeSafe -OutputTree $resolvedOutput -ProtectedPath $resolvedProject -Label 'ProjectRoot recheck'
Assert-OutputTreeSafe -OutputTree $resolvedOutput -ProtectedPath $resolvedApk -Label 'APK input recheck'
Assert-OutputTreeSafe -OutputTree $resolvedOutput -ProtectedPath $gradlePath -Label 'Build configuration input recheck'
Assert-OutputTreeSafe -OutputTree $resolvedOutput -ProtectedPath $iconPath -Label 'Icon input recheck'
$stagingOutput = Join-Path $outputParent ('.' + $outputLeaf + '.stage-' + [guid]::NewGuid().ToString('N'))
$outputBackup = Join-Path $outputParent ('.' + $outputLeaf + '.backup-' + [guid]::NewGuid().ToString('N'))
$outputBackedUp = $false
$publishCommitted = $false
$stagingCreatedByThisRun = [pscustomobject]@{ Created = $false }

try {
    $stageCreationAdapter = $null
    if ($null -ne $BeforeStageCreationHook) {
        $capturedStageCreationHook = $BeforeStageCreationHook
        $stageCreationAdapter = {
            param(
                [Parameter(Mandatory = $true)][string] $Parent,
                [Parameter(Mandatory = $true)][string] $Child,
                [Parameter(Mandatory = $true)][string] $Label
            )

            & $capturedStageCreationHook -StagingOutput $Child
        }.GetNewClosure()
    }
    $stageCreatedAdapter = {
        param(
            [Parameter(Mandatory = $true)][string] $Parent,
            [Parameter(Mandatory = $true)][string] $Child,
            [Parameter(Mandatory = $true)][string] $Label
        )

        $stagingCreatedByThisRun.Created = $true
    }.GetNewClosure()
    New-JmApiSafeDirectoryPath `
        -Path $stagingOutput `
        -ExpectedPhysicalPath $stagingOutput `
        -Label 'Repository metadata staging path' `
        -RequireNew `
        -BeforeCreateHook $stageCreationAdapter `
        -AfterCreateHook $stageCreatedAdapter | Out-Null
    if (@(Get-ChildItem -LiteralPath $stagingOutput -Force).Count -ne 0) {
        throw "New repository metadata staging tree was not empty: '$stagingOutput'."
    }
    $apkOutput = Join-Path $stagingOutput 'apk'
    $iconOutput = Join-Path $stagingOutput 'icon'
    if ((Test-Path -LiteralPath $apkOutput) -or (Test-Path -LiteralPath $iconOutput)) {
        throw 'Repository metadata staging child path appeared before creation.'
    }
    New-JmApiSafeDirectoryPath `
        -Path $apkOutput `
        -ExpectedPhysicalPath $apkOutput `
        -Label 'Repository metadata APK staging directory' `
        -RequireNew | Out-Null
    New-JmApiSafeDirectoryPath `
        -Path $iconOutput `
        -ExpectedPhysicalPath $iconOutput `
        -Label 'Repository metadata icon staging directory' `
        -RequireNew | Out-Null
    if (@(Get-ChildItem -LiteralPath $apkOutput -Force).Count -ne 0 -or
        @(Get-ChildItem -LiteralPath $iconOutput -Force).Count -ne 0
    ) {
        throw 'New repository metadata APK/icon staging directories must be empty.'
    }

    $apkDestination = Join-Path $apkOutput $apkName
    Assert-JmApiDirectChildPath `
        -Parent $apkOutput `
        -Child $apkDestination `
        -ExpectedLeaf $apkName `
        -Label 'Repository metadata APK destination'
    Assert-JmApiSafeInternalTree `
        -Path $apkOutput `
        -ExpectedPhysicalPath $apkOutput `
        -ExpectedPhysicalParent $stagingOutput `
        -Label 'Repository metadata APK staging directory recheck'
    Copy-VerifiedApkInput `
        -InputStream $apkInputStream `
        -Destination $apkDestination `
        -ExpectedSha256 $validatedApkSha256
    $iconName = "$packageName.png"
    $iconDestination = Join-Path $iconOutput $iconName
    Assert-JmApiDirectChildPath `
        -Parent $iconOutput `
        -Child $iconDestination `
        -ExpectedLeaf $iconName `
        -Label 'Repository metadata icon destination'
    Copy-Item -LiteralPath $iconPath -Destination $iconDestination
    $stagingEntries = @(Get-ChildItem -LiteralPath $stagingOutput -Force)
    if ($stagingEntries.Count -ne 2 -or
        @($stagingEntries | Where-Object { $_.Name -notin @('apk', 'icon') }).Count -ne 0 -or
        @(Get-ChildItem -LiteralPath $apkOutput -Force).Count -ne 1 -or
        @(Get-ChildItem -LiteralPath $iconOutput -Force).Count -ne 1
    ) {
        throw 'Repository metadata staging tree changed before JSON generation.'
    }
    Write-Utf8NoBom -Path (Join-Path $stagingOutput '.nojekyll') -Content ''

    $indexMinPath = Join-Path $stagingOutput 'index.min.json'
    $indexPath = Join-Path $stagingOutput 'index.json'
    $repoPath = Join-Path $stagingOutput 'repo.json'
    Write-Utf8NoBom -Path $indexMinPath -Content ($indexJson + [Environment]::NewLine)
    Write-Utf8NoBom -Path $indexPath -Content ($indexJson + [Environment]::NewLine)
    Write-Utf8NoBom -Path $repoPath -Content ($repoJson + [Environment]::NewLine)

    $roundTripIndex = @(Get-Content -LiteralPath $indexMinPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($roundTripIndex.Count -ne 1) {
        throw 'index.min.json must contain exactly one extension entry.'
    }
    $entry = $roundTripIndex[0]
    if ($entry.apk -ne $apkName -or $entry.version -ne $version -or [int]$entry.code -ne $versionCode -or
        $entry.pkg -ne $packageName -or $entry.sources[0].baseUrl -ne $baseUrl) {
        throw 'Generated index.min.json failed its metadata round-trip validation.'
    }
    $roundTripRepo = Get-Content -LiteralPath $repoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($roundTripRepo.meta.signingKeyFingerprint -ne $fingerprint) {
        throw 'Generated repo.json failed its signing fingerprint round-trip validation.'
    }

    if (Test-Path -LiteralPath $resolvedOutput -PathType Container) {
        $existingOutput = Get-JmApiPhysicalPath $resolvedOutput
        Assert-ExactPath -Actual $existingOutput -Expected $resolvedOutput -Label 'Existing repository metadata output'
        Move-ExactDirectory `
            -Source $existingOutput `
            -Destination $outputBackup `
            -Label 'Repository metadata existing-output backup'
        $outputBackedUp = $true
    }
    Move-ExactDirectory `
        -Source $stagingOutput `
        -Destination $resolvedOutput `
        -Label 'Repository metadata staged publish'
    $publishCommitted = $true

    if ($outputBackedUp) {
        Remove-ExactTree -Path $outputBackup -Expected $outputBackup -Label 'Repository metadata backup cleanup'
    }
} finally {
    if (-not $publishCommitted -and $outputBackedUp -and
        (Test-Path -LiteralPath $outputBackup) -and -not (Test-Path -LiteralPath $resolvedOutput)
    ) {
        Move-ExactDirectory `
            -Source $outputBackup `
            -Destination $resolvedOutput `
            -Label 'Repository metadata failed-publish restore'
    }
    if ($stagingCreatedByThisRun.Created) {
        Remove-ExactTree -Path $stagingOutput -Expected $stagingOutput -Label 'Repository metadata staging cleanup'
    }
}
} finally {
    try {
        $apkInputStream.Dispose()
    } finally {
        if ($processDirectoryRelocated) {
            [Environment]::CurrentDirectory = $originalProcessDirectory
        }
    }
}

Write-Host "Repository metadata generated for $apkName."
Write-Host "Signing fingerprint: $fingerprint"
Write-Host "Output directory: $resolvedOutput"
