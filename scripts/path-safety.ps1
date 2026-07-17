Set-StrictMode -Version Latest

if (-not ('JmApi.PathSafety.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace JmApi.PathSafety
{
    public static class NativeMethods
    {
        private const uint OpenExisting = 3;
        private const uint FileReadAttributes = 0x00000080;
        private const uint DeleteAccess = 0x00010000;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint ShareReadWrite = 0x00000003;
        private const uint ShareReadWriteDelete = 0x00000007;

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            StringBuilder path,
            uint pathLength,
            uint flags
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information
        );

        private static SafeFileHandle OpenPathEntry(string path, uint shareMode)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                FileReadAttributes | DeleteAccess,
                shareMode,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Could not open stable path entry: " + path);
            }
            return handle;
        }

        public static SafeFileHandle OpenPathEntryWithDeleteSharing(string path)
        {
            return OpenPathEntry(path, ShareReadWriteDelete);
        }

        public static SafeFileHandle OpenPathEntryWithoutDeleteSharing(string path)
        {
            return OpenPathEntry(path, ShareReadWrite);
        }

        public static string GetFileIdentity(SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read path-entry identity.");
            }
            return information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") + information.FileIndexLow.ToString("X8");
        }

        public static string GetFinalPath(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path,
                0,
                ShareReadWriteDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero
            ))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not open path for physical-path resolution: " + path
                    );
                }

                StringBuilder buffer = new StringBuilder(512);
                uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not resolve the final physical path: " + path
                    );
                }
                if (length >= buffer.Capacity)
                {
                    buffer = new StringBuilder(checked((int)length + 1));
                    length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                    if (length == 0 || length >= buffer.Capacity)
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "Could not resolve the complete final physical path: " + path
                        );
                    }
                }

                string result = buffer.ToString();
                if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                {
                    return @"\\" + result.Substring(8);
                }
                if (result.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
                {
                    return result.Substring(4);
                }
                return result;
            }
        }
    }
}
'@
}

function Get-JmApiFullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $full = [System.IO.Path]::GetFullPath($providerPath)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full
    }
    return $full.TrimEnd('\', '/')
}

function Get-JmApiPhysicalPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $full = Get-JmApiFullPath $Path
    $current = $full
    $missingTail = New-Object 'System.Collections.Generic.List[string]'
    while (-not (Test-Path -LiteralPath $current)) {
        $root = [System.IO.Path]::GetPathRoot($current)
        if ([string]::Equals($current, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Could not find an existing ancestor while resolving physical path '$full'."
        }
        $leaf = Split-Path -Leaf $current
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            throw "Could not isolate the missing path suffix while resolving '$full'."
        }
        $missingTail.Insert(0, $leaf)
        $current = Split-Path -Parent $current
    }

    if ($missingTail.Count -gt 0 -and (Test-Path -LiteralPath $current -PathType Leaf)) {
        throw "Existing ancestor '$current' is a file while resolving physical path '$full'."
    }

    $physical = [JmApi.PathSafety.NativeMethods]::GetFinalPath($current)
    foreach ($segment in $missingTail) {
        $physical = [System.IO.Path]::Combine($physical, $segment)
    }
    return Get-JmApiFullPath $physical
}

