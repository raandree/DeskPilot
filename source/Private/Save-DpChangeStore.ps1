function Save-DpChangeStore {
    <#
    .SYNOPSIS
        Persists the pending AI change set atomically.
    .DESCRIPTION
        Writes the change set to changes.json via a temp file plus a forced move,
        the same way every other DeskPilot store is written, so a crash mid-write
        cannot leave a half-file that would lose the record of what the AI did.
        Never throws.
    .PARAMETER Store
        The change set, keyed by normalized Project folder.
    .PARAMETER Directory
        The per-user data directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not $PSCmdlet.ShouldProcess($Directory, 'Save the DeskPilot change set')) { return }

    try {
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop
        }
        $path = Join-Path $Directory 'changes.json'
        $temp = "$path.tmp"
        ($Store | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $temp -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
    }
    catch { $null = $_ }
}
