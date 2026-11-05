function Add-DpIntercomIdentityFailure {
    <#
    .SYNOPSIS
        Records a failed getMe lookup and schedules the next one.
    .DESCRIPTION
        Intercom learns its own @name from getMe. Without it, a leading mention
        stays in the prompt, and with requireGroupMention on no group Message is
        accepted except a reply to the pending question. The log line names the
        consequence that applies now, so the operator is not left guessing why
        a group went quiet.

        The lookup is asked again after 30 seconds, then 2, 10 and 30 minutes. A
        failure at startup is usually a network that is not up yet; asking for
        the rest of the session would add an error line every few minutes for a
        token that is simply wrong, which the poll reports anyway. After the last
        attempt the line says how to ask again by hand.
    .PARAMETER Problem
        What failed, as a sentence opening such as "Telegram did not tell me my
        own name".
    .PARAMETER Cause
        The error Telegram or the transport reported. Redacted before logging.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Problem,

        [AllowEmptyString()]
        [string]$Cause = ''
    )

    $intercom = $script:DeskPilot.Intercom
    $settings = Get-DpPropertyValue -InputObject $script:DeskPilot.Settings -Name @('intercom') -Default @{}
    $intercom.Counters.errors++

    $groupsAllowed = [bool](Get-DpPropertyValue -InputObject $settings -Name @('allowGroupChat') -Default $false) -and
        @(Get-DpPropertyValue -InputObject $settings -Name @('groupChatIds') -Default @()).Count -gt 0
    $mentionRequired = [bool](Get-DpPropertyValue -InputObject $settings -Name @('requireGroupMention') -Default $true)
    $consequence = if ($groupsAllowed -and $mentionRequired) {
        'so I ignore every group Message except a reply to my question'
    }
    else {
        'so a leading @mention will stay in the prompt'
    }

    $retryDelaySeconds = @(30, 120, 600, 1800)
    # A lookup the caller started without counting it is still the first one.
    $attempt = [Math]::Max(1, [int](Get-DpPropertyValue -InputObject $intercom -Name @('IdentityAttempts') -Default 0))
    $intercom['IdentityAttempts'] = $attempt
    if ($attempt -le $retryDelaySeconds.Count) {
        $delay = $retryDelaySeconds[$attempt - 1]
        $intercom['IdentityRetryUtc'] = [DateTime]::UtcNow.AddSeconds($delay)
        $wait = if ($delay -lt 60) { "$delay seconds" } else { "$($delay / 60) minutes" }
        $next = "I will ask again in $wait."
    }
    else {
        $intercom['IdentityRetryUtc'] = $null
        $next = 'I stopped asking. Press Send a test message in Settings > Intercom, or switch Intercom off and on, to ask again.'
    }

    $line = "$Problem, $consequence. $next"
    if (-not [string]::IsNullOrWhiteSpace($Cause)) { $line += " ($(Hide-DpIntercomSecret -Text $Cause))" }
    Add-DpIntercomLog -Direction 'system' -Kind 'identity-error' -Accepted $false -Detail $line
}
