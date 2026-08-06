function Get-DpChangeEntry {
    <#
    .SYNOPSIS
        Reads a Project's pending AI change-set entries from the store.
    .DESCRIPTION
        The store is keyed by the normalized Project folder, so every caller has to
        normalize the same way; this is that one place. Returns an empty array when
        the Project has nothing pending. Never throws.
    .PARAMETER Store
        The change set, keyed by normalized Project folder.
    .PARAMETER Root
        The Project (Workspace) folder.
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store,

        [string]$Root
    )

    # The comma keeps the array intact: PowerShell would otherwise unroll it and a
    # single entry (or none) would reach the caller as one object (or $null).
    if ([string]::IsNullOrWhiteSpace($Root)) { return , @() }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { return , @() }
    $key = $rootFull.TrimEnd('\', '/')
    if (-not $Store.ContainsKey($key)) { return , @() }
    , @($Store[$key])
}
