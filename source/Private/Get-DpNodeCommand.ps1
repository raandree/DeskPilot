function Get-DpNodeCommand {
    <#
    .SYNOPSIS
        Locates a usable Node.js runtime, or reports that there is none.
    .DESCRIPTION
        Its own function so the browser runtime check has one seam to probe and
        the tests have one thing to replace. DeskPilot does not bundle Node and
        never installs it silently: an executable runtime arriving without the
        user asking is precisely what the security model forbids, so absence is
        reported and acted on by the user.

        Returns $null rather than throwing. A missing Node is an ordinary state
        for a Permission that ships off, not an error.
    .OUTPUTS
        System.Collections.Hashtable, or $null when Node is not installed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $command = Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) { return $null }

    $version = ''
    try { $version = (& $command.Source '--version' 2>&1 | Out-String).Trim() }
    catch { return $null }

    $major = 0
    if ($version -match '^v?(\d+)\.') { $major = [int]$Matches[1] }

    @{ path = $command.Source; version = $version; major = $major }
}
