function Get-DpIntercomStatus {
    <#
    .SYNOPSIS
        Builds the structured status Intercom reports to the phone.
    .DESCRIPTION
        One source for both the /status reply and the live status message, so the
        two can never disagree. Every value is a structured fact DeskPilot owns -
        machine name, Conversation title, Project, elapsed time, whether a question
        is waiting - rather than text the agent authored.

        The status message carries an explicit "next check-in by" time. That is
        how a dead machine is detected: DeskPilot edits this message on a timer and
        Telegram does not notify on an edit, so when the machine stops the message
        simply freezes with a deadline that has passed. Absence becomes a
        self-dating fact instead of an ambiguous silence.
    .OUTPUTS
        System.Collections.Hashtable with title and lines.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $settings = $state.Settings

    $conversation = $null
    if ($intercom.ConversationId) { $conversation = $state.Conversations[$intercom.ConversationId] }

    $projectName = 'none'
    $projectAllowed = $false
    if ($settings.selectedProjectId) {
        $decision = Test-DpIntercomProject -Settings $settings
        if ($decision.project) { $projectName = [string]$decision.project.name }
        $projectAllowed = [bool]$decision.allowed
    }

    $status = if ($intercom.PendingQuestion) { 'waiting for your answer' }
    elseif ($state.TurnRunning) { 'working' }
    else { 'idle' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Machine: $([Environment]::MachineName)")
    $lines.Add("Status: $status")
    $lines.Add("Conversation: $(if ($conversation) { [string]$conversation.title } else { 'none yet' })")
    $lines.Add("Project: $projectName$(if (-not $projectAllowed) { ' (remote control off)' })")
    # The file stem, not the display name: resolving that means parsing every
    # agent file, and this runs on every heartbeat.
    $agentName = if ($settings.selectedAgent) { ([string]$settings.selectedAgent) -replace '\.agent\.md$', '' } else { 'default' }
    $lines.Add("Agent: $agentName")
    # The resolved id, not the Settings field: a Conversation's own pin outranks
    # it, so naming the Setting here would report a Model the next Turn will not
    # run on.
    $modelId = Get-DpIntercomModelId
    $lines.Add("Model: $(if ($modelId) { $modelId } else { 'default' })")

    if ($state.TurnRunning) {
        $quiet = [int]([DateTime]::UtcNow - $intercom.LastActivityUtc).TotalMinutes
        $lines.Add("Last agent activity: $(if ($quiet -lt 1) { 'just now' } else { "$quiet min ago" })")
    }
    if ($intercom.QueuedPrompt) { $lines.Add('Queued: one instruction is waiting for the current job to finish.') }

    $nowLocal = [DateTime]::Now
    $lines.Add("Checked in: $($nowLocal.ToString('HH:mm:ss'))")
    if ($intercom.NextCheckInUtc) {
        $lines.Add("Next check-in by: $(([DateTime]$intercom.NextCheckInUtc).ToLocalTime().ToString('HH:mm:ss')) - if this time has passed, DeskPilot has stopped.")
    }

    # Which build is actually loaded. A DeskPilot left running across a rebuild
    # keeps the old functions in memory, which looks exactly like a broken feature:
    # the file on disk has the fix and the machine does not. Best-effort - the
    # status message is the heartbeat, so it must never be the thing that throws.
    try {
        $module = $ExecutionContext.SessionState.Module
        if ($module -and $module.Path -and (Test-Path -LiteralPath $module.Path)) {
            $built = (Get-Item -LiteralPath $module.Path).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            $lines.Add("Build: $built - restart DeskPilot if that is older than your last change.")
        }
    }
    catch {
        Write-Verbose "Could not read the loaded module's build stamp: $_"
    }

    @{ title = 'DeskPilot Intercom'; lines = @($lines.ToArray()) }
}
