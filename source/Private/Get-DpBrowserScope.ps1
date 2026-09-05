function Get-DpBrowserScope {
    <#
    .SYNOPSIS
        Builds the host scope for one browser run.
    .DESCRIPTION
        Scope has exactly three sources, and the order of trust is the point:

        1. **Complete `https://` addresses present in the user's own message.**
           It used to be seeded from the first URL the *Model* chose, which gave
           every Turn one free, unapproved navigation to any host on the internet
           (Blocker B-1, 2026-09-05).

           Only complete `https://` URLs count. A bare token that merely looks
           like a host was tried and withdrawn: `.md`, `.sh`, `.py`, `.io`, `.ai`
           and `.co` are all registrable, so `README.md` and `install.sh` in an
           ordinary prompt became authorised hosts an attacker can pre-register,
           and a trailing slash made the match backtrack a label so
           `news.bbc.co.uk/weather` authorised `news.bbc.co` while not
           authorising the site the user actually named.

           **Present in, not typed by.** An earlier version of this description
           claimed the scheme requirement also stopped pasted text from
           authorising a host. It does not, and cannot: a prompt is one string,
           and a URL a user pasted in a stack trace is indistinguishable from one
           they typed (B3-2, 2026-09-05). The property that does hold is that the
           host appeared in the message the user sent - so they could see it - and
           everything reached through that host is still bounded by the deny rules
           below, by per-address provenance, and by an approval card for anything
           the Model composes itself.

           A candidate seeds scope only if `Resolve-DpBrowserUrlDecision` would be
           willing to raise a card for it. A form it refuses outright must not
           become a silent permanent grant instead, which is what
           `https://good.example@evil.test/` did: never approvable, and it read as
           `good.example` to anyone skimming their own message (B3-3).
        2. **The Project's own list.** Durable, and widened only from Settings -
           never from a button beside an approval card, for the reason decision
           0008 gives about safeCommands: "always allow this" next to a prompt is
           the button a tired operator presses.
        3. **Hosts granted during this run.** They expire with the run.

        Anything else raises a card. That costs one approval on a task whose site
        the user did not name, and removes the free hop entirely.

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
        The user's own message. Complete `https://` addresses in it seed the
        scope; nothing else in the text does.
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

    foreach ($candidate in @(Get-DpBrowserUserUrl -Text $StartUrl)) {
        # Seeded only if the classifier would be willing to raise a card for it.
        # A form it refuses outright must not become a silent permanent grant.
        $decision = Resolve-DpBrowserUrlDecision -Url $candidate -Scope @()
        if ($decision.decision -ne 'deny') { & $add $decision.host }
    }

    foreach ($domain in @($ProjectDomain)) { & $add $domain }
    foreach ($name in @($GrantedHost)) { & $add $name }

    $scope.ToArray()
}
