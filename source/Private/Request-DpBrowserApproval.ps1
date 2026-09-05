function Request-DpBrowserApproval {
    <#
    .SYNOPSIS
        Parks on the approval bridge until the user rules on one browser action.
    .DESCRIPTION
        The gate blocks before anything happens, so a pending card means the
        address has not been contacted and the form has not been submitted. It
        uses the same rendezvous the terminal gate uses, and for the same reason:
        a decision that arrives after the action is a notification, not an
        approval.

        Every write action is approved individually, with no safe-list. The
        terminal has one because `git status` is genuinely routine and a gate
        that interrupts on it gets switched off; there is no equivalent on the
        web, where every write has an external effect on somebody else's system.
        A "routine" web submission is a category error.

        Approval covers this action, this Turn and these exact values. The
        fingerprint binds the values themselves, so an approval for one set
        cannot be spent on another - which matters most here, because the values
        are the part an injected page would want to change.
    .PARAMETER Context
        The Turn context: conversationId, turnId and project.
    .PARAMETER Class
        BrowserNavigation for leaving the site, BrowserAction for a write.
    .PARAMETER Argument
        The allow-listed fields the card is built from.
    .PARAMETER Subject
        What to name in a denial message, for example a host or an action.
    .PARAMETER Bridge
        The approval rendezvous.
    .PARAMETER TimeoutMinutes
        How long an unanswered request waits before it is denied.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [ValidateSet('BrowserNavigation', 'BrowserAction')]
        [string]$Class,

        [Parameter(Mandatory)]
        [hashtable]$Argument,

        [AllowEmptyString()]
        [string]$Subject = 'that',

        [AllowNull()]
        [object]$Bridge,

        [int]$TimeoutMinutes = 15
    )

    if ($null -eq $Bridge -or -not $Bridge.Enabled) {
        return @{ approved = $false; message = 'DeskPilot cannot ask the user about this right now, so nothing was done.' }
    }

    if ($TimeoutMinutes -lt 1) { $TimeoutMinutes = 15 }

    $request = New-DpApprovalRequest -Tool 'browser_page' -Class $Class `
        -Argument $Argument `
        -ProjectName ([string]$Context.project) `
        -ConversationId ([string]$Context.conversationId) `
        -TurnId ([string]$Context.turnId)

    $Bridge.CaptureQuestion(($request | ConvertTo-Json -Depth 6 -Compress))

    $answerText = ''
    try { $answerText = $Bridge.RequestAnswer($TimeoutMinutes * 60) }
    catch [System.TimeoutException] {
        return @{ approved = $false; message = "Nobody approved this within $TimeoutMinutes minute(s), so nothing was done." }
    }
    catch {
        return @{ approved = $false; message = 'The turn was stopped before this was approved, so nothing was done.' }
    }

    $answer = $null
    try { $answer = $answerText | ConvertFrom-Json -ErrorAction Stop } catch { $answer = $null }

    $decisionText = if ($answer -and $answer.PSObject.Properties['decision']) { [string]$answer.decision } else { 'deny' }

    # The fingerprint binds the answer to this action, these values, this
    # Conversation and this Turn. An answer that does not carry it back is
    # treated as a denial rather than matched on the request id alone, which a
    # stale grant would also satisfy.
    $returned = if ($answer -and $answer.PSObject.Properties['fingerprint']) { [string]$answer.fingerprint } else { '' }
    if ($decisionText -eq 'approve' -and $returned -ne $request.fingerprint) {
        return @{ approved = $false; message = 'That approval did not match this action, so nothing was done.' }
    }

    if ($decisionText -ne 'approve') {
        $note = if ($answer -and $answer.PSObject.Properties['note']) { ([string]$answer.note).Trim() } else { '' }
        $message = "The user declined $Subject."
        $message += if ($note) { " They said: $note" } else { ' Suggest a different approach, or explain why it is needed.' }
        return @{ approved = $false; message = $message }
    }

    @{ approved = $true; message = '' }
}
