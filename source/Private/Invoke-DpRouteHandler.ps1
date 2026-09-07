function Invoke-DpRouteHandler {
    <#
    .SYNOPSIS
        Executes the named API route handler and writes its response.
    .DESCRIPTION
        Implements every DeskPilot API route. JSON routes write their response
        directly; the streaming routes (authStart, postMessage) hand off to the
        SSE runners.
    .PARAMETER Name
        The route name from the route table.
    .PARAMETER RouteParams
        Captured path parameters (for example the Conversation id).
    .PARAMETER Body
        The parsed JSON request body, or $null.
    .PARAMETER Stream
        The network stream to write the response to.
    .PARAMETER Request
        The raw request hashtable (Headers, BodyBytes); used by handlers that
        need the raw bytes (for example the multipart Upload handler).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [hashtable]$RouteParams = @{},

        [object]$Body,

        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [hashtable]$Request
    )

    $state = $script:DeskPilot

    if ($Name -in @('regenerateTurn', 'editTurn')) {
        $conversation = $state.Conversations[$RouteParams.id]
        if ($conversation) {
            $target = if ($Name -eq 'regenerateTurn') {
                @($conversation.messages | Where-Object { $_.role -eq 'user' }) | Select-Object -Last 1
            } else {
                $messageId = [string](Get-DpPropertyValue -InputObject $Body -Name 'messageId' -Default '')
                @($conversation.messages | Where-Object { $_.id -ceq $messageId }) | Select-Object -First 1
            }
            if ($target -and (Get-DpPropertyValue -InputObject $target -Name 'childRunId')) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'child_consent_required'; message = 'Start a new private child with explicit consent; this task cannot fall back to an ordinary Turn.' } }
                return
            }
        }
    }

    switch ($Name) {
        'health' {
            Write-DpResponse -Stream $Stream -Json @{
                status           = 'ok'
                version          = $state.Version
                engineImported   = $state.Engine.Imported
                engineError      = $state.Engine.ImportError
                authenticated    = (Test-Path -LiteralPath $state.Engine.TokenPath)
                model            = $state.Settings.model
                engineModulePath = $state.Engine.ModulePath
            }
        }
        'getDiagnostics' {
            [long]$afterSequence = 0
            $afterText = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('after')) { [string]$Request.Query['after'] } else { '0' }
            if (-not [long]::TryParse($afterText, [ref]$afterSequence) -or $afterSequence -lt 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_cursor'; message = 'The diagnostics log cursor must be a non-negative integer.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpDiagnosticPayload -AfterSequence $afterSequence)
        }
        'getChildReadiness' {
            Update-DpChildPreparation
            $child = Get-DpPropertyValue -InputObject $state -Name 'Child' -Default @{}
            $readiness = Get-DpChildReadiness -Settings $state.Settings -Runtime $child.Runtime -Proof $child.Proof -Health $child.Health -CleanupBlocked:([bool]$child.CleanupBlocked)
            $readiness.preparing = [bool]$child.SetupJob
            $readiness.operationError = $child.Error
            Write-DpResponse -Stream $Stream -Json $readiness
        }
        { $_ -in @('prepareChildRuntime', 'checkChildRuntime', 'cleanupChildRuntime', 'removeChildRuntime') } {
            $action = switch ($Name) { 'prepareChildRuntime' { 'prepare' }; 'checkChildRuntime' { 'check' }; 'cleanupChildRuntime' { 'cleanup' }; 'removeChildRuntime' { 'remove' } }
            try {
                $started = Start-DpChildPreparation -Action $action
                Write-DpResponse -Stream $Stream -Status $(if ($started) { 202 } else { 409 }) -Json @{ preparing = $started }
            } catch {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'child_runtime_busy'; message = 'Stop active work before child preparation or cleanup.' } }
            }
        }
        'startChildRun' {
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'An active Turn already owns execution.' } }
                return
            }
            $child = Get-DpPropertyValue -InputObject $state -Name 'Child' -Default @{}
            $readiness = Get-DpChildReadiness -Settings $state.Settings -Runtime $child.Runtime -Proof $child.Proof -Health $child.Health -CleanupBlocked:([bool]$child.CleanupBlocked)
            if ($readiness.ready -and $readiness.enabled) {
                $conversation = $state.Conversations[$RouteParams.id]
                if (-not $conversation) {
                    Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                    return
                }
                try {
                    $started = Start-DpChildRun -Conversation $conversation -Body $Body
                    Write-DpResponse -Stream $Stream -Status 202 -Json $started
                } catch {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'child_admission_refused'; message = 'Child consent, selected Model, scope, or current runtime proof is invalid.' } }
                }
                return
            }
            $status = if ($readiness.enabled) { 503 } else { 403 }
            $code = if ($readiness.enabled) { 'child_profile_unavailable' } else { 'child_profile_disabled' }
            Write-DpResponse -Stream $Stream -Status $status -Json @{
                error = @{ code = $code; message = $readiness.message }
                readiness = $readiness
            }
        }
        { $_ -in @('getChildRun', 'getChildEvents', 'getChildProposal') } {
            try {
                $record = Get-DpChildRunRecord -ConversationId $RouteParams.id -Id $RouteParams.childId -Proposal:($Name -eq 'getChildProposal')
                if (-not $record) {
                    Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Child run not found in this Conversation.' } }
                    return
                }
                if ($Name -eq 'getChildEvents') { $record = @{ id = $record.id; events = @($record.events) } }
                Write-DpResponse -Stream $Stream -Json $record
            } catch {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'child_data_unavailable'; message = 'The bounded child record or proposal is unavailable.' } }
            }
        }
        { $_ -in @('approveChildRun', 'stopChildRun') } {
            $child = Get-DpPropertyValue -InputObject $state -Name 'Child' -Default @{}
            $controller = $child.Controller
            if (-not $controller -or $controller.Id -cne $RouteParams.childId -or $controller.ConversationId -cne $RouteParams.id) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Active child run not found in this Conversation.' } }
                return
            }
            if ($Name -eq 'stopChildRun') {
                $controller.Stop()
                Write-DpResponse -Stream $Stream -Status 202 -Json @{ stopping = $true }
                return
            }
            $approvalId = [string](Get-DpPropertyValue -InputObject $Body -Name 'approvalId' -Default '')
            $fingerprint = [string](Get-DpPropertyValue -InputObject $Body -Name 'fingerprint' -Default '')
            $decision = [string](Get-DpPropertyValue -InputObject $Body -Name 'decision' -Default '')
            if ($decision -cnotin @('approve', 'deny') -or $fingerprint -cnotmatch '^[a-f0-9]{64}$' -or
                -not $controller.SubmitApproval($RouteParams.id, $RouteParams.childId, $approvalId, $fingerprint, ($decision -ceq 'approve'))) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'stale_child_approval'; message = 'This exact child action is not awaiting a decision.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Status 202 -Json @{ accepted = $true }
        }
        'runDiagnosticCheck' {
            $started = Start-DpDiagnosticCheck
            if ($started.alreadyRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'check_running'; message = 'A diagnostics self-check is already running.' } }
                return
            }
            if (-not $started.started) {
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'check_failed'; message = $started.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Status 202 -Json (Get-DpDiagnosticPayload)
        }
        'clearDiagnosticLog' {
            $removed = Clear-DpDiagnosticLog -Log $state.Diagnostics.Log
            Write-DpResponse -Stream $Stream -Json @{
                cleared = $removed
                latestSequence = [long]$state.Diagnostics.Log.NextSequence
            }
        }
        { $_ -in @('getTerminalRuntime', 'checkTerminalRuntime', 'installTerminalRuntime', 'cleanupTerminalRuntime', 'uninstallTerminalRuntime') } {
            if ($Name -ne 'getTerminalRuntime' -and ($state.TurnRunning -or ($state.TerminalSetupJob -and $state.TerminalSetupJob.State -in @('NotStarted', 'Running')))) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'Stop the active Turn or wait for runtime preparation before changing the Terminal runtime.' } }
                return
            }
            try {
                switch ($Name) {
                    'checkTerminalRuntime' { $state.TerminalRuntime = Get-DpTerminalRuntime -DataDirectory $state.DataDir -Probe }
                    'installTerminalRuntime' { $null = Start-DpTerminalPreparation }
                    'cleanupTerminalRuntime' {
                        $null = Remove-DpTerminalRuntime -DataDirectory $state.DataDir -Confirm:$false
                        $state.TerminalRuntime = Get-DpTerminalRuntime -DataDirectory $state.DataDir -Probe
                    }
                    'uninstallTerminalRuntime' {
                        $null = Remove-DpTerminalRuntime -DataDirectory $state.DataDir -Uninstall -Confirm:$false
                        $state.TerminalRuntime = $null
                    }
                }
                Write-DpResponse -Stream $Stream -Status $(if ($Name -eq 'installTerminalRuntime') { 202 } else { 200 }) -Json (Get-DpTerminalStatus)
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'terminal_runtime_failed'; message = 'The Terminal runtime operation failed. Check Docker Desktop and retry; execution mode was not changed.' } }
            }
        }
        'installBrowserRuntime' {
            # The consent gate for downloading a browser engine. It is reachable
            # only from this user-initiated route: no Turn, Tool or Model path
            # leads here, because acquiring an executable without being asked is
            # what the security model forbids outright.
            $result = Install-DpBrowserRuntime -Confirm:$false
            if (-not $result.installed) {
                Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'error' -Component 'browser' `
                    -EventId 'browser.install.failed' -Summary $result.error
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'browser_install_failed'; message = $result.error } }
                return
            }
            Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'information' -Component 'browser' `
                -EventId 'browser.install.completed' -Summary "Browser automation was set up with Playwright $($result.runtime.pinnedVersion)."
            Write-DpResponse -Stream $Stream -Status 201 -Json @{
                ok = $true
                pinnedVersion = [string]$result.runtime.pinnedVersion
                nodeVersion = [string]$result.runtime.nodeVersion
                ready = [bool]$result.runtime.ready
            }
        }
        'cleanupBrowserRuntime' {
            $runtime = Get-DpBrowserRuntime
            $result = Remove-DpBrowserOrphan -RuntimeRoot $runtime.runtimeRoot -Confirm:$false
            Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'information' -Component 'browser' `
                -EventId 'browser.cleanup' -Summary "Closed $($result.closed) of $($result.found) leftover browser process(es)."
            Write-DpResponse -Stream $Stream -Json @{
                ok = ($result.failed.Count -eq 0)
                found = [int]$result.found
                closed = [int]$result.closed
                failed = @($result.failed)
            }
        }
        'uninstallBrowserRuntime' {
            $runtime = Get-DpBrowserRuntime
            $result = Uninstall-DpBrowserRuntime -RuntimeRoot $runtime.runtimeRoot -Confirm:$false
            if (-not $result.removed -and -not $result.alreadyAbsent) {
                Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'error' -Component 'browser' `
                    -EventId 'browser.uninstall.failed' -Summary $result.error
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'browser_uninstall_failed'; message = $result.error } }
                return
            }
            Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'information' -Component 'browser' `
                -EventId 'browser.uninstall.completed' -Summary 'The downloaded browser runtime was removed.'
            Write-DpResponse -Stream $Stream -Json @{ ok = $true; removed = [bool]$result.removed; alreadyAbsent = [bool]$result.alreadyAbsent }
        }
        'exportSupportBundle' {
            if ($state.Diagnostics.Exporting) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'export_running'; message = 'A support bundle is already being created.' } }
                return
            }
            if (-not $state.DataDir) {
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'no_data_directory'; message = 'No DeskPilot data directory is available for the support bundle.' } }
                return
            }

            $state.Diagnostics.Exporting = $true
            try {
                $bundle = New-DpSupportBundle -Directory $state.DataDir -Confirm:$false
            }
            finally {
                $state.Diagnostics.Exporting = $false
            }
            if (-not $bundle.ok) {
                $status = if ($bundle.code -in @('outside_destination', 'redirected_destination', 'already_exists', 'too_large', 'invalid_data_directory')) { 400 } else { 500 }
                Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'error' -Component 'diagnostics' `
                    -EventId 'support-bundle.failed' -Summary $bundle.error
                Write-DpResponse -Stream $Stream -Status $status -Json @{ error = @{ code = $bundle.code; message = $bundle.error } }
                return
            }
            $state.Diagnostics.LastExport = @{
                path = [string]$bundle.path
                createdUtc = [string]$bundle.createdUtc
                bytes = [long]$bundle.bytes
            }
            Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'information' -Component 'diagnostics' `
                -EventId 'support-bundle.created' -Summary "A redacted support bundle was created as '$($bundle.name)'."
            Write-DpResponse -Stream $Stream -Status 201 -Json @{
                ok = $true
                path = $bundle.path
                name = $bundle.name
                createdUtc = $bundle.createdUtc
                bytes = $bundle.bytes
                uncompressedBytes = $bundle.uncompressedBytes
                entries = $bundle.entries
            }
        }
        'authStatus' {
            Write-DpResponse -Stream $Stream -Json @{ authenticated = (Test-Path -LiteralPath $state.Engine.TokenPath) }
        }
        'authStart' {
            # force=true re-runs the device flow even when a stale token file is
            # present (an expired sign-in), so a re-auth actually replaces it.
            $force = [bool](Get-DpPropertyValue -InputObject $Body -Name @('force') -Default $false)
            Invoke-DpAuthFlow -Stream $Stream -Force:$force
        }
        'models' {
            try {
                $models = Invoke-DpEngineCommand -Command 'Get-ShpModel'
                $default = $null
                try { $default = Invoke-DpEngineCommand -Command 'Get-ShpDefault' | Select-Object -First 1 } catch { $null = $_ }
                $list = foreach ($model in $models) {
                    @{
                        id                     = [string](Get-DpPropertyValue -InputObject $model -Name @('Id', 'id', 'Name') -Default '')
                        maxContextWindowTokens = [int](Get-DpPropertyValue -InputObject $model -Name @('MaxContextWindowTokens', 'ContextWindow', 'MaxContextWindow') -Default 0)
                        maxOutputTokens        = [int](Get-DpPropertyValue -InputObject $model -Name @('MaxOutputTokens', 'MaxOutput') -Default 0)
                        reasoningEfforts       = @(Get-DpPropertyValue -InputObject $model -Name @('ReasoningEfforts') -Default @())
                        vision                 = [bool](Get-DpPropertyValue -InputObject $model -Name @('Vision', 'SupportsVision') -Default $false)
                    }
                }
                $defaultId = if ($default -is [string]) { $default } else { [string](Get-DpPropertyValue -InputObject $default -Name @('Id', 'Model', 'Name') -Default $state.Settings.model) }
                # DeskPilot's own preference wins whenever the Engine advertises it;
                # the Engine's default is the fallback, so an id this account cannot
                # use is never handed back as the default.
                $modelIds = @($list | ForEach-Object { $_.id })
                if ($state.PreferredModel -and $modelIds -contains $state.PreferredModel) { $defaultId = $state.PreferredModel }
                # Cache the capability list so a Turn can send -ReasoningEffort only
                # to a Model that advertises support (see Get-DpModelReasoningEfforts).
                $state.Models = @($list)
                $state.DefaultModel = $defaultId
                Write-DpResponse -Stream $Stream -Json @{ default = $defaultId; models = @($list) }
            }
            catch {
                # An expired or missing GitHub token surfaces here as a 401/403
                # while the Engine exchanges the token. Answer with an actionable
                # auth_required so the UI can re-trigger the device-code flow,
                # rather than a generic engine error the user cannot act on.
                if (Test-DpAuthError -ErrorRecord $_) {
                    Write-DpResponse -Stream $Stream -Status 401 -Json @{ error = @{ code = 'auth_required'; reauth = $true; message = 'Your GitHub Copilot sign-in has expired or is missing. Sign in again to continue.' } }
                }
                else {
                    Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'engine_unavailable'; message = "Could not list models: $_" } }
                }
            }
        }
        'getSettings' {
            Write-DpResponse -Stream $Stream -Json $state.Settings
        }
        'getTranscript' {
            # No new access path: this is an /api/ route like every other, so it is
            # loopback-bound and session-token gated by Invoke-DpRequest before it
            # is reached.
            $conversationId = [string]$Request.Query['conversationId']
            $messageId = [string]$Request.Query['messageId']
            if (-not $conversationId -or -not $messageId) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'conversationId and messageId are required.' } }
                return
            }
            if (-not $state.DataDir) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'no_data_dir'; message = 'No data directory is configured, so no transcript was recorded.' } }
                return
            }
            $transcript = Read-DpTranscript -Directory $state.DataDir -ConversationId $conversationId -MessageId $messageId
            if (-not $transcript.ok) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'no_transcript'; message = $transcript.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{
                path       = $transcript.path
                records    = @($transcript.records)
                unreadable = $transcript.unreadable
            }
        }
        'putSettings' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A Settings body is required.' } }
                return
            }
            try {
                $merged = Merge-DpSettings -Current $state.Settings -Patch $Body
                $previous = $state.Settings
                $scopeChanged = $previous.selectedProjectId -cne $merged.selectedProjectId -or
                    $previous.workspaceFolder -cne $merged.workspaceFolder -or
                    $previous.perCallApproval -ne $merged.perCallApproval -or
                    ($previous.permissions.terminal -and -not $merged.permissions.terminal) -or
                    ($previous.permissions.userTools -and -not $merged.permissions.userTools)
                foreach ($key in $merged.terminalExecution.Keys) {
                    if (($previous.terminalExecution[$key] | ConvertTo-Json -Depth 6 -Compress) -cne
                        ($merged.terminalExecution[$key] | ConvertTo-Json -Depth 6 -Compress)) { $scopeChanged = $true }
                }
                $state.Settings = $merged
                if ($state.TurnRunning -and $scopeChanged) {
                    $engine = Get-DpPropertyValue -InputObject $state -Name 'Engine'
                    $approvalBridge = Get-DpPropertyValue -InputObject $engine -Name 'ApprovalBridge'
                    if ($approvalBridge) { $approvalBridge.Cancel() }
                    $state.PendingApproval = $null
                }
                if ($state.DataDir) { Save-DpSettings -Settings $merged -Directory $state.DataDir }
                Write-DpResponse -Stream $Stream -Json $merged
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_settings'; message = "$_" } }
            }
        }
        'agents' {
            # Resolve the effective Agents folder. When none is configured but the
            # conventional ~/.copilot/agents now exists (e.g. after CopilotAtelier
            # setup created the junction), adopt and persist it so the agents
            # appear - and a selected Agent reaches Turn assembly - without a
            # restart. A refresh (manual or the periodic client poll) picks this up.
            $root = Resolve-DpAgentsRoot -Settings $state.Settings
            if ($root -and $root -ne $state.Settings.agentsRoot) {
                $state.Settings.agentsRoot = $root
                if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }
            }
            $agentList = @(Get-DpAgentList -Root $root | ForEach-Object { @{ id = $_.id; name = $_.name; description = $_.description } })
            Write-DpResponse -Stream $Stream -Json @{ agents = $agentList; selected = $state.Settings.selectedAgent; root = $root }
        }
        'customizations' {
            Write-DpResponse -Stream $Stream -Json (Get-DpCustomizationList -Settings $state.Settings)
        }
        'createCustomization' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A category and name are required.' } }
                return
            }
            $category = [string](Get-DpPropertyValue -InputObject $Body -Name @('category') -Default '')
            $name = [string](Get-DpPropertyValue -InputObject $Body -Name @('name') -Default '')
            $root = [string](Get-DpPropertyValue -InputObject $Body -Name @('root') -Default '')
            try {
                $created = if ([string]::IsNullOrWhiteSpace($root)) {
                    New-DpCustomization -Settings $state.Settings -Category $category -Name $name
                }
                else {
                    New-DpCustomization -Settings $state.Settings -Category $category -Name $name -Root $root
                }
                Write-DpResponse -Stream $Stream -Status 201 -Json $created
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'create_failed'; message = "$_" } }
            }
        }
        'customizationContent' {
            $category = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('category')) { [string]$Request.Query['category'] } else { '' }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($category) -or [string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'A category and path are required.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpCustomizationContent -Settings $state.Settings -Category $category -Path $requested)
        }
        'saveCustomizationContent' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A category, path and text are required.' } }
                return
            }
            $category = [string](Get-DpPropertyValue -InputObject $Body -Name @('category') -Default '')
            $requested = [string](Get-DpPropertyValue -InputObject $Body -Name @('path') -Default '')
            $text = [string](Get-DpPropertyValue -InputObject $Body -Name @('text') -Default '')
            if ([string]::IsNullOrWhiteSpace($category) -or [string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'A category and path are required.' } }
                return
            }
            try {
                $saved = Save-DpCustomizationContent -Settings $state.Settings -Category $category -Path $requested -Text $text
                Write-DpResponse -Stream $Stream -Json $saved
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'save_failed'; message = "$_" } }
            }
        }
        'fsList' {
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            Write-DpResponse -Stream $Stream -Json (Get-DpDirectoryListing -Path $requested)
        }
        'fsTree' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            Write-DpResponse -Stream $Stream -Json (Get-DpDirectoryEntries -Root $root -Path $requested)
        }
        'fsFile' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_path'; message = 'A file path is required.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpFileContent -Root $root -Path $requested)
        }
        'fsImage' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_path'; message = 'A file path is required.' } }
                return
            }
            $image = Get-DpFileImage -Root $root -Path $requested
            if ($image.error) {
                $status = if ($image.code -eq 'not_found') { 404 } else { 400 }
                Write-DpResponse -Stream $Stream -Status $status -Json @{ error = @{ code = $image.code; message = $image.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Bytes $image.content -ContentType $image.mime
        }
        'fsOpen' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = [string](Get-DpPropertyValue -InputObject $Body -Name @('path') -Default '')
            if ([string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_path'; message = 'A file path is required.' } }
                return
            }
            $opened = Start-DpExternalFile -Root $root -Path $requested
            if ($opened.error) {
                $status = switch ($opened.code) {
                    'not_found' { 404 }
                    'executable' { 403 }
                    'open_failed' { 500 }
                    default { 400 }
                }
                Write-DpResponse -Stream $Stream -Status $status -Json @{ error = @{ code = $opened.code; message = $opened.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{ opened = $true; path = $opened.path; name = $opened.name; extension = $opened.extension }
        }
        'gitStatus' {
            Write-DpResponse -Stream $Stream -Json (Get-DpGitStatus -Path $state.Settings.workspaceFolder)
        }
        'gitInit' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $init = Invoke-DpGitCommand -Path $root -Arguments @('init')
            if (-not $init.Ok) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'git_init_failed'; message = "git init failed: $($init.StdErr.Trim())" } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpGitStatus -Path $root)
        }
        'gitCheckout' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            # Only allow switching to a branch that already exists, validated against
            # the live branch list (the process call already prevents shell injection).
            $status = Get-DpGitStatus -Path $root
            if (-not $status.isRepo) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_a_repo'; message = 'This project is not a Git repository.' } }
                return
            }
            if (@($status.branches) -notcontains $branch) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'unknown_branch'; message = "Unknown branch '$branch'." } }
                return
            }
            $checkout = Invoke-DpGitCommand -Path $root -Arguments @('checkout', $branch)
            if (-not $checkout.Ok) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'checkout_failed'; message = $checkout.StdErr.Trim() } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpGitStatus -Path $root)
        }
        'gitBranches' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $doFetch = $false
            if ($Request -and $Request.Query -and $Request.Query.ContainsKey('fetch')) {
                $fv = [string]$Request.Query['fetch']
                $doFetch = ($fv -eq '1' -or $fv -eq 'true')
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpBranchList -Path $root -Fetch:$doFetch)
        }
        'gitChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            # The optional filter is newline-separated: a path can contain a comma
            # or a semicolon on every supported platform, but never a newline.
            $rawPaths = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('paths')) { [string]$Request.Query['paths'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($rawPaths)) {
                Write-DpResponse -Stream $Stream -Json (Get-DpGitChanges -Root $root)
            }
            else {
                $wanted = @($rawPaths -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                Write-DpResponse -Stream $Stream -Json (Get-DpGitChanges -Root $root -Paths $wanted)
            }
        }
        'gitCommit' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $message = [string](Get-DpPropertyValue -InputObject $Body -Name @('message') -Default '')
            if ([string]::IsNullOrWhiteSpace($message)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_message'; message = 'A commit message is required.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            $commit = if ($paths.Count -gt 0) {
                Invoke-DpGitCommit -Root $root -Message $message -Paths $paths
            }
            else {
                Invoke-DpGitCommit -Root $root -Message $message
            }
            if ($commit.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'commit_failed'; message = $commit.error }; result = $commit }
                return
            }
            # A committed file is a reviewed file: leaving it in the pending set
            # would keep telling the user it still needs a decision after they
            # saved it, and would offer an undo that now contradicts history.
            $commit.kept = 0
            if ($commit.committed -and @($commit.files).Count -gt 0) {
                $cleared = Remove-DpChangeEntry -Store $state.Changes -Root $root -Paths @($commit.files)
                $commit.kept = $cleared.cleared
                if ($cleared.cleared -gt 0 -and $state.DataDir) { Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir }
            }
            Write-DpResponse -Stream $Stream -Json $commit
        }
        'gitCommitMessage' {
            # Suggest the one line the Save dialog asks for. A required free-text
            # field is exactly where the target user stalls, so the Model reads the
            # change set and writes it - on an explicit click, never automatically,
            # because it costs a Turn.
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            # This Turn shares the single Engine Runspace.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'turn_running'; message = 'Another task is running; wait for it to finish.' } }
                return
            }
            $changes = Get-DpGitChanges -Root $root
            if ($changes.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'changes_failed'; message = $changes.error } }
                return
            }
            if ($changes.fileCount -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'nothing_to_save'; message = 'Nothing has changed since the last save.' } }
                return
            }
            # Untracked files have no diff against HEAD, and an unborn HEAD has no
            # diff at all; the file list alone still describes those well enough.
            $diffResult = Invoke-DpGitCommand -Path $root -Arguments @('diff', 'HEAD', '--', '.')
            $diffText = if ($diffResult.Ok) { [string]$diffResult.StdOut } else { '' }
            $engineParams = @{
                Prompt             = New-DpCommitMessagePrompt -Files @($changes.files) -Diff $diffText
                DisableBrowsing    = $true
                DisableFileAccess  = $true
                DisableTerminal    = $true
                DisableUserPrompts = $true
                DisableUserTools   = $true
                DisableTodoList    = $true
            }
            if ($state.Settings.model) { $engineParams.Model = $state.Settings.model }
            $state.TurnRunning = $true
            try {
                $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
            }
            catch {
                $state.TurnRunning = $false
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'engine_error'; message = "The model could not suggest a description: $($_.Exception.Message)" } }
                return
            }
            $state.TurnRunning = $false
            $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
            # A commit subject is the same shape as a Conversation title - one clean
            # line, capped - so it goes through the same cleaner.
            $suggestion = ConvertFrom-DpTitleResult -Text $content -MaxWords 12 -MaxLength 72
            if ([string]::IsNullOrWhiteSpace($suggestion)) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'no_suggestion'; message = 'The model did not return a usable description.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{ message = $suggestion; fileCount = $changes.fileCount }
        }
        'gitBranchCreate' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branchName = [string](Get-DpPropertyValue -InputObject $Body -Name @('name') -Default '')
            $from = [string](Get-DpPropertyValue -InputObject $Body -Name @('from') -Default '')
            $checkout = [bool](Get-DpPropertyValue -InputObject $Body -Name @('checkout') -Default $true)
            $created = if ([string]::IsNullOrWhiteSpace($from)) {
                New-DpGitBranch -Root $root -Name $branchName -Checkout:$checkout
            }
            else {
                New-DpGitBranch -Root $root -Name $branchName -From $from -Checkout:$checkout
            }
            if ($created.error -and -not $created.created) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'branch_create_failed'; message = $created.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $created
        }
        'gitBranchDelete' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branchName = [string](Get-DpPropertyValue -InputObject $Body -Name @('name', 'branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branchName)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            $force = [bool](Get-DpPropertyValue -InputObject $Body -Name @('force') -Default $false)
            $deleteRemote = [bool](Get-DpPropertyValue -InputObject $Body -Name @('deleteRemote') -Default $false)
            $removed = Remove-DpGitBranch -Root $root -Name $branchName -Force:$force -DeleteRemote:$deleteRemote
            if ($removed.error) {
                # notMerged is a recoverable refusal, not a failure: answer 409 so the
                # UI can offer an explicit force instead of showing a dead end.
                $statusCode = if ($removed.notMerged) { 409 } else { 400 }
                Write-DpResponse -Stream $Stream -Status $statusCode -Json @{ error = @{ code = 'branch_delete_failed'; message = $removed.error; notMerged = $removed.notMerged }; result = $removed }
                return
            }
            Write-DpResponse -Stream $Stream -Json $removed
        }
        'gitSyncStatus' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $doFetch = $false
            if ($Request -and $Request.Query -and $Request.Query.ContainsKey('fetch')) {
                $fv = [string]$Request.Query['fetch']
                $doFetch = ($fv -eq '1' -or $fv -eq 'true')
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpGitSyncStatus -Path $root -Fetch:$doFetch)
        }
        'gitSync' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $action = [string](Get-DpPropertyValue -InputObject $Body -Name @('action') -Default 'sync')
            if ($action -notin @('pull', 'push', 'sync')) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_action'; message = "Unknown sync action '$action'." } }
                return
            }
            $autostash = [bool](Get-DpPropertyValue -InputObject $Body -Name @('autostash') -Default $false)
            $syncResult = Invoke-DpGitSync -Root $root -Action $action -Autostash:$autostash
            Write-DpResponse -Stream $Stream -Json $syncResult
        }
        'gitConflictPrompt' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $sync = Get-DpGitSyncStatus -Path $root
            if (-not $sync.isRepo) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_a_repo'; message = 'This project is not a Git repository.' } }
                return
            }
            $conflictFiles = @($sync.conflictFiles)
            $sourceBranch = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('branch')) { [string]$Request.Query['branch'] } else { '' }
            $targetBranch = if ($sync.branch) { $sync.branch } else { '' }
            $promptText = New-DpConflictPrompt -Files $conflictFiles -SourceBranch $sourceBranch -TargetBranch $targetBranch -Root $root
            Write-DpResponse -Stream $Stream -Json @{
                inMerge      = $sync.inMerge
                files        = $conflictFiles
                sourceBranch = $sourceBranch
                targetBranch = $targetBranch
                prompt       = $promptText
            }
        }
        'pendingChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Json @{ files = @(); fileCount = 0; totalAdded = 0; totalDeleted = 0; undoable = $false; error = $null }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpChangePayload -Root $root -Entries (Get-DpChangeEntry -Store $state.Changes -Root $root))
        }
        'keepChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            $cleared = if ($paths.Count -gt 0) {
                Remove-DpChangeEntry -Store $state.Changes -Root $root -Paths $paths
            }
            else {
                Remove-DpChangeEntry -Store $state.Changes -Root $root
            }
            if ($state.DataDir) { Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir }
            Write-DpResponse -Stream $Stream -Json @{
                kept      = $cleared.cleared
                remaining = $cleared.remaining
                changes   = (Get-DpChangePayload -Root $root -Entries (Get-DpChangeEntry -Store $state.Changes -Root $root))
            }
        }
        'undoChanges' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            $entries = Get-DpChangeEntry -Store $state.Changes -Root $root
            $undo = if ($paths.Count -gt 0) {
                Invoke-DpChangeUndo -Root $root -Entries $entries -Paths $paths
            }
            else {
                Invoke-DpChangeUndo -Root $root -Entries $entries
            }
            if ($undo.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'undo_failed'; message = $undo.error } }
                return
            }
            # Only stop tracking what actually went back; a file that could not be
            # restored stays in the set so the user can see it still needs a decision.
            $done = @(@($undo.restored) + @($undo.removed))
            if ($done.Count -gt 0) {
                $null = Remove-DpChangeEntry -Store $state.Changes -Root $root -Paths $done
                if ($state.DataDir) { Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir }
            }
            Write-DpResponse -Stream $Stream -Json @{
                restored = @($undo.restored)
                removed  = @($undo.removed)
                skipped  = @($undo.skipped)
                changes  = (Get-DpChangePayload -Root $root -Entries (Get-DpChangeEntry -Store $state.Changes -Root $root))
            }
        }
        'gitMergePreview' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('branch')) { [string]$Request.Query['branch'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpMergePreview -Root $root -Branch $branch)
        }
        'gitMerge' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            $autofix = [bool](Get-DpPropertyValue -InputObject $Body -Name @('autofix') -Default $false)
            Write-DpResponse -Stream $Stream -Json (Invoke-DpGitMerge -Root $root -Branch $branch -Autofix:$autofix)
        }
        'gitMergePlan' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            # The conflict-resolution Turn runs synchronously on the shared Engine
            # Runspace; refuse to start it while another Turn is in flight.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'turn_running'; message = 'Another task is running; wait for it to finish.' } }
                return
            }
            $conflict = Get-DpMergeConflict -Root $root
            if ($conflict.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'conflict_read_failed'; message = $conflict.error } }
                return
            }
            if (-not $conflict.inMerge) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_in_merge'; message = 'There is no merge in progress.' } }
                return
            }
            $textFiles = @($conflict.files | Where-Object { -not $_.binary })
            $binaryFiles = @($conflict.files | Where-Object { $_.binary })
            $sourceBranch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($sourceBranch)) { $sourceBranch = 'the merged branch' }
            $defaultBranch = Get-DpDefaultBranch -Path $root
            $plan = @{ ok = $true; resolutions = @(); notes = $null; error = $null }
            if ($textFiles.Count -gt 0) {
                $defaultForPrompt = if ($defaultBranch) { $defaultBranch } else { 'main' }
                $prompt = New-DpMergePlanPrompt -SourceBranch $sourceBranch -DefaultBranch $defaultForPrompt -Files $textFiles
                $engineParams = @{
                    Prompt             = $prompt
                    DisableBrowsing    = $true
                    DisableFileAccess  = $true
                    DisableTerminal    = $true
                    DisableUserPrompts = $true
                    DisableUserTools   = $true
                    DisableTodoList    = $true
                }
                if ($state.Settings.model) { $engineParams.Model = $state.Settings.model }
                $state.TurnRunning = $true
                try {
                    $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                }
                catch {
                    $state.TurnRunning = $false
                    Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'engine_error'; message = "The model could not produce a merge plan: $($_.Exception.Message)" } }
                    return
                }
                $state.TurnRunning = $false
                $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                $plan = ConvertFrom-DpMergePlan -Text $content
            }
            Write-DpResponse -Stream $Stream -Json @{
                inMerge       = $true
                sourceBranch  = $sourceBranch
                defaultBranch = $defaultBranch
                textFiles     = @($textFiles | ForEach-Object { @{ rel = $_.rel; truncated = $_.truncated } })
                binaryFiles   = @($binaryFiles | ForEach-Object { @{ rel = $_.rel } })
                plan          = @{ ok = $plan.ok; resolutions = $plan.resolutions; notes = $plan.notes; error = $plan.error }
            }
        }
        'gitMergeApply' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $resolutions = @()
            if ($Body -and $Body.PSObject.Properties['resolutions'] -and $Body.resolutions) { $resolutions = @($Body.resolutions) }
            $binaryChoices = @()
            if ($Body -and $Body.PSObject.Properties['binaryChoices'] -and $Body.binaryChoices) { $binaryChoices = @($Body.binaryChoices) }
            $popStash = [bool](Get-DpPropertyValue -InputObject $Body -Name @('popStash') -Default $false)
            $result = Invoke-DpMergeApply -Root $root -Resolutions $resolutions -BinaryChoices $binaryChoices -PopStash:$popStash
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'merge_apply_failed'; message = $result.error }; result = $result }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'gitMergeAbort' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $popStash = [bool](Get-DpPropertyValue -InputObject $Body -Name @('popStash') -Default $false)
            $result = Invoke-DpGitMergeAbort -Root $root -PopStash:$popStash
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'merge_abort_failed'; message = $result.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'gitMergeUndo' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $sha = [string](Get-DpPropertyValue -InputObject $Body -Name @('sha') -Default '')
            if ([string]::IsNullOrWhiteSpace($sha)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_sha'; message = 'A commit id is required.' } }
                return
            }
            $result = Invoke-DpGitMergeUndo -Root $root -Sha $sha
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'merge_undo_failed'; message = $result.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'gitCleanup' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $branch = [string](Get-DpPropertyValue -InputObject $Body -Name @('branch') -Default '')
            if ([string]::IsNullOrWhiteSpace($branch)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_branch'; message = 'A branch name is required.' } }
                return
            }
            $deleteRemote = [bool](Get-DpPropertyValue -InputObject $Body -Name @('deleteRemote') -Default $false)
            $pushDefault = [bool](Get-DpPropertyValue -InputObject $Body -Name @('pushDefaultBranch') -Default $false)
            $force = [bool](Get-DpPropertyValue -InputObject $Body -Name @('force') -Default $false)
            $result = Invoke-DpBranchCleanup -Root $root -Branch $branch -DeleteRemote:$deleteRemote -PushDefaultBranch:$pushDefault -Force:$force
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'cleanup_failed'; message = $result.error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'fsMkdir' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A parent and name are required.' } }
                return
            }
            try {
                $parent = [string](Get-DpPropertyValue -InputObject $Body -Name @('parent') -Default '')
                $folderName = [string](Get-DpPropertyValue -InputObject $Body -Name @('name') -Default '')
                $created = New-DpDirectory -Parent $parent -Name $folderName
                Write-DpResponse -Stream $Stream -Json (Get-DpDirectoryListing -Path $created)
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'mkdir_failed'; message = "$_" } }
            }
        }
        'usage' {
            Write-DpResponse -Stream $Stream -Json (Get-DpUsagePayload)
        }
        'exportSettings' {
            $backup = @{
                type        = 'deskpilot-settings-backup'
                version     = 1
                exportedUtc = [DateTime]::UtcNow.ToString('o')
                settings    = $state.Settings
            }
            Write-DpResponse -Stream $Stream -Json $backup
        }
        'importSettings' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'A settings backup is required.' } }
                return
            }
            try {
                # Accept either a wrapped backup ({ type, settings }) or a bare
                # settings object. Restore replaces the current settings, so the
                # patch is merged onto the defaults rather than the live state.
                $payload = if ($Body.PSObject.Properties['settings'] -and $Body.settings) { $Body.settings } else { $Body }
                $patch = @{}
                foreach ($prop in $payload.PSObject.Properties) { $patch[$prop.Name] = $prop.Value }
                # version is metadata; workspaceFolder is derived from the selection.
                $patch.Remove('version') | Out-Null
                $patch.Remove('workspaceFolder') | Out-Null
                $restored = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch $patch
                $state.Settings = $restored
                if ($state.DataDir) { Save-DpSettings -Settings $restored -Directory $state.DataDir }
                Write-DpResponse -Stream $Stream -Json $restored
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_backup'; message = "$_" } }
            }
        }
        'resetUsage' {
            $scope = if ($Body -and $Body.PSObject.Properties['scope'] -and $Body.scope) { [string]$Body.scope } else { 'lifetime' }
            switch ($scope) {
                'lifetime' {
                    $state.LifetimeUsage = New-DpLifetimeUsage
                    if ($state.DataDir) { Save-DpLifetimeUsage -Usage $state.LifetimeUsage -Directory $state.DataDir }
                }
                'session' {
                    $state.Usage = @{ promptTokens = 0; completionTokens = 0; totalTokens = 0; costUSD = 0.0; credits = 0.0; turns = 0; unpricedTurns = 0; byModel = @{} }
                }
                default {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_scope'; message = "Unknown reset scope '$scope'. Use 'lifetime' or 'session'." } }
                    return
                }
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpUsagePayload)
        }
        'getSchedules' {
            # A read also advances the pump so a next-run time the browser shows is
            # the one the dispatcher will act on, never a stale one from last launch.
            try { Update-DpScheduleState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Json (Get-DpSchedulePayload)
        }
        'createSchedule' {
            if (@($state.Schedules.schedules).Count -ge 50) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'too_many_schedules'; message = 'DeskPilot keeps at most 50 schedules. Delete one first.' } }
                return
            }
            try { $schedule = ConvertTo-DpSchedule -InputObject $Body }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_schedule'; message = "$_" } }
                return
            }
            # A brand-new schedule gets its id here, never from the request, so a
            # crafted body cannot overwrite an existing one through create.
            $schedule.id = New-DpId -Prefix 'sch'
            $state.Schedules.schedules = @(@($state.Schedules.schedules) + $schedule)
            try { Update-DpScheduleState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Status 201 -Json (Get-DpSchedulePayload)
        }
        'updateSchedule' {
            $scheduleId = [string]$RouteParams['id']
            $existing = @($state.Schedules.schedules | Where-Object { $_.id -eq $scheduleId }) | Select-Object -First 1
            if (-not $existing) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'That schedule does not exist.' } }
                return
            }
            try { $schedule = ConvertTo-DpSchedule -InputObject $Body }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_schedule'; message = "$_" } }
                return
            }
            # The path names the schedule; the body never renames it. Timing fields
            # are recomputed, and the run history stays with the schedule.
            $schedule.id = $scheduleId
            $schedule.createdUtc = $existing.createdUtc
            $schedule.updatedUtc = [datetime]::UtcNow.ToString('o')
            $schedule.history = @($existing.history)
            $schedule.lastRun = $existing.lastRun
            $schedule.nextRunUtc = $null
            $state.Schedules.schedules = @(@($state.Schedules.schedules) | ForEach-Object { if ($_.id -eq $scheduleId) { $schedule } else { $_ } })
            # An edit invalidates a run queued under the old definition.
            $state.Schedules.queue = @(@($state.Schedules.queue) | Where-Object { $_.scheduleId -ne $scheduleId })
            try { Update-DpScheduleState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Json (Get-DpSchedulePayload)
        }
        'deleteSchedule' {
            $scheduleId = [string]$RouteParams['id']
            $before = @($state.Schedules.schedules).Count
            $state.Schedules.schedules = @(@($state.Schedules.schedules) | Where-Object { $_.id -ne $scheduleId })
            if (@($state.Schedules.schedules).Count -eq $before) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'That schedule does not exist.' } }
                return
            }
            $state.Schedules.queue = @(@($state.Schedules.queue) | Where-Object { $_.scheduleId -ne $scheduleId })
            $state.SchedulesRevision = [int]$state.SchedulesRevision + 1
            if ($state.DataDir) { Save-DpScheduleStore -Store $state.Schedules -Directory $state.DataDir -Confirm:$false }
            Write-DpResponse -Stream $Stream -Json (Get-DpSchedulePayload)
        }
        'runSchedule' {
            # "Run now" queues, it does not run inline: this route is served on the
            # single accept thread, and the queue is the only place that knows the
            # Engine is free.
            $scheduleId = [string]$RouteParams['id']
            $schedule = @($state.Schedules.schedules | Where-Object { $_.id -eq $scheduleId }) | Select-Object -First 1
            if (-not $schedule) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'That schedule does not exist.' } }
                return
            }
            $pending = @($state.Schedules.queue | Where-Object { $_.scheduleId -eq $scheduleId })
            if ($pending.Count -gt 0) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'already_queued'; message = 'A run for this schedule is already waiting.' } }
                return
            }
            if (@($state.Schedules.queue).Count -ge 20) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'queue_full'; message = 'The run queue is full. Try again once it drains.' } }
                return
            }
            $nowIso = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
            $state.Schedules.queue = @(@($state.Schedules.queue) + @{
                    scheduleId = $scheduleId
                    dueUtc     = $nowIso
                    queuedUtc  = $nowIso
                    source     = 'manual'
                })
            $state.SchedulesRevision = [int]$state.SchedulesRevision + 1
            if ($state.DataDir) { Save-DpScheduleStore -Store $state.Schedules -Directory $state.DataDir -Confirm:$false }
            Write-DpResponse -Stream $Stream -Status 202 -Json (Get-DpSchedulePayload)
        }
        'getUpdate' {
            Write-DpResponse -Stream $Stream -Json (Get-DpUpdatePayload)
        }
        'checkUpdate' {
            # Manual "Check for updates": force an immediate Gallery check
            # off-thread (Update-DpUpdateCheckState starts a background job unless
            # one is already running) and return the current status; the SPA polls
            # GET /api/update until 'checking' clears.
            try { Update-DpUpdateCheckState -Force } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Status 202 -Json (Get-DpUpdatePayload)
        }
        'installUpdate' {
            # Consent-gated self-update: the SPA calls this only after the user
            # clicks "Update now" on the notice. It installs the newest DeskPilot
            # and ShellPilot (a preview DeskPilot target also accepts a preview
            # ShellPilot) into the CurrentUser scope, then force-reloads ShellPilot
            # live in the Engine Runspace so the Engine update takes effect at once.
            # The DeskPilot host cannot hot-swap its own running code in-process, so
            # its update applies on a relaunch (POST /api/update/restart). Installing
            # runs inline on this single accept thread - like the Git/atelier routes.
            if ($state.Update.installing) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'already_installing'; message = 'An update is already being installed.' } }
                return
            }
            if ($state.TurnRunning) {
                # Reloading ShellPilot re-imports it in the Engine Runspace, which a
                # running Turn is using - refuse until it finishes.
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A turn is running. Try updating again once it finishes.' } }
                return
            }
            if (-not $state.Update.updateAvailable) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_update'; message = 'No newer version is available to install.' } }
                return
            }
            $state.Update.installing = $true
            try {
                $r = Invoke-DpSelfUpdate -IncludePrerelease:([bool]$state.Update.targetIsPrerelease)
                # Reload the Engine live so the new ShellPilot is used without a
                # restart (only DeskPilot's own host code needs the relaunch).
                $engineReload = if ($r.Ok) { Update-DpEngineModule } else { @{ Ok = $false; Version = $null; Error = 'Skipped (install failed).' } }
            }
            finally {
                $state.Update.installing = $false
            }
            $state.Update.installResult = @{
                ok              = [bool]$r.Ok
                restartRequired = [bool]$r.Ok
                modules         = @($r.Modules)
                engineReloaded  = [bool]$engineReload.Ok
                engineVersion   = $engineReload.Version
                error           = $r.Error
                installedUtc    = [DateTime]::UtcNow.ToString('o')
            }
            if (-not $r.Ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'update_failed'; message = $r.Error } }
                return
            }
            $engineNote = if ($engineReload.Ok) { ' The Engine (ShellPilot) reloaded and is active now.' } else { '' }
            Write-DpResponse -Stream $Stream -Json @{
                ok                = $true
                restartRequired   = $true
                includePrerelease = [bool]$r.IncludePrerelease
                modules           = @($r.Modules)
                engineReloaded    = [bool]$engineReload.Ok
                engineVersion     = $engineReload.Version
                message           = "Update installed.$engineNote Restart DeskPilot to finish applying the app update."
            }
        }
        'restartUpdate' {
            # Relaunch DeskPilot in a fresh process (which imports the updated
            # DeskPilot + ShellPilot) and signal this one to stop. This is the only
            # safe way to apply the DeskPilot host update - the running module cannot
            # hot-swap its own executing code. Refuse mid-Turn.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A turn is running. Try restarting again once it finishes.' } }
                return
            }
            $restart = Restart-DpHost
            if (-not $restart.Ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'restart_failed'; message = $restart.Error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{
                ok      = $true
                message = 'DeskPilot is restarting. A new window will open; you can close this tab.'
            }
        }
        'getMemory' {
            Write-DpResponse -Stream $Stream -Json (Get-DpMemoryPayload)
        }
        'updateMemory' {
            # Manual edits to either memory store. User Profile is the preferences
            # Setting (validated + persisted via Merge-DpSettings); Agent Memory is
            # its own store. Either or both may be present in the body.
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'Nothing to update.' } }
                return
            }
            $limits = Get-DpMemoryLimits
            if ($Body.PSObject.Properties['userProfile']) {
                $profileText = if ($null -eq $Body.userProfile) { $null } else { [string]$Body.userProfile }
                if ($profileText -and $profileText.Length -gt $limits.userProfile) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_long'; message = "The user profile must be $($limits.userProfile) characters or fewer." } }
                    return
                }
                try {
                    $state.Settings = Merge-DpSettings -Current $state.Settings -Patch @{ preferences = $profileText }
                    if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }
                }
                catch {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_profile'; message = "$_" } }
                    return
                }
            }
            if ($Body.PSObject.Properties['agentMemory']) {
                $memText = if ($null -eq $Body.agentMemory) { '' } else { ([string]$Body.agentMemory).Trim() }
                if ($memText.Length -gt $limits.agentMemory) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_long'; message = "The agent memory must be $($limits.agentMemory) characters or fewer." } }
                    return
                }
                $state.Memory = @{ text = $memText; updatedUtc = [DateTime]::UtcNow.ToString('o') }
                if ($state.DataDir) { Save-DpMemoryStore -Memory $state.Memory -Directory $state.DataDir }
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpMemoryPayload)
        }
        'learnMemory' {
            # Fold durable facts from a Conversation into the Agent Memory via a
            # pure-reasoning Turn (all Tools off, like auto-title / compaction). The
            # visible transcript is untouched; only the persistent memory changes.
            $conversationId = if ($Body -and $Body.PSObject.Properties['conversationId'] -and $Body.conversationId) { [string]$Body.conversationId } else { $null }
            if (-not $conversationId) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'missing_conversation'; message = 'A conversationId is required.' } }
                return
            }
            $conversation = $state.Conversations[$conversationId]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $limits = Get-DpMemoryLimits
            $recent = @($conversation.messages | Where-Object { $_.role -in @('user', 'assistant') } | Select-Object -Last 8)
            if ($recent.Count -lt 2) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_short'; message = 'This conversation is too short to learn from.' } }
                return
            }
            $current = if ($state.Memory) { [string]$state.Memory.text } else { '' }
            $changed = $false
            $engineParams = @{
                Prompt             = New-DpMemoryPrompt -CurrentMemory $current -Messages $recent -MaxChars $limits.agentMemory
                DisableBrowsing    = $true
                DisableFileAccess  = $true
                DisableTerminal    = $true
                DisableUserPrompts = $true
                DisableUserTools   = $true
                DisableTodoList    = $true
            }
            $effectiveModel = if ($conversation.model) { $conversation.model } elseif ($state.Settings.model) { $state.Settings.model } else { $null }
            if ($effectiveModel) { $engineParams.Model = $effectiveModel }
            $state.TurnRunning = $true
            try {
                $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                $extracted = ConvertFrom-DpMemoryResult -Text $content -MaxLength $limits.agentMemory
                if (-not [string]::IsNullOrWhiteSpace($extracted) -and $extracted -ne $current) {
                    $state.Memory = @{ text = $extracted; updatedUtc = [DateTime]::UtcNow.ToString('o') }
                    if ($state.DataDir) { Save-DpMemoryStore -Memory $state.Memory -Directory $state.DataDir }
                    $changed = $true
                }
            }
            catch {
                # Best-effort: a failed extraction leaves the memory unchanged.
                $null = $_
            }
            finally {
                $state.TurnRunning = $false
            }
            $payload = Get-DpMemoryPayload
            $payload.changed = $changed
            Write-DpResponse -Stream $Stream -Json $payload
        }
        'listConversations' {
            $summaries = $state.Conversations.Values |
                Sort-Object @{ Expression = { [bool]$_.pinned }; Descending = $true }, @{ Expression = { $_.updatedUtc }; Descending = $true } |
                ForEach-Object {
                    @{ id = $_.id; title = $_.title; model = $_.model; pinned = [bool]$_.pinned; archived = [bool]$_.archived; unread = [bool]$_.unread; color = $_.color; compactedUtc = $_.compactedUtc; createdUtc = $_.createdUtc; updatedUtc = $_.updatedUtc; messageCount = $_.messages.Count }
                }
            Write-DpResponse -Stream $Stream -Json @{ conversations = @($summaries) }
        }
        'createConversation' {
            $title = if ($Body -and $Body.PSObject.Properties['title'] -and $Body.title) { [string]$Body.title } else { 'New conversation' }
            $model = if ($Body -and $Body.PSObject.Properties['model'] -and $Body.model) { [string]$Body.model } else { $state.Settings.model }
            $conversation = New-DpConversation -Title $title -Model $model
            $state.Conversations[$conversation.id] = $conversation
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            Write-DpResponse -Stream $Stream -Status 201 -Json @{
                id = $conversation.id; title = $conversation.title; model = $conversation.model
                createdUtc = $conversation.createdUtc; updatedUtc = $conversation.updatedUtc; messageCount = 0
            }
        }
        'getConversation' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{
                id = $conversation.id; title = $conversation.title; model = $conversation.model
                compactedUtc = $conversation.compactedUtc
                createdUtc = $conversation.createdUtc; updatedUtc = $conversation.updatedUtc
                messages = @($conversation.messages)
            }
        }
        'patchConversation' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            # Validate the colour up-front so an unknown value rejects cleanly
            # before any field is mutated. An empty/absent colour clears it.
            $requestedColor = $null
            if ($Body -and $Body.PSObject.Properties['color']) {
                $requestedColor = if ($Body.color) { [string]$Body.color } else { '' }
                $allowedColors = @('red', 'amber', 'green', 'teal', 'blue', 'purple')
                if ($requestedColor -and $allowedColors -notcontains $requestedColor) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_color'; message = "Unknown colour '$requestedColor'." } }
                    return
                }
            }
            if ($Body -and $Body.PSObject.Properties['title'] -and $Body.title) {
                $conversation.title = [string]$Body.title
                # A manual rename locks the title so auto-titling never overwrites it.
                $conversation.titleLocked = $true
            }
            if ($Body -and $Body.PSObject.Properties['model']) { $conversation.model = if ($Body.model) { [string]$Body.model } else { $null } }
            # Pin / archive / unread / colour are organisational flags; they must
            # not reorder the list, so they do not bump updatedUtc (only a
            # title/model edit does).
            $touched = $false
            if ($Body -and ($Body.PSObject.Properties['title'] -or $Body.PSObject.Properties['model'])) { $touched = $true }
            if ($Body -and $Body.PSObject.Properties['pinned']) { $conversation.pinned = [bool]$Body.pinned }
            if ($Body -and $Body.PSObject.Properties['archived']) { $conversation.archived = [bool]$Body.archived }
            if ($Body -and $Body.PSObject.Properties['unread']) { $conversation.unread = [bool]$Body.unread }
            if ($null -ne $requestedColor) { $conversation.color = if ($requestedColor) { $requestedColor } else { $null } }
            if ($touched) { $conversation.updatedUtc = [DateTime]::UtcNow.ToString('o') }
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            Write-DpResponse -Stream $Stream -Json @{
                id = $conversation.id; title = $conversation.title; model = $conversation.model
                pinned = [bool]$conversation.pinned; archived = [bool]$conversation.archived
                unread = [bool]$conversation.unread; color = $conversation.color
                createdUtc = $conversation.createdUtc; updatedUtc = $conversation.updatedUtc; messageCount = $conversation.messages.Count
            }
        }
        'deleteConversation' {
            if ($state.Conversations.ContainsKey($RouteParams.id)) {
                $state.Conversations.Remove($RouteParams.id)
                Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            }
            Write-DpResponse -Stream $Stream -Status 204 -NoBody
        }
        'duplicateConversation' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            $copy = Copy-DpConversation -Conversation $conversation
            $state.Conversations[$copy.id] = $copy
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            Write-DpResponse -Stream $Stream -Status 201 -Json @{
                id = $copy.id; title = $copy.title; model = $copy.model
                pinned = [bool]$copy.pinned; archived = [bool]$copy.archived
                unread = [bool]$copy.unread; color = $copy.color; compactedUtc = $copy.compactedUtc
                createdUtc = $copy.createdUtc; updatedUtc = $copy.updatedUtc; messageCount = $copy.messages.Count
            }
        }
        'readAllConversations' {
            $cleared = 0
            foreach ($conversation in $state.Conversations.Values) {
                if ($conversation.unread) { $conversation.unread = $false; $cleared++ }
            }
            if ($cleared -gt 0) {
                Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            }
            Write-DpResponse -Stream $Stream -Json @{ ok = $true; cleared = $cleared }
        }
        'postMessage' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $writable = Test-DpConversationWritable -Conversation $conversation
            if (-not $writable.ok) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = $writable.code; message = $writable.reason } }
                return
            }
            $prompt = if ($Body -and $Body.PSObject.Properties['prompt']) { [string]$Body.prompt } else { '' }

            # Attachments are read before the empty-prompt check: dropping files on
            # the composer and pressing Send without typing is a Turn, not a
            # mistake - the files are what the user is asking about. They go
            # through the same upload-store gate as Vision input, so a crafted
            # Message still cannot nominate an arbitrary local file for the agent.
            $attachments = @()
            if ($Body -and $Body.PSObject.Properties['attachments']) {
                $requestedAttachmentPaths = @($Body.attachments | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($requestedAttachmentPaths.Count -gt 0) {
                    try {
                        $attachments = @(Resolve-DpAttachmentPath -Path $requestedAttachmentPaths -AttachmentStore $state.Attachments -AnyContentType |
                                ForEach-Object { @{ name = [System.IO.Path]::GetFileName($_); path = $_ } })
                    }
                    catch {
                        $attachmentError = $_
                        Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'invalid_attachment'; message = $attachmentError.Exception.Message } }
                        return
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($prompt) -and $attachments.Count -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_prompt'; message = 'A prompt or an Attachment is required.' } }
                return
            }

            $imagePaths = @()
            if ($Body -and $Body.PSObject.Properties['images']) {
                $requestedImagePaths = @($Body.images | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($requestedImagePaths.Count -gt 0) {
                    try {
                        $imagePaths = @(Resolve-DpAttachmentPath -Path $requestedImagePaths -AttachmentStore $state.Attachments)
                    }
                    catch {
                        $attachmentError = $_
                        Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'invalid_attachment'; message = $attachmentError.Exception.Message } }
                        return
                    }

                    # Refuse here rather than paying a round trip for the endpoint's
                    # bare 413, which arrives as a raw EndInvoke exception.
                    $budgetError = Get-DpVisionBudgetError -Path $imagePaths
                    if ($budgetError) {
                        Write-DpResponse -Stream $Stream -Status 413 -Json @{ error = @{ code = 'too_large'; message = $budgetError } }
                        return
                    }
                }
            }

            Invoke-DpTurn -Conversation $conversation -Prompt $prompt -Image $imagePaths -Attachment $attachments -Stream $Stream
        }
        'regenerateTurn' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $writable = Test-DpConversationWritable -Conversation $conversation
            if (-not $writable.ok) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = $writable.code; message = $writable.reason } }
                return
            }
            $lastUser = @($conversation.messages | Where-Object { $_.role -eq 'user' }) | Select-Object -Last 1
            if (-not $lastUser) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'nothing_to_regenerate'; message = 'There is no user message to regenerate.' } }
                return
            }
            # An Attachment belongs to the Message rather than to its text, so a
            # re-run has to carry it forward or the model loses the files the
            # answer was about. Read before the truncation removes the Message.
            $priorAttachments = @(Get-DpPropertyValue -InputObject $lastUser -Name @('attachments') -Default @() | Where-Object { $_ })
            $prompt = Reset-DpConversationForRerun -Conversation $conversation -FromMessageId ([string]$lastUser.id)
            if ([string]::IsNullOrWhiteSpace($prompt) -and $priorAttachments.Count -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'nothing_to_regenerate'; message = 'There is no user message to regenerate.' } }
                return
            }
            Invoke-DpTurn -Conversation $conversation -Prompt ([string]$prompt) -Attachment $priorAttachments -Stream $Stream
        }
        'editTurn' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $writable = Test-DpConversationWritable -Conversation $conversation
            if (-not $writable.ok) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = $writable.code; message = $writable.reason } }
                return
            }
            $messageId = [string](Get-DpPropertyValue -InputObject $Body -Name @('messageId') -Default '')
            $prompt = if ($Body -and $Body.PSObject.Properties['prompt']) { [string]$Body.prompt } else { '' }
            if ([string]::IsNullOrWhiteSpace($messageId) -or [string]::IsNullOrWhiteSpace($prompt)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'A messageId and a non-empty prompt are required.' } }
                return
            }
            $edited = @($conversation.messages | Where-Object { [string]$_.id -eq $messageId }) | Select-Object -First 1
            $priorAttachments = @(Get-DpPropertyValue -InputObject $edited -Name @('attachments') -Default @() | Where-Object { $_ })
            $removed = Reset-DpConversationForRerun -Conversation $conversation -FromMessageId $messageId
            if ($null -eq $removed) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'not_a_user_message'; message = 'That message cannot be edited (not found or not a user message).' } }
                return
            }
            Invoke-DpTurn -Conversation $conversation -Prompt $prompt -Attachment $priorAttachments -Stream $Stream
        }
        'restoreCheckpoint' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is running. Wait for it to finish.' } }
                return
            }
            $messageId = [string](Get-DpPropertyValue -InputObject $Body -Name @('messageId') -Default '')
            if ([string]::IsNullOrWhiteSpace($messageId)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_request'; message = 'A messageId is required.' } }
                return
            }
            $skipFiles = [bool](Get-DpPropertyValue -InputObject $Body -Name @('skipFiles') -Default $false)
            $restoreParams = @{
                Conversation = $conversation
                MessageId    = $messageId
                Root         = [string]$state.Settings.workspaceFolder
                SkipFiles    = $skipFiles
            }
            $restore = Restore-DpCheckpoint @restoreParams
            if (-not $restore.ok) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'checkpoint_failed'; message = $restore.error } }
                return
            }
            if ($state.DataDir) {
                Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
                Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir
            }
            # The thread just lost messages, so a phone sitting on it is looking at
            # something that no longer exists.
            $state.ConversationsRevision = [int]$state.ConversationsRevision + 1
            Write-DpResponse -Stream $Stream -Json @{
                ok       = $true
                prompt   = $restore.prompt
                restored = @($restore.restored)
                removed  = @($restore.removed)
                skipped  = @($restore.skipped)
                files    = [bool]$restore.filesTried
            }
        }
        'submitUserPrompt' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{
                    error = @{ code = 'not_found'; message = 'Conversation not found.' }
                }
                return
            }

            $questionId = [string](Get-DpPropertyValue -InputObject $Body -Name @('questionId') -Default '')
            $answer = [string](Get-DpPropertyValue -InputObject $Body -Name @('answer') -Default '')
            if ([string]::IsNullOrWhiteSpace($questionId) -or [string]::IsNullOrWhiteSpace($answer)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{
                    error = @{ code = 'bad_answer'; message = 'A questionId and non-empty answer are required.' }
                }
                return
            }

            $bridge = $state.Engine.UserPromptBridge
            $accepted = $state.TurnRunning -and $bridge -and
                $bridge.SubmitAnswer([string]$conversation.id, $questionId, $answer.Trim())
            if (-not $accepted) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{
                    error = @{ code = 'stale_question'; message = 'That question is no longer waiting for an answer.' }
                }
                return
            }

            Write-DpResponse -Stream $Stream -Status 202 -Json @{ accepted = $true }
        }
        'getApproval' {
            # What a reloaded browser asks to find out whether the Turn it rejoined
            # is waiting on it. Returns the card, or an empty one when nothing is
            # pending - never an error, because "nothing pending" is the normal case.
            $pending = $state.PendingApproval
            if (-not $pending -or [string]$pending.conversationId -ne [string]$RouteParams.id) {
                Write-DpResponse -Stream $Stream -Json @{ pending = $false }
                return
            }

            Write-DpResponse -Stream $Stream -Json @{
                pending = $true
                id      = [string]$pending.id
                tool    = [string]$pending.request.tool
                class   = [string]$pending.request.class
                risk    = [string]$pending.request.risk
                summary = $pending.request.summary
                allowedScopes = @(Get-DpPropertyValue -InputObject $pending.request -Name 'allowedScopes' -Default @('once'))
            }
        }
        'submitApproval' {
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{
                    error = @{ code = 'not_found'; message = 'Conversation not found.' }
                }
                return
            }

            $requestId = [string](Get-DpPropertyValue -InputObject $Body -Name @('requestId') -Default '')
            $decision = ([string](Get-DpPropertyValue -InputObject $Body -Name @('decision') -Default '')).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($requestId) -or @('approve', 'deny') -notcontains $decision) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{
                    error = @{ code = 'bad_decision'; message = 'A requestId and a decision of approve or deny are required.' }
                }
                return
            }

            $scope = 'once'
            if ($Body -is [System.Collections.IDictionary]) {
                if ($Body.Contains('scope')) { $scope = $Body['scope'] }
            }
            elseif ($Body.PSObject.Properties['scope']) { $scope = $Body.scope }
            if ($scope -isnot [string] -or $scope -cnotin @('once', 'turn') -or ($decision -eq 'deny' -and $scope -ne 'once')) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{
                    error = @{ code = 'bad_scope'; message = 'Approval scope must be once, or turn for an eligible Terminal approval.' }
                }
                return
            }
            if ($scope -ceq 'turn') {
                $pending = $state.PendingApproval
                if (-not $pending -or $pending.id -cne $requestId -or $pending.conversationId -cne $conversation.id -or
                    $pending.request.class -cne 'Terminal' -or $pending.request.tool -cne 'run_terminal_command' -or
                    @($pending.request.allowedScopes) -cnotcontains 'turn' -or
                    -not $state.Settings.permissions.terminal -or -not $state.Settings.permissions.userTools) {
                    Write-DpResponse -Stream $Stream -Status 409 -Json @{
                        error = @{ code = 'stale_approval_scope'; message = 'This live Terminal request does not allow a Turn-wide grant.' }
                    }
                    return
                }
            }

            # The note steers the agent after a refusal, so it is bounded and
            # trimmed like any other text that ends up in a prompt.
            $note = ([string](Get-DpPropertyValue -InputObject $Body -Name @('note') -Default '')).Trim()
            if ($note.Length -gt 500) { $note = $note.Substring(0, 500) }

            $payload = @{ decision = $decision; scope = $scope }
            if ($note) { $payload.note = $note }

            # SubmitAnswer checks the Conversation and request identifiers itself,
            # so a replayed answer, one aimed at another Conversation, or one for a
            # request that has already been answered authorises nothing.
            $bridge = $state.Engine.ApprovalBridge
            $accepted = $state.TurnRunning -and -not $state.CancelRequested -and $bridge -and
                $bridge.SubmitAnswer([string]$conversation.id, $requestId, ($payload | ConvertTo-Json -Compress))
            if (-not $accepted) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{
                    error = @{ code = 'stale_approval'; message = 'That request is no longer waiting for a decision.' }
                }
                return
            }

            $state.PendingApproval = $null
            # Every decision is recorded, approvals included. The log is not the
            # control - the gate is - but a Turn that ran a command nobody in the
            # room remembers approving needs to be answerable afterwards. The
            # command itself is deliberately not in the summary: Protect-DpDiagnosticText
            # redacts what it recognises, and a command line is exactly the kind of
            # free text that carries a token it would not.
            Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity 'information' `
                -Component 'approval' -EventId "terminal.$decision" `
                -Summary "An action was $(if ($decision -eq 'approve') { 'approved' } else { 'declined' }) in the DeskPilot window with $scope scope."
            Write-DpResponse -Stream $Stream -Status 202 -Json @{ accepted = $true }
        }
        'stopTurn' {
            $state.CancelRequested = $true
            $child = Get-DpPropertyValue -InputObject $state -Name 'Child'
            if ($child -and $child.Controller) {
                $child.Controller.Stop()
                Write-DpResponse -Stream $Stream -Status 202 -Json @{ stopping = $true }
                return
            }
            if ($state.Engine.TerminalSession) { $state.Engine.TerminalSession.Cancel() }
            $bridge = $state.Engine.UserPromptBridge
            if ($bridge) { $bridge.Cancel() }
            # A Turn parked on an approval is parked inside the Engine pipeline, so
            # Stop has to release this bridge too or the pipeline never unwinds and
            # the Stop button appears to do nothing.
            if ($state.Engine.ApprovalBridge) { $state.Engine.ApprovalBridge.Cancel() }
            # Stop has to mean the browser stops too, and it has to work while
            # the runspace is mid-Turn - which is why the session is held here
            # rather than reached through a pipeline that cannot start.
            try { Close-DpBrowserSession -State $state.Engine.BrowserState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Status 202 -Json @{ stopping = $true }
        }
        'titleConversation' {
            # Auto-title a new Conversation from its first prompt, the way GitHub
            # Copilot renames a new chat to a short summary. Best-effort: the caller
            # already shows a fallback title (the truncated prompt), so any failure
            # here just leaves that in place.
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            # A manual rename wins: never overwrite a title the user set themselves.
            if ($conversation.titleLocked) {
                Write-DpResponse -Stream $Stream -Json @{ id = $conversation.id; title = $conversation.title }
                return
            }
            # Only the first exchange is auto-titled. Later Turns leave the title
            # alone, so a caller can safely fire this after every Turn.
            $userMessages = @($conversation.messages | Where-Object { $_.role -eq 'user' })
            if ($userMessages.Count -ne 1) {
                Write-DpResponse -Stream $Stream -Json @{ id = $conversation.id; title = $conversation.title }
                return
            }
            # The title Turn shares the single Engine Runspace, so refuse while a
            # Turn is running rather than corrupting its state.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            $firstPrompt = [string]$userMessages[0].text
            $newTitle = $conversation.title
            if (-not [string]::IsNullOrWhiteSpace($firstPrompt)) {
                # Pure-reasoning Turn with every Tool disabled (as the Merge Plan does).
                $engineParams = @{
                    Prompt             = New-DpTitlePrompt -Prompt $firstPrompt
                    DisableBrowsing    = $true
                    DisableFileAccess  = $true
                    DisableTerminal    = $true
                    DisableUserPrompts = $true
                    DisableUserTools   = $true
                    DisableTodoList    = $true
                }
                $effectiveModel = if ($conversation.model) { $conversation.model } elseif ($state.Settings.model) { $state.Settings.model } else { $null }
                if ($effectiveModel) { $engineParams.Model = $effectiveModel }
                $state.TurnRunning = $true
                try {
                    $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                    $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                    $cleaned = ConvertFrom-DpTitleResult -Text $content
                    if (-not [string]::IsNullOrWhiteSpace($cleaned)) { $newTitle = $cleaned }
                }
                catch {
                    # A title failure must never surface to the user or break the
                    # Conversation; keep whatever title is already set.
                    $null = $_
                }
                finally {
                    $state.TurnRunning = $false
                }
            }
            if ($newTitle -ne $conversation.title) {
                $conversation.title = $newTitle
                $conversation.updatedUtc = [DateTime]::UtcNow.ToString('o')
                Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            }
            Write-DpResponse -Stream $Stream -Json @{ id = $conversation.id; title = $conversation.title }
        }
        'compactConversation' {
            # Compact the Conversation's replayed context, the way GitHub Copilot
            # offers "Compact Conversation": summarise the earlier part of the
            # Engine -History into a short briefing and keep only the most recent
            # entries verbatim, so future Turns send far fewer tokens. The visible
            # transcript (messages) is deliberately left untouched - nothing the
            # user can see is lost; only what is replayed to the Engine shrinks.
            $conversation = $state.Conversations[$RouteParams.id]
            if (-not $conversation) {
                Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = 'Conversation not found.' } }
                return
            }
            # The compaction Turn shares the single Engine Runspace, so refuse while
            # a Turn is running rather than corrupting its state.
            if ($state.TurnRunning) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'busy'; message = 'A Turn is already running.' } }
                return
            }
            # How many recent history entries to keep verbatim comes from Settings
            # (compactionKeepRecent, default 4), so the same knob drives the manual
            # Compact action and the automatic compaction the browser triggers.
            $keepCount = 4
            if ($state.Settings -and $state.Settings.ContainsKey('compactionKeepRecent') -and $state.Settings.compactionKeepRecent) {
                $keepCount = [int]$state.Settings.compactionKeepRecent
            }
            if ($keepCount -lt 2) { $keepCount = 2 } elseif ($keepCount -gt 100) { $keepCount = 100 }
            $history = @($conversation.history)
            # Too little to be worth a summarisation Turn (and its credit cost):
            # there must be at least a few entries to summarise beyond the kept tail.
            if ($history.Count -lt ($keepCount + 3)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_short'; message = 'This conversation is too short to compact.' } }
                return
            }
            $summary = ''
            # Pure-reasoning Turn with every Tool disabled (as the auto-title and
            # Merge Plan Turns do): the Model only summarises, it never acts.
            $engineParams = @{
                Prompt             = New-DpCompactionPrompt -History $history
                DisableBrowsing    = $true
                DisableFileAccess  = $true
                DisableTerminal    = $true
                DisableUserPrompts = $true
                DisableUserTools   = $true
                DisableTodoList    = $true
            }
            $effectiveModel = if ($conversation.model) { $conversation.model } elseif ($state.Settings.model) { $state.Settings.model } else { $null }
            if ($effectiveModel) { $engineParams.Model = $effectiveModel }
            $state.TurnRunning = $true
            try {
                $engineResult = Invoke-DpEngineCommand -Command 'Invoke-Shp' -Parameter $engineParams | Select-Object -Last 1
                $content = if ($engineResult) { [string]$engineResult.Content } else { '' }
                $summary = ConvertFrom-DpCompactionResult -Text $content
            }
            catch {
                # A failed summarisation must never corrupt the Conversation; leave
                # the history untouched and report the failure to the caller.
                $summary = ''
                $null = $_
            }
            finally {
                $state.TurnRunning = $false
            }
            if ([string]::IsNullOrWhiteSpace($summary)) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'compaction_failed'; message = 'The summary could not be generated. Please try again.' } }
                return
            }
            $beforeChars = ([string](@($history) | ConvertTo-Json -Depth 20 -Compress)).Length
            $compact = Compress-DpConversationHistory -History $history -Summary $summary -KeepCount $keepCount
            if (-not $compact.changed) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'too_short'; message = 'This conversation is too short to compact.' } }
                return
            }
            $conversation.history = $compact.history
            # compactedUtc is an organisational marker; it does not bump updatedUtc
            # (compaction changes only the replayed context, not the visible thread).
            $conversation.compactedUtc = [DateTime]::UtcNow.ToString('o')
            Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
            $afterChars = ([string](@($compact.history) | ConvertTo-Json -Depth 20 -Compress)).Length
            $estimatedFreed = [Math]::Max(0, [int][Math]::Round(($beforeChars - $afterChars) / 4.0))
            Write-DpResponse -Stream $Stream -Json @{
                ok             = $true
                summarised     = $compact.summarised
                kept           = $compact.kept
                before         = $compact.before
                after          = $compact.after
                estimatedFreed = $estimatedFreed
                compactedUtc   = $conversation.compactedUtc
            }
        }
        'uploads' {
            # Uploads land in the active Workspace Folder; with no Project selected
            # they fall back to an 'uploads' folder in the per-user data directory,
            # so attaching a file never requires a registered Project.
            $workspace = Get-DpUploadDir -WorkspaceFolder $state.Settings.workspaceFolder
            $boundary = Get-DpMultipartBoundary -ContentType ([string]$Request.Headers['Content-Type'])
            if (-not $boundary -or -not $Request.BodyBytes -or $Request.BodyBytes.Length -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_multipart'; message = 'Request must be a non-empty multipart/form-data upload.' } }
                return
            }
            try {
                if (-not (Test-Path -LiteralPath $workspace)) {
                    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
                }
                $parts = Read-DpMultipartParts -Bytes $Request.BodyBytes -Boundary $boundary
                $maxBytes = 25 * 1024 * 1024
                $saved = [System.Collections.Generic.List[object]]::new()
                foreach ($part in $parts) {
                    if (-not $part.FileName) { continue }
                    if ($part.Content.Length -gt $maxBytes) {
                        Write-DpResponse -Stream $Stream -Status 413 -Json @{ error = @{ code = 'too_large'; message = "File '$($part.FileName)' exceeds the 25 MiB upload limit." } }
                        return
                    }
                    $target = Get-DpUniqueFilePath -Directory $workspace -Name $part.FileName
                    [System.IO.File]::WriteAllBytes($target, $part.Content)
                    $registeredPath = [System.IO.Path]::GetFullPath($target)
                    $state.Attachments[$registeredPath] = [string]$part.ContentType
                    $saved.Add(@{
                            name        = $part.FileName
                            savedAs     = [System.IO.Path]::GetFileName($registeredPath)
                            path        = $registeredPath
                            bytes       = $part.Content.Length
                            contentType = $part.ContentType
                        })
                }
                if ($saved.Count -eq 0) {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_files'; message = 'No file parts were found in the upload.' } }
                    return
                }
                Write-DpResponse -Stream $Stream -Json @{ files = @($saved) }
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'upload_failed'; message = "$_" } }
            }
        }
        'searchConversations' {
            $query = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('q')) { ([string]$Request.Query['q']).Trim() } else { '' }
            if ([string]::IsNullOrWhiteSpace($query)) {
                Write-DpResponse -Stream $Stream -Json @{ query = ''; results = @() }
                return
            }
            $needle = $query.ToLowerInvariant()
            $results = [System.Collections.Generic.List[hashtable]]::new()
            $ordered = $state.Conversations.Values |
                Sort-Object @{ Expression = { [bool]$_.pinned }; Descending = $true }, @{ Expression = { $_.updatedUtc }; Descending = $true }
            foreach ($conversation in $ordered) {
                $titleHit = $conversation.title -and $conversation.title.ToLowerInvariant().Contains($needle)
                $snippet = $null
                $messageHit = $false
                foreach ($message in @($conversation.messages)) {
                    $text = [string](Get-DpPropertyValue -InputObject $message -Name @('text', 'content') -Default '')
                    if (-not $text) { continue }
                    $idx = $text.ToLowerInvariant().IndexOf($needle)
                    if ($idx -ge 0) {
                        $messageHit = $true
                        $start = [Math]::Max(0, $idx - 30)
                        $len = [Math]::Min($text.Length - $start, $needle.Length + 70)
                        $snippet = $text.Substring($start, $len).Trim() -replace '\s+', ' '
                        if ($start -gt 0) { $snippet = [char]0x2026 + $snippet }
                        break
                    }
                }
                if ($titleHit -or $messageHit) {
                    $results.Add(@{
                            id           = $conversation.id
                            title        = $conversation.title
                            pinned       = [bool]$conversation.pinned
                            archived     = [bool]$conversation.archived
                            unread       = [bool]$conversation.unread
                            color        = $conversation.color
                            updatedUtc   = $conversation.updatedUtc
                            messageCount = $conversation.messages.Count
                            snippet      = $snippet
                            titleHit     = [bool]$titleHit
                        })
                }
            }
            Write-DpResponse -Stream $Stream -Json @{ query = $query; results = @($results) }
        }
        'fsFind' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $query = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('q')) { [string]$Request.Query['q'] } else { '' }
            Write-DpResponse -Stream $Stream -Json (Get-DpFileFind -Root $root -Query $query)
        }
        'gitDiff' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $requested = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('path')) { [string]$Request.Query['path'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($requested)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_path'; message = 'A file path is required.' } }
                return
            }
            # An explicit base is only honoured when it is one of this Project's own
            # snapshots, so the query cannot name an arbitrary commit to read from.
            $base = if ($Request -and $Request.Query -and $Request.Query.ContainsKey('base')) { [string]$Request.Query['base'] } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($base)) {
                $known = @(Get-DpChangeEntry -Store $state.Changes -Root $root | ForEach-Object { [string]$_.snapshotSha })
                if ($known -notcontains $base) { $base = '' }
            }
            if ([string]::IsNullOrWhiteSpace($base)) {
                Write-DpResponse -Stream $Stream -Json (Get-DpGitDiff -Root $root -Path $requested)
            }
            else {
                Write-DpResponse -Stream $Stream -Json (Get-DpGitDiff -Root $root -Path $requested -BaseSha $base)
            }
        }
        'gitRestore' {
            $root = $state.Settings.workspaceFolder
            if ([string]::IsNullOrWhiteSpace($root)) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_workspace'; message = 'No project selected.' } }
                return
            }
            $paths = @()
            if ($Body -and $Body.PSObject.Properties['paths'] -and $Body.paths) { $paths = @($Body.paths | ForEach-Object { [string]$_ }) }
            if ($paths.Count -eq 0) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'no_paths'; message = 'At least one file path is required.' } }
                return
            }
            $result = Invoke-DpGitRestore -Root $root -Paths $paths
            if ($result.error) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'restore_failed'; message = $result.error } }
                return
            }
            # A file that actually went back is no longer an unreviewed change;
            # leaving it pending would keep offering an undo for work already gone.
            $done = @(@($result.restored) + @($result.removed))
            if ($done.Count -gt 0) {
                $null = Remove-DpChangeEntry -Store $state.Changes -Root $root -Paths $done
                if ($state.DataDir) { Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir }
            }
            Write-DpResponse -Stream $Stream -Json $result
        }
        'atelierHealth' {
            Write-DpResponse -Stream $Stream -Json (Get-DpAtelierHealth -Settings $state.Settings)
        }
        'atelierSetup' {
            # Opt-in and consent-gated: download CopilotAtelier and run its
            # Setup-CopilotSettings.ps1. The SPA requires an explicit confirmation
            # (a modal that spells out what the script changes) before calling
            # this, so it is never a one-click action. Downloading blocks this
            # single accept thread briefly, like the Git routes - acceptable for a
            # deliberate, one-time action.
            $r = Invoke-DpAtelierSetup
            if (-not $r.Ok) {
                $code = if ($r.Code) { $r.Code } else { 'atelier_setup_failed' }
                $status = if ($code -eq 'download_failed') { 502 } else { 500 }
                Write-DpResponse -Stream $Stream -Status $status -Json @{ error = @{ code = $code; message = $r.Error } }
                return
            }
            Write-DpResponse -Stream $Stream -Json @{
                ok         = $true
                launched   = $r.Launched
                windows    = $r.Windows
                sourcePath = $r.SourcePath
                scriptPath = $r.ScriptPath
                message    = $r.Message
            }
        }
        'getMcp' {
            Write-DpResponse -Stream $Stream -Json (Get-DpMcpState -Settings $state.Settings)
        }
        'putMcp' {
            # Saving the list and attaching the servers are one act. Persisting
            # without reconciling would leave the Engine running the previous set
            # while the panel showed the new one; reconciling without persisting
            # would lose it all on restart.
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'An MCP server list is required.' } }
                return
            }
            $incoming = if ($Body.PSObject.Properties['servers']) { @($Body.servers) } else { @($Body) }
            try {
                $merged = Merge-DpSettings -Current $state.Settings -Patch @{ mcpServers = $incoming }
            }
            catch {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_mcp_server'; message = "$_" } }
                return
            }

            if (-not $state.Engine.McpSupported) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'mcp_unsupported'; message = 'This Engine does not support MCP servers. Update ShellPilot to 0.4.0-preview0007 or later.' } }
                return
            }

            # Persist first. A server that fails to start is reported per row and the
            # user keeps what they typed; discarding the list because a command line
            # was wrong would make the panel unusable exactly when it is needed.
            $state.Settings = $merged
            if ($state.DataDir) { Save-DpSettings -Settings $merged -Directory $state.DataDir }

            $results = @()
            try { $results = @(Sync-DpMcpServer -Server @($merged.mcpServers)) }
            catch {
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'mcp_sync_failed'; message = "$_" } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpMcpState -Settings $state.Settings -SyncResult $results)
        }
        'refreshMcp' {
            # The Engine lists a server's tools once, at registration, and offers
            # that frozen list for the life of the attachment - which is what stops
            # a server changing its tools after the user approved them. Refreshing
            # is therefore an explicit act, and it is also how a crashed server is
            # restarted.
            if (-not $state.Engine.McpSupported) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'mcp_unsupported'; message = 'This Engine does not support MCP servers. Update ShellPilot to 0.4.0-preview0007 or later.' } }
                return
            }
            $results = @()
            try { $results = @(Sync-DpMcpServer -Server @($state.Settings.mcpServers) -Force) }
            catch {
                Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'mcp_sync_failed'; message = "$_" } }
                return
            }
            Write-DpResponse -Stream $Stream -Json (Get-DpMcpState -Settings $state.Settings -SyncResult $results)
        }
        'getIntercom' {
            Write-DpResponse -Stream $Stream -Json (Get-DpIntercomPayload)
        }
        'getIntercomTurn' {
            # A Turn started from the phone streams over no browser request, and a
            # long-lived SSE channel is impossible on a single-threaded accept
            # loop - it would hold the only thread. The SPA polls this instead
            # while a remote Turn is running, so the window shows the same answer
            # taking shape rather than needing a reload afterwards.
            $remote = $state.Intercom.RemoteTurn
            $text = [string]$remote.text
            $reasoning = [string]$remote.reasoning
            $maxChars = 40000
            $truncated = $text.Length -gt $maxChars
            if ($truncated) { $text = $text.Substring($text.Length - $maxChars) }
            if ($reasoning.Length -gt $maxChars) { $reasoning = $reasoning.Substring($reasoning.Length - $maxChars) }
            Write-DpResponse -Stream $Stream -Json @{
                active         = [bool]$remote.active
                conversationId = [string]$remote.conversationId
                prompt         = [string]$remote.prompt
                startedUtc     = $(if ($remote.startedUtc) { ([DateTime]$remote.startedUtc).ToString('o') } else { $null })
                text           = $text
                reasoning      = $reasoning
                truncated      = $truncated
                # Also the window's liveness poll: Intercom can create, archive,
                # unarchive and delete Conversations, and nothing else would tell
                # the browser its sidebar is now wrong.
                conversationsRevision = [int]$state.ConversationsRevision
            }
        }
        'putIntercom' {
            if ($null -eq $Body) {
                Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'empty_body'; message = 'An Intercom settings body is required.' } }
                return
            }

            # botToken is write-only and never a Setting: it is split off here so it
            # cannot reach settings.json, a Settings export, or any response. The
            # group confirmation is split off for the same structural reason - it is
            # an answer to this request, not a value to store.
            $patch = @{}
            $tokenSupplied = $false
            $token = ''
            $groupConfirmed = $false
            foreach ($property in $Body.PSObject.Properties) {
                if ($property.Name -eq 'botToken') {
                    $tokenSupplied = $true
                    $token = [string]$property.Value
                    continue
                }
                if ($property.Name -eq 'confirmGroupProjects') {
                    $groupConfirmed = [bool]$property.Value
                    continue
                }
                $patch[$property.Name] = $property.Value
            }

            if ($tokenSupplied) {
                $trimmed = $token.Trim()
                if ($trimmed -and $trimmed -notmatch '^\d{6,}:[A-Za-z0-9_-]{30,}$') {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_token'; message = 'That does not look like a Telegram bot token. BotFather gives you one shaped like 123456789:AA…' } }
                    return
                }
                try {
                    $configured = Save-DpIntercomSecret -Token $trimmed -Directory $state.DataDir -Confirm:$false
                }
                catch {
                    Write-DpResponse -Stream $Stream -Status 500 -Json @{ error = @{ code = 'token_store_failed'; message = (Hide-DpIntercomSecret -Text "$_") } }
                    return
                }
                $state.Intercom.Token = $trimmed
                $state.Intercom.TokenConfigured = $configured
                # A new credential invalidates everything the old one established.
                $state.Intercom.Running = $false
                $state.Intercom.PollTask = $null
                $state.Intercom.StatusMessageId = 0
                $state.Intercom.PendingQuestion = $null
                Add-DpIntercomLog -Direction 'system' -Kind 'token' -Detail $(if ($configured) { 'A bot token was stored.' } else { 'The bot token was removed.' })
            }

            if ($patch.Count -gt 0) {
                # Switching group access on is the moment a set of Projects becomes
                # reachable by a membership Telegram controls. The per-Project flag
                # is the control; this is the disclosure, so the grant is never
                # made without the list of what it covers being read first.
                if ($patch.ContainsKey('allowGroupChat') -and [bool]$patch['allowGroupChat'] -and
                    -not [bool]$state.Settings.intercom.allowGroupChat -and -not $groupConfirmed) {
                    $shared = @(@($state.Settings.projects) |
                            Where-Object { $_ -and [bool](Get-DpPropertyValue -InputObject $_ -Name @('intercomGroup') -Default $false) } |
                            ForEach-Object { [string](Get-DpPropertyValue -InputObject $_ -Name @('name') -Default '') })
                    if ($shared.Count -gt 0) {
                        Write-DpResponse -Stream $Stream -Status 409 -Json @{
                            error = @{
                                code     = 'confirm_group_projects'
                                message  = "Everyone in an allow-listed group will be able to run work in $($shared.Count) project$(if ($shared.Count -ne 1) { 's' }) you have already shared with groups, with the same permissions you have - including git push."
                                projects = @($shared)
                            }
                        }
                        return
                    }
                }

                # Group approval is the stronger of the two grants: it hands the
                # group the decision on a command DeskPilot has judged risky enough
                # to stop for. Confirmed on its own, so switching group access on
                # never carries it along.
                if ($patch.ContainsKey('groupApproval') -and [bool]$patch['groupApproval'] -and
                    -not [bool]$state.Settings.intercom.groupApproval -and -not $groupConfirmed) {
                    Write-DpResponse -Stream $Stream -Status 409 -Json @{
                        error = @{
                            code    = 'confirm_group_approval'
                            message = 'Anyone in an allow-listed group will be able to approve a command DeskPilot stopped to ask about, and it will run on this computer with your permissions. They see the command, not what you would see in the window.'
                        }
                    }
                    return
                }

                $groupsBefore = @()
                if ([bool]$state.Settings.intercom.allowGroupChat) { $groupsBefore = @($state.Settings.intercom.groupChatIds) }                try {
                    $merged = Merge-DpSettings -Current $state.Settings -Patch @{ intercom = $patch }
                    $state.Settings = $merged
                    if ($state.DataDir) { Save-DpSettings -Settings $merged -Directory $state.DataDir }
                }
                catch {
                    Write-DpResponse -Stream $Stream -Status 400 -Json @{ error = @{ code = 'bad_settings'; message = "$_" } }
                    return
                }
                $groupsAfter = @()
                if ([bool]$merged.intercom.allowGroupChat) { $groupsAfter = @($merged.intercom.groupChatIds) }
                $dropped = @($groupsBefore | Where-Object { $groupsAfter -notcontains $_ })
                if ($dropped.Count -gt 0 -or (@($groupsAfter | Where-Object { $groupsBefore -notcontains $_ }).Count -gt 0)) {
                    # Work a group asked for must not be reported back to it once it
                    # is no longer allow-listed, so anything still bound to one that
                    # was dropped goes rather than reaching a de-authorised chat.
                    if ($dropped.Count -gt 0) {
                        $pendingChat = ''
                        if ($state.Intercom.PendingQuestion) {
                            $pendingChat = [string](Get-DpPropertyValue -InputObject $state.Intercom.PendingQuestion -Name @('chatId') -Default '')
                        }
                        if ($dropped -contains $pendingChat) { $state.Intercom.PendingQuestion = $null }
                        if ($dropped -contains [string](Get-DpPropertyValue -InputObject $state.Intercom -Name @('QueuedChatId') -Default '')) {
                            $state.Intercom.QueuedPrompt = $null
                            $state.Intercom.QueuedImage = $null
                            $state.Intercom.QueuedChatId = $null
                        }
                        # An attachment fetch spans pump ticks and carries its own
                        # chat, so it survives both other clears.
                        if ($dropped -contains [string](Get-DpPropertyValue -InputObject $state.Intercom.Download -Name @('chatId') -Default '')) {
                            Clear-DpIntercomDownload
                        }
                    }
                    Add-DpIntercomLog -Direction 'system' -Kind 'group' -Detail $(if ($groupsAfter.Count -gt 0) { "Groups $($groupsAfter -join ', ') can now send instructions. Everyone in them has the same control you do." } else { 'Group control is off. Only your own chat can reach DeskPilot.' })
                }
                if ($patch.ContainsKey('chatId')) {
                    # A different allow-listed chat is a different link: close any
                    # pairing window, drop the in-flight poll, and let the pump run
                    # its enable transition again so the backlog is discarded and
                    # the new chat gets the welcome message. Everything bound to the
                    # old chat goes with it - a queued prompt and an attachment fetch
                    # each carry their own copy of it and would otherwise outlive it.
                    $state.Intercom.Running = $false
                    $state.Intercom.PollTask = $null
                    $state.Intercom.StatusMessageId = 0
                    $state.Intercom.PendingQuestion = $null
                    $state.Intercom.QueuedPrompt = $null
                    $state.Intercom.QueuedImage = $null
                    $state.Intercom.QueuedChatId = $null
                    Clear-DpIntercomDownload
                    $state.Intercom.Pairing.active = $false
                    $state.Intercom.Pairing.startedUtc = $null
                    $state.Intercom.Pairing.candidates.Clear()
                    Add-DpIntercomLog -Direction 'system' -Kind 'paired' -Detail $(if ($merged.intercom.chatId) { "Chat $($merged.intercom.chatId) is now the only chat allowed to reach DeskPilot." } else { 'The allowed chat was cleared.' })
                }
            }

            # Apply the change now rather than on the next idle tick, so the panel
            # reports the real state instead of the state it is about to be in.
            try { Update-DpIntercomState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Json (Get-DpIntercomPayload)
        }
        'testIntercom' {
            $intercom = $state.Intercom
            if (-not $intercom.TokenConfigured -or -not $intercom.Client) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_token'; message = 'Store a bot token first.' } }
                return
            }
            $chatId = [string]$state.Settings.intercom.chatId
            if ([string]::IsNullOrWhiteSpace($chatId)) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_chat'; message = 'Enter the chat id that is allowed to control DeskPilot.' } }
                return
            }

            # The one place Intercom waits on the network: the user pressed a
            # button and is watching, and it is bounded by the client timeout.
            $identity = Receive-DpTelegramResponse -Task (Invoke-DpTelegramRequest -Client $intercom.Client -Token $intercom.Token -Operation 'getMe')
            if (-not $identity.ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'telegram_error'; message = "Telegram did not accept the token: $($identity.error)" } }
                return
            }

            $testPayload = @{
                chat_id                  = $chatId
                text                     = "DeskPilot Intercom test from $([Environment]::MachineName). If you can read this, you are connected."
                disable_web_page_preview = $true
            }
            $sent = Receive-DpTelegramResponse -Task (Invoke-DpTelegramRequest -Client $intercom.Client -Token $intercom.Token -Operation 'sendMessage' -Payload $testPayload)
            if (-not $sent.ok) {
                Write-DpResponse -Stream $Stream -Status 502 -Json @{ error = @{ code = 'telegram_error'; message = "The test message was not delivered: $($sent.error)" } }
                return
            }

            Add-DpIntercomLog -Direction 'out' -Kind 'test' -Detail 'Sent a test message.'
            # This call already knows the bot's own @name, which the pump needs to
            # strip an addressing mention off a group message.
            $intercom.BotUsername = [string](Get-DpPropertyValue -InputObject $identity.result -Name @('username') -Default '')
            Write-DpResponse -Stream $Stream -Json @{
                ok      = $true
                botName = [string]$intercom.BotUsername
            }
        }
        'pairIntercom' {
            # Without this the setup cannot be completed at all: Intercom will not
            # listen until it knows which chat is the operator's, so the bot cannot
            # answer - not even /start - and there is no way to learn the chat id
            # from it. This opens a five-minute window in which the poller runs with
            # no allow-list, executes nothing, and only collects who messaged the
            # bot. Adoption stays an explicit click at the machine.
            $intercom = $state.Intercom
            if (-not $intercom.TokenConfigured) {
                Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'no_token'; message = 'Store a bot token first.' } }
                return
            }
            $stop = [bool](Get-DpPropertyValue -InputObject $Body -Name @('stop') -Default $false)
            if ($stop) {
                $intercom.Pairing.active = $false
                $intercom.Pairing.startedUtc = $null
                $intercom.Pairing.candidates.Clear()
                Add-DpIntercomLog -Direction 'system' -Kind 'pairing' -Detail 'Pairing was cancelled.'
            }
            else {
                if (-not [string]::IsNullOrWhiteSpace([string]$state.Settings.intercom.chatId)) {
                    Write-DpResponse -Stream $Stream -Status 409 -Json @{ error = @{ code = 'already_paired'; message = 'A chat is already linked. Clear the chat id first if you want to link a different phone.' } }
                    return
                }
                $intercom.Pairing.active = $true
                $intercom.Pairing.startedUtc = [DateTime]::UtcNow
                $intercom.Pairing.candidates.Clear()
                $intercom.Running = $false
                $intercom.PollTask = $null
                Add-DpIntercomLog -Direction 'system' -Kind 'pairing' -Detail 'Pairing is open for five minutes. Message the bot from your phone.'
            }
            try { Update-DpIntercomState } catch { $null = $_ }
            Write-DpResponse -Stream $Stream -Json (Get-DpIntercomPayload)
        }
        default {
            Write-DpResponse -Stream $Stream -Status 404 -Json @{ error = @{ code = 'not_found'; message = "Unknown handler '$Name'." } }
        }
    }
}
