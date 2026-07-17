[CmdletBinding()]
param(
    [ValidateSet(
        'All',
        'BuildJunction',
        'IntermediateParentJunction',
        'IntermediateParentSwapRace',
        'MetadataJunction',
        'MetadataParentSwapRace',
        'MetadataCurrentDirectory',
        'MetadataExternalParentLock',
        'ExpectedPathMismatch',
        'SettingsBomSuccess',
        'SettingsBomFailure',
        'UnsafeVersion',
        'MovePostCheckRollback',
        'MoveDestinationRace',
        'MoveSourceIdentityRace',
        'MovePostIdentityRace',
        'MovePostHandleOpenFailure',
        'RemoveTraversalRace',
        'ManifestMismatch',
        'MetadataStageCollision',
        'ApkInputSwap',
        'ManifestBinding',
        'TrailingDotHost',
        'VersionReferences'
    )]
    [string] $Case = 'All'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$buildScript = Join-Path $root 'scripts\build-with-keiyoushi.ps1'
$metadataScript = Join-Path $root 'scripts\generate-repo-metadata.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-BytesEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Expected,
        [Parameter(Mandatory = $true)][byte[]] $Actual,
        [Parameter(Mandatory = $true)][string] $Label
    )

    if ($Expected.Length -ne $Actual.Length) {
        throw "$Label byte length changed from $($Expected.Length) to $($Actual.Length)."
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            throw "$Label byte $index changed from $($Expected[$index]) to $($Actual[$index])."
        }
    }
}

function Write-Bytes {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-UniqueFixtureRoot {
    param([Parameter(Mandatory = $true)][string] $Label)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) (
        'jmapi-extension-safety-' + $Label + '-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $path | Out-Null
    return (Resolve-Path -LiteralPath $path).ProviderPath
}

function Remove-UniqueFixtureRoot {
    param(
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [string[]] $KnownJunctions = @()
    )

    foreach ($junction in $KnownJunctions) {
        if (Test-Path -LiteralPath $junction) {
            $item = Get-Item -LiteralPath $junction -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw "Fixture cleanup expected a reparse point at '$junction'."
            }
            [System.IO.Directory]::Delete($junction, $false)
        }
    }

    if (-not (Test-Path -LiteralPath $FixtureRoot)) {
        return
    }
    $fullFixture = [System.IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\', '/')
    $fullTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if (-not $fullFixture.StartsWith(
        $fullTemp + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or (Split-Path -Leaf $fullFixture) -notlike 'jmapi-extension-safety-*') {
        throw "Refusing to clean an unexpected fixture path '$fullFixture'."
    }
    Remove-Item -LiteralPath $fullFixture -Recurse -Force
}

function New-FakeBuildPrerequisites {
    param(
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string] $KeiyoushiRoot,
        [Parameter(Mandatory = $true)][string] $GradleBody
    )

    $javaHome = Join-Path $FixtureRoot 'jdk'
    $sdkRoot = Join-Path $FixtureRoot 'sdk'
    New-Item -ItemType Directory -Path (Join-Path $javaHome 'bin') -Force | Out-Null
    New-Item -ItemType Directory -Path $sdkRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $javaHome 'bin\java.exe'), 'fixture')
    [System.IO.File]::WriteAllText((Join-Path $KeiyoushiRoot 'gradlew.bat'), $GradleBody)
    return [pscustomobject]@{
        JavaHome = $javaHome
        AndroidSdkRoot = $sdkRoot
    }
}

function New-FakeApkSigner {
    param(
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string] $InvocationMarker
    )

    $bin = Join-Path $FixtureRoot 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $signer = Join-Path $bin 'apksigner.bat'
    $body = @"
@echo off
> "$InvocationMarker" echo invoked
echo Signer #1 certificate SHA-256 digest: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
exit /b 0
"@
    [System.IO.File]::WriteAllText($signer, $body, [System.Text.Encoding]::ASCII)
    return $bin
}

function New-FakeMetadataTools {
    param(
        [Parameter(Mandatory = $true)][string] $FixtureRoot,
        [Parameter(Mandatory = $true)][string] $SignerMarker,
        [Parameter(Mandatory = $true)][string] $Aapt2Marker
    )

    $bin = Join-Path $FixtureRoot 'metadata-bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $signer = Join-Path $bin 'apksigner.bat'
    $signerBody = @"
@echo off
> "$SignerMarker" echo invoked
echo Signer #1 certificate SHA-256 digest: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
exit /b 0
"@
    [System.IO.File]::WriteAllText($signer, $signerBody, [System.Text.Encoding]::ASCII)

    $aapt2 = Join-Path $bin 'aapt2.bat'
    $aapt2Body = @"
@echo off
> "$Aapt2Marker" echo invoked
echo package: name='eu.kanade.tachiyomi.extension.zh.jmapi' versionCode='13' versionName='1.4.13'
exit /b 0
"@
    [System.IO.File]::WriteAllText($aapt2, $aapt2Body, [System.Text.Encoding]::ASCII)
    return $bin
}

function Initialize-FakeMetadataProject {
    param([Parameter(Mandatory = $true)][string] $ProjectRoot)

    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi') -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $ProjectRoot 'src\zh\jmapi\build.gradle.kts'),
        "versionCode = 13`r`nlibVersion = `"1.4`"`r`nbaseUrl = `"http://127.0.0.1:8088`"`r`n"
    )
    Write-Bytes `
        -Path (Join-Path $ProjectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi\ic_launcher.png') `
        -Bytes ([byte[]](137, 80, 78, 71))
}

