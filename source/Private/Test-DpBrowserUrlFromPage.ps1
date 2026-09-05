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

        The first version of this test compared only scheme, host and path, and
        waved through any URL with no query and no fragment on the reasoning that
        "a bare path carries no payload beyond the path itself". That sentence
        refutes itself: the path *is* a payload, it is Model-composed, and it
        lands in the access log of the host doing the injecting. The fragment was
        excluded on the reasoning that it "never leaves the browser" - it never
        leaves over the network, and `location.hash` reads it in full. Both were
        found exploitable end to end (NEW-001, 2026-09-05), so the comparison now
        covers path, query **and** fragment.

        Three things count as authored:

        - the site root, which carries nothing;
        - an address the user wrote in their own message;
        - an address that appeared as a link on the page just read, because
          following a link the site published tells that site nothing new.

        Everything else is the Model's own composition and is escalated.
    .PARAMETER Url
        The address the Model proposes.
    .PARAMETER Session
        The live session, whose last read page supplied the link set.
    .PARAMETER UserText
        The user's own message, so an address they typed is not queried back.
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
        [string]$UserText
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }

    # The site root carries nothing: no path, no query, no fragment.
    $bare = $uri.AbsolutePath -in @('', '/') -and
        [string]::IsNullOrEmpty($uri.Query) -and [string]::IsNullOrEmpty($uri.Fragment)
    if ($bare) { return $true }

    # Everything the address carries, fragment included.
    $wanted = $uri.GetLeftPart([System.UriPartial]::Query) + $uri.Fragment

    $matchesCandidate = {
        param([string]$Candidate)
        $other = $null
        if (-not [System.Uri]::TryCreate($Candidate, [System.UriKind]::Absolute, [ref]$other)) { return $false }
        ($other.GetLeftPart([System.UriPartial]::Query) + $other.Fragment) -eq $wanted
    }

    if (-not [string]::IsNullOrWhiteSpace($UserText)) {
        $text = if ($UserText.Length -gt 8000) { $UserText.Substring(0, 8000) } else { $UserText }
        foreach ($match in [regex]::Matches($text, 'https://[^\s"''<>)\]]+')) {
            if (& $matchesCandidate $match.Value) { return $true }
        }
    }

    if ($null -eq $Session) { return $false }
    foreach ($link in @($Session.pageLinks)) {
        if (& $matchesCandidate ([string]$link)) { return $true }
    }

    $false
}
