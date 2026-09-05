function Request-DpBrowserApproval {
    <#
    .SYNOPSIS
        Parks on the approval bridge until the user rules on one navigation.
    .DESCRIPTION
        The gate blocks before anything is requested from the network, so a
        pending card means the address has not been contacted. It uses the same
        rendezvous the terminal gate uses, and for the same reason: a decision
        that arrives after the action is a notification, not an approval.

        Approval is for this host, this Turn and this run only. There is no
        "always allow" here on purpose - decision 0008 records why that button is
        the one a tired operator presses, and the durable widening lives in
        Settings, where it is a considered edit rather than a reflex beside a
        prompt.
    .PARAMETER Context
        The Turn context: conversationId, turnId and project.
    .PARAMETER Decision
        The classifier's verdict, carrying the redacted URL and host.
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
        [object]$Decision,

        [AllowNull()]
        [object]$Bridge,

        [int]$TimeoutMinutes = 15
    )

    if ($null -eq $Bridge -or -not $Bridge.Enabled) {
        return @{ approved = $false; message = 'DeskPilot cannot ask the user about leaving this site right now, so nothing was opened.' }
    }

    if ($TimeoutMinutes -lt 1) { $TimeoutMinutes = 15 }

    $request = New-DpApprovalRequest -Tool 'browser_page' -Class 'BrowserNavigation' `
        -Argument @{ url = $Decision.url; host = $Decision.host } `
        -ProjectName ([string]$Context.project) `
        -ConversationId ([string]$Context.conversationId) `
        -TurnId ([string]$Context.turnId)

    $Bridge.CaptureQuestion(($request | ConvertTo-Json -Depth 6 -Compress))

    $answerText = ''
    try { $answerText = $Bridge.RequestAnswer($TimeoutMinutes * 60) }
    catch [System.TimeoutException] {
        return @{ approved = $false; message = "Nobody approved leaving this site within $TimeoutMinutes minute(s), so nothing was opened." }
    }
    catch {
        return @{ approved = $false; message = 'The turn was stopped before this was approved, so nothing was opened.' }
    }

    $answer = $null
    try { $answer = $answerText | ConvertFrom-Json -ErrorAction Stop } catch { $answer = $null }

    $decisionText = if ($answer -and $answer.PSObject.Properties['decision']) { [string]$answer.decision } else { 'deny' }

    # The fingerprint binds the answer to this URL, Conversation and Turn. An
    # answer that does not carry it back is treated as a denial rather than
    # matched on the request id alone, which a stale grant would also satisfy.
    $returned = if ($answer -and $answer.PSObject.Properties['fingerprint']) { [string]$answer.fingerprint } else { '' }
    if ($decisionText -eq 'approve' -and $returned -ne $request.fingerprint) {
        return @{ approved = $false; message = 'That approval did not match this navigation, so nothing was opened.' }
    }

    if ($decisionText -ne 'approve') {
        $note = if ($answer -and $answer.PSObject.Properties['note']) { ([string]$answer.note).Trim() } else { '' }
        $message = "The user declined to open $($Decision.host)."
        $message += if ($note) { " They said: $note" } else { ' Suggest a different approach, or explain why it is needed.' }
        return @{ approved = $false; message = $message }
    }

    @{ approved = $true; message = '' }
}
