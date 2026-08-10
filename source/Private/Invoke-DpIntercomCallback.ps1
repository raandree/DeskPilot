function Invoke-DpIntercomCallback {
    <#
    .SYNOPSIS
        Acts on a tapped inline-keyboard button.
    .DESCRIPTION
        A button tap is answered twice: once to Telegram, so the button stops
        spinning, and once to the operator, so they can see what it did.

        The `callback_data` is a token this bot minted, but it arrives from the
        client and is treated as untrusted all the same. Every branch validates it
        before acting - and an option tap must carry the nonce of the question
        currently waiting, so a button from a question that has already been
        answered or has expired cannot answer the next one. That is the whole
        reason the nonce exists: old buttons stay on screen in Telegram forever.
    .PARAMETER Command
        The 'callback' command record from ConvertFrom-DpIntercomUpdate.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Drives in-process Intercom state from an already-authorised tap; ShouldProcess is not meaningful on the accept thread.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Command
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom

    # Telegram shows the button as loading until this lands, so it is queued first
    # and bypasses the hourly cap: it is a protocol obligation, not a notification.
    $callbackId = [string](Get-DpPropertyValue -InputObject $Command -Name @('callbackId') -Default '')
    if ($callbackId) {
        $intercom.Outbound.Enqueue(@{
                kind      = 'callback-ack'
                text      = 'Acknowledged a button tap.'
                capture   = ''
                edit      = $false
                plainOnly = $true
                keyboard  = $null
                operation = 'answerCallbackQuery'
                payload   = @{ callback_query_id = $callbackId }
            })
    }

    $parts = ([string]$Command.text) -split '\|'
    switch ($parts[0]) {
        'q' {
            $pending = $intercom.PendingQuestion
            $token = if ($pending) { [string](Get-DpPropertyValue -InputObject $pending -Name @('token') -Default '') } else { '' }
            if ($parts.Count -lt 3 -or -not $token -or $parts[1] -ne $token) {
                $null = Send-DpIntercomMessage -Title 'That question has moved on.' -Line @(
                    'Those buttons belong to a question that is no longer waiting.',
                    'Send /status to see what is happening.'
                ) -Kind 'notice'
                return
            }
            $options = @(Get-DpPropertyValue -InputObject $pending -Name @('options') -Default @())
            $index = -1
            if (-not [int]::TryParse($parts[2], [ref]$index) -or $index -lt 0 -or $index -ge $options.Count) {
                $null = Send-DpIntercomMessage -Title 'I did not recognise that choice.' -Line @('Reply to the question with your answer instead.') -Kind 'notice'
                return
            }
            $null = Submit-DpIntercomAnswer -Answer ([string]$options[$index])
        }

        'k' {
            if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) { return }
            $conversation = $state.Conversations[[string]$parts[1]]
            if (-not $conversation) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @('It may have been deleted. Send /chats for the current list.') -Kind 'notice'
                return
            }
            $intercom.ConversationId = [string]$conversation.id
            $null = Send-DpIntercomMessage -Title 'Switched.' -Line @(
                [string]$conversation.title,
                'Send an instruction whenever you are ready.'
            ) -Kind 'chat'
        }

        'g' {
            # An Agent id is a file name with no length bound, so this button
            # carries the number from the listing that produced it.
            $index = @($intercom.AgentIndex)
            $number = 0
            if ($parts.Count -lt 2 -or -not [int]::TryParse($parts[1], [ref]$number) -or $number -lt 1 -or $number -gt $index.Count) {
                $null = Send-DpIntercomMessage -Title 'That list has moved on.' -Line @('Send /agents for the current one.') -Kind 'notice'
                return
            }
            Switch-DpIntercomAgent -AgentId ([string]$index[$number - 1])
        }

        'p' {
            if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) { return }
            Switch-DpIntercomProject -ProjectId ([string]$parts[1])
        }

        default {
            Add-DpIntercomLog -Direction 'in' -Kind 'callback-unknown' -Detail "Unrecognised button data '$([string]$Command.text)'." -Accepted $false
        }
    }
}
