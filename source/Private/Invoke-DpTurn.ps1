function Invoke-DpTurn {
    <#
    .SYNOPSIS
        Runs one Turn and streams the assistant response over SSE.
    .DESCRIPTION
        Records the user Message, assembles the Engine parameters from Settings and
        the Conversation, runs Invoke-Shp asynchronously on the Engine Runspace,
        captures the streamed answer (and optional reasoning) from the
        Information stream as SSE delta frames, then emits a final done frame with
        the authoritative content, Activity and Usage. On failure it emits an
        error frame and leaves Conversation history unchanged.
    .PARAMETER Conversation
        The Conversation hashtable to run the Turn against.
    .PARAMETER Prompt
        The user prompt.
    .PARAMETER Image
        Paths to image Attachments for the Engine's native Vision input.
    .PARAMETER Stream
        The network stream to write SSE frames to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Conversation,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [AllowEmptyCollection()]
        [string[]]$Image = @(),

        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream
    )

    $writer = New-DpSseWriter -Stream $Stream
    $script:DeskPilot.TurnRunning = $true
    $script:DeskPilot.CancelRequested = $false
    if ($script:DeskPilot.Intercom) {
        $script:DeskPilot.Intercom.LastActivityUtc = [DateTime]::UtcNow
        $script:DeskPilot.Intercom.StallNotified = $false
    }
    $startTime = [DateTime]::UtcNow
    $assistantId = New-DpId -Prefix 'm'
    $settings = $script:DeskPilot.Settings
    $shell = $null
    $userPromptBridge = $script:DeskPilot.Engine.UserPromptBridge
    $engineUsageBefore = $null
    $stoppedUsageEstimate = $null

    # Per-Turn Task List state. This is a fresh function-local on every Turn, so one
    # Turn's list never bleeds into the next. It holds the latest list streamed live
    # from ShpProgress records and is only a fallback: the authoritative final list
    # comes from result.TodoList (see below). pendingEvent/pendingText buffer a run of
    # same-kind text frames so a fast token stream is coalesced into one socket write
    # per drain instead of one write per token (see $emit / $flush). reasoning keeps
    # the whole Thinking trace this Turn streamed, which a Stop has nothing else to
    # fall back on.
    $turnState = @{
        tasks        = @()
        emitted      = 0
        pendingEvent = $null
        pendingText  = [System.Text.StringBuilder]::new()
        reasoning    = [System.Text.StringBuilder]::new()
    }

    # Flush the buffered text frame (a coalesced run of same-kind 'delta'/'reasoning'
    # records) to the client. Idempotent: a no-op when nothing is buffered. Called
    # after every stream drain and whenever the frame kind changes.
    $flush = {
        if ($turnState.pendingEvent -and $turnState.pendingText.Length -gt 0) {
            $pending = $turnState.pendingText.ToString()
            $writer.Write((ConvertTo-DpSseFrame -EventName $turnState.pendingEvent -Data @{ text = $pending }))
            if ($turnState.pendingEvent -eq 'reasoning') { [void]$turnState.reasoning.Append($pending) }
            # A Turn started from the phone has no browser request to stream over,
            # so the same text is also buffered for the SPA to poll (spec 110).
            $remote = if ($script:DeskPilot.Intercom) { $script:DeskPilot.Intercom.RemoteTurn } else { $null }
            if ($remote -and $remote.active) {
                if ($turnState.pendingEvent -eq 'reasoning') { $remote.reasoning += $pending }
                else { $remote.text += $pending }
            }
        }
        $turnState.pendingEvent = $null
        [void]$turnState.pendingText.Clear()
    }

    # Publish a pending Engine Read-Host request once. GetPendingRequest marks
    # the request emitted, so this can run on every 10 ms stream drain without
    # duplicating the in-thread card. The matching answer arrives through the
    # mid-Turn request pump and releases the Engine pipeline on the bridge.
    $emitUserPrompt = {
        if (-not $userPromptBridge) { return }
        $request = $userPromptBridge.GetPendingRequest()
        if ($null -eq $request) { return }
        $questionnaire = ConvertTo-DpQuestionnaire -InputObject $request.Question
        & $flush
        $turnState.emitted = [int]$turnState.emitted + 1
        $writer.Write((ConvertTo-DpSseFrame -EventName 'question' -Data @{
                    id         = $request.Id
                    structured = [bool]$questionnaire.structured
                    title      = $questionnaire.title
                    questions  = $questionnaire.questions
                }))
        # The phone learns about the question in the same breath as the window, so
        # an operator who is away is never the last to know (spec 110).
        try {
            $questionParams = @{
                RequestId      = [string]$request.Id
                ConversationId = [string]$request.ConversationId
                Questionnaire  = $questionnaire
            }
            Send-DpIntercomQuestion @questionParams
        }
        catch {
            $intercomError = $_
            Write-Verbose "Could not forward the question to Intercom: $intercomError"
        }
    }

    # Translate each Engine Information record into at most one SSE frame:
    # ShpProgress 'TodoList' records become live 'tasks' frames (and refresh the
    # Turn-local list), tool-call / unknown progress records are consumed silently,
    # and ordinary host echo becomes a 'delta' (answer) or, under -ShowThinking, a
    # 'reasoning' frame. All of that classification lives in Get-DpStreamFrame.
    #
    # To keep a fast token stream smooth without a JSON-encode + socket write per
    # token, consecutive same-kind text frames are coalesced: $emit appends to a
    # buffer and $flush (at the end of each drain) writes it as one frame. A 'tasks'
    # frame or a change of kind flushes the buffer first, so frame ordering is
    # preserved exactly.
    $emit = {
        param($Record)
        # Intercom's stall watchdog measures silence, so every record the Engine
        # produces is proof of life - stamped before any of it is interpreted.
        if ($script:DeskPilot.Intercom) { $script:DeskPilot.Intercom.LastActivityUtc = [DateTime]::UtcNow }
        if ($userPromptBridge) {
            $questionText = Get-DpUserPromptText -Record $Record
            if ($questionText) { $userPromptBridge.CaptureQuestion($questionText) }
        }
        $decision = Get-DpStreamFrame -Record $Record -ShowThinking:([bool]$settings.showThinking)
        if ($null -eq $decision) { return }
        # Count frames produced this Turn (buffered or written) so the retry below
        # knows whether anything has streamed yet (retrying is only safe before the
        # first frame, so answer text is never duplicated).
        $turnState.emitted = [int]$turnState.emitted + 1
        if ($decision.event -eq 'tasks') {
            & $flush
            $turnState.tasks = $decision.Tasks
            $writer.Write((ConvertTo-DpSseFrame -EventName 'tasks' -Data $decision.data))
            return
        }
        # A 'delta' or 'reasoning' text frame: flush first if the kind changed, then
        # buffer this record's text for the next $flush.
        if ($turnState.pendingEvent -and $turnState.pendingEvent -ne $decision.event) { & $flush }
        $turnState.pendingEvent = $decision.event
        [void]$turnState.pendingText.Append([string]$decision.data.text)
    }

    try {
        $questionnaireEnabled = [bool]$settings.permissions.askUser
        $questionnaireToolParams = @{
            Runspace = $script:DeskPilot.Engine.Runspace
            Enabled  = $questionnaireEnabled
        }
        $null = Set-DpQuestionnaireTool @questionnaireToolParams

        $userMessage = @{
            id         = New-DpId -Prefix 'm'
            role       = 'user'
            text       = $Prompt
            createdUtc = [DateTime]::UtcNow.ToString('o')
        }
        $Conversation.messages.Add($userMessage)
        $Conversation.updatedUtc = $userMessage.createdUtc
        if ($Conversation.title -eq 'New conversation') {
            $trimmed = $Prompt.Substring(0, [Math]::Min(60, $Prompt.Length))
            if ($Prompt.Length -gt 60) { $trimmed += '…' }
            $Conversation.title = $trimmed
        }

        $writer.Write((ConvertTo-DpSseFrame -EventName 'start' -Data @{ messageId = $assistantId; userMessageId = $userMessage.id }))

        $agentPrompt = $null
        if ($settings.selectedAgent -and $settings.agentsRoot) {
            try { $agentPrompt = Get-DpAgentSystemPrompt -Root $settings.agentsRoot -Id $settings.selectedAgent } catch { $agentPrompt = $null }
        }

        # The agent's persistent Memory (durable notes about the user + environment),
        # injected into every Turn's system prompt so past learning carries forward.
        $agentMemory = if ($script:DeskPilot.Memory) { [string]$script:DeskPilot.Memory.text } else { '' }

        # Resolve the effective Model (Conversation-pinned, else the Settings
        # default, else DeskPilot's default) and its advertised reasoning efforts
        # from the capability cache the /api/models route fills. The resolved id is
        # what the Turn runs on, so a Conversation that pins nothing runs on the
        # Model DeskPilot reports as the default rather than on the Engine's own.
        # New-DpTurnParameter forwards the global reasoning-effort Setting only when
        # this Model lists it, so a Model that supports none (for example
        # claude-haiku-4.5) never receives reasoning_effort and cannot fail the Turn
        # with an HTTP 400.
        $effectiveModelId = if ($Conversation.model) { $Conversation.model } elseif ($settings.model) { $settings.model } else { $script:DeskPilot.DefaultModel }
        $modelEfforts = @()
        if ($effectiveModelId) {
            $modelEntry = @($script:DeskPilot.Models) | Where-Object { $_.id -eq $effectiveModelId } | Select-Object -First 1
            if ($modelEntry) { $modelEfforts = @($modelEntry.reasoningEfforts) }
        }

        $params = New-DpTurnParameter -Prompt $Prompt -Image $Image -History @($Conversation.history) -Settings $settings -Model $effectiveModelId -AgentSystemPrompt $agentPrompt -AgentMemory $agentMemory -ModelReasoningEfforts $modelEfforts
        if ($settings.showThinking) { $params.ShowThinking = $true }

        # A hard pipeline stop can interrupt the Engine before its normal result
        # and Usage-log append. Capture a pre-Turn Usage summary and an input-cost
        # estimate while the Runspace is idle. On cancellation, an exact summary
        # delta wins; the estimate is an explicitly labelled fallback.
        try {
            $usageCommandParams = @{
                Command   = 'Get-ShpUsage'
                Parameter = @{ Summary = $true }
            }
            $engineUsageBefore = Invoke-DpEngineCommand @usageCommandParams |
                Select-Object -Last 1
        }
        catch {
            $usageProbeError = $_
            Write-Verbose "Could not capture pre-Turn Engine Usage: $usageProbeError"
        }
        if ($userPromptBridge -and [bool]$settings.permissions.askUser) {
            $userPromptBridge.BeginTurn([string]$Conversation.id)
        }

        # Reposition the long-lived Engine Runspace every Turn, not only when a
        # Project is selected. The runspace keeps whatever working directory it
        # was last given, so a no-Project Turn would otherwise inherit the folder
        # DeskPilot was launched from (which may hold a .memory-bank the agent
        # then reads and mistakes for the user's) or a previously selected
        # Project. Get-DpEngineWorkingDir yields the Workspace Folder when a
        # Project is active, else a neutral data-directory scratch folder,
        # keeping the working directory deterministic.
        $null = Set-DpEngineLocation -Path (Get-DpEngineWorkingDir -WorkspaceFolder $settings.workspaceFolder)

        # Capture what the files look like BEFORE the agent runs. Without this,
        # "undo what DeskPilot did" can only mean "revert to the last commit",
        # which also throws away whatever the user had changed by hand.
        $turnSnapshotSha = ''
        if ($settings.workspaceFolder) {
            $snapshot = New-DpChangeSnapshot -Root $settings.workspaceFolder -Id $assistantId
            if ($snapshot.sha) { $turnSnapshotSha = $snapshot.sha }
        }

        # The same snapshot, made addressable from the transcript: the user Message
        # carries the Checkpoint the thread offers to go back to.
        if ($turnSnapshotSha) {
            $userMessage.checkpoint = @{
                sha        = $turnSnapshotSha
                root       = [string]$settings.workspaceFolder
                createdUtc = [DateTime]::UtcNow.ToString('o')
            }
        }

        # Run the Engine call with a bounded retry for transient PRE-STREAM
        # failures. ShellPilot exchanges the GitHub token for a short-lived Copilot
        # session token at the start of every Turn, and that exchange intermittently
        # returns 403 (or 429/5xx); previously the whole Turn failed and the user had
        # to stop and resend. Retry only while nothing has streamed yet
        # ($turnState.emitted -eq 0) so no answer text is ever duplicated, and only
        # for transient errors - a genuine 401/expired token is surfaced, not retried.
        $maxAttempts = 3
        $attempt = 0
        $result = $null
        while ($true) {
            $attempt++
            $shell = [powershell]::Create()
            $shell.Runspace = $script:DeskPilot.Engine.Runspace
            $null = $shell.AddCommand('Invoke-Shp')
            foreach ($key in $params.Keys) { $null = $shell.AddParameter($key, $params[$key]) }

            $info = $shell.Streams.Information
            $lastIndex = 0
            $heartbeat = 0
            $async = $shell.BeginInvoke()
            while ($true) {
                while ($lastIndex -lt $info.Count) {
                    & $emit $info[$lastIndex]
                    $lastIndex++
                }
                & $emitUserPrompt
                # Write the coalesced text buffer for this batch, then either finish or
                # yield briefly. A short 10 ms poll keeps streaming smooth (tokens reach
                # the browser in ~10 ms bursts, not 40 ms) while Start-Sleep stays a
                # cancellation checkpoint; the idle CPU cost of the poll is negligible.
                & $flush
                if ($async.IsCompleted) { break }
                # The Host Server accepts requests inline on this single thread, so a
                # concurrent POST /stop would otherwise wait in the backlog until this
                # Turn ended - the Stop button would do nothing. Service any pending
                # request here so the stopTurn handler can flip CancelRequested, which
                # the next line then observes and aborts the Engine pipeline.
                Invoke-DpPendingRequest
                if ($script:DeskPilot.CancelRequested) {
                    & $flush
                    try {
                        $writer.Write((ConvertTo-DpSseFrame -EventName 'stopping' -Data @{ message = 'Turn stopped.' }))
                    }
                    catch {
                        $streamError = $_
                        Write-Verbose "Could not stream the stopping event: $streamError"
                    }
                    try {
                        $stopAsync = $shell.BeginStop($null, $null)
                        while (-not $stopAsync.IsCompleted) {
                            Invoke-DpPendingRequest
                            Start-Sleep -Milliseconds 10
                        }
                        $shell.EndStop($stopAsync)
                    }
                    catch {
                        $stopError = $_
                        Write-Verbose "Asynchronous Engine stop failed: $stopError"
                        try { $shell.Stop() } catch { $null = $_ }
                    }
                    break
                }
                Start-Sleep -Milliseconds 10
                # ~10 s between keep-alive comments (1000 x 10 ms), unchanged in
                # wall-clock from the prior 250 x 40 ms cadence.
                $heartbeat++
                if ($heartbeat -ge 1000) { $writer.Write(": heartbeat`n`n"); $heartbeat = 0 }
            }
            while ($lastIndex -lt $info.Count) { & $emit $info[$lastIndex]; $lastIndex++ }
            & $emitUserPrompt
            & $flush

            if ($script:DeskPilot.CancelRequested) {
                try { $shell.EndInvoke($async) | Out-Null } catch { $null = $_ }

                $engineUsageAfter = $null
                try {
                    $usageCommandParams = @{
                        Command   = 'Get-ShpUsage'
                        Parameter = @{ Summary = $true }
                    }
                    $engineUsageAfter = Invoke-DpEngineCommand @usageCommandParams |
                        Select-Object -Last 1
                }
                catch {
                    $usageProbeError = $_
                    Write-Verbose "Could not capture post-stop Engine Usage: $usageProbeError"
                }
                try {
                    $estimateTextParams = @{
                        TurnParameter = $params
                        History       = @($Conversation.history)
                        Prompt        = $Prompt
                    }
                    $estimateText = Get-DpStoppedTurnEstimateText @estimateTextParams
                    $estimateParams = @{ Text = $estimateText }
                    if ($effectiveModelId) { $estimateParams.Model = $effectiveModelId }
                    $estimateCommandParams = @{
                        Command   = 'Get-ShpCostEstimate'
                        Parameter = $estimateParams
                    }
                    $stoppedUsageEstimate = Invoke-DpEngineCommand @estimateCommandParams |
                        Select-Object -Last 1
                }
                catch {
                    $estimateError = $_
                    Write-Verbose "Could not estimate stopped-Turn Usage: $estimateError"
                }
                $stoppedUsageParams = @{
                    Before   = $engineUsageBefore
                    After    = $engineUsageAfter
                    Estimate = $stoppedUsageEstimate
                }
                $stoppedUsage = Get-DpStoppedTurnUsage @stoppedUsageParams
                $usedModel = if ($effectiveModelId) { $effectiveModelId } else { $settings.model }
                # A hard Stop discards the Engine result, so result.Reasoning never
                # arrives. What already streamed into the Thinking pane is the only
                # surviving record of what the Turn was thinking, and without this a
                # stopped Turn reloads with an empty pane.
                $stoppedReasoning = if ($turnState.reasoning.Length -gt 0) { $turnState.reasoning.ToString() } else { $null }
                $stoppedMessage = @{
                    id         = $assistantId
                    role       = 'assistant'
                    text       = ''
                    stopped    = $true
                    stopReason = 'Turn stopped.'
                    reasoning  = $stoppedReasoning
                    activity   = @{ filesRead = @(); filesWritten = @(); commandsRun = @(); pagesFetched = @(); questionsAsked = @(); toolCalls = @() }
                    usage      = $stoppedUsage
                    tasks      = $turnState.tasks
                    model      = $usedModel
                    durationMs = [int]([DateTime]::UtcNow - $startTime).TotalMilliseconds
                    createdUtc = [DateTime]::UtcNow.ToString('o')
                }
                $Conversation.messages.Add($stoppedMessage)
                $Conversation.updatedUtc = $stoppedMessage.createdUtc
                Update-DpUsage -Usage $stoppedUsage -Model $usedModel
                if ($script:DeskPilot.DataDir) {
                    $saveParams = @{
                        Store     = $script:DeskPilot.Conversations
                        Directory = $script:DeskPilot.DataDir
                    }
                    Save-DpConversationStore @saveParams
                }
                $writer.Write((ConvertTo-DpSseFrame -EventName 'stopped' -Data $stoppedMessage))
                return
            }

            try {
                $result = $shell.EndInvoke($async) | Select-Object -Last 1
                if ($shell.HadErrors -and $null -eq $result) {
                    $firstError = $shell.Streams.Error | Select-Object -First 1
                    throw ($(if ($firstError) { $firstError.ToString() } else { 'The Engine returned an error.' }))
                }
                break
            }
            catch {
                # Retry a transient pre-stream failure (for example the session-token
                # exchange returning 403) so the user is not forced to stop and resend.
                # Gated on emitted -eq 0 so a mid-stream failure never duplicates output.
                if ($attempt -lt $maxAttempts -and [int]$turnState.emitted -eq 0 -and (Test-DpTransientEngineError -ErrorRecord $_)) {
                    try { $shell.Dispose() } catch { $null = $_ }
                    $shell = $null
                    Start-Sleep -Milliseconds (400 * $attempt)
                    if ($script:DeskPilot.CancelRequested) {
                        $writer.Write((ConvertTo-DpSseFrame -EventName 'error' -Data @{ message = 'Turn stopped.' }))
                        return
                    }
                    continue
                }
                throw
            }
        }

        $mapped = ConvertFrom-DpEngineResult -Result $result

        $newHistory = @(Get-DpPropertyValue -InputObject $result -Name @('History') -Default @())
        if ($newHistory.Count -gt 0) {
            $Conversation.history = $newHistory
        }
        else {
            $fallback = @($Conversation.history)
            $fallback += @{ role = 'user'; content = $Prompt }
            $fallback += @{ role = 'assistant'; content = $mapped.content }
            $Conversation.history = $fallback
        }

        $usedModel = if ($Conversation.model) { $Conversation.model } else { $settings.model }
        # Prefer the Engine's authoritative final Task List (result.TodoList, mapped to
        # $mapped.tasks). Fall back to the last list streamed live this Turn only when
        # the result carried none.
        $finalTasks = $mapped.tasks
        if (-not (@($finalTasks).Count -gt 0)) { $finalTasks = $turnState.tasks }
        $assistantMessage = @{
            id         = $assistantId
            role       = 'assistant'
            text       = $mapped.content
            reasoning  = $mapped.reasoning
            activity   = $mapped.activity
            usage      = $mapped.usage
            tasks      = $finalTasks
            model      = $usedModel
            durationMs = [int]([DateTime]::UtcNow - $startTime).TotalMilliseconds
            createdUtc = [DateTime]::UtcNow.ToString('o')
        }
        $Conversation.messages.Add($assistantMessage)
        $Conversation.updatedUtc = $assistantMessage.createdUtc

        # Track what the agent wrote as a pending change, so it stays reviewable
        # after this Turn and after a reload - until the user keeps or undoes it.
        if ($settings.workspaceFolder) {
            $written = @(Get-DpPropertyValue -InputObject $mapped.activity -Name @('filesWritten') -Default @())
            if ($written.Count -gt 0) {
                $null = Add-DpChangeEntry -Store $script:DeskPilot.Changes -Root $settings.workspaceFolder -Paths ([string[]]$written) -SnapshotSha $turnSnapshotSha -ConversationId ([string]$Conversation.id)
                if ($script:DeskPilot.DataDir) { Save-DpChangeStore -Store $script:DeskPilot.Changes -Directory $script:DeskPilot.DataDir }
            }
        }

        Update-DpUsage -Usage $mapped.usage -Model $usedModel

        if ($script:DeskPilot.DataDir) {
            Save-DpConversationStore -Store $script:DeskPilot.Conversations -Directory $script:DeskPilot.DataDir
        }

        $writer.Write((ConvertTo-DpSseFrame -EventName 'done' -Data $assistantMessage))
    }
    catch {
        $message = "$_"
        try { $writer.Write((ConvertTo-DpSseFrame -EventName 'error' -Data @{ message = $message })) } catch { $null = $_ }
    }
    finally {
        if ($userPromptBridge) { $userPromptBridge.EndTurn() }
        $script:DeskPilot.TurnRunning = $false
        $script:DeskPilot.CancelRequested = $false
        if ($shell) { try { $shell.Dispose() } catch { $null = $_ } }
        try { $writer.Flush(); $writer.Dispose() } catch { $null = $_ }
    }
}
