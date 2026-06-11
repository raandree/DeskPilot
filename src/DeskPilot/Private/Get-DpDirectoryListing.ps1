function Get-DpDirectoryListing {
    <#
    .SYNOPSIS
        Lists the sub-folders of a directory for the folder-picker UI.
    .DESCRIPTION
        Returns a hashtable describing a directory: its resolved path, parent,
        leaf name, the immediate sub-folders (name + full path, hidden/system
        entries skipped), the ready drives, and the user's home folder. An empty
        or whitespace path, or one that does not resolve to a directory, falls
        back to the home folder. Enumeration errors (for example access denied)
        are reported in the 'error' field while navigation (parent, drives) stays
        usable so the user is never stuck.
    .PARAMETER Path
        The directory to list. Empty means "start at home".
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path
    )

    $homeDir = $HOME
    $drives = if ($IsWindows) {
        @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.Name })
    }
    else {
        @('/')
    }

    $target = if ([string]::IsNullOrWhiteSpace($Path)) { $homeDir } else { $Path }

    $resolvedPath = $target
    $parent = $null
    $name = $null
    $entries = @()
    $listError = $null

    try {
        $full = [System.IO.Path]::GetFullPath($target)
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            $full = [System.IO.Path]::GetFullPath($homeDir)
        }
        $resolvedPath = $full

        $leaf = Split-Path -Leaf $full
        $name = if ([string]::IsNullOrEmpty($leaf)) { $full } else { $leaf }
        $parentRaw = Split-Path -Parent $full
        $parent = if ([string]::IsNullOrEmpty($parentRaw)) { $null } else { $parentRaw }
    }
    catch {
        $listError = "$($_.Exception.Message)"
    }

    if (-not $listError) {
        try {
            $children = Get-ChildItem -LiteralPath $resolvedPath -Directory -ErrorAction Stop |
                Where-Object { -not ($_.Attributes -band ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) } |
                Sort-Object Name
            $entries = @(foreach ($child in $children) { @{ name = $child.Name; path = $child.FullName } })
        }
        catch {
            $listError = "$($_.Exception.Message)"
        }
    }

    @{
        path    = $resolvedPath
        parent  = $parent
        name    = $name
        entries = $entries
        drives  = $drives
        home    = $homeDir
        error   = $listError
    }
}
