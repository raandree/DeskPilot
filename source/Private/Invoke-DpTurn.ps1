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
    .PARAMETER Stream
        The network stream to write SSE frames to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Conversation,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream
    )

    $writer = New-DpSseWriter -Stream $Stream
    $script:DeskPilot.TurnRunning = $true
    $script:DeskPilot.CancelRequested = $false
    $startTime = [DateTime]::UtcNow
    $assistantId = New-DpId -Prefix 'm'
    $settings = $script:DeskPilot.Settings
    $shell = $null

    # Per-Turn Task List state. This is a fresh function-local on every Turn, so one
    # Turn's list never bleeds into the next. It holds the latest list streamed live
    # from ShpProgress records and is only a fallback: the authoritative final list
    # comes from result.TodoList (see below).
    $turnState = @{ tasks = @() }

    # Translate each Engine Information record into at most one SSE frame:
    # ShpProgress 'TodoList' records become live 'tasks' frames (and refresh the
    # Turn-local list), tool-call / unknown progress records are consumed silently,
    # and ordinary host echo becomes a 'delta' (answer) or, under -ShowThinking, a
    # 'reasoning' frame. All of that classification lives in Get-DpStreamFrame.
    $emit = {
        param($Record)
        $decision = Get-DpStreamFrame -Record $Record -ShowThinking:([bool]$settings.showThinking)
        if ($null -eq $decision) { return }
        if ($decision.event -eq 'tasks') { $turnState.tasks = $decision.Tasks }
        $writer.Write((ConvertTo-DpSseFrame -EventName $decision.event -Data $decision.data))
    }

    try {
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
        $params = New-DpTurnParameter -Prompt $Prompt -History @($Conversation.history) -Settings $settings -Model $Conversation.model -AgentSystemPrompt $agentPrompt
        if ($settings.showThinking) { $params.ShowThinking = $true }

        # Reposition the long-lived Engine Runspace every Turn, not only when a
        # Project is selected. The runspace keeps whatever working directory it
        # was last given, so a no-Project Turn would otherwise inherit the folder
        # DeskPilot was launched from (which may hold a .memory-bank the agent
        # then reads and mistakes for the user's) or a previously selected
        # Project. Get-DpEngineWorkingDir yields the Workspace Folder when a
        # Project is active, else a neutral data-directory scratch folder,
        # keeping the working directory deterministic.
        $null = Set-DpEngineLocation -Path (Get-DpEngineWorkingDir -WorkspaceFolder $settings.workspaceFolder)

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
            if ($async.IsCompleted) { break }
            if ($script:DeskPilot.CancelRequested) { try { $shell.Stop() } catch { $null = $_ }; break }
            Start-Sleep -Milliseconds 40
            $heartbeat++
            if ($heartbeat -ge 250) { $writer.Write(": heartbeat`n`n"); $heartbeat = 0 }
        }
        while ($lastIndex -lt $info.Count) { & $emit $info[$lastIndex]; $lastIndex++ }

        if ($script:DeskPilot.CancelRequested) {
            try { $shell.EndInvoke($async) | Out-Null } catch { $null = $_ }
            $writer.Write((ConvertTo-DpSseFrame -EventName 'error' -Data @{ message = 'Turn stopped.' }))
            return
        }

        $result = $shell.EndInvoke($async) | Select-Object -Last 1
        if ($shell.HadErrors -and $null -eq $result) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw ($(if ($firstError) { $firstError.ToString() } else { 'The Engine returned an error.' }))
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
        $script:DeskPilot.TurnRunning = $false
        $script:DeskPilot.CancelRequested = $false
        if ($shell) { try { $shell.Dispose() } catch { $null = $_ } }
        try { $writer.Flush(); $writer.Dispose() } catch { $null = $_ }
    }
}
