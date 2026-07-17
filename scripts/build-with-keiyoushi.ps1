[CmdletBinding()]
param(
    [string] $KeiyoushiRoot = 'D:\jm\keiyoushi',
    [string] $SourceRoot = '',
    [string] $JavaHome = '',
    [string] $AndroidSdkRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $scriptRoot
}
. (Join-Path $scriptRoot 'path-safety.ps1')

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

function Assert-SeparateTrees {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right,
        [Parameter(Mandatory = $true)][string] $Label
    )

    Assert-JmApiSeparateTrees -Left $Left -Right $Right -Label $Label
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

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string[]] $Fallbacks = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    foreach ($candidate in $Fallbacks) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    throw "Required executable '$Name' was not found."
}

function Invoke-GradleTask {
    param(
        [Parameter(Mandatory = $true)][string] $GradleWrapper,
        [Parameter(Mandatory = $true)][string] $Task
    )

    & $GradleWrapper $Task '--stacktrace'
    if ($LASTEXITCODE -ne 0) {
        throw "Gradle task '$Task' failed with exit code $LASTEXITCODE."
    }
}

$sourceExtension = Join-Path (Get-FullPath $SourceRoot) 'src\zh\jmapi'
if (-not (Test-Path -LiteralPath $sourceExtension -PathType Container)) {
    throw "JM API extension source was not found at '$sourceExtension'."
}
$sourceExtension = Get-JmApiPhysicalPath $sourceExtension

$requestedKeiyoushiRoot = Get-FullPath $KeiyoushiRoot
$requestedKeiyoushiPhysical = Get-JmApiPhysicalPath $requestedKeiyoushiRoot
if ([string]::Equals(
        $requestedKeiyoushiRoot,
        [System.IO.Path]::GetPathRoot($requestedKeiyoushiRoot),
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or [string]::Equals(
        $requestedKeiyoushiPhysical,
        [System.IO.Path]::GetPathRoot($requestedKeiyoushiPhysical),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "KeiyoushiRoot must name a non-root directory: '$requestedKeiyoushiRoot'."
}
$requestedKeiyoushiRoot = $requestedKeiyoushiPhysical
$expectedTarget = Join-Path $requestedKeiyoushiRoot 'src\zh\jmapi'
Assert-SeparateTrees -Left $sourceExtension -Right $expectedTarget -Label 'Source and Keiyoushi extension target'

$cloneStage = $null
if (-not (Test-Path -LiteralPath $requestedKeiyoushiRoot -PathType Container)) {
    $git = Resolve-Executable -Name 'git.exe' -Fallbacks @(
        'D:\jm\.tools\mingit-2.55.0.2\cmd\git.exe'
    )
    $cloneParent = Split-Path -Parent $requestedKeiyoushiRoot
    $cloneParent = New-JmApiSafeDirectoryPath `
        -Path $cloneParent `
        -ExpectedPhysicalPath $cloneParent `
        -Label 'Keiyoushi clone parent'
    $cloneLeaf = Split-Path -Leaf $requestedKeiyoushiRoot
    $cloneStage = Join-Path $cloneParent ('.' + $cloneLeaf + '.clone-' + [guid]::NewGuid().ToString('N'))
    Assert-SeparateTrees -Left $sourceExtension -Right $cloneStage -Label 'Source and Keiyoushi clone staging tree'
    try {
        New-JmApiSafeDirectoryPath `
            -Path $cloneStage `
            -ExpectedPhysicalPath $cloneStage `
            -Label 'Keiyoushi clone staging tree' `
            -RequireNew | Out-Null
        & $git clone --depth 1 'https://github.com/keiyoushi/extensions-source.git' $cloneStage
        if ($LASTEXITCODE -ne 0) {
            throw "Cloning Keiyoushi failed with exit code $LASTEXITCODE."
        }
        if (Test-Path -LiteralPath $requestedKeiyoushiRoot) {
            throw "Keiyoushi target appeared while the staged clone was running: '$requestedKeiyoushiRoot'."
        }
        Move-ExactDirectory `
            -Source $cloneStage `
            -Destination $requestedKeiyoushiRoot `
            -Label 'Keiyoushi staged clone publish'
        $cloneStage = $null
    } finally {
        if ($null -ne $cloneStage) {
            Remove-ExactTree -Path $cloneStage -Expected $cloneStage -Label 'Keiyoushi clone staging cleanup'
        }
    }
}

$resolvedKeiyoushiRoot = Get-JmApiPhysicalPath $requestedKeiyoushiRoot
$settingsPath = Join-Path $resolvedKeiyoushiRoot 'settings.gradle.kts'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Keiyoushi settings file was not found at '$settingsPath'."
}
if (Test-JmApiReparsePoint $settingsPath) {
    throw "Keiyoushi settings file must not be a reparse point: '$settingsPath'."
}
$settingsPath = Get-JmApiPhysicalPath $settingsPath

