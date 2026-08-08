function Get-DpIntercomPayload {
    <#
    .SYNOPSIS
        Projects Intercom state for GET /api/intercom.
    .DESCRIPTION
        Builds the response the Settings panel renders: the configuration, whether
        a token is stored, live status, counters and the audit log.

        The bot token is never included. It is a bearer credential that grants
        control of this machine, and the API's job is to report that one is
        configured, not what it is.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $settings = $state.Settings.intercom

    $projectDecision = Test-DpIntercomProject -Settings $state.Settings

    $status = if (-not $settings.enabled) { 'off' }
    elseif (-not $intercom.TokenConfigured) { 'needs-token' }
    elseif ([string]::IsNullOrWhiteSpace([string]$settings.chatId)) { 'needs-chat' }
    elseif ($intercom.LastError) { 'error' }
    elseif ($intercom.Running) { 'on' }
    else { 'starting' }

    @{
        enabled                = [bool]$settings.enabled
        status                 = $status
        tokenConfigured        = [bool]$intercom.TokenConfigured
        chatId                 = [string]$settings.chatId
        heartbeatMinutes       = [int]$settings.heartbeatMinutes
        stallMinutes           = [int]$settings.stallMinutes
        questionTimeoutMinutes = [int]$settings.questionTimeoutMinutes
        maxMessagesPerHour     = [int]$settings.maxMessagesPerHour
        notifyOnDone           = [bool]$settings.notifyOnDone
        sendFinalAnswer        = [bool]$settings.sendFinalAnswer
        projectAllowed         = [bool]$projectDecision.allowed
        projectReason          = [string]$projectDecision.reason
        questionPending        = [bool]$intercom.PendingQuestion
        promptQueued           = [bool]$intercom.QueuedPrompt
        lastPollUtc            = $(if ($intercom.LastPollUtc) { ([DateTime]$intercom.LastPollUtc).ToString('o') } else { $null })
        nextCheckInUtc         = $(if ($intercom.NextCheckInUtc) { ([DateTime]$intercom.NextCheckInUtc).ToString('o') } else { $null })
        lastError              = [string]$intercom.LastError
        counters               = @{
            received = [int]$intercom.Counters.received
            accepted = [int]$intercom.Counters.accepted
            rejected = [int]$intercom.Counters.rejected
            sent     = [int]$intercom.Counters.sent
            dropped  = [int]$intercom.Counters.dropped
            errors   = [int]$intercom.Counters.errors
        }
        log                    = @(@($intercom.Log) | Select-Object -Last 50)
    }
}
