function Hide-DpIntercomSecret {
    <#
    .SYNOPSIS
        Removes the Intercom bot token from text before it is shown or logged.
    .DESCRIPTION
        The bot token travels in every Telegram request URL, so an unredacted
        transport error - "No such host is known (api.telegram.org/bot12345:ABC)"
        - would print a bearer credential into the audit log, a route response, or
        the console. Every Intercom error string passes through here first.

        Redacts both the configured token (when the state holds one) and anything
        with the shape of a Telegram token, so a token from an earlier
        configuration in a buffered message is caught too.
    .PARAMETER Text
        The text to redact.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $redacted = $Text

    $token = $null
    $intercom = if ($script:DeskPilot -is [System.Collections.IDictionary] -and $script:DeskPilot.Contains('Intercom')) {
        $script:DeskPilot['Intercom']
    }
    else { $null }
    if ($intercom) { $token = [string](Get-DpPropertyValue -InputObject $intercom -Name @('Token') -Default '') }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $redacted = $redacted.Replace($token, '<token>')
    }

    # A Telegram bot token is <digits>:<35 URL-safe characters>.
    $redacted -replace '\d{6,}:[A-Za-z0-9_-]{30,}', '<token>'
}