$originalSettingsBytes = [System.IO.File]::ReadAllBytes($settingsPath)
$originalSettings = [System.IO.File]::ReadAllText($settingsPath)
$isolatedSettings = [regex]::Replace(
    $originalSettings,
    '(?m)^(?<indent>\s*)loadAllIndividualExtensions\(\)\s*$',
    '${indent}// loadAllIndividualExtensions()'
)
$isolatedSettings = [regex]::Replace(
    $isolatedSettings,
    '(?m)^(?<indent>\s*)loadIndividualExtension\([^\r\n]+\)\s*$',
    '${indent}// $0'
)
$isolatedSettings = $isolatedSettings.TrimEnd() + [Environment]::NewLine +
    'loadIndividualExtension("zh", "jmapi")' + [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($JavaHome)) {
    $javaCandidates = @(
        $env:JAVA_HOME,
        'D:\jm\.tools\temurin-17.0.19+10\jdk-17.0.19+10'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $JavaHome = $javaCandidates | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'bin\java.exe') -PathType Leaf
    } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($JavaHome) -or -not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\java.exe') -PathType Leaf)) {
    throw 'JDK 17 was not found. Pass -JavaHome or install the configured Temurin JDK.'
}
$JavaHome = Get-JmApiPhysicalPath $JavaHome

if ([string]::IsNullOrWhiteSpace($AndroidSdkRoot)) {
    $sdkCandidates = @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        'D:\jm\.tools\android-sdk'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $AndroidSdkRoot = $sdkCandidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Container
    } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($AndroidSdkRoot) -or -not (Test-Path -LiteralPath $AndroidSdkRoot -PathType Container)) {
    throw 'Android SDK was not found. Pass -AndroidSdkRoot or set ANDROID_HOME.'
}
$AndroidSdkRoot = Get-JmApiPhysicalPath $AndroidSdkRoot

$gradleWrapper = Join-Path $resolvedKeiyoushiRoot 'gradlew.bat'
if (-not (Test-Path -LiteralPath $gradleWrapper -PathType Leaf)) {
    throw "Gradle wrapper was not found at '$gradleWrapper'."
}

