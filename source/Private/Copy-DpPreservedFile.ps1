function Copy-DpPreservedFile {
    <#
    .SYNOPSIS
        Copies a file to a name in a directory without ever overwriting another
        file.
    .DESCRIPTION
        Used to keep a copy of something before it is replaced - an Agent Memory
        store DeskPilot could not read in full, whose bytes are the only remaining
        record of what was in it. "Do not overwrite" therefore has to be a
        guarantee rather than an intention.

        Checking the name first is not that guarantee: a name that is free when it
        is checked can be taken before it is written, and Copy-Item (with or
        without -Force) will then replace whatever arrived. So the copy itself is
        the atomic create-new primitive, [System.IO.File]::Copy with overwrite
        false, which fails rather than replacing an existing file. A collision is
        handled by allocating a different name and trying again - never by
        overwriting - and when no name can be had, the copy fails loudly so the
        caller keeps the original rather than replacing something it could not
        preserve.

        A destination that already holds exactly these bytes is the one case that
        needs no write: the file is already preserved, and saying so is what stops
        a repeated save from leaving a pile of identical copies.
    .PARAMETER Path
        The file to preserve.
    .PARAMETER Directory
        The directory to write the copy into.
    .PARAMETER Name
        The preferred file name for the copy.
    .PARAMETER MaxAttempts
        How many names to try before giving up. Default 5.
    .OUTPUTS
        System.Collections.Hashtable with keys path and created.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a new file and never replaces one; it is the preservation step of an atomic store write.')]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$Name,

        [int]$MaxAttempts = 5
    )

    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()

    $holdsSameBytes = {
        param([string]$Candidate)
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $false }
        try { (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash.ToLowerInvariant() -eq $hash }
        catch { $false }
    }

    $candidate = Join-Path $Directory $Name
    for ($attempt = 0; $attempt -lt [Math]::Max(1, $MaxAttempts); $attempt++) {
        # A cheap look first, so the common "already preserved" case costs one
        # hash instead of a failed copy. It is an optimisation, not the guarantee.
        if (& $holdsSameBytes $candidate) { return @{ path = $candidate; created = $false } }

        try {
            # The guarantee: create-new semantics. Throws if anything is already
            # there, including something that arrived since the look above.
            [System.IO.File]::Copy($Path, $candidate, $false)
            return @{ path = $candidate; created = $true }
        }
        catch [System.IO.IOException] {
            $collision = $_
            Write-Verbose "Could not create '$candidate' ($($collision.Exception.Message)); trying another name."
            if (& $holdsSameBytes $candidate) { return @{ path = $candidate; created = $false } }
            # Allocate only - never retry the same name, and never overwrite.
            $candidate = Get-DpUniqueFilePath -Directory $Directory -Name $Name
        }
    }

    throw "'$Path' could not be preserved: no free name for '$Name' was available in '$Directory'."
}
