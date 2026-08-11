function Invoke-DpIntercomCommand {
    <#
    .SYNOPSIS
        Executes one normalized Intercom command.
    .DESCRIPTION
        Acts on a command record from ConvertFrom-DpIntercomUpdate. Every path
        either performs the action and acknowledges it, or refuses with a sentence
        a non-expert can act on.

        Two rules hold everywhere:

        A rejected chat is never answered. Replying would confirm the bot exists
        and turn it into a free oracle for anyone probing it; the rejection is
        counted and logged instead.

        Nothing here starts a Turn. A prompt becomes QueuedPrompt and the pump's
        final step runs it once the Engine Runspace is free, so a command arriving
        mid-Turn can never re-enter Invoke-DpTurn.
    .PARAMETER Command
        The command record from ConvertFrom-DpIntercomUpdate.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Drives in-process Intercom state from an already-authorised message; ShouldProcess is not meaningful on the accept thread.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Command
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $intercom.Counters.received++

    if ($Command.kind -eq 'rejected') {
        $intercom.Counters.rejected++
        Add-DpIntercomLog -Direction 'in' -Kind 'rejected' -Detail $Command.reason -Accepted $false
        return
    }

    if ($Command.kind -eq 'ignore') {
        Add-DpIntercomLog -Direction 'in' -Kind 'ignored' -Detail $Command.reason -Accepted $false
        if ($Command.reason -like 'Unknown command*') {
            $null = Send-DpIntercomMessage -Title 'Unknown command' -Line @($Command.reason) -Kind 'notice'
        }
        return
    }

    if ($Command.kind -eq 'edited') {
        Add-DpIntercomLog -Direction 'in' -Kind 'edited' -Detail 'An edited message was acknowledged, not run.' -Accepted $false
        # Almost nobody edits a message on purpose here. In Telegram Desktop and
        # Web, the up arrow in an empty input box opens the last message for
        # editing - a reflex for anyone with shell history habits - and the result
        # looks exactly like sending. Naming that is the difference between a
        # baffling refusal and an obvious one.
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('That arrived as an edit of an earlier message, not as a new one.')
        $lines.Add('Telegram does this when you press the up arrow in an empty message box - it reopens your last message instead of starting a new one.')
        if (-not [string]::IsNullOrWhiteSpace([string]$Command.preview)) {
            $lines.Add("You wrote: $([string]$Command.preview)")
        }
        $lines.Add('Send it again as a new message and I will run it.')
        $null = Send-DpIntercomMessage -Title 'I did not run that.' -Line @($lines.ToArray()) -Kind 'notice'
        return
    }

    $intercom.Counters.accepted++
    Add-DpIntercomLog -Direction 'in' -Kind $Command.kind -Detail $Command.text

    switch ($Command.kind) {
        'answer' {
            $null = Submit-DpIntercomAnswer -Answer ([string]$Command.text)
        }

        'callback' {
            Invoke-DpIntercomCallback -Command $Command
        }

        'stop' {
            if (-not $state.TurnRunning) {
                $null = Send-DpIntercomMessage -Title 'Nothing is running.' -Kind 'notice'
                return
            }
            $state.CancelRequested = $true
            if ($state.Engine.UserPromptBridge) { $state.Engine.UserPromptBridge.Cancel() }
            $intercom.PendingQuestion = $null
            $null = Send-DpIntercomMessage -Title 'Stopping the job.' -Kind 'ack'
        }

        'status' {
            $status = Get-DpIntercomStatus
            $null = Send-DpIntercomMessage -Title $status.title -Line $status.lines -Kind 'status-reply'
        }

        'help' {
            $null = Send-DpIntercomMessage -Title 'DeskPilot Intercom' -Line @(
                'Reply to a question message to answer it.',
                'Send any other text to give the agent a new instruction.',
                '/status - what is happening right now',
                '/chats - list your conversations',
                '/chats all - include the archived ones',
                '/chat 3 - switch to conversation 3',
                '/agents - list the agents you can pick from',
                '/agent 2 - switch to agent 2',
                '/agent none - go back to the default agent',
                '/models - list the models you can pick from',
                '/model 2 - switch to model 2',
                '/model default - go back to the standard model',
                '/projects - list your projects',
                '/project 2 - switch to project 2',
                '/project new C:\Git\Notes - add that folder as a project',
                '/new - start a fresh conversation',
                '/new <text> - start a fresh conversation and do this',
                '/archive 3 - hide conversation 3 from the list',
                '/unarchive 3 - bring an archived one back',
                '/delete 3 - remove it for good (asks first)',
                '/stop - stop the running job',
                '/steer <text> - stop the job, then do this instead',
                '/undo - go back to before the last instruction (asks first)',
                '/help - this list'
            ) -Kind 'help'
        }

        'chats' {
            # Archived conversations are the ones already finished with, so they
            # are out of the way until asked for - which is the only time their
            # numbers are needed, to bring one back.
            $includeArchived = ([string]$Command.text).Trim().ToLowerInvariant() -in @('all', 'archived')
            $chats = @(Get-DpIntercomChatList -IncludeArchived:$includeArchived)
            if ($chats.Count -eq 0) {
                $null = Send-DpIntercomMessage -Title 'There are no conversations yet.' -Line @('Send /new to start one.') -Kind 'chats'
                return
            }
            # Remember what each number pointed at: the list is ordered by last
            # activity, so running a Turn reorders it under the operator's feet.
            $intercom.ChatIndex = @($chats | ForEach-Object { $_.id })
            $lines = @($chats | ForEach-Object {
                    '{0}. {1}{2}{3}' -f $_.number, $_.title,
                    $(if ($_.archived) { '  (archived)' } else { '' }),
                    $(if ($_.current) { '  <- current' } else { '' })
                })
            $footer = if ($includeArchived) {
                @('', 'Tap one to switch, or send /unarchive 2 to bring one back and /new to start one.')
            }
            else {
                @('', 'Tap one to switch, or send /chats all to include archived and /new to start one.')
            }
            # Buttons make the number redundant for the common case, but it stays in
            # the text: /archive, /unarchive and /delete still take one.
            $choices = @($chats | ForEach-Object {
                    @{ label = '{0}. {1}{2}' -f $_.number, $_.title, $(if ($_.current) { ' <- current' } else { '' }); data = "k|$($_.id)" }
                })
            $listParams = @{
                Title = $(if ($includeArchived) { 'Your conversations (including archived)' } else { 'Your conversations' })
                Line  = ($lines + $footer)
                Kind  = 'chats'
            }
            $keyboard = Get-DpIntercomKeyboard -Choice $choices
            if ($keyboard) { $listParams.Keyboard = $keyboard }
            $null = Send-DpIntercomMessage @listParams
        }

        'chat' {
            if ([string]::IsNullOrWhiteSpace($Command.text)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /chats to see the list, then /chat 2.') -Kind 'notice'
                return
            }
            $choice = 0
            if (-not [int]::TryParse($Command.text.Trim(), [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'That is not a number from the list.' -Line @('Send /chats to see it again.') -Kind 'notice'
                return
            }
            $resolved = Resolve-DpIntercomChat -Number $choice
            if (-not $resolved.ok) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @($resolved.message) -Kind 'notice'
                return
            }
            $intercom.ConversationId = [string]$resolved.conversation.id
            $null = Send-DpIntercomMessage -Title 'Switched.' -Line @(
                "Now working in: $([string]$resolved.conversation.title)",
                'Send an instruction, or /chats to switch again.'
            ) -Kind 'chat'
        }

        'agents' {
            $agents = @(Get-DpIntercomAgentList)
            if ($agents.Count -eq 0) {
                $null = Send-DpIntercomMessage -Title 'There are no agents to pick from.' -Line @(
                    'DeskPilot found no agent files. Add one at the machine, under Settings > Agents.'
                ) -Kind 'agents'
                return
            }
            # Remember what each number pointed at, the same way /chats does: the
            # folder can gain or lose a file between listing and picking.
            $intercom.AgentIndex = @($agents | ForEach-Object { $_.id })
            $lines = @($agents | ForEach-Object {
                    '{0}. {1}{2}' -f $_.number, $_.name, $(if ($_.current) { '  <- current' } else { '' })
                })
            $listParams = @{
                Title = 'Your agents'
                Line  = ($lines + @('', 'Tap one to switch, or send /agent none for the default one.'))
                Kind  = 'agents'
            }
            # The id is a file name and has no length bound, so the button carries
            # the number instead - a whole keyboard dropped over one long file name
            # would be a worse trade here than it is for a question.
            $keyboard = Get-DpIntercomKeyboard -Choice @($agents | ForEach-Object {
                    @{ label = '{0}. {1}{2}' -f $_.number, $_.name, $(if ($_.current) { ' <- current' } else { '' }); data = "g|$($_.number)" }
                })
            if ($keyboard) { $listParams.Keyboard = $keyboard }
            $null = Send-DpIntercomMessage @listParams
        }

        'agent' {
            $argument = ([string]$Command.text).Trim()
            if ([string]::IsNullOrWhiteSpace($argument)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /agents to see the list, then /agent 2.') -Kind 'notice'
                return
            }
            if ($argument.ToLowerInvariant() -in @('none', 'off', 'default')) {
                Switch-DpIntercomAgent -AgentId ''
                return
            }
            $choice = 0
            if (-not [int]::TryParse($argument, [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'That is not a number from the list.' -Line @('Send /agents to see it again.') -Kind 'notice'
                return
            }
            $index = @($intercom.AgentIndex)
            $agentId = if ($choice -ge 1 -and $choice -le $index.Count) { [string]$index[$choice - 1] }
            else { [string](@(Get-DpIntercomAgentList) | Where-Object { $_.number -eq $choice } | Select-Object -First 1 -ExpandProperty id) }
            if (-not $agentId) {
                $null = Send-DpIntercomMessage -Title "There is no agent $choice." -Line @('Send /agents to see the list.') -Kind 'notice'
                return
            }
            Switch-DpIntercomAgent -AgentId $agentId
        }

        'models' {
            $models = @(Get-DpIntercomModelList)
            if ($models.Count -eq 0) {
                # Two different causes, and the operator can only act on one of
                # them: asking the single-threaded Engine Runspace mid-Turn would
                # freeze the window, so the list is simply not available yet.
                $reason = if ($state.TurnRunning) { 'A job is running, and I cannot ask the engine for the list while it works. Send /models again when it finishes.' }
                else { 'The engine offered none. Check the GitHub Copilot sign-in at the machine.' }
                $null = Send-DpIntercomMessage -Title 'I could not list the models.' -Line @($reason) -Kind 'models'
                return
            }
            # Remember what each number pointed at, the same way /chats does: the
            # list belongs to the account, not to DeskPilot.
            $intercom.ModelIndex = @($models | ForEach-Object { $_.id })
            $lines = @($models | ForEach-Object {
                    '{0}. {1}{2}' -f $_.number, $_.id, $(if ($_.current) { '  <- current' } else { '' })
                })
            $listParams = @{
                Title = 'Your models'
                Line  = ($lines + @('', 'Tap one to switch, or send /model default for the standard one.'))
                Kind  = 'models'
            }
            # A Model id is short today but it is the provider's string, not one
            # DeskPilot bounds, so the button carries the number rather than risking
            # the whole keyboard on the 64-byte callback_data cap.
            $keyboard = Get-DpIntercomKeyboard -Choice @($models | ForEach-Object {
                    @{ label = '{0}. {1}{2}' -f $_.number, $_.id, $(if ($_.current) { ' <- current' } else { '' }); data = "m|$($_.number)" }
                })
            if ($keyboard) { $listParams.Keyboard = $keyboard }
            $null = Send-DpIntercomMessage @listParams
        }

        'model' {
            $argument = ([string]$Command.text).Trim()
            if ([string]::IsNullOrWhiteSpace($argument)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /models to see the list, then /model 2.') -Kind 'notice'
                return
            }
            if ($argument.ToLowerInvariant() -in @('default', 'none', 'off')) {
                Switch-DpIntercomModel -ModelId ''
                return
            }
            $choice = 0
            if (-not [int]::TryParse($argument, [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'That is not a number from the list.' -Line @('Send /models to see it again.') -Kind 'notice'
                return
            }
            $index = @($intercom.ModelIndex)
            $modelId = if ($choice -ge 1 -and $choice -le $index.Count) { [string]$index[$choice - 1] }
            else { [string](@(Get-DpIntercomModelList) | Where-Object { $_.number -eq $choice } | Select-Object -First 1 -ExpandProperty id) }
            if (-not $modelId) {
                $null = Send-DpIntercomMessage -Title "There is no model $choice." -Line @('Send /models to see the list.') -Kind 'notice'
                return
            }
            Switch-DpIntercomModel -ModelId $modelId
        }

        'projects' {
            $projects = @(Get-DpIntercomProjectList)
            if ($projects.Count -eq 0) {
                $null = Send-DpIntercomMessage -Title 'There are no projects yet.' -Line @(
                    'Send /project new C:\Git\Notes to add one, or add it at the machine under Settings > Projects.'
                ) -Kind 'projects'
                return
            }
            $intercom.ProjectIndex = @($projects | ForEach-Object { $_.id })
            # Whether a Project allows remote control is the fact that decides
            # whether the next instruction runs at all, so it is on every line
            # rather than discovered through a refusal.
            $lines = @($projects | ForEach-Object {
                    '{0}. {1}{2}{3}' -f $_.number, $_.name,
                    $(if ($_.current) { '  <- current' } else { '' }),
                    $(if ($_.remote) { '' } else { '  (remote control off)' })
                })
            $listParams = @{
                Title = 'Your projects'
                Line  = ($lines + @('', 'Tap one to switch, or send /project new <folder> to add one.'))
                Kind  = 'projects'
            }
            $keyboard = Get-DpIntercomKeyboard -Choice @($projects | ForEach-Object {
                    @{ label = '{0}. {1}{2}' -f $_.number, $_.name, $(if ($_.current) { ' <- current' } else { '' }); data = "p|$($_.id)" }
                })
            if ($keyboard) { $listParams.Keyboard = $keyboard }
            $null = Send-DpIntercomMessage @listParams
        }

        'project' {
            $argument = ([string]$Command.text).Trim()
            if ([string]::IsNullOrWhiteSpace($argument)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @(
                    'Send /projects to see the list, then /project 2.',
                    'Or /project new C:\Git\Notes to add a folder.'
                ) -Kind 'notice'
                return
            }
            $parts = $argument -split '\s+', 2
            if ($parts[0].ToLowerInvariant() -eq 'new') {
                New-DpIntercomProject -Path $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
                return
            }
            $choice = 0
            if (-not [int]::TryParse($argument, [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'That is not a number from the list.' -Line @('Send /projects to see it again.') -Kind 'notice'
                return
            }
            $index = @($intercom.ProjectIndex)
            $projectId = if ($choice -ge 1 -and $choice -le $index.Count) { [string]$index[$choice - 1] }
            else { [string](@(Get-DpIntercomProjectList) | Where-Object { $_.number -eq $choice } | Select-Object -First 1 -ExpandProperty id) }
            if (-not $projectId) {
                $null = Send-DpIntercomMessage -Title "There is no project $choice." -Line @('Send /projects to see the list.') -Kind 'notice'
                return
            }
            Switch-DpIntercomProject -ProjectId $projectId
        }

        'archive' {
            $choice = 0
            if (-not [int]::TryParse(([string]$Command.text).Trim(), [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /chats to see the list, then /archive 2.') -Kind 'notice'
                return
            }
            $resolved = Resolve-DpIntercomChat -Number $choice
            if (-not $resolved.ok) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @($resolved.message) -Kind 'notice'
                return
            }
            $resolved.conversation.archived = $true
            Update-DpIntercomChatBinding -ConversationId ([string]$resolved.conversation.id)
            $null = Send-DpIntercomMessage -Title 'Archived.' -Line @(
                "Hidden from the list: $([string]$resolved.conversation.title)",
                'Send /chats all to see it again, or /unarchive to bring it back.'
            ) -Kind 'archive'
        }

        'unarchive' {
            $choice = 0
            if (-not [int]::TryParse(([string]$Command.text).Trim(), [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /chats all to see the archived ones, then /unarchive 2.') -Kind 'notice'
                return
            }
            $resolved = Resolve-DpIntercomChat -Number $choice -IncludeArchived
            if (-not $resolved.ok) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @($resolved.message) -Kind 'notice'
                return
            }
            if (-not [bool](Get-DpPropertyValue -InputObject $resolved.conversation -Name @('archived') -Default $false)) {
                $null = Send-DpIntercomMessage -Title 'That one is not archived.' -Line @(
                    "Already in the list: $([string]$resolved.conversation.title)"
                ) -Kind 'notice'
                return
            }
            $resolved.conversation.archived = $false
            Update-DpIntercomChatBinding -ConversationId ([string]$resolved.conversation.id)
            $null = Send-DpIntercomMessage -Title 'Unarchived.' -Line @(
                "Back in the list: $([string]$resolved.conversation.title)",
                'Send /chats to see it, or /chat <n> to switch to it.'
            ) -Kind 'unarchive'
        }

        'delete' {
            $parts = ([string]$Command.text).Trim() -split '\s+', 2
            $choice = 0
            if (-not [int]::TryParse($parts[0], [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /chats to see the list, then /delete 2.') -Kind 'notice'
                return
            }
            $resolved = Resolve-DpIntercomChat -Number $choice
            if (-not $resolved.ok) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @($resolved.message) -Kind 'notice'
                return
            }
            $title = [string]$resolved.conversation.title
            # Deleting is the one irreversible thing Intercom can do, and a phone
            # is where a mistyped number is most likely, so it takes two messages.
            if ($parts.Count -lt 2 -or $parts[1].Trim().ToLowerInvariant() -ne 'confirm') {
                $null = Send-DpIntercomMessage -Title 'This cannot be undone.' -Line @(
                    "About to delete: $title",
                    "Send /delete $choice confirm to go ahead, or /archive $choice to just hide it."
                ) -Kind 'notice'
                return
            }
            $null = $state.Conversations.Remove([string]$resolved.conversation.id)
            Update-DpIntercomChatBinding -ConversationId ([string]$resolved.conversation.id)
            $null = Send-DpIntercomMessage -Title 'Deleted.' -Line @($title) -Kind 'delete'
        }

        'undo' {
            $confirmed = ([string]$Command.text).Trim().ToLowerInvariant() -eq 'confirm'
            Restore-DpIntercomCheckpoint -Confirmed:$confirmed
        }

        'steer' {
            if ([string]::IsNullOrWhiteSpace($Command.text)) {
                $null = Send-DpIntercomMessage -Title 'Add the new instruction after /steer.' -Kind 'notice'
                return
            }
            $decision = Test-DpIntercomProject -Settings $state.Settings
            if (-not $decision.allowed) {
                $null = Send-DpIntercomMessage -Title 'I cannot do that from here.' -Line @($decision.reason) -Kind 'refused'
                return
            }
            if ($state.TurnRunning) {
                $state.CancelRequested = $true
                if ($state.Engine.UserPromptBridge) { $state.Engine.UserPromptBridge.Cancel() }
                $intercom.PendingQuestion = $null
            }
            $intercom.QueuedPrompt = [string]$Command.text
            $null = Send-DpIntercomMessage -Title 'Stopping, then doing that instead.' -Kind 'ack'
        }

        'new' {
            if ($state.TurnRunning) {
                $null = Send-DpIntercomMessage -Title 'A job is running.' -Line @('Send /stop first, or /steer <text> to replace it.') -Kind 'notice'
                return
            }
            # A bare /new only moves where Intercom is pointing, so it needs no
            # Project permission; only running work in the Project does.
            $hasWork = -not [string]::IsNullOrWhiteSpace($Command.text)
            if ($hasWork) {
                $decision = Test-DpIntercomProject -Settings $state.Settings
                if (-not $decision.allowed) {
                    $null = Send-DpIntercomMessage -Title 'I cannot do that from here.' -Line @($decision.reason) -Kind 'refused'
                    return
                }
            }
            $conversation = New-DpConversation -Model $state.Settings.model
            $state.Conversations[$conversation.id] = $conversation
            if ($state.DataDir) { Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir }
            $state.ConversationsRevision = [int]$state.ConversationsRevision + 1
            $intercom.ConversationId = $conversation.id
            $intercom.ChatIndex = @()
            if ($hasWork) {
                $intercom.QueuedPrompt = [string]$Command.text
                $null = Send-DpIntercomMessage -Title 'New conversation started. Working on it.' -Kind 'ack'
            }
            else {
                $null = Send-DpIntercomMessage -Title 'New conversation started.' -Line @('Send an instruction whenever you are ready.') -Kind 'ack'
            }
        }

        'prompt' {
            $decision = Test-DpIntercomProject -Settings $state.Settings
            if (-not $decision.allowed) {
                $null = Send-DpIntercomMessage -Title 'I cannot do that from here.' -Line @($decision.reason) -Kind 'refused'
                return
            }
            if ($Command.attachment) {
                Start-DpIntercomDownload -Attachment $Command.attachment -Caption ([string]$Command.text)
                return
            }
            if ($intercom.QueuedPrompt) {
                $null = Send-DpIntercomMessage -Title 'One instruction is already queued.' -Line @('Send /stop if you want to replace what is running.') -Kind 'notice'
                return
            }
            $intercom.QueuedPrompt = [string]$Command.text
            if ($state.TurnRunning) {
                $null = Send-DpIntercomMessage -Title 'Queued - it will run when the current job finishes.' -Kind 'ack'
            }
            else {
                $null = Send-DpIntercomMessage -Title 'Got it, working on it.' -Kind 'ack'
            }
        }
    }
}