$expectedSourceParent = Get-FullPath (Join-Path $resolvedKeiyoushiRoot 'src')
$expectedTargetParent = Get-FullPath (Join-Path $expectedSourceParent 'zh')
$plannedTargetParent = Get-JmApiPhysicalPath $expectedTargetParent
Assert-JmApiPhysicalPathEquals `
    -Actual $plannedTargetParent `
    -Expected $expectedTargetParent `
    -Label 'Planned Keiyoushi target parent'
$sourceParentExisted = Test-Path -LiteralPath $expectedSourceParent -PathType Container
$targetParentExisted = Test-Path -LiteralPath $expectedTargetParent -PathType Container
try {
    if (-not $targetParentExisted) {
        New-JmApiSafeDirectoryPath `
            -Path $expectedTargetParent `
            -ExpectedPhysicalPath $expectedTargetParent `
            -Label 'Keiyoushi target parent' | Out-Null
    }
    $targetParent = Get-JmApiPhysicalPath $expectedTargetParent
    Assert-JmApiPhysicalPathEquals `
        -Actual $targetParent `
        -Expected $expectedTargetParent `
        -Label 'Created Keiyoushi target parent'
} catch {
    $targetParentFailure = $_
    if (-not $targetParentExisted -and (Test-Path -LiteralPath $expectedTargetParent -PathType Container)) {
        Remove-JmApiSafeTree `
            -Path $expectedTargetParent `
            -ExpectedPhysicalPath $expectedTargetParent `
            -ExpectedPhysicalParent $expectedSourceParent `
            -Label 'Failed Keiyoushi target-parent creation cleanup'
    }
    if (-not $sourceParentExisted -and (Test-Path -LiteralPath $expectedSourceParent -PathType Container) -and
        @(Get-ChildItem -LiteralPath $expectedSourceParent -Force).Count -eq 0
    ) {
        Remove-JmApiSafeTree `
            -Path $expectedSourceParent `
            -ExpectedPhysicalPath $expectedSourceParent `
            -ExpectedPhysicalParent $resolvedKeiyoushiRoot `
            -Label 'Failed Keiyoushi source-parent creation cleanup'
    }
    throw $targetParentFailure
}
$targetExtension = Join-Path $targetParent 'jmapi'
$expectedTarget = Join-Path $resolvedKeiyoushiRoot 'src\zh\jmapi'
Assert-ExactPath -Actual $targetExtension -Expected $expectedTarget -Label 'Keiyoushi extension target'
Assert-SeparateTrees -Left $sourceExtension -Right $expectedTarget -Label 'Source and Keiyoushi extension target'

$targetStage = Join-Path $targetParent ('.jmapi-stage-' + [guid]::NewGuid().ToString('N'))
$targetBackup = Join-Path $targetParent ('.jmapi-backup-' + [guid]::NewGuid().ToString('N'))
$targetInstalled = $false
$targetHadOriginal = $false
$buildSucceeded = $false
$resolvedTargetAfterCopy = $null
$apk = $null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$oldJavaHome = $env:JAVA_HOME
$oldAndroidHome = $env:ANDROID_HOME
$oldAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$oldPath = $env:PATH

try {
    New-JmApiSafeDirectoryPath `
        -Path $targetStage `
        -ExpectedPhysicalPath $targetStage `
        -Label 'Keiyoushi extension copy staging tree' `
        -RequireNew | Out-Null
    foreach ($sourceChild in @(Get-ChildItem -LiteralPath $sourceExtension -Force)) {
        Copy-Item -LiteralPath $sourceChild.FullName -Destination $targetStage -Recurse -Force
    }
    $resolvedTargetStage = Get-JmApiPhysicalPath $targetStage
    Assert-ExactPath -Actual $resolvedTargetStage -Expected $targetStage -Label 'Staged Keiyoushi extension target'
    Assert-JmApiSafeInternalTree `
        -Path $resolvedTargetStage `
        -ExpectedPhysicalPath $targetStage `
        -ExpectedPhysicalParent $targetParent `
        -Label 'Staged Keiyoushi extension target'
    $stagedBuildDirectory = Join-Path $resolvedTargetStage 'build'
    Remove-ExactTree -Path $stagedBuildDirectory -Expected $stagedBuildDirectory -Label 'Staged extension build output cleanup'

    if (Test-Path -LiteralPath $targetExtension) {
        $resolvedTarget = Get-JmApiPhysicalPath $targetExtension
        Assert-ExactPath -Actual $resolvedTarget -Expected $expectedTarget -Label 'Existing Keiyoushi extension target'
        Move-ExactDirectory `
            -Source $resolvedTarget `
            -Destination $targetBackup `
            -Label 'Existing Keiyoushi extension backup'
        $targetHadOriginal = $true
    }
    Move-ExactDirectory `
        -Source $targetStage `
        -Destination $targetExtension `
        -Label 'Staged Keiyoushi extension install'
    $targetInstalled = $true
    $resolvedTargetAfterCopy = Get-JmApiPhysicalPath $targetExtension
    Assert-ExactPath -Actual $resolvedTargetAfterCopy -Expected $expectedTarget -Label 'Copied Keiyoushi extension target'

    try {
        [System.IO.File]::WriteAllText($settingsPath, $isolatedSettings, $utf8NoBom)
        $env:JAVA_HOME = $JavaHome
        $env:ANDROID_HOME = $AndroidSdkRoot
        $env:ANDROID_SDK_ROOT = $AndroidSdkRoot
        $env:PATH = (Join-Path $JavaHome 'bin') + [System.IO.Path]::PathSeparator + $oldPath

        Push-Location $resolvedKeiyoushiRoot
        try {
            Invoke-GradleTask -GradleWrapper $gradleWrapper -Task ':src:zh:jmapi:spotlessApply'
            Invoke-GradleTask -GradleWrapper $gradleWrapper -Task ':src:zh:jmapi:assembleRelease'
        } finally {
            Pop-Location
        }
    } finally {
        try {
            [System.IO.File]::WriteAllBytes($settingsPath, $originalSettingsBytes)
        } finally {
            $env:JAVA_HOME = $oldJavaHome
            $env:ANDROID_HOME = $oldAndroidHome
            $env:ANDROID_SDK_ROOT = $oldAndroidSdkRoot
            $env:PATH = $oldPath
        }
    }

    $releaseDirectory = Join-Path $resolvedTargetAfterCopy 'build\outputs\apk\release'
    $releaseApks = @(Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.apk' -File -ErrorAction SilentlyContinue)
    if ($releaseApks.Count -ne 1) {
        throw "assembleRelease must produce exactly one APK under '$releaseDirectory'; found $($releaseApks.Count)."
    }
    $apk = $releaseApks[0]
    if ($apk.Length -le 0) {
        throw "assembleRelease produced an empty APK: '$($apk.FullName)'."
    }
    $buildSucceeded = $true
} finally {
    if (-not $buildSucceeded) {
        if ($targetInstalled) {
            Remove-ExactTree -Path $targetExtension -Expected $expectedTarget -Label 'Failed Keiyoushi extension cleanup'
        }
        if ($targetHadOriginal -and (Test-Path -LiteralPath $targetBackup) -and -not (Test-Path -LiteralPath $targetExtension)) {
            Move-ExactDirectory `
                -Source $targetBackup `
                -Destination $targetExtension `
                -Label 'Failed Keiyoushi extension restore'
        }
    } elseif ($targetHadOriginal) {
        Remove-ExactTree -Path $targetBackup -Expected $targetBackup -Label 'Keiyoushi extension backup cleanup'
    }
    Remove-ExactTree -Path $targetStage -Expected $targetStage -Label 'Keiyoushi extension staging cleanup'
}

Write-Host "Keiyoushi build passed: $($apk.FullName)"
$apk.FullName
