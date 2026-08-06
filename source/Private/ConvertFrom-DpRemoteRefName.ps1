function ConvertFrom-DpRemoteRefName {
    <#
    .SYNOPSIS
        Turns full remote ref names into '<remote>/<branch>', dropping remote HEAD.
    .DESCRIPTION
        Git's %(refname:short) abbreviates refs/remotes/origin/HEAD to plain
        'origin', so a filter on the short name cannot tell the remote's symbolic
        HEAD apart from a branch and the remote itself ends up listed as a Branch.
        This takes FULL ref names (%(refname)), drops every remote HEAD, and
        returns the '<remote>/<branch>' form the rest of DeskPilot uses. Anything
        that is not a remote ref is ignored. Never throws.
    .PARAMETER Line
        The raw output lines of a for-each-ref / branch -r listing.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Line
    )

    $prefix = 'refs/remotes/'
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in @($Line)) {
        if ($null -eq $raw) { continue }
        $ref = $raw.Trim()
        if (-not $ref.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        if ($ref.EndsWith('/HEAD', [System.StringComparison]::Ordinal)) { continue }
        $name = $ref.Substring($prefix.Length)
        if ($name) { $names.Add($name) }
    }
    $names.ToArray()
}