function Invoke-MetadataCurrentDirectoryCase {
    $fixture = New-UniqueFixtureRoot 'metadata-current-directory'
    $projectRoot = Join-Path $fixture 'project'
    $outputDir = Join-Path $projectRoot 'dist-local'
    $apkPath = Join-Path $fixture 'input.apk'
    $signerMarker = Join-Path $fixture 'signer-called.txt'
    $aapt2Marker = Join-Path $fixture 'aapt2-called.txt'
    $oldPath = $env:PATH
    $oldProcessDirectory = [Environment]::CurrentDirectory
    try {
        Initialize-FakeMetadataProject -ProjectRoot $projectRoot
        Write-Bytes -Path $apkPath -Bytes ([byte[]](80, 75, 3, 4, 10, 20, 30, 40))
        $toolsBin = New-FakeMetadataTools `
            -FixtureRoot $fixture `
            -SignerMarker $signerMarker `
            -Aapt2Marker $aapt2Marker
        $env:PATH = $toolsBin + [System.IO.Path]::PathSeparator + (Join-Path $env:SystemRoot 'System32')
        [Environment]::CurrentDirectory = $projectRoot

        & $metadataScript `
            -ApkPath $apkPath `
            -OutputDir $outputDir `
            -ProjectRoot $projectRoot | Out-Null

        Assert-True `
            -Condition ([string]::Equals(
                [Environment]::CurrentDirectory,
                $projectRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            )) `
            -Message 'Metadata helper did not restore the caller process current directory.'
        $publishedApk = Join-Path $outputDir 'apk\tachiyomi-zh.jmapi-v1.4.13.apk'
        Assert-True -Condition (Test-Path -LiteralPath $publishedApk -PathType Leaf) -Message 'Metadata helper did not publish from the project-root process directory.'
    } finally {
        [Environment]::CurrentDirectory = $oldProcessDirectory
        $env:PATH = $oldPath
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-MetadataExternalParentLockCase {
    $fixture = New-UniqueFixtureRoot 'metadata-external-parent-lock'
    $projectRoot = Join-Path $fixture 'project'
    $outputDir = Join-Path $projectRoot 'dist-local'
    $apkPath = Join-Path $fixture 'input.apk'
    $signerMarker = Join-Path $fixture 'signer-called.txt'
    $aapt2Marker = Join-Path $fixture 'aapt2-called.txt'
    $oldPath = $env:PATH
    $oldProcessDirectory = [Environment]::CurrentDirectory
    try {
        Initialize-FakeMetadataProject -ProjectRoot $projectRoot
        Write-Bytes -Path $apkPath -Bytes ([byte[]](80, 75, 3, 4, 10, 20, 30, 40))
        $toolsBin = New-FakeMetadataTools `
            -FixtureRoot $fixture `
            -SignerMarker $signerMarker `
            -Aapt2Marker $aapt2Marker
        $env:PATH = $toolsBin + [System.IO.Path]::PathSeparator + (Join-Path $env:SystemRoot 'System32')
        [Environment]::CurrentDirectory = $projectRoot
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $rejected = $false
        $errorText = ''
        try {
            $childOutput = & $powershellExe `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -File $metadataScript `
                -ApkPath $apkPath `
                -OutputDir $outputDir `
                -ProjectRoot $projectRoot 2>&1
            if ($LASTEXITCODE -ne 0) {
                $rejected = $true
                $errorText = $childOutput -join [Environment]::NewLine
            }
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $rejected -Message 'Metadata helper ignored an externally locked output parent.'
        Assert-True `
            -Condition ($errorText -match '(?i)OpenPathEntryWithoutDeleteSharing|New-JmApiSafeDirectoryPath|stable path entry|sharing violation|being used by another process') `
            -Message "External parent-lock rejection was not explicit: '$errorText'."
        Assert-True -Condition (-not (Test-Path -LiteralPath $outputDir)) -Message 'Metadata helper changed OutputDir after external parent-lock rejection.'
    } finally {
        [Environment]::CurrentDirectory = $oldProcessDirectory
        $env:PATH = $oldPath
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Assert-NoBuildTransactionResidue {
    param([Parameter(Mandatory = $true)][string] $TargetParent)

    $residue = @(Get-ChildItem -LiteralPath $TargetParent -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '.jmapi-stage-*' -or $_.Name -like '.jmapi-backup-*'
    })
    if ($residue.Count -ne 0) {
        throw "Build transaction residue remained: $($residue.FullName -join ', ')."
    }
}

function Invoke-BuildJunctionCase {
    $fixture = New-UniqueFixtureRoot 'build-junction'
    $physicalRoot = Join-Path $fixture 'physical-root'
    $keiyoushiAlias = Join-Path $fixture 'keiyoushi-alias'
    $sourceExtension = Join-Path $physicalRoot 'src\zh\jmapi'
    $sourceMarker = Join-Path $sourceExtension 'source-marker.bin'
    $settingsPath = Join-Path $physicalRoot 'settings.gradle.kts'
    $gradleCalled = Join-Path $fixture 'gradle-called.txt'
    try {
        New-Item -ItemType Directory -Path $sourceExtension -Force | Out-Null
        $markerBytes = [byte[]](0, 1, 2, 3, 254, 255)
        Write-Bytes -Path $sourceMarker -Bytes $markerBytes
        [System.IO.File]::WriteAllText($settingsPath, "loadAllIndividualExtensions()`r`n")
        New-Item -ItemType Junction -Path $keiyoushiAlias -Target $physicalRoot | Out-Null

        $gradleBody = "@echo off`r`n> `"$gradleCalled`" echo called`r`nexit /b 9`r`n"
        $prerequisites = New-FakeBuildPrerequisites `
            -FixtureRoot $fixture `
            -KeiyoushiRoot $physicalRoot `
            -GradleBody $gradleBody
        $settingsBytes = [System.IO.File]::ReadAllBytes($settingsPath)

        $rejected = $false
        $errorText = ''
        try {
            & $buildScript `
                -KeiyoushiRoot $keiyoushiAlias `
                -SourceRoot $physicalRoot `
                -JavaHome $prerequisites.JavaHome `
                -AndroidSdkRoot $prerequisites.AndroidSdkRoot | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $rejected -Message 'Build helper accepted a KeiyoushiRoot junction that resolves to SourceRoot.'
        Assert-True `
            -Condition ([regex]::IsMatch($errorText, '(?i)physical|non-overlapping')) `
            -Message "Build junction rejection did not identify physical overlap: '$errorText'."
        Assert-True `
            -Condition (-not (Test-Path -LiteralPath $gradleCalled)) `
            -Message 'Build helper reached Gradle instead of rejecting the physical overlap before its transaction.'
        Assert-True -Condition (Test-Path -LiteralPath $sourceMarker -PathType Leaf) -Message 'Build junction rejection removed the source marker.'
        Assert-BytesEqual -Expected $markerBytes -Actual ([System.IO.File]::ReadAllBytes($sourceMarker)) -Label 'Build source marker'
        Assert-BytesEqual -Expected $settingsBytes -Actual ([System.IO.File]::ReadAllBytes($settingsPath)) -Label 'Build settings input'
        Assert-NoBuildTransactionResidue -TargetParent (Join-Path $physicalRoot 'src\zh')
    } finally {
        Remove-UniqueFixtureRoot -FixtureRoot $fixture -KnownJunctions @($keiyoushiAlias)
    }
}

function Invoke-IntermediateParentJunctionCase {
    $fixture = New-UniqueFixtureRoot 'intermediate-parent-junction'
    $sourceRoot = Join-Path $fixture 'source'
    $sourceExtension = Join-Path $sourceRoot 'src\zh\jmapi'
    $keiyoushiRoot = Join-Path $fixture 'keiyoushi'
    $srcJunction = Join-Path $keiyoushiRoot 'src'
    $victimRoot = Join-Path $fixture 'victim'
    $victimMarker = Join-Path $victimRoot 'victim-marker.bin'
    $settingsPath = Join-Path $keiyoushiRoot 'settings.gradle.kts'
    $gradleCalled = Join-Path $fixture 'gradle-called.txt'
    try {
        New-Item -ItemType Directory -Path $sourceExtension -Force | Out-Null
        New-Item -ItemType Directory -Path $keiyoushiRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $victimRoot -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sourceExtension 'source.txt'), 'source')
        $victimBytes = [byte[]](51, 52, 53, 54)
        Write-Bytes -Path $victimMarker -Bytes $victimBytes
        [System.IO.File]::WriteAllText($settingsPath, "loadAllIndividualExtensions()`r`n")
        New-Item -ItemType Junction -Path $srcJunction -Target $victimRoot | Out-Null
        $gradleBody = "@echo off`r`n> `"$gradleCalled`" echo called`r`nexit /b 9`r`n"
        $prerequisites = New-FakeBuildPrerequisites `
            -FixtureRoot $fixture `
            -KeiyoushiRoot $keiyoushiRoot `
            -GradleBody $gradleBody
        $settingsBytes = [System.IO.File]::ReadAllBytes($settingsPath)

        $rejected = $false
        $errorText = ''
        try {
            & $buildScript `
                -KeiyoushiRoot $keiyoushiRoot `
                -SourceRoot $sourceRoot `
                -JavaHome $prerequisites.JavaHome `
                -AndroidSdkRoot $prerequisites.AndroidSdkRoot | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $rejected -Message 'Build helper accepted a src junction outside KeiyoushiRoot.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $victimRoot 'zh'))) -Message 'Build helper created targetParent through an intermediate junction before rejecting it.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $gradleCalled)) -Message 'Intermediate-parent junction reached Gradle instead of being rejected before writes.'
        Assert-BytesEqual -Expected $victimBytes -Actual ([System.IO.File]::ReadAllBytes($victimMarker)) -Label 'Intermediate-parent victim marker'
        Assert-BytesEqual -Expected $settingsBytes -Actual ([System.IO.File]::ReadAllBytes($settingsPath)) -Label 'Intermediate-parent settings input'
        Assert-True `
            -Condition ($errorText -match '(?i)physical|outside.*Keiyoushi') `
            -Message "Intermediate-parent rejection did not identify the physical boundary: '$errorText'."
    } finally {
        Remove-UniqueFixtureRoot -FixtureRoot $fixture -KnownJunctions @($srcJunction)
    }
}

function Invoke-IntermediateParentSwapRaceCase {
    $fixture = New-UniqueFixtureRoot 'intermediate-parent-swap-race'
    $sourceRoot = Join-Path $fixture 'source'
    $sourceExtension = Join-Path $sourceRoot 'src\zh\jmapi'
    $keiyoushiRoot = Join-Path $fixture 'keiyoushi'
    $sourceParent = Join-Path $keiyoushiRoot 'src'
    $targetParent = Join-Path $sourceParent 'zh'
    $stolenSourceParent = Join-Path $fixture 'stolen-src'
    $victimRoot = Join-Path $fixture 'victim'
    $victimMarker = Join-Path $victimRoot 'victim-marker.bin'
    $settingsPath = Join-Path $keiyoushiRoot 'settings.gradle.kts'
    $state = [pscustomobject]@{ Attempted = $false; Blocked = $false }
    $originalNewItemFunction = $null
    try {
        New-Item -ItemType Directory -Path $sourceExtension -Force | Out-Null
        New-Item -ItemType Directory -Path $keiyoushiRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $victimRoot -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sourceExtension 'source.txt'), 'source')
        $victimBytes = [byte[]](151, 152, 153, 154)
        Write-Bytes -Path $victimMarker -Bytes $victimBytes
        [System.IO.File]::WriteAllText($settingsPath, "loadAllIndividualExtensions()`r`n")
        $prerequisites = New-FakeBuildPrerequisites `
            -FixtureRoot $fixture `
            -KeiyoushiRoot $keiyoushiRoot `
            -GradleBody "@echo off`r`nexit /b 9`r`n"
        $settingsBytes = [System.IO.File]::ReadAllBytes($settingsPath)

        $existingFunction = Get-Item -LiteralPath 'Function:\New-Item' -ErrorAction SilentlyContinue
        if ($null -ne $existingFunction) {
            $originalNewItemFunction = $existingFunction.ScriptBlock
        }
        $injectedNewItem = {
            [CmdletBinding()]
            param(
                [Parameter(Position = 0)][string[]] $Path,
                [string] $ItemType,
                [object] $Value,
                [switch] $Force
            )

            if (-not $state.Attempted -and $Path.Count -eq 1 -and
                [string]::Equals($Path[0], $targetParent, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $state.Attempted = $true
                if (-not (Test-Path -LiteralPath $sourceParent -PathType Container)) {
                    Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $sourceParent | Out-Null
                }
                try {
                    [System.IO.Directory]::Move($sourceParent, $stolenSourceParent)
                    Microsoft.PowerShell.Management\New-Item -ItemType Junction -Path $sourceParent -Target $victimRoot | Out-Null
                } catch {
                    $state.Blocked = $true
                    throw
                }
            }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }.GetNewClosure()
        Set-Item -LiteralPath 'Function:\New-Item' -Value $injectedNewItem

        $rejected = $false
        $errorText = ''
        try {
            & $buildScript `
                -KeiyoushiRoot $keiyoushiRoot `
                -SourceRoot $sourceRoot `
                -JavaHome $prerequisites.JavaHome `
                -AndroidSdkRoot $prerequisites.AndroidSdkRoot | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $state.Attempted -Message "Intermediate-parent swap fault injection did not run: '$errorText'."
        Assert-True -Condition $rejected -Message 'Build helper returned success after an intermediate parent swap.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $victimRoot 'zh'))) -Message 'Build helper created src/zh through a swapped parent into the victim tree.'
        Assert-True -Condition $state.Blocked -Message 'Build helper did not hold the intermediate parent without delete sharing.'
        Assert-BytesEqual -Expected $victimBytes -Actual ([System.IO.File]::ReadAllBytes($victimMarker)) -Label 'Intermediate-parent swap victim marker'
        Assert-BytesEqual -Expected $settingsBytes -Actual ([System.IO.File]::ReadAllBytes($settingsPath)) -Label 'Intermediate-parent swap settings input'
    } finally {
        if ($null -ne $originalNewItemFunction) {
            Set-Item -LiteralPath 'Function:\New-Item' -Value $originalNewItemFunction
        } elseif (Test-Path -LiteralPath 'Function:\New-Item') {
            Remove-Item -LiteralPath 'Function:\New-Item'
        }
        $knownJunctions = @()
        if ((Test-Path -LiteralPath $sourceParent) -and
            ((Get-Item -LiteralPath $sourceParent -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            $knownJunctions = @($sourceParent)
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture -KnownJunctions $knownJunctions
    }
}

function Invoke-MetadataJunctionCase {
    $fixture = New-UniqueFixtureRoot 'metadata-junction'
    $physicalParent = Join-Path $fixture 'physical-parent'
    $projectRoot = Join-Path $physicalParent 'project'
    $parentAlias = Join-Path $fixture 'parent-alias'
    $outputAlias = Join-Path $parentAlias 'project'
    $projectMarker = Join-Path $projectRoot 'project-marker.bin'
    $apkPath = Join-Path $fixture 'input.apk'
    $signerMarker = Join-Path $fixture 'signer-called.txt'
    $oldPath = $env:PATH
    try {
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi') -Force | Out-Null
        $markerBytes = [byte[]](9, 8, 7, 6, 5)
        Write-Bytes -Path $projectMarker -Bytes $markerBytes
        $gradlePath = Join-Path $projectRoot 'src\zh\jmapi\build.gradle.kts'
        $gradleText = "versionCode = 13`r`nlibVersion = `"1.4`"`r`nbaseUrl = `"http://127.0.0.1:8088`"`r`n"
        [System.IO.File]::WriteAllText($gradlePath, $gradleText)
        $gradleBytes = [System.IO.File]::ReadAllBytes($gradlePath)
        $iconPath = Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi\ic_launcher.png'
        $iconBytes = [byte[]](137, 80, 78, 71)
        Write-Bytes `
            -Path $iconPath `
            -Bytes $iconBytes
        Write-Bytes -Path $apkPath -Bytes ([byte[]](80, 75, 3, 4))
        New-Item -ItemType Junction -Path $parentAlias -Target $physicalParent | Out-Null
        $signerBin = New-FakeApkSigner -FixtureRoot $fixture -InvocationMarker $signerMarker
        $env:PATH = $signerBin + [System.IO.Path]::PathSeparator + $oldPath

        $rejected = $false
        $errorText = ''
        try {
            & $metadataScript -ApkPath $apkPath -OutputDir $outputAlias -ProjectRoot $projectRoot | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $rejected -Message 'Metadata helper accepted an OutputDir alias that physically equals ProjectRoot.'
        Assert-True `
            -Condition ([regex]::IsMatch($errorText, '(?i)physical|ProjectRoot|inside repository OutputDir')) `
            -Message "Metadata junction rejection did not identify the protected physical tree: '$errorText'."
        Assert-True -Condition (-not (Test-Path -LiteralPath $signerMarker)) -Message 'Metadata junction reached apksigner instead of rejecting the physical alias before publication work.'
        Assert-True -Condition (Test-Path -LiteralPath $projectMarker -PathType Leaf) -Message 'Metadata junction handling removed ProjectRoot before rejecting it.'
        Assert-BytesEqual -Expected $markerBytes -Actual ([System.IO.File]::ReadAllBytes($projectMarker)) -Label 'Metadata ProjectRoot marker'
        Assert-BytesEqual -Expected $gradleBytes -Actual ([System.IO.File]::ReadAllBytes($gradlePath)) -Label 'Metadata build configuration input'
        Assert-BytesEqual -Expected $iconBytes -Actual ([System.IO.File]::ReadAllBytes($iconPath)) -Label 'Metadata icon input'
        Assert-BytesEqual -Expected ([byte[]](80, 75, 3, 4)) -Actual ([System.IO.File]::ReadAllBytes($apkPath)) -Label 'Metadata APK input'
    } finally {
        $env:PATH = $oldPath
        Remove-UniqueFixtureRoot -FixtureRoot $fixture -KnownJunctions @($parentAlias)
    }
}

function Invoke-MetadataParentSwapRaceCase {
    $fixture = New-UniqueFixtureRoot 'metadata-parent-swap-race'
    $projectRoot = Join-Path $fixture 'project'
    $outputBase = Join-Path $fixture 'publish-parent'
    $outputParent = Join-Path $outputBase 'nested'
    $outputDir = Join-Path $outputParent 'repo'
    $stolenOutputBase = Join-Path $fixture 'stolen-publish-parent'
    $victimRoot = Join-Path $fixture 'victim'
    $victimMarker = Join-Path $victimRoot 'victim-marker.bin'
    $apkPath = Join-Path $fixture 'input.apk'
    $signerMarker = Join-Path $fixture 'signer-called.txt'
    $aapt2Marker = Join-Path $fixture 'aapt2-called.txt'
    $state = [pscustomobject]@{ Attempted = $false; Blocked = $false }
    $originalNewItemFunction = $null
    $oldPath = $env:PATH
    try {
        Initialize-FakeMetadataProject -ProjectRoot $projectRoot
        New-Item -ItemType Directory -Path $victimRoot | Out-Null
        $victimBytes = [byte[]](161, 162, 163, 164)
        Write-Bytes -Path $victimMarker -Bytes $victimBytes
        Write-Bytes -Path $apkPath -Bytes ([byte[]](80, 75, 3, 4, 50, 60))
        $toolsBin = New-FakeMetadataTools `
            -FixtureRoot $fixture `
            -SignerMarker $signerMarker `
            -Aapt2Marker $aapt2Marker
        $env:PATH = $toolsBin + [System.IO.Path]::PathSeparator + (Join-Path $env:SystemRoot 'System32')

        $existingFunction = Get-Item -LiteralPath 'Function:\New-Item' -ErrorAction SilentlyContinue
        if ($null -ne $existingFunction) {
            $originalNewItemFunction = $existingFunction.ScriptBlock
        }
        $injectedNewItem = {
            [CmdletBinding()]
            param(
                [Parameter(Position = 0)][string[]] $Path,
                [string] $ItemType,
                [object] $Value,
                [switch] $Force
            )

            if (-not $state.Attempted -and $Path.Count -eq 1 -and
                [string]::Equals($Path[0], $outputParent, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $state.Attempted = $true
                if (-not (Test-Path -LiteralPath $outputBase -PathType Container)) {
                    Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $outputBase | Out-Null
                }
                try {
                    [System.IO.Directory]::Move($outputBase, $stolenOutputBase)
                    Microsoft.PowerShell.Management\New-Item -ItemType Junction -Path $outputBase -Target $victimRoot | Out-Null
                } catch {
                    $state.Blocked = $true
                    throw
                }
            }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }.GetNewClosure()
        Set-Item -LiteralPath 'Function:\New-Item' -Value $injectedNewItem

        $rejected = $false
        $errorText = ''
        try {
            & $metadataScript -ApkPath $apkPath -OutputDir $outputDir -ProjectRoot $projectRoot | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $state.Attempted -Message "Metadata-parent swap fault injection did not run: '$errorText'."
        Assert-True -Condition $rejected -Message 'Metadata helper returned success after an output-parent swap.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $victimRoot 'nested'))) -Message 'Metadata helper created outputParent through a swapped parent into the victim tree.'
        Assert-True -Condition $state.Blocked -Message 'Metadata helper did not hold the output parent without delete sharing.'
        Assert-BytesEqual -Expected $victimBytes -Actual ([System.IO.File]::ReadAllBytes($victimMarker)) -Label 'Metadata-parent swap victim marker'
        Assert-True -Condition (-not (Test-Path -LiteralPath $outputDir)) -Message 'Metadata-parent swap published repository output.'
    } finally {
        $env:PATH = $oldPath
        if ($null -ne $originalNewItemFunction) {
            Set-Item -LiteralPath 'Function:\New-Item' -Value $originalNewItemFunction
        } elseif (Test-Path -LiteralPath 'Function:\New-Item') {
            Remove-Item -LiteralPath 'Function:\New-Item'
        }
        $knownJunctions = @()
        if ((Test-Path -LiteralPath $outputBase) -and
            ((Get-Item -LiteralPath $outputBase -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            $knownJunctions = @($outputBase)
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture -KnownJunctions $knownJunctions
    }
}

function Invoke-ExpectedPathMismatchCase {
    $fixture = New-UniqueFixtureRoot 'expected-path-mismatch'
    $evilPath = Join-Path $fixture 'evil'
    $victimPath = Join-Path $fixture 'victim'
    $pathSafetyScript = Join-Path $root 'scripts\path-safety.ps1'
    try {
        . $pathSafetyScript
        $rejected = $false
        $errorText = ''
        try {
            New-JmApiSafeDirectoryPath `
                -Path $evilPath `
                -ExpectedPhysicalPath $victimPath `
                -Label 'Injected expected-path mismatch' | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $rejected -Message 'Safe directory creation accepted different missing Path and ExpectedPhysicalPath values.'
        Assert-True `
            -Condition ($errorText -match '(?i)physical|expected|outside') `
            -Message "Expected-path mismatch rejection was not explicit: '$errorText'."
        Assert-True -Condition (-not (Test-Path -LiteralPath $evilPath)) -Message 'Expected-path mismatch created the unverified evil directory.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $victimPath)) -Message 'Expected-path mismatch created the victim directory.'
    } finally {
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-SettingsBomCase {
    param([Parameter(Mandatory = $true)][bool] $GradleSucceeds)

    $label = if ($GradleSucceeds) { 'settings-bom-success' } else { 'settings-bom-failure' }
    $fixture = New-UniqueFixtureRoot $label
    $sourceRoot = Join-Path $fixture 'source'
    $keiyoushiRoot = Join-Path $fixture 'keiyoushi'
    $sourceExtension = Join-Path $sourceRoot 'src\zh\jmapi'
    $targetParent = Join-Path $keiyoushiRoot 'src\zh'
    $settingsPath = Join-Path $keiyoushiRoot 'settings.gradle.kts'
    $oldTargetMarker = Join-Path $targetParent 'jmapi\old-target.bin'

    $callerJavaHome = $env:JAVA_HOME
    $callerAndroidHome = $env:ANDROID_HOME
    $callerAndroidSdkRoot = $env:ANDROID_SDK_ROOT
    $callerPath = $env:PATH
    try {
        New-Item -ItemType Directory -Path $sourceExtension -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldTargetMarker) -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sourceExtension 'source.txt'), 'new source')
        Write-Bytes -Path $oldTargetMarker -Bytes ([byte[]](11, 22, 33))

        $settingsText = "pluginManagement {}`r`nloadAllIndividualExtensions()`r`n// preserve trailing whitespace  `r`n`r`n"
        [byte[]] $settingsBytes = @([byte]0xEF, [byte]0xBB, [byte]0xBF) +
            [System.Text.Encoding]::UTF8.GetBytes($settingsText)
        Write-Bytes -Path $settingsPath -Bytes $settingsBytes

        if ($GradleSucceeds) {
            $gradleBody = @'
@echo off
if "%1"==":src:zh:jmapi:assembleRelease" (
  mkdir "%CD%\src\zh\jmapi\build\outputs\apk\release" 2>nul
  > "%CD%\src\zh\jmapi\build\outputs\apk\release\fixture.apk" echo fixture-apk
)
exit /b 0
'@
        } else {
            $gradleBody = "@echo off`r`nexit /b 7`r`n"
        }
        $prerequisites = New-FakeBuildPrerequisites `
            -FixtureRoot $fixture `
            -KeiyoushiRoot $keiyoushiRoot `
            -GradleBody $gradleBody

        $env:JAVA_HOME = 'jmapi-caller-java-sentinel'
        $env:ANDROID_HOME = 'jmapi-caller-android-home-sentinel'
        $env:ANDROID_SDK_ROOT = 'jmapi-caller-android-sdk-sentinel'
        $env:PATH = 'jmapi-caller-path-sentinel' + [System.IO.Path]::PathSeparator + $callerPath
        $expectedJavaHome = $env:JAVA_HOME
        $expectedAndroidHome = $env:ANDROID_HOME
        $expectedAndroidSdkRoot = $env:ANDROID_SDK_ROOT
        $expectedPath = $env:PATH

        $failed = $false
        try {
            & $buildScript `
                -KeiyoushiRoot $keiyoushiRoot `
                -SourceRoot $sourceRoot `
                -JavaHome $prerequisites.JavaHome `
                -AndroidSdkRoot $prerequisites.AndroidSdkRoot | Out-Null
        } catch {
            $failed = $true
        }

        if ($GradleSucceeds) {
            Assert-True -Condition (-not $failed) -Message 'Successful settings-byte fixture did not complete its fake build.'
        } else {
            Assert-True -Condition $failed -Message 'Failing settings-byte fixture unexpectedly completed its fake build.'
            Assert-True -Condition (Test-Path -LiteralPath $oldTargetMarker -PathType Leaf) -Message 'Failed build did not restore the prior extension target.'
        }
        Assert-BytesEqual -Expected $settingsBytes -Actual ([System.IO.File]::ReadAllBytes($settingsPath)) -Label "UTF-8 BOM settings ($label)"
        Assert-True -Condition ($env:JAVA_HOME -ceq $expectedJavaHome) -Message "JAVA_HOME was not restored after $label."
        Assert-True -Condition ($env:ANDROID_HOME -ceq $expectedAndroidHome) -Message "ANDROID_HOME was not restored after $label."
        Assert-True -Condition ($env:ANDROID_SDK_ROOT -ceq $expectedAndroidSdkRoot) -Message "ANDROID_SDK_ROOT was not restored after $label."
        Assert-True -Condition ($env:PATH -ceq $expectedPath) -Message "PATH was not restored after $label."
        Assert-NoBuildTransactionResidue -TargetParent $targetParent
    } finally {
        $env:JAVA_HOME = $callerJavaHome
        $env:ANDROID_HOME = $callerAndroidHome
        $env:ANDROID_SDK_ROOT = $callerAndroidSdkRoot
        $env:PATH = $callerPath
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-UnsafeVersionCase {
    $fixture = New-UniqueFixtureRoot 'unsafe-version'
    $projectRoot = Join-Path $fixture 'project'
    $outputDir = Join-Path $fixture 'output'
    $apkPath = Join-Path $fixture 'input.apk'
    $victimPath = Join-Path $fixture 'victim.bin'
    $signerMarker = Join-Path $fixture 'signer-called.txt'
    $oldPath = $env:PATH
    try {
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi') -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $projectRoot 'src\zh\jmapi\build.gradle.kts'),
            "versionCode = 13`r`nlibVersion = `"1.4/../../victim`"`r`nbaseUrl = `"http://127.0.0.1:8088`"`r`n"
        )
        Write-Bytes `
            -Path (Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi\ic_launcher.png') `
            -Bytes ([byte[]](137, 80, 78, 71))
        $apkBytes = [byte[]](80, 75, 3, 4)
        $victimBytes = [byte[]](99, 88, 77, 66)
        Write-Bytes -Path $apkPath -Bytes $apkBytes
        Write-Bytes -Path $victimPath -Bytes $victimBytes
        $signerBin = New-FakeApkSigner -FixtureRoot $fixture -InvocationMarker $signerMarker
        $env:PATH = $signerBin + [System.IO.Path]::PathSeparator + $oldPath

        $rejected = $false
        $errorText = ''
        try {
            & $metadataScript -ApkPath $apkPath -OutputDir $outputDir -ProjectRoot $projectRoot | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $rejected -Message 'Metadata helper accepted an unsafe libVersion containing path traversal.'
        Assert-True `
            -Condition ([regex]::IsMatch($errorText, '(?i)libVersion|numeric dotted|unsafe version')) `
            -Message "Unsafe libVersion rejection was not an explicit validation failure: '$errorText'."
        Assert-True -Condition (-not (Test-Path -LiteralPath $signerMarker)) -Message 'Unsafe libVersion reached apksigner instead of being rejected before external execution/writes.'
        Assert-BytesEqual -Expected $victimBytes -Actual ([System.IO.File]::ReadAllBytes($victimPath)) -Label 'Unsafe-version victim'
        Assert-BytesEqual -Expected $apkBytes -Actual ([System.IO.File]::ReadAllBytes($apkPath)) -Label 'Unsafe-version APK input'
        Assert-True -Condition (-not (Test-Path -LiteralPath $outputDir)) -Message 'Unsafe libVersion created repository output before rejection.'
        $transactionResidue = @(Get-ChildItem -LiteralPath $fixture -Force | Where-Object {
            $_.Name -like '.output.stage-*' -or $_.Name -like '.output.backup-*'
        })
        Assert-True -Condition ($transactionResidue.Count -eq 0) -Message 'Unsafe libVersion left metadata staging/backup residue.'
    } finally {
        $env:PATH = $oldPath
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-MovePostCheckRollbackCase {
    $fixture = New-UniqueFixtureRoot 'move-postcheck-rollback'
    $source = Join-Path $fixture 'source'
    $destination = Join-Path $fixture 'destination'
    $marker = Join-Path $source 'marker.bin'
    $pathSafetyScript = Join-Path $root 'scripts\path-safety.ps1'
    $originalAssert = $null
    try {
        New-Item -ItemType Directory -Path $source | Out-Null
        $markerBytes = [byte[]](41, 42, 43, 44, 45)
        Write-Bytes -Path $marker -Bytes $markerBytes

        . $pathSafetyScript
        $originalAssert = (Get-Item -LiteralPath 'Function:\Assert-JmApiSafeInternalTree').ScriptBlock
        $injectedAssert = {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $ExpectedPhysicalPath,
                [Parameter(Mandatory = $true)][string] $ExpectedPhysicalParent,
                [Parameter(Mandatory = $true)][string] $Label
            )

            if ($Label -like '*moved destination') {
                throw 'injected post-move validation failure'
            }
            & $originalAssert @PSBoundParameters
        }.GetNewClosure()
        Set-Item -LiteralPath 'Function:\Assert-JmApiSafeInternalTree' -Value $injectedAssert

        $failed = $false
        $errorText = ''
        try {
            Move-JmApiSafeDirectory `
                -Source $source `
                -ExpectedSourcePhysicalPath $source `
                -Destination $destination `
                -ExpectedDestinationPhysicalPath $destination `
                -ExpectedPhysicalParent $fixture `
                -Label 'Injected transaction move'
        } catch {
            $failed = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $failed -Message 'Injected post-move validation failure did not propagate.'
        Assert-True `
            -Condition ($errorText -match 'injected post-move validation failure') `
            -Message "Move helper hid the injected post-check failure: '$errorText'."
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'Move helper did not restore the source after its post-check failed.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $destination)) -Message 'Move helper left the destination installed after its post-check failed.'
        Assert-True -Condition (Test-Path -LiteralPath $marker -PathType Leaf) -Message 'Move rollback lost its source marker.'
        Assert-BytesEqual -Expected $markerBytes -Actual ([System.IO.File]::ReadAllBytes($marker)) -Label 'Move rollback marker'
    } finally {
        if ($null -ne $originalAssert) {
            Set-Item -LiteralPath 'Function:\Assert-JmApiSafeInternalTree' -Value $originalAssert
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-MoveDestinationRaceCase {
    $fixture = New-UniqueFixtureRoot 'move-destination-race'
    $source = Join-Path $fixture 'source'
    $destination = Join-Path $fixture 'destination'
    $sourceMarker = Join-Path $source 'source-marker.bin'
    $outsiderMarker = Join-Path $destination 'outsider-marker.bin'
    $pathSafetyScript = Join-Path $root 'scripts\path-safety.ps1'
    $originalHook = $null
    try {
        New-Item -ItemType Directory -Path $source | Out-Null
        $sourceBytes = [byte[]](61, 62, 63)
        $outsiderBytes = [byte[]](81, 82, 83)
        Write-Bytes -Path $sourceMarker -Bytes $sourceBytes

        . $pathSafetyScript
        $existingHook = Get-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -ErrorAction SilentlyContinue
        if ($null -ne $existingHook) {
            $originalHook = $existingHook.ScriptBlock
        }
        $injectedHook = {
            param(
                [Parameter(Mandatory = $true)][string] $Source,
                [Parameter(Mandatory = $true)][string] $Destination,
                [Parameter(Mandatory = $true)][string] $Label
            )

            New-Item -ItemType Directory -Path $Destination | Out-Null
            [System.IO.File]::WriteAllBytes(
                (Join-Path $Destination 'outsider-marker.bin'),
                [byte[]](81, 82, 83)
            )
        }
        Set-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -Value $injectedHook

        $failed = $false
        try {
            Move-JmApiSafeDirectory `
                -Source $source `
                -ExpectedSourcePhysicalPath $source `
                -Destination $destination `
                -ExpectedDestinationPhysicalPath $destination `
                -ExpectedPhysicalParent $fixture `
                -Label 'Injected destination race'
        } catch {
            $failed = $true
        }

        Assert-True -Condition $failed -Message 'Move helper accepted a destination that appeared immediately before the filesystem move.'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'Destination race removed the original source.'
        Assert-True -Condition (Test-Path -LiteralPath $destination -PathType Container) -Message 'Destination race fixture did not create the outsider directory.'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $destination 'source'))) -Message 'Move helper nested source under a destination that appeared during the race window.'
        Assert-BytesEqual -Expected $sourceBytes -Actual ([System.IO.File]::ReadAllBytes($sourceMarker)) -Label 'Destination-race source marker'
        Assert-BytesEqual -Expected $outsiderBytes -Actual ([System.IO.File]::ReadAllBytes($outsiderMarker)) -Label 'Destination-race outsider marker'
    } finally {
        if ($null -ne $originalHook) {
            Set-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -Value $originalHook
        } elseif (Test-Path -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove') {
            Remove-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove'
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-MoveSourceIdentityRaceCase {
    $fixture = New-UniqueFixtureRoot 'move-source-identity-race'
    $source = Join-Path $fixture 'source'
    $destination = Join-Path $fixture 'destination'
    $stolen = Join-Path $fixture 'stolen-original'
    $sourceMarker = Join-Path $source 'original-marker.bin'
    $impostorMarker = Join-Path $destination 'impostor-marker.bin'
    $pathSafetyScript = Join-Path $root 'scripts\path-safety.ps1'
    $originalHook = $null
    try {
        New-Item -ItemType Directory -Path $source | Out-Null
        $originalBytes = [byte[]](91, 92, 93)
        $impostorBytes = [byte[]](101, 102, 103)
        Write-Bytes -Path $sourceMarker -Bytes $originalBytes
        . $pathSafetyScript
        $existingHook = Get-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -ErrorAction SilentlyContinue
        if ($null -ne $existingHook) {
            $originalHook = $existingHook.ScriptBlock
        }
        $injectedHook = {
            param(
                [Parameter(Mandatory = $true)][string] $Source,
                [Parameter(Mandatory = $true)][string] $Destination,
                [Parameter(Mandatory = $true)][string] $Label
            )

            [System.IO.Directory]::Move($Source, (Join-Path (Split-Path -Parent $Source) 'stolen-original'))
            New-Item -ItemType Directory -Path $Source | Out-Null
            [System.IO.File]::WriteAllBytes(
                (Join-Path $Source 'impostor-marker.bin'),
                [byte[]](101, 102, 103)
            )
        }
        Set-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -Value $injectedHook

        $failed = $false
        $errorText = ''
        try {
            Move-JmApiSafeDirectory `
                -Source $source `
                -ExpectedSourcePhysicalPath $source `
                -Destination $destination `
                -ExpectedDestinationPhysicalPath $destination `
                -ExpectedPhysicalParent $fixture `
                -Label 'Injected source identity race'
        } catch {
            $failed = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $failed -Message 'Move helper accepted an impostor that replaced the validated source.'
        Assert-True -Condition ($errorText -match '(?i)identity') -Message "Source identity failure was not explicit: '$errorText'."
        Assert-BytesEqual -Expected $originalBytes -Actual ([System.IO.File]::ReadAllBytes((Join-Path $stolen 'original-marker.bin'))) -Label 'Stolen original marker'
        Assert-BytesEqual -Expected $impostorBytes -Actual ([System.IO.File]::ReadAllBytes($impostorMarker)) -Label 'Moved impostor marker'
    } finally {
        if ($null -ne $originalHook) {
            Set-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -Value $originalHook
        } elseif (Test-Path -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove') {
            Remove-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove'
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-MovePostIdentityRaceCase {
    $fixture = New-UniqueFixtureRoot 'move-post-identity-race'
    $source = Join-Path $fixture 'source'
    $destination = Join-Path $fixture 'destination'
    $stolenVerifiedTree = Join-Path $fixture 'stolen-verified-tree'
    $sourceMarker = Join-Path $source 'verified-marker.bin'
    $impostorMarker = Join-Path $destination 'impostor-marker.bin'
    $pathSafetyScript = Join-Path $root 'scripts\path-safety.ps1'
    $state = [pscustomobject]@{ Attempted = $false; Blocked = $false }
    $originalAssert = $null
    try {
        New-Item -ItemType Directory -Path $source | Out-Null
        $verifiedBytes = [byte[]](131, 132, 133, 134)
        Write-Bytes -Path $sourceMarker -Bytes $verifiedBytes

        . $pathSafetyScript
        $originalAssert = (Get-Item -LiteralPath 'Function:\Assert-JmApiSafeInternalTree').ScriptBlock
        $injectedAssert = {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $ExpectedPhysicalPath,
                [Parameter(Mandatory = $true)][string] $ExpectedPhysicalParent,
                [Parameter(Mandatory = $true)][string] $Label
            )

            if ($Label -like '*moved destination') {
                $state.Attempted = $true
                try {
                    [System.IO.Directory]::Move($Path, $stolenVerifiedTree)
                    New-Item -ItemType Directory -Path $Path | Out-Null
                    [System.IO.File]::WriteAllBytes(
                        (Join-Path $Path 'impostor-marker.bin'),
                        [byte[]](141, 142, 143, 144)
                    )
                } catch {
                    $state.Blocked = $true
                    throw
                }
            }
            & $originalAssert @PSBoundParameters
        }.GetNewClosure()
        Set-Item -LiteralPath 'Function:\Assert-JmApiSafeInternalTree' -Value $injectedAssert

        $failed = $false
        try {
            Move-JmApiSafeDirectory `
                -Source $source `
                -ExpectedSourcePhysicalPath $source `
                -Destination $destination `
                -ExpectedDestinationPhysicalPath $destination `
                -ExpectedPhysicalParent $fixture `
                -Label 'Injected post-identity race'
        } catch {
            $failed = $true
        }

        Assert-True -Condition $state.Attempted -Message 'Move post-identity fault injection did not run.'
        Assert-True -Condition $failed -Message 'Move helper returned success after its verified destination was replaced during postcheck.'
        Assert-True -Condition $state.Blocked -Message 'Move helper did not hold the verified destination without delete sharing through postcheck.'
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'Move post-identity rollback lost the verified source tree.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $destination)) -Message 'Move post-identity rollback accepted a destination impostor.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $stolenVerifiedTree)) -Message 'Move post-identity race detached the verified tree.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $impostorMarker)) -Message 'Move post-identity race installed an impostor tree.'
        Assert-BytesEqual -Expected $verifiedBytes -Actual ([System.IO.File]::ReadAllBytes($sourceMarker)) -Label 'Move post-identity verified marker'
    } finally {
        if ($null -ne $originalAssert) {
            Set-Item -LiteralPath 'Function:\Assert-JmApiSafeInternalTree' -Value $originalAssert
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-MovePostHandleOpenFailureCase {
    $fixture = New-UniqueFixtureRoot 'move-post-handle-open-failure'
    $source = Join-Path $fixture 'source'
    $destination = Join-Path $fixture 'destination'
    $sourceMarker = Join-Path $source 'verified-marker.bin'
    $pathSafetyScript = Join-Path $root 'scripts\path-safety.ps1'
    $state = [pscustomobject]@{ Attempted = $false; ConflictingHandle = $null }
    $originalHook = $null
    try {
        New-Item -ItemType Directory -Path $source | Out-Null
        $markerBytes = [byte[]](171, 172, 173, 174)
        Write-Bytes -Path $sourceMarker -Bytes $markerBytes

        . $pathSafetyScript
        $existingHook = Get-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -ErrorAction SilentlyContinue
        if ($null -ne $existingHook) {
            $originalHook = $existingHook.ScriptBlock
        }
        $injectedHook = {
            param(
                [Parameter(Mandatory = $true)][string] $Source,
                [Parameter(Mandatory = $true)][string] $Destination,
                [Parameter(Mandatory = $true)][string] $Label
            )

            $state.Attempted = $true
            $state.ConflictingHandle = [JmApi.PathSafety.NativeMethods]::OpenPathEntryWithDeleteSharing($Source)
        }.GetNewClosure()
        Set-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -Value $injectedHook

        $failed = $false
        $errorText = ''
        try {
            Move-JmApiSafeDirectory `
                -Source $source `
                -ExpectedSourcePhysicalPath $source `
                -Destination $destination `
                -ExpectedDestinationPhysicalPath $destination `
                -ExpectedPhysicalParent $fixture `
                -Label 'Injected post-move handle-open failure'
        } catch {
            $failed = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $state.Attempted -Message 'Post-move handle-open failure injection did not run.'
        Assert-True -Condition $failed -Message 'Move helper ignored the injected post-move handle-open failure.'
        $sourceRestored = Test-Path -LiteralPath $source -PathType Container
        $destinationRetained = Test-Path -LiteralPath $destination -PathType Container
        Assert-True `
            -Condition ($sourceRestored -and -not $destinationRetained) `
            -Message "Move handle-open failure did not rollback atomically: sourceRestored=$sourceRestored destinationRetained=$destinationRetained error='$errorText'."
        Assert-BytesEqual -Expected $markerBytes -Actual ([System.IO.File]::ReadAllBytes($sourceMarker)) -Label 'Move handle-open rollback marker'
    } finally {
        if ($null -ne $state.ConflictingHandle) {
            $state.ConflictingHandle.Dispose()
        }
        if ($null -ne $originalHook) {
            Set-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove' -Value $originalHook
        } elseif (Test-Path -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove') {
            Remove-Item -LiteralPath 'Function:\Invoke-JmApiBeforeDirectoryMove'
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-RemoveTraversalRaceCase {
    $fixture = New-UniqueFixtureRoot 'remove-traversal-race'
    $deleteRoot = Join-Path $fixture 'delete-root'
    $child = Join-Path $deleteRoot 'child'
    $victim = Join-Path $fixture 'victim'
    $victimMarker = Join-Path $victim 'victim-marker.bin'
    $pathSafetyScript = Join-Path $root 'scripts\path-safety.ps1'
    $raceState = [pscustomobject]@{ Attempted = $false; Blocked = $false }
    try {
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        New-Item -ItemType Directory -Path $victim -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $child 'local.txt'), 'local')
        $victimBytes = [byte[]](111, 112, 113, 114)
        Write-Bytes -Path $victimMarker -Bytes $victimBytes
        . $pathSafetyScript
        $injectedEnumerationHook = {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $Label
            )

            if (-not $raceState.Attempted -and
                [string]::Equals($Path, $child, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $raceState.Attempted = $true
                try {
                    [System.IO.Directory]::Delete($child, $true)
                    New-Item -ItemType Junction -Path $child -Target $victim | Out-Null
                } catch {
                    $raceState.Blocked = $true
                }
            }
        }.GetNewClosure()
        Remove-JmApiSafeTree `
            -Path $deleteRoot `
            -ExpectedPhysicalPath $deleteRoot `
            -ExpectedPhysicalParent $fixture `
            -Label 'Injected traversal removal' `
            -BeforeEnumerationHook $injectedEnumerationHook

        Assert-True -Condition $raceState.Attempted -Message 'Remove traversal fault injection did not run.'
        Assert-True -Condition $raceState.Blocked -Message 'Remove traversal did not hold the child entry stable during enumeration.'
        Assert-BytesEqual -Expected $victimBytes -Actual ([System.IO.File]::ReadAllBytes($victimMarker)) -Label 'Remove traversal victim marker'
    } finally {
        if (Test-Path -LiteralPath $child) {
            $childItem = Get-Item -LiteralPath $child -Force
            if (($childItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                [System.IO.Directory]::Delete($child, $false)
            }
        }
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-ManifestMismatchCase {
    $fixture = New-UniqueFixtureRoot 'manifest-mismatch'
    $projectRoot = Join-Path $fixture 'project'
    $outputDir = Join-Path $fixture 'published-repo'
    $outputMarker = Join-Path $outputDir 'must-survive.bin'
    $apkPath = Join-Path $root 'dist-local\apk\tachiyomi-zh.jmapi-v1.4.13.apk'
    if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
        $apkPath = 'D:\jm\keiyoushi\src\zh\jmapi\build\outputs\apk\release\tachiyomi-zh.jmapi-v1.4.13-release.apk'
    }
    try {
        Assert-True -Condition (Test-Path -LiteralPath $apkPath -PathType Leaf) -Message 'Manifest mismatch contract requires the freshly signed v1.4.13 APK.'
        $apkHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath).Hash
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi') -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $projectRoot 'src\zh\jmapi\build.gradle.kts'),
            "versionCode = 14`r`nlibVersion = `"1.4`"`r`nbaseUrl = `"http://127.0.0.1:8088`"`r`n"
        )
        Write-Bytes `
            -Path (Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi\ic_launcher.png') `
            -Bytes ([byte[]](137, 80, 78, 71))
        $markerBytes = [byte[]](71, 72, 73, 74)
        Write-Bytes -Path $outputMarker -Bytes $markerBytes

        $rejected = $false
        $errorText = ''
        try {
            & $metadataScript -ApkPath $apkPath -OutputDir $outputDir -ProjectRoot $projectRoot | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $rejected -Message 'Metadata helper published a v1.4.13 APK under mismatched v1.4.14 metadata.'
        Assert-True `
            -Condition ($errorText -match '(?i)manifest.*(?:versionCode|versionName)|does not match') `
            -Message "Manifest mismatch rejection was not explicit: '$errorText'."
        Assert-True -Condition (Test-Path -LiteralPath $outputMarker -PathType Leaf) -Message 'Manifest mismatch changed OutputDir before rejection.'
        Assert-BytesEqual -Expected $markerBytes -Actual ([System.IO.File]::ReadAllBytes($outputMarker)) -Label 'Manifest mismatch OutputDir marker'
        Assert-True -Condition ((Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath).Hash -eq $apkHash) -Message 'Manifest mismatch validation changed the APK input.'
        $residue = @(Get-ChildItem -LiteralPath $fixture -Force | Where-Object {
            $_.Name -like '.published-repo.stage-*' -or $_.Name -like '.published-repo.backup-*'
        })
        Assert-True -Condition ($residue.Count -eq 0) -Message 'Manifest mismatch left metadata transaction residue.'
    } finally {
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-MetadataStageCollisionCase {
    $fixture = New-UniqueFixtureRoot 'metadata-stage-collision'
    $projectRoot = Join-Path $fixture 'project'
    $outputDir = Join-Path $fixture 'published-repo'
    $outputMarker = Join-Path $outputDir 'must-survive.bin'
    $apkPath = Join-Path $root 'dist-local\apk\tachiyomi-zh.jmapi-v1.4.13.apk'
    $state = [pscustomobject]@{ Attempted = $false; Stage = '' }
    try {
        Assert-True -Condition (Test-Path -LiteralPath $apkPath -PathType Leaf) -Message 'Metadata stage-collision contract requires the freshly signed v1.4.13 APK.'
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi') -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $projectRoot 'src\zh\jmapi\build.gradle.kts'),
            "versionCode = 13`r`nlibVersion = `"1.4`"`r`nbaseUrl = `"http://127.0.0.1:8088`"`r`n"
        )
        Write-Bytes `
            -Path (Join-Path $projectRoot 'src\zh\jmapi\res\mipmap-xxxhdpi\ic_launcher.png') `
            -Bytes ([byte[]](137, 80, 78, 71))
        $outputBytes = [byte[]](121, 122, 123)
        Write-Bytes -Path $outputMarker -Bytes $outputBytes
        $hook = {
            param([Parameter(Mandatory = $true)][string] $StagingOutput)

            $state.Attempted = $true
            $state.Stage = $StagingOutput
            New-Item -ItemType Directory -Path $StagingOutput | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $StagingOutput 'injected.txt'), 'unknown')
        }.GetNewClosure()

        $rejected = $false
        $errorText = ''
        try {
            & $metadataScript `
                -ApkPath $apkPath `
                -OutputDir $outputDir `
                -ProjectRoot $projectRoot `
                -BeforeStageCreationHook $hook | Out-Null
        } catch {
            $rejected = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $state.Attempted -Message "Metadata stage-collision fault injection did not run: '$errorText'."
        Assert-True -Condition $rejected -Message 'Metadata helper reused a pre-existing staging directory.'
        Assert-True -Condition ($errorText -match '(?i)staging.*already exists') -Message "Stage collision rejection was not explicit: '$errorText'."
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $state.Stage 'injected.txt') -PathType Leaf) -Message 'Metadata helper deleted an unowned colliding stage.'
        Assert-BytesEqual -Expected $outputBytes -Actual ([System.IO.File]::ReadAllBytes($outputMarker)) -Label 'Stage-collision output marker'
    } finally {
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-ApkBindingRaceCase {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PathSwap', 'InPlaceRewrite')]
        [string] $Attack
    )

    $fixtureLabel = if ($Attack -eq 'PathSwap') { 'apk-input-swap' } else { 'manifest-binding' }
    $fixture = New-UniqueFixtureRoot $fixtureLabel
    $projectRoot = Join-Path $fixture 'project'
    $outputDir = Join-Path $fixture 'published-repo'
    $apkPath = Join-Path $fixture 'input.apk'
    $stolenApk = Join-Path $fixture 'validated-original.apk'
    $signerMarker = Join-Path $fixture 'signer-called.txt'
    $aapt2Marker = Join-Path $fixture 'aapt2-called.txt'
    $oldPath = $env:PATH
    $state = [pscustomobject]@{ Attempted = $false; Blocked = $false }
    try {
        Initialize-FakeMetadataProject -ProjectRoot $projectRoot
        $validatedBytes = [byte[]](80, 75, 3, 4, 10, 20, 30, 40)
        $impostorBytes = [byte[]](80, 75, 3, 4, 200, 201, 202, 203)
        Write-Bytes -Path $apkPath -Bytes $validatedBytes
        $validatedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath).Hash
        $toolsBin = New-FakeMetadataTools `
            -FixtureRoot $fixture `
            -SignerMarker $signerMarker `
            -Aapt2Marker $aapt2Marker
        $env:PATH = $toolsBin + [System.IO.Path]::PathSeparator + (Join-Path $env:SystemRoot 'System32')

        $hook = {
            param([Parameter(Mandatory = $true)][string] $StagingOutput)

            $state.Attempted = $true
            try {
                if ($Attack -eq 'PathSwap') {
                    [System.IO.File]::Move($apkPath, $stolenApk)
                    [System.IO.File]::WriteAllBytes($apkPath, $impostorBytes)
                } else {
                    [System.IO.File]::WriteAllBytes($apkPath, $impostorBytes)
                }
            } catch {
                $state.Blocked = $true
            }
        }.GetNewClosure()

        $failed = $false
        $errorText = ''
        try {
            & $metadataScript `
                -ApkPath $apkPath `
                -OutputDir $outputDir `
                -ProjectRoot $projectRoot `
                -BeforeStageCreationHook $hook | Out-Null
        } catch {
            $failed = $true
            $errorText = $_.Exception.Message
        }

        Assert-True -Condition $state.Attempted -Message "$fixtureLabel fault injection did not run."
        Assert-True -Condition (Test-Path -LiteralPath $signerMarker -PathType Leaf) -Message "$fixtureLabel did not run apksigner before the injected mutation."
        Assert-True -Condition (Test-Path -LiteralPath $aapt2Marker -PathType Leaf) -Message "$fixtureLabel did not run aapt2 before the injected mutation."
        Assert-True -Condition (-not $failed) -Message "$fixtureLabel rejected the stable validated APK instead of publishing it: '$errorText'."
        Assert-True -Condition $state.Blocked -Message "$fixtureLabel changed the APK after manifest/signature validation."
        Assert-True -Condition (-not (Test-Path -LiteralPath $stolenApk)) -Message "$fixtureLabel detached the validated APK from its input path."
        Assert-True `
            -Condition ((Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath).Hash -eq $validatedHash) `
            -Message "$fixtureLabel changed the validated APK input bytes."
        $publishedApk = Join-Path $outputDir 'apk\tachiyomi-zh.jmapi-v1.4.13.apk'
        Assert-True -Condition (Test-Path -LiteralPath $publishedApk -PathType Leaf) -Message "$fixtureLabel did not publish the verified APK."
        Assert-True `
            -Condition ((Get-FileHash -Algorithm SHA256 -LiteralPath $publishedApk).Hash -eq $validatedHash) `
            -Message "$fixtureLabel published bytes that were not bound to manifest/signature validation."
        Assert-BytesEqual -Expected $validatedBytes -Actual ([System.IO.File]::ReadAllBytes($publishedApk)) -Label "$fixtureLabel published APK"
    } finally {
        $env:PATH = $oldPath
        Remove-UniqueFixtureRoot -FixtureRoot $fixture
    }
}

function Invoke-ApkInputSwapCase {
    Invoke-ApkBindingRaceCase -Attack PathSwap
}

function Invoke-ManifestBindingCase {
    Invoke-ApkBindingRaceCase -Attack InPlaceRewrite
}

function Invoke-TrailingDotHostCase {
    $sourcePath = Join-Path $root 'src\zh\jmapi\src\eu\kanade\tachiyomi\extension\zh\jmapi\JmApi.kt'
    $source = [System.IO.File]::ReadAllText($sourcePath)
    if ($source -notmatch "parsed\.host\.trimEnd\('\.'\)") {
        throw 'JM API host safety check must remove an absolute-DNS trailing dot before unspecified-host checks.'
    }
    if ($source -notmatch 'UNSPECIFIED_HOSTS[\s\S]*?UNSPECIFIED_IPV4_REGEX[\s\S]*?hostForSafetyCheck') {
        throw 'JM API unspecified-host checks must use the trailing-dot-normalized host.'
    }

    $zeroRegex = [regex]'^(?:0+)(?:\.0+){0,3}$'
    foreach ($hostValue in @('0.0.0.0.', '00.0.0.0.', '0.0.0.00.')) {
        $normalized = $hostValue.TrimEnd('.')
        Assert-True -Condition $zeroRegex.IsMatch($normalized) -Message "Trailing-dot negative fixture '$hostValue' does not model an all-zero numeric IPv4 host."
    }
    foreach ($hostValue in @('example.com.', 'api.internal.', '0.example.')) {
        $normalized = $hostValue.TrimEnd('.')
        Assert-True -Condition (-not $zeroRegex.IsMatch($normalized)) -Message "Ordinary hostname fixture '$hostValue' was treated as an all-zero numeric IPv4 host."
    }
}

function Invoke-VersionReferencesCase {
    $expectations = [ordered]@{
        'src\zh\jmapi\build.gradle.kts' = @('versionCode\s*=\s*13')
        'README.md' = @('tachiyomi-zh\.jmapi-v1\.4\.13\.apk', '1\.4\.13', 'versionCode\s*=\s*13')
        'docs\apk-optimization-design.md' = @('tachiyomi-zh\.jmapi-v1\.4\.13\.apk', '1\.4\.13', 'versionCode\s*=\s*13')
        'docs\ai-delivery-prompt.md' = @('tachiyomi-zh\.jmapi-v1\.4\.13\.apk', 'v1\.4\.13', 'versionCode 13')
    }
    foreach ($entry in $expectations.GetEnumerator()) {
        $text = [System.IO.File]::ReadAllText((Join-Path $root $entry.Key))
        foreach ($pattern in $entry.Value) {
            if ($text -notmatch $pattern) {
                throw "Version reference '$pattern' is missing from '$($entry.Key)'."
            }
        }
    }

    $stalePattern = '1\.4\.' + '12|versionCode\s*=\s*' + '12|v1\.4\.' + '12'
    $stale = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
        $_.FullName -notmatch '[\\/]dist-local[\\/]' -and
        $_.FullName -notmatch '[\\/]build[\\/]'
    } | Select-String -Pattern $stalePattern)
    if ($stale.Count -ne 0) {
        throw "Stale prior-version references remain: $($stale.Path -join ', ')."
    }
}

$cases = if ($Case -eq 'All') {
    @(
        'BuildJunction',
        'IntermediateParentJunction',
        'IntermediateParentSwapRace',
        'MetadataJunction',
        'MetadataParentSwapRace',
        'MetadataCurrentDirectory',
        'MetadataExternalParentLock',
        'ExpectedPathMismatch',
        'SettingsBomSuccess',
        'SettingsBomFailure',
        'UnsafeVersion',
        'MovePostCheckRollback',
        'MoveDestinationRace',
        'MoveSourceIdentityRace',
        'MovePostIdentityRace',
        'MovePostHandleOpenFailure',
        'RemoveTraversalRace',
        'ManifestMismatch',
        'MetadataStageCollision',
        'ApkInputSwap',
        'ManifestBinding',
        'TrailingDotHost',
        'VersionReferences'
    )
} else {
    @($Case)
}

foreach ($selectedCase in $cases) {
    switch ($selectedCase) {
        'BuildJunction' { Invoke-BuildJunctionCase }
        'IntermediateParentJunction' { Invoke-IntermediateParentJunctionCase }
        'IntermediateParentSwapRace' { Invoke-IntermediateParentSwapRaceCase }
        'MetadataJunction' { Invoke-MetadataJunctionCase }
        'MetadataParentSwapRace' { Invoke-MetadataParentSwapRaceCase }
        'MetadataCurrentDirectory' { Invoke-MetadataCurrentDirectoryCase }
        'MetadataExternalParentLock' { Invoke-MetadataExternalParentLockCase }
        'ExpectedPathMismatch' { Invoke-ExpectedPathMismatchCase }
        'SettingsBomSuccess' { Invoke-SettingsBomCase -GradleSucceeds $true }
        'SettingsBomFailure' { Invoke-SettingsBomCase -GradleSucceeds $false }
        'UnsafeVersion' { Invoke-UnsafeVersionCase }
        'MovePostCheckRollback' { Invoke-MovePostCheckRollbackCase }
        'MoveDestinationRace' { Invoke-MoveDestinationRaceCase }
        'MoveSourceIdentityRace' { Invoke-MoveSourceIdentityRaceCase }
        'MovePostIdentityRace' { Invoke-MovePostIdentityRaceCase }
        'MovePostHandleOpenFailure' { Invoke-MovePostHandleOpenFailureCase }
        'RemoveTraversalRace' { Invoke-RemoveTraversalRaceCase }
        'ManifestMismatch' { Invoke-ManifestMismatchCase }
        'MetadataStageCollision' { Invoke-MetadataStageCollisionCase }
        'ApkInputSwap' { Invoke-ApkInputSwapCase }
        'ManifestBinding' { Invoke-ManifestBindingCase }
        'TrailingDotHost' { Invoke-TrailingDotHostCase }
        'VersionReferences' { Invoke-VersionReferencesCase }
        default { throw "Unknown safety contract case '$selectedCase'." }
    }
    Write-Host "JM API extension safety contract passed: $selectedCase"
}
