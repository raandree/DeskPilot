function Get-DpBrowserScope {
    <#
    .SYNOPSIS
        Builds the host scope for one browser run.
    .DESCRIPTION
        Scope has exactly three sources, and the order of trust is the point:

        1. **The starting URL's host.** The task already names where it is going,
           so the common case needs no configuration at all. The Osorno workflow
           never leaves weathercity.com and never raises a card.
        2. **The Project's own list.** Durable, and widened only from Settings -
           never from a button beside an approval card, for the reason decision
           0008 gives about safeCommands: "always allow this" next to a prompt is
           the button a tired operator presses.
        3. **Hosts granted during this run.** They expire with the run.

        Scope is the host plus its subdomains, deliberately not the registered
        domain (eTLD+1). Deriving eTLD+1 correctly needs the Public Suffix List,
        and guessing it treats `co.uk` as one organisation. Starting from the
        host is narrower than the truth rather than wider, which is the safe
        direction, and a redirect to a sibling host simply raises one card.

        An entry that is not a usable hostname is dropped rather than throwing:
        this runs per Turn, and a stale Project row must not break a run. Entries
        arriving from the API are validated at that boundary, where a bad value
        can still be reported.
    .PARAMETER StartUrl
        The URL the run begins at. Its host seeds the scope.
    .PARAMETER ProjectDomain
        Additional hosts the Project allows.
    .PARAMETER GrantedHost
        Hosts the user approved during this run.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$StartUrl,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ProjectDomain,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$GrantedHost
    )

    $scope = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $add = {
        param([string]$Candidate)
        if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
        $name = $Candidate.Trim().TrimEnd('.').ToLowerInvariant()
        # At least two labels, letters/digits/hyphens only, no leading or
        # trailing hyphen. Rejects wildcards, spaces, ports, paths and schemes.
        if ($name -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') { return }
        if ($seen.Add($name)) { $scope.Add($name) }
    }

    if (-not [string]::IsNullOrWhiteSpace($StartUrl)) {
        $uri = $null
        if ([System.Uri]::TryCreate($StartUrl, [System.UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') {
            & $add $uri.DnsSafeHost
        }
    }

    foreach ($domain in @($ProjectDomain)) { & $add $domain }
    foreach ($name in @($GrantedHost)) { & $add $name }

    , $scope.ToArray()
}
