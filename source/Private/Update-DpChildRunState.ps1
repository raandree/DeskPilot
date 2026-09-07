function Update-DpChildRunState {
    <#
    .SYNOPSIS
        Advances child state and records completed work on the Host Server.
    .DESCRIPTION
        Runs on the accept loop, never in the parent Engine Runspace. Revokes
        captured scope immediately, writes one inert transcript reference, and
        preserves unknown Usage with known partial consumption. Child prose
        never enters parent history, active HTML, Memory, or Intercom.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Records an explicitly consented child outcome on the Host Server accept loop; there is no separate interactive operation.')]
    param()

    $state = $script:DeskPilot
    $child = Get-DpPropertyValue -InputObject $state -Name 'Child'
    if (-not $child) { return }
    $controller = $child.Controller
    if (-not $controller) { return }
    if (-not $controller.Completion.IsCompleted) {
        $policy = $state.Settings.childExecution
        $enabled = [bool]$policy.enabled -and $policy.profile -ceq 'single-child-v3' -and $policy.budgetMode -ceq 'provider-estimate'
        $controller.UpdatePermissions([bool]$state.Settings.permissions.file, [bool]$state.Settings.permissions.terminal, $enabled, ($policy.projectAccess -ceq 'read-write'))
        if ($state.CancelRequested) { $controller.Stop() }
        return
    }
    if ($child.Recorded) { return }
    $snapshot = $controller.Snapshot() | ConvertFrom-Json -AsHashtable -Depth 24
    $child.Last = $snapshot
    $child.CleanupBlocked = -not [bool]$snapshot.cleanupSucceeded
    $state.TurnRunning = [bool]$child.CleanupBlocked
    $state.CancelRequested = $false
    $conversation = $state.Conversations[$snapshot.conversationId]
    if (-not $conversation) { $child.CleanupBlocked = $true; throw 'The child Conversation is missing.' }
    $rawUsage = $snapshot.usage
    $usage = @{
        promptTokens = $null; completionTokens = $null; totalTokens = $null; costUSD = $null; credits = $null
        usageKnown = $false; partial = $true; priced = $false; budgetMode = 'provider-estimate'
        reservedTokens = $null; reservedCostUSD = $null; knownUsage = $null
    }
    if ($rawUsage) {
        $usage.usageKnown = [bool]$rawUsage.UsageKnown
        $usage.partial = -not $usage.usageKnown
        $usage.priced = $usage.usageKnown -and $null -ne $rawUsage.CostUSD
        $fields = @{ promptTokens = 'PromptTokens'; completionTokens = 'CompletionTokens'; totalTokens = 'TotalTokens'; costUSD = 'CostUSD'; credits = 'Credits'; reservedTokens = 'ReservedTokens'; reservedCostUSD = 'ReservedCostUSD' }
        foreach ($name in $fields.Keys) {
            $usage[$name] = $rawUsage[$fields[$name]]
        }
        if ($rawUsage.KnownUsage) {
            $usage.knownUsage = @{
                promptTokens = $rawUsage.KnownUsage.PromptTokens
                completionTokens = $rawUsage.KnownUsage.CompletionTokens
                totalTokens = $rawUsage.KnownUsage.TotalTokens
                costUSD = $rawUsage.KnownUsage.CostUSD
                credits = $rawUsage.KnownUsage.Credits
            }
        }
    }
    $now = [datetime]::UtcNow.ToString('o')
    $messages = @(
        @{ id = $snapshot.parentTurnId; role = 'user'; text = $child.Prompt; createdUtc = $now; childRunId = $snapshot.id }
        @{
            id = New-DpId -Prefix 'm'; role = 'assistant'; text = ('Private child run: ' + $snapshot.status + '.')
            createdUtc = $now; childRunId = $snapshot.id; childProfile = 'single-child-v3'; budgetMode = 'provider-estimate'
            usage = $usage; tools = @{ filesRead = @($snapshot.filesRead); filesWritten = @(); commandsRun = @($snapshot.commandsRun) }
            model = $snapshot.model; status = $snapshot.status
        }
    )
    foreach ($message in $messages) {
        $existing = @($conversation.messages | Where-Object { $_.id -ceq $message.id })
        if ($existing.Count -eq 0) { $conversation.messages.Add($message) }
    }
    $conversation.updatedUtc = $now
    Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
    $partial = if ($usage.usageKnown) { $usage } else { $usage.knownUsage }
    $accrual = @{
        promptTokens = $(if ($partial) { $partial.promptTokens } else { $null })
        completionTokens = $(if ($partial) { $partial.completionTokens } else { $null })
        totalTokens = $(if ($partial) { $partial.totalTokens } else { $null })
        costUSD = $(if ($partial) { $partial.costUSD } else { $null })
        credits = $(if ($partial) { $partial.credits } else { $null })
        priced = $usage.priced
    }
    Update-DpUsage -Usage $accrual -Model $snapshot.model
    $child.Recorded = $true
    $controller.Dispose()
    $child.Controller = $null
}
