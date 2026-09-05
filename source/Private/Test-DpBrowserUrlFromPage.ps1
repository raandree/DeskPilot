function Test-DpBrowserUrlFromPage {
    <#
    .SYNOPSIS
        Whether an address was authored by the user or offered by the page,
        rather than composed by the Model.
    .DESCRIPTION
        An in-scope host is not a blank cheque. The Model composes the entire
        address, so anything it invents on a site the user named carries the
        Model's context outward exactly as an off-scope navigation would - one
        hop shorter, and previously with no card at all.

        This test has now been wrong twice in the same shape, and both times the
        wrongness was written down as a reason:

        - "a bare path carries no payload beyond the path itself". The path *is*
          the payload, it is Model-composed, and it lands in the access log of
          the host doing the injecting. The fragment was excluded as "never
          leaves the browser" - it never leaves over the network, and
          `location.hash` reads it in full (NEW-001, 2026-09-05).
        - "the site root carries nothing". The site root carries the *host*, and
          scope matches on a label boundary, so every subdomain of an in-scope
          name was in scope and every subdomain *root* was treated as authored.
          That is roughly 200 bytes of Model-chosen data per navigation,
          delivered to a wildcard DNS server, with no card at either enforcement
          point (B3-1, 2026-09-05).

        So three things count as authored, and a host the Model chose is not
        among them:

        - the site **root of a host somebody else named** - the user's message,
          the Project's list, or an approval the user answered;
        - an address the user wrote in their own message;
        - an address that appeared as a link on the page just read, because
          following a link the site published tells that site nothing new.

        Everything else is the Model's own composition and is escalated.

        The comparison covers scheme, host, path, query and fragment. It does not
        also have to defend against percent-encoding games, because
        `Resolve-DpBrowserUrlDecision` rebuilds the address it hands onward and
        the browser is sent that rebuilt string rather than the Model's original.
    .PARAMETER Url
        The address the Model proposes.
    .PARAMETER Session
        The live session, whose last read page supplied the link set.
    .PARAMETER UserText
        The user's own message, so an address they typed is not queried back.
    .PARAMETER AuthoredHost
        Hosts named by somebody other than the Model: the Project's list and the
        hosts approved during this run. Their site roots are authored.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Url,

        [AllowNull()]
        [object]$Session,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserText,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$AuthoredHost
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }

    # Punycode, matching how scope and the approval card compare hosts.
    $hostOf = {
        param([System.Uri]$Candidate)
        $name = ''
        try { $name = $Candidate.IdnHost } catch { $name = '' }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $Candidate.DnsSafeHost }
        ([string]$name).Trim().TrimEnd('.').ToLowerInvariant()
    }

    # Everything the address carries, fragment included.
    $wanted = $uri.GetLeftPart([System.UriPartial]::Query) + $uri.Fragment

    $matchesCandidate = {
        param([string]$Candidate)
        $other = $null
        if (-not [System.Uri]::TryCreate($Candidate, [System.UriKind]::Absolute, [ref]$other)) { return $false }
        ($other.GetLeftPart([System.UriPartial]::Query) + $other.Fragment) -eq $wanted
    }

    $authored = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($AuthoredHost)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $null = $authored.Add($name.Trim().TrimEnd('.').ToLowerInvariant())
    }

    # An address the user wrote matches outright, and also names its host.
    foreach ($candidate in @(Get-DpBrowserUserUrl -Text $UserText)) {
        if (& $matchesCandidate $candidate) { return $true }
        $other = $null
        if ([System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$other)) {
            $null = $authored.Add((& $hostOf $other))
        }
    }

    $bare = $uri.AbsolutePath -in @('', '/') -and
        [string]::IsNullOrEmpty($uri.Query) -and [string]::IsNullOrEmpty($uri.Fragment)
    if ($bare -and $authored.Contains((& $hostOf $uri))) { return $true }

    if ($null -eq $Session) { return $false }
    foreach ($link in @($Session.pageLinks)) {
        if (& $matchesCandidate ([string]$link)) { return $true }
    }

    $false
}
