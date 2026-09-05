function Resolve-DpBrowserUrlDecision {
    <#
    .SYNOPSIS
        Classifies one URL against the current browser run's scope.
    .DESCRIPTION
        The load-bearing boundary of contained browser automation (decision
        0003), and the analogue of Test-DpCommandSafe for the terminal: it is
        written to be wrong only in the safe direction. Anything it does not
        positively recognise is refused or escalated, never allowed.

        Three outcomes, and the difference between the last two is the whole
        design:

        - **allow** - an https URL on a host already in scope. Proceeds silently.
        - **ask** - a well-formed https URL somewhere else. The user sees the
          full URL and decides, for this run only. This is the answer to "nobody
          can list the permitted domains in advance": the scope is derived from
          the URL the task already names, and every departure is a decision made
          with the real address in view.
        - **deny** - never approvable, so no card is offered. A card the user
          could say yes to would be a hole, not a control.

        What is denied outright, and why each one is not merely off-scope:

        - **Any scheme but https.** `file:` reads the disk the browser exists not
          to reach; `javascript:` and `data:` execute attacker text with the
          current page's authority; `blob:`, `view-source:` and `chrome:` have no
          host to scope at all. Plain `http` is refused because a network
          attacker rewrites the page the user is about to be shown.
        - **Userinfo in the URL.** `https://user:secret@host` is a credential in
          a string the Model chose. The secret is stripped before this function
          returns, so it cannot reach a card, a log or a transcript.
        - **IP literals.** A public site is reached by name. An IP literal in a
          Model-chosen URL evades a host-based allow-list by construction, and
          the private ranges among them - loopback, RFC1918, link-local - reach
          DeskPilot's own API and the cloud metadata service. This check runs
          **before** the scope match, so a Project cannot re-open the path by
          adding `127.0.0.1` to its list.
        - **Single-label hosts.** `https://intranet/` resolves through the
          machine's search domains to something inside the network.

        The scope match is on a label boundary, never a suffix: `weathercity.com`
        must not authorise `evilweathercity.com` or `weathercity.com.evil.test`.
    .PARAMETER Url
        The URL to classify, as the Model proposed it.
    .PARAMETER Scope
        Host entries currently in scope. A URL matches an entry when its host
        equals the entry or is a subdomain of it.
    .OUTPUTS
        System.Collections.Hashtable with decision, reason, host and url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Url,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Scope
    )

    $refuse = {
        param([string]$Reason, [string]$SafeUrl = '', [string]$HostName = '')
        @{ decision = 'deny'; reason = $Reason; host = $HostName; url = $SafeUrl }
    }

    if ([string]::IsNullOrWhiteSpace($Url)) { return (& $refuse 'empty') }

    # Bounded before parsing: a URL this long is a payload wearing an address.
    if ($Url.Length -gt 4096) { return (& $refuse 'too-long') }

    # Rejected explicitly rather than left to the parser, which may normalise a
    # newline away and hand back something that looks harmless.
    if ($Url -match '[\x00-\x1f\x7f]') { return (& $refuse 'control-character') }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return (& $refuse 'unparseable')
    }

    if ($uri.Scheme -ne 'https') { return (& $refuse 'scheme') }

    $hostName = $uri.DnsSafeHost
    if ([string]::IsNullOrWhiteSpace($hostName)) { return (& $refuse 'no-host') }
    # The root label's trailing dot is legal and resolves identically, so it is
    # normalised away rather than allowed to miss a scope entry.
    $hostName = $hostName.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($hostName)) { return (& $refuse 'no-host') }

    # Rebuilt without userinfo so a password in the URL cannot travel onward in
    # the decision, whatever the caller does with it.
    $safeUrl = if ($uri.UserInfo) { '{0}://{1}{2}' -f $uri.Scheme, $uri.Authority, $uri.PathAndQuery } else { $Url }

    if ($uri.UserInfo) { return (& $refuse 'userinfo' $safeUrl $hostName) }

    $address = $null
    if ([System.Net.IPAddress]::TryParse($hostName, [ref]$address)) {
        return (& $refuse 'ip-literal' $safeUrl $hostName)
    }

    if ($hostName -notmatch '\.') { return (& $refuse 'single-label-host' $safeUrl $hostName) }
    if ($hostName.EndsWith('.localhost') -or $hostName.EndsWith('.local')) {
        return (& $refuse 'private-host' $safeUrl $hostName)
    }

    foreach ($entry in @($Scope)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $allowed = $entry.Trim().TrimEnd('.').ToLowerInvariant()
        if (-not $allowed) { continue }

        # The label boundary is the point: a plain suffix test would let
        # evilweathercity.com inherit weathercity.com's scope.
        if ($hostName -eq $allowed -or $hostName.EndsWith('.' + $allowed)) {
            return @{ decision = 'allow'; reason = 'in-scope'; host = $hostName; url = $safeUrl }
        }
    }

    @{ decision = 'ask'; reason = 'off-scope'; host = $hostName; url = $safeUrl }
}
