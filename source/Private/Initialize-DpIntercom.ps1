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
        # Large enough for a Telegram file download, which the Bot API caps at
        # 20 MB and Intercom caps again by its own setting.
        $client.MaxResponseContentBufferSize = 25MB
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
        # The Conversation ids behind the numbers the last /chats listing showed,
        # so /chat 3 selects what the operator saw even though the list reorders
        # itself by last activity.
        ChatIndex        = @()
        # The same snapshot for /agents, /models and /projects: a folder can gain
        # or lose an agent file, the account's model list is the provider's to
        # change, and a Project can be added at the machine, between the listing
        # and the tap.
        AgentIndex       = @()
        ModelIndex       = @()
        ProjectIndex     = @()
        Offset           = 0
        # The first poll only learns the newest update id and discards the
        # backlog: acting on a command the operator sent while DeskPilot was not
        # running would be a genuinely dangerous surprise on startup.
        Priming          = $true
        PollTask         = $null
        SendTask         = $null
        SendRecord       = $null
        Outbound         = [System.Collections.Generic.Queue[hashtable]]::new()
        # A message Telegram rejected once, held for a plain-text retry ahead of
        # anything still queued behind it.
        Retry            = $null
        StatusMessageId  = 0
        # The forwarded Ask-User question awaiting a reply: its Telegram message id
        # is the nonce, so only a reply to that exact message is accepted.
        PendingQuestion  = $null
        # A prompt received from the phone, run by the pump's final step once the
        # Engine Runspace is free. This is also how /steer resumes after its stop.
        QueuedPrompt     = $null
        # An image Attachment to hand the Engine's Vision input alongside it.
        QueuedImage      = $null
        # A file the operator sent, being fetched across two Telegram calls. Both
        # are started on one pump tick and reaped on a later one, because a
        # multi-megabyte download on the accept thread would freeze the window.
        Download         = @{
            stage      = ''
            task       = $null
            fileId     = ''
            fileName   = ''
            mimeType   = ''
            isImage    = $false
            caption    = ''
            startedUtc = $null
        }
        LastActivityUtc  = [DateTime]::UtcNow
        # What a Turn started from the phone is producing right now. The browser
        # has no request to stream over for a remote Turn, and the single-threaded
        # accept loop rules out a long-lived SSE channel, so the Host Server keeps
        # the running answer here and the SPA polls it.
        RemoteTurn       = @{
            active         = $false
            conversationId = $null
            prompt         = ''
            startedUtc     = $null
            text           = ''
            reasoning      = ''
        }
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
