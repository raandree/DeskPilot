function Test-DpBrowserUrlFromPage {
    <#
    .SYNOPSIS
        Whether an address was offered by the page rather than composed by the Model.
    .DESCRIPTION
        An in-scope host is not a blank cheque. The Model composes the entire
        address, so a query string it invented on a site the user named carries
        the Model's context outward exactly as an off-scope navigation would -
        one hop shorter, and previously with no card at all. This is the
        same-origin half of Blocker B-1 from the security review of 2026-09-05.

        The test is provenance, not content: an address that appeared as a link
        on the page just read was authored by the site, so following it tells the
        site nothing it did not already know. Anything else is the Model's own
        composition and is escalated to an approval.

        A URL with no query and no fragment is treated as page-offered. A bare
        path on an in-scope host carries no payload beyond the path itself, and
        refusing those would raise a card on ordinary navigation and train the
        user to click through - the failure decision 0008 records at length.

        Comparison ignores the fragment, which never leaves the browser, and is
        done on the normalised absolute URI so trivial encoding differences do
        not manufacture a card.
    .PARAMETER Url
        The address the Model proposes.
    .PARAMETER Session
        The live session, whose last read page supplied the link set.
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
        [object]$Session
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }

    # Nothing to carry: no query, no fragment.
    if ([string]::IsNullOrEmpty($uri.Query) -and [string]::IsNullOrEmpty($uri.Fragment)) { return $true }

    if ($null -eq $Session) { return $false }
    $links = @($Session.pageLinks)
    if ($links.Count -eq 0) { return $false }

    $wanted = $uri.GetLeftPart([System.UriPartial]::Query)
    foreach ($link in $links) {
        $candidate = $null
        if (-not [System.Uri]::TryCreate([string]$link, [System.UriKind]::Absolute, [ref]$candidate)) { continue }
        if ($candidate.GetLeftPart([System.UriPartial]::Query) -eq $wanted) { return $true }
    }

    $false
}
