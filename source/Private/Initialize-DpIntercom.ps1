function Initialize-DpIntercom {
    <#
    .SYNOPSIS
        Builds the Intercom runtime state block for the Host Server.
    .DESCRIPTION
        Creates the in-memory state Intercom keeps for one Host Server launch: the
        shared HttpClient, the bot token read from its protected store, the
        outbound queue, the audit ring, the rolling rate window and the counters.

        Nothing here contacts the network. The pump (Update-DpIntercomState)
        decides on its first tick whether Intercom should actually run, based on
        the Settings, the token and the allow-listed chat.
    .PARAMETER Directory
        The data directory holding intercom.secret.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Directory
    )

    $token = Read-DpIntercomSecret -Directory $Directory

    $client = $null
    try {
        $client = [System.Net.Http.HttpClient]::new()
        # Must exceed the long-poll timeout below, or every idle poll would fault.
        $client.Timeout = [TimeSpan]::FromSeconds(45)
        # A bounded read, so a hostile or broken response cannot exhaust memory.
        $client.MaxResponseContentBufferSize = 4MB
    }
    catch {
        Write-Verbose "Could not create the Intercom HTTP client: $_"
    }

    @{
        Client           = $client
        Token            = $token
        TokenConfigured  = -not [string]::IsNullOrWhiteSpace($token)
        Running          = $false
        StartedUtc       = $null
        ConversationId   = $null
        Offset           = 0
        # The first poll only learns the newest update id and discards the
        # backlog: acting on a command the operator sent while DeskPilot was not
        # running would be a genuinely dangerous surprise on startup.
        Priming          = $true
        PollTask         = $null
        SendTask         = $null
        SendRecord       = $null
        Outbound         = [System.Collections.Generic.Queue[hashtable]]::new()
        StatusMessageId  = 0
        # The forwarded Ask-User question awaiting a reply: its Telegram message id
        # is the nonce, so only a reply to that exact message is accepted.
        PendingQuestion  = $null
        # A prompt received from the phone, run by the pump's final step once the
        # Engine Runspace is free. This is also how /steer resumes after its stop.
        QueuedPrompt     = $null
        LastActivityUtc  = [DateTime]::UtcNow
        StallNotified    = $false
        LastHeartbeatUtc = $null
        NextCheckInUtc   = $null
        LastPollUtc      = $null
        LastError        = ''
        Counters         = @{ received = 0; accepted = 0; rejected = 0; sent = 0; dropped = 0; errors = 0 }
        Log              = [System.Collections.Generic.List[object]]::new()
        RateWindow       = [System.Collections.Generic.List[DateTime]]::new()
        # A time-boxed window, opened by hand from Settings, in which the poller
        # runs with no allow-list purely to collect the chat ids that message the
        # bot. Nothing is executed and nothing is adopted without a click - see
        # Add-DpIntercomPairingCandidate.
        Pairing          = @{
            active     = $false
            startedUtc = $null
            candidates = [System.Collections.Generic.List[object]]::new()
        }
    }
}