function Test-JmApiSamePhysicalPath {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right
    )

    return [string]::Equals(
        (Get-JmApiPhysicalPath $Left),
        (Get-JmApiPhysicalPath $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-JmApiPhysicalPathEquals {
    param(
        [Parameter(Mandatory = $true)][string] $Actual,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $actualPhysical = Get-JmApiPhysicalPath $Actual
    $expectedPhysical = Get-JmApiFullPath $Expected
    if (-not [string]::Equals(
        $actualPhysical,
        $expectedPhysical,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Label resolved outside the expected physical location. Expected '$expectedPhysical', got '$actualPhysical'."
    }
}

function Assert-JmApiSeparateTrees {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $leftPhysical = Get-JmApiPhysicalPath $Left
    $rightPhysical = Get-JmApiPhysicalPath $Right
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ([string]::Equals($leftPhysical, $rightPhysical, $comparison) -or
        $leftPhysical.StartsWith($rightPhysical + $separator, $comparison) -or
        $rightPhysical.StartsWith($leftPhysical + $separator, $comparison)
    ) {
        throw "$Label must use non-overlapping physical directory trees. Left '$leftPhysical', right '$rightPhysical'."
    }
}

function Assert-JmApiOutputTreeSafe {
    param(
        [Parameter(Mandatory = $true)][string] $OutputTree,
        [Parameter(Mandatory = $true)][string] $ProtectedPath,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $outputPhysical = Get-JmApiPhysicalPath $OutputTree
    $protectedPhysical = Get-JmApiPhysicalPath $ProtectedPath
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $separator = [System.IO.Path]::DirectorySeparatorChar
    if ([string]::Equals($outputPhysical, $protectedPhysical, $comparison) -or
        $protectedPhysical.StartsWith($outputPhysical + $separator, $comparison)
    ) {
        throw "$Label is inside repository OutputDir physical tree '$outputPhysical': '$protectedPhysical'."
    }
}

function Test-JmApiReparsePoint {
    param([Parameter(Mandatory = $true)][string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-JmApiSafeInternalTree {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalPath,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalParent,
        [Parameter(Mandatory = $true)][string] $Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label is not an existing directory: '$Path'."
    }
    if (Test-JmApiReparsePoint $Path) {
        throw "$Label must not be a reparse point: '$Path'."
    }
    Assert-JmApiPhysicalPathEquals -Actual $Path -Expected $ExpectedPhysicalPath -Label $Label
    Assert-JmApiPhysicalPathEquals `
        -Actual (Split-Path -Parent (Get-JmApiFullPath $Path)) `
        -Expected $ExpectedPhysicalParent `
        -Label "$Label parent"
}

function Assert-JmApiSafeMoveDestination {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalPath,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalParent,
        [Parameter(Mandatory = $true)][string] $Label
    )

    if (Test-Path -LiteralPath $Path) {
        throw "$Label already exists: '$Path'."
    }
    Assert-JmApiPhysicalPathEquals -Actual $Path -Expected $ExpectedPhysicalPath -Label $Label
    Assert-JmApiPhysicalPathEquals `
        -Actual (Split-Path -Parent (Get-JmApiFullPath $Path)) `
        -Expected $ExpectedPhysicalParent `
        -Label "$Label parent"
}

function Invoke-JmApiBeforeDirectoryMove {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $Label
    )

    # Intentional no-op seam for deterministic transaction fault-injection contracts.
}

function Undo-JmApiSafeDirectoryMove {
    param(
        [Parameter(Mandatory = $true)][string] $OriginalSource,
        [Parameter(Mandatory = $true)][string] $ExpectedOriginalSourcePhysicalPath,
        [Parameter(Mandatory = $true)][string] $MovedDestination,
        [Parameter(Mandatory = $true)][string] $ExpectedMovedDestinationPhysicalPath,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalParent,
        [Parameter(Mandatory = $true)][string] $Label
    )

    Assert-JmApiSafeInternalTree `
        -Path $MovedDestination `
        -ExpectedPhysicalPath $ExpectedMovedDestinationPhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label rollback current tree"
    Assert-JmApiSafeMoveDestination `
        -Path $OriginalSource `
        -ExpectedPhysicalPath $ExpectedOriginalSourcePhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label rollback original path"

    Assert-JmApiSafeInternalTree `
        -Path $MovedDestination `
        -ExpectedPhysicalPath $ExpectedMovedDestinationPhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label rollback current tree recheck"
    Assert-JmApiSafeMoveDestination `
        -Path $OriginalSource `
        -ExpectedPhysicalPath $ExpectedOriginalSourcePhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label rollback original path recheck"
    [System.IO.Directory]::Move(
        (Get-JmApiFullPath $MovedDestination),
        (Get-JmApiFullPath $OriginalSource)
    )
    Assert-JmApiSafeInternalTree `
        -Path $OriginalSource `
        -ExpectedPhysicalPath $ExpectedOriginalSourcePhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label rollback restored source"
    if (Test-Path -LiteralPath $MovedDestination) {
        throw "$Label rollback left the moved destination in place: '$MovedDestination'."
    }
}

function Move-JmApiSafeDirectory {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $ExpectedSourcePhysicalPath,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $ExpectedDestinationPhysicalPath,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalParent,
        [Parameter(Mandatory = $true)][string] $Label
    )

    Assert-JmApiSafeInternalTree `
        -Path $Source `
        -ExpectedPhysicalPath $ExpectedSourcePhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label source"
    Assert-JmApiSafeMoveDestination `
        -Path $Destination `
        -ExpectedPhysicalPath $ExpectedDestinationPhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label destination"

    Assert-JmApiSafeInternalTree `
        -Path $Source `
        -ExpectedPhysicalPath $ExpectedSourcePhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label source recheck"
    Assert-JmApiSafeMoveDestination `
        -Path $Destination `
        -ExpectedPhysicalPath $ExpectedDestinationPhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label destination recheck"
    $sourceIdentityHandle = [JmApi.PathSafety.NativeMethods]::OpenPathEntryWithDeleteSharing($Source)
    $sourceIdentityHandleReleased = $false
    try {
        $sourceIdentity = [JmApi.PathSafety.NativeMethods]::GetFileIdentity($sourceIdentityHandle)
        Invoke-JmApiBeforeDirectoryMove `
            -Source $Source `
            -Destination $Destination `
            -Label "$Label forward move"
        [System.IO.Directory]::Move(
            (Get-JmApiFullPath $Source),
            (Get-JmApiFullPath $Destination)
        )
        $sourceIdentityHandle.Dispose()
        $sourceIdentityHandleReleased = $true

        $destinationIdentityHandle = $null
        $destinationIdentityHandleReleased = $false
        try {
            try {
                $destinationIdentityHandle = [JmApi.PathSafety.NativeMethods]::OpenPathEntryWithoutDeleteSharing($Destination)
                $destinationIdentity = [JmApi.PathSafety.NativeMethods]::GetFileIdentity($destinationIdentityHandle)
            } catch {
                $identityAcquisitionFailure = $_
                if ($null -ne $destinationIdentityHandle -and -not $destinationIdentityHandleReleased) {
                    $destinationIdentityHandle.Dispose()
                    $destinationIdentityHandleReleased = $true
                }
                try {
                    Undo-JmApiSafeDirectoryMove `
                        -OriginalSource $Source `
                        -ExpectedOriginalSourcePhysicalPath $ExpectedSourcePhysicalPath `
                        -MovedDestination $Destination `
                        -ExpectedMovedDestinationPhysicalPath $ExpectedDestinationPhysicalPath `
                        -ExpectedPhysicalParent $ExpectedPhysicalParent `
                        -Label $Label
                } catch {
                    $rollbackFailure = $_
                    $combinedMessage = "$Label post-move identity acquisition failed: $($identityAcquisitionFailure.Exception.Message) " +
                        "Automatic rollback also failed: $($rollbackFailure.Exception.Message) " +
                        'The moved tree was left in place rather than deleting or replacing an unverified path.'
                    throw (New-Object System.InvalidOperationException -ArgumentList $combinedMessage, $rollbackFailure.Exception)
                }
                throw $identityAcquisitionFailure
            }
            if ($destinationIdentity -cne $sourceIdentity) {
                throw "$Label source identity changed during the move. " +
                    "Expected '$sourceIdentity', moved '$destinationIdentity'. " +
                    'The unverified destination was left in place for forensic recovery.'
            }

            try {
                Assert-JmApiSafeInternalTree `
                    -Path $Destination `
                    -ExpectedPhysicalPath $ExpectedDestinationPhysicalPath `
                    -ExpectedPhysicalParent $ExpectedPhysicalParent `
                    -Label "$Label moved destination"
            } catch {
                $postCheckFailure = $_
                $destinationIdentityHandle.Dispose()
                $destinationIdentityHandleReleased = $true
                try {
                    Undo-JmApiSafeDirectoryMove `
                        -OriginalSource $Source `
                        -ExpectedOriginalSourcePhysicalPath $ExpectedSourcePhysicalPath `
                        -MovedDestination $Destination `
                        -ExpectedMovedDestinationPhysicalPath $ExpectedDestinationPhysicalPath `
                        -ExpectedPhysicalParent $ExpectedPhysicalParent `
                        -Label $Label
                } catch {
                    $rollbackFailure = $_
                    $combinedMessage = "$Label post-move validation failed: $($postCheckFailure.Exception.Message) " +
                        "Automatic rollback also failed: $($rollbackFailure.Exception.Message) " +
                        'The moved tree was left in place rather than deleting or replacing an unverified path.'
                    throw (New-Object System.InvalidOperationException -ArgumentList $combinedMessage, $rollbackFailure.Exception)
                }
                throw $postCheckFailure
            }
        } finally {
            if ($null -ne $destinationIdentityHandle -and -not $destinationIdentityHandleReleased) {
                $destinationIdentityHandle.Dispose()
            }
        }
    } finally {
        if (-not $sourceIdentityHandleReleased) {
            $sourceIdentityHandle.Dispose()
        }
    }
}

function Remove-JmApiTreeEntryWithoutFollowingReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [scriptblock] $BeforeEnumerationHook = $null
    )

    $stableHandle = [JmApi.PathSafety.NativeMethods]::OpenPathEntryWithoutDeleteSharing($Path)
    $fullName = $null
    $isDirectory = $false
    $isReparse = $false
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $fullName = $item.FullName
        $isDirectory = $item.PSIsContainer
        $isReparse = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if (-not $isReparse -and $isDirectory) {
            if ($null -ne $BeforeEnumerationHook) {
                & $BeforeEnumerationHook -Path $fullName -Label 'Safe tree removal'
            }
            foreach ($child in @(Get-ChildItem -LiteralPath $fullName -Force -ErrorAction Stop)) {
                Remove-JmApiTreeEntryWithoutFollowingReparsePoints `
                    -Path $child.FullName `
                    -BeforeEnumerationHook $BeforeEnumerationHook
            }
        }
    } finally {
        $stableHandle.Dispose()
    }

    if ($isDirectory) {
        [System.IO.Directory]::Delete($fullName, $false)
    } else {
        if (-not $isReparse) {
            [System.IO.File]::SetAttributes($fullName, [System.IO.FileAttributes]::Normal)
        }
        [System.IO.File]::Delete($fullName)
    }
}

function Remove-JmApiSafeTree {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalPath,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalParent,
        [Parameter(Mandatory = $true)][string] $Label,
        [scriptblock] $BeforeEnumerationHook = $null
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-JmApiSafeInternalTree `
        -Path $Path `
        -ExpectedPhysicalPath $ExpectedPhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label $Label
    Assert-JmApiSafeInternalTree `
        -Path $Path `
        -ExpectedPhysicalPath $ExpectedPhysicalPath `
        -ExpectedPhysicalParent $ExpectedPhysicalParent `
        -Label "$Label recheck"
    Remove-JmApiTreeEntryWithoutFollowingReparsePoints `
        -Path $Path `
        -BeforeEnumerationHook $BeforeEnumerationHook
}

function Assert-JmApiDirectChildPath {
    param(
        [Parameter(Mandatory = $true)][string] $Parent,
        [Parameter(Mandatory = $true)][string] $Child,
        [Parameter(Mandatory = $true)][string] $ExpectedLeaf,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $parentPhysical = Get-JmApiPhysicalPath $Parent
    $childPhysical = Get-JmApiPhysicalPath $Child
    $childParent = Split-Path -Parent $childPhysical
    $childLeaf = Split-Path -Leaf $childPhysical
    if (-not [string]::Equals($childParent, $parentPhysical, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($childLeaf, $ExpectedLeaf, [System.StringComparison]::Ordinal)
    ) {
        throw "$Label must be the direct child '$ExpectedLeaf' of '$parentPhysical'; got '$childPhysical'."
    }
}

function New-JmApiSafeDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedPhysicalPath,
        [Parameter(Mandatory = $true)][string] $Label,
        [switch] $RequireNew,
        [scriptblock] $BeforeCreateHook = $null,
        [scriptblock] $AfterCreateHook = $null
    )

    $target = Get-JmApiFullPath $Path
    $expectedTarget = Get-JmApiFullPath $ExpectedPhysicalPath
    $plannedTargetPhysical = Get-JmApiPhysicalPath $target
    if (-not [string]::Equals(
        $plannedTargetPhysical,
        $expectedTarget,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Label target resolved outside ExpectedPhysicalPath before creation. " +
            "Expected '$expectedTarget', got '$plannedTargetPhysical'."
    }
    $targetRoot = [System.IO.Path]::GetPathRoot($target)
    if ([string]::Equals($target, $targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($RequireNew) {
            throw "$Label cannot create a filesystem root: '$target'."
        }
        Assert-JmApiPhysicalPathEquals -Actual $target -Expected $expectedTarget -Label $Label
        return $target
    }

    if (Test-Path -LiteralPath $target) {
        if ($RequireNew) {
            throw "$Label already exists and is not owned by this operation: '$target'."
        }
        Assert-JmApiSafeInternalTree `
            -Path $target `
            -ExpectedPhysicalPath $expectedTarget `
            -ExpectedPhysicalParent (Get-JmApiFullPath (Split-Path -Parent $expectedTarget)) `
            -Label $Label
        return $target
    }

    $missingLeaves = New-Object 'System.Collections.Generic.List[string]'
    $existingAncestor = $target
    $expectedAncestor = $expectedTarget
    while (-not (Test-Path -LiteralPath $existingAncestor)) {
        $leaf = Split-Path -Leaf $existingAncestor
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            throw "$Label could not isolate a direct child while resolving '$target'."
        }
        $missingLeaves.Insert(0, $leaf)
        $existingAncestor = Split-Path -Parent $existingAncestor
        $expectedAncestor = Split-Path -Parent $expectedAncestor
    }
    if (Test-Path -LiteralPath $existingAncestor -PathType Leaf) {
        throw "$Label existing ancestor is a file: '$existingAncestor'."
    }

    $parentHandle = [JmApi.PathSafety.NativeMethods]::OpenPathEntryWithoutDeleteSharing($existingAncestor)
    try {
        if (Test-JmApiReparsePoint $existingAncestor) {
            throw "$Label existing ancestor must not be a reparse point: '$existingAncestor'."
        }
        Assert-JmApiPhysicalPathEquals `
            -Actual $existingAncestor `
            -Expected $expectedAncestor `
            -Label "$Label existing ancestor"

        $currentParent = Get-JmApiFullPath $existingAncestor
        $currentExpectedParent = Get-JmApiFullPath $expectedAncestor
        foreach ($leaf in $missingLeaves) {
            $child = Get-JmApiFullPath ([System.IO.Path]::Combine($currentParent, $leaf))
            $expectedChild = Get-JmApiFullPath ([System.IO.Path]::Combine($currentExpectedParent, $leaf))
            $parentIdentity = [JmApi.PathSafety.NativeMethods]::GetFileIdentity($parentHandle)
            Assert-JmApiPhysicalPathEquals `
                -Actual $currentParent `
                -Expected $currentExpectedParent `
                -Label "$Label stable parent"
            if ($null -ne $BeforeCreateHook) {
                & $BeforeCreateHook -Parent $currentParent -Child $child -Label $Label
            }
            if (Test-Path -LiteralPath $child) {
                throw "$Label direct child already exists and was not created by this operation: '$child'."
            }

            New-Item -ItemType Directory -Path $child -ErrorAction Stop | Out-Null
            if ($null -ne $AfterCreateHook -and
                [string]::Equals($child, $target, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                & $AfterCreateHook -Parent $currentParent -Child $child -Label $Label
            }
            $childHandle = [JmApi.PathSafety.NativeMethods]::OpenPathEntryWithoutDeleteSharing($child)
            $childHandleAccepted = $false
            try {
                if (Test-JmApiReparsePoint $child) {
                    throw "$Label created child must not be a reparse point: '$child'."
                }
                Assert-JmApiPhysicalPathEquals `
                    -Actual $child `
                    -Expected $expectedChild `
                    -Label "$Label created child"
                Assert-JmApiPhysicalPathEquals `
                    -Actual $currentParent `
                    -Expected $currentExpectedParent `
                    -Label "$Label stable parent recheck"
                $parentIdentityAfterCreate = [JmApi.PathSafety.NativeMethods]::GetFileIdentity($parentHandle)
                if ($parentIdentityAfterCreate -cne $parentIdentity) {
                    throw "$Label parent identity changed while creating '$child'."
                }
                $childHandleAccepted = $true
            } finally {
                if (-not $childHandleAccepted) {
                    $childHandle.Dispose()
                }
            }

            $parentHandle.Dispose()
            $parentHandle = $childHandle
            $currentParent = $child
            $currentExpectedParent = $expectedChild
        }
    } finally {
        $parentHandle.Dispose()
    }

    return $target
}
