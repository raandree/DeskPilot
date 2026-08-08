function Stop-DpIntercom {
    <#
    .SYNOPSIS
        Sends the Intercom farewell and releases its HTTP client.
    .DESCRIPTION
        Called from the accept loop's finally, so a clean shutdown - Ctrl+C, a
        relaunch after an update, closing the window - tells the phone instead of
        just going quiet. Silence is the one state Intercom cannot otherwise
        explain, so every exit it can observe is announced.

        This is the only place Intercom waits on the network, and it is bounded:
        the server is already stopping, there is no accept loop left to block, and
        a dead network costs at most the timeout below.

        A sudden power loss or a hard kill still cannot be reported. That residual
        gap is stated in spec 110 and in the getting-started guide; the live status
        message and its "next check-in by" time are what cover it.
    .PARAMETER TimeoutSeconds
        How long to wait for the farewell to be delivered.
    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 5
    )

    $state = $script:DeskPilot
    if (-not $state) { return }
    $intercom = $state.Intercom
    if (-not $intercom -or -not $intercom.Client) { return }

    if (-not $PSCmdlet.ShouldProcess('Intercom', 'Send the shutdown notice and release the HTTP client')) { return }

    try {
        if ($intercom.Running -and $state.Settings.intercom -and $state.Settings.intercom.chatId) {
            $payload = @{
                chat_id                  = [string]$state.Settings.intercom.chatId
                text                     = "DeskPilot has stopped on $([Environment]::MachineName).`nIntercom is off until it is started again."
                disable_web_page_preview = $true
            }
            $requestParams = @{
                Client    = $intercom.Client
                Token     = $intercom.Token
                Operation = 'sendMessage'
                Payload   = $payload
            }
            $task = Invoke-DpTelegramRequest @requestParams
            $null = $task.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
    }
    catch { $null = $_ }
    finally {
        $intercom.Running = $false
        try { $intercom.Client.Dispose() } catch { $null = $_ }
        $intercom.Client = $null
    }
}
