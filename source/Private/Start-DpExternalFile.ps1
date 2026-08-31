function Start-DpExternalFile {
    <#
    .SYNOPSIS
        Opens one Project file with the program the operating system associates
        with its type.
    .DESCRIPTION
        Resolves Path (relative to Root or absolute) and confines it to Root the
        same way Get-DpFileContent and Get-DpFileImage do, then hands the file to
        the platform's own shell association: ShellExecute on Windows, 'open' on
        macOS, 'xdg-open' elsewhere. Nothing about the program is chosen here -
        the operating system decides, exactly as it would from a file manager.

        Two refusals stand in front of that launch. The extension must be a plain
        '.' plus letters and digits, so an alternate data stream or a name padded
        with trailing junk cannot reach the shell at all; and an extension the
        platform treats as executable or as script-host input (Get-DpExecutableExtension)
        is refused outright rather than confirmed, because the agent writes into
        this same folder and one click in the file tree must never be able to run
        code. Such a file is still readable in DeskPilot's own viewer.

        The launch is the ShouldProcess operation, so -WhatIf runs every check and
        reports the outcome without starting anything.
    .PARAMETER Root
        The Project folder the file must lie inside.
    .PARAMETER Path
        The file to open, relative to Root or an absolute path inside Root.
    .OUTPUTS
        System.Collections.Hashtable with path, name, extension, opened, code and
        error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = @{ path = $null; name = $null; extension = $null; opened = $false; code = $null; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.code = 'no_workspace'
        $result.error = 'No project folder.'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.code = 'no_path'
        $result.error = 'No file path.'
        return $result
    }

    try { $rootFull = [System.IO.Path]::GetFullPath($Root) }
    catch { $result.code = 'no_workspace'; $result.error = 'Invalid project folder.'; return $result }

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $rootFull $Path }
    try { $full = [System.IO.Path]::GetFullPath($candidate) }
    catch { $result.code = 'invalid_path'; $result.error = 'Invalid path.'; return $result }

    $rootCompare = $rootFull.TrimEnd('\', '/')
    $inside = $full.TrimEnd('\', '/').StartsWith($rootCompare + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
        $result.code = 'outside_workspace'
        $result.error = 'Outside the project folder.'
        return $result
    }

    $result.path = $full
    $result.name = [System.IO.Path]::GetFileName($full)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $result.code = 'not_found'
        $result.error = 'File not found.'
        return $result
    }

    $extension = ([System.IO.Path]::GetExtension($full)).ToLowerInvariant()
    $result.extension = $extension
    if ($extension -notmatch '^\.[a-z0-9]{1,16}$') {
        $result.code = 'no_file_type'
        $result.error = 'This file has no file type your computer can associate a program with.'
        return $result
    }
    if ((Get-DpExecutableExtension) -contains $extension) {
        $result.code = 'executable'
        $result.error = "DeskPilot never opens a $extension file outside itself, because that would run it."
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess($full, 'Open with the associated program')) {
        $result.opened = $true
        return $result
    }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        if ($IsWindows) {
            # ShellExecute is what applies the user's own file association.
            $psi.FileName = $full
            $psi.UseShellExecute = $true
            $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($full)
        }
        else {
            # The path goes in as one argv entry, so a name with spaces or quotes
            # is never re-split by a shell.
            $psi.FileName = if ($IsMacOS) { 'open' } else { 'xdg-open' }
            $psi.ArgumentList.Add($full)
            $psi.UseShellExecute = $false
        }
        $null = [System.Diagnostics.Process]::Start($psi)
        $result.opened = $true
    }
    catch {
        $result.code = 'open_failed'
        $result.error = "$($_.Exception.Message)"
    }
    $result
}
