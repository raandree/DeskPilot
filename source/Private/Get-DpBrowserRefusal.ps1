function Get-DpBrowserRefusal {
    <#
    .SYNOPSIS
        Turns a policy reason into a sentence the Model can act on.
    .DESCRIPTION
        A refusal is an answer, not a failure, so it has to say enough for the
        Agent to choose a different approach instead of retrying the same address
        and burning the Turn's iterations against a wall.

        What it deliberately does not say is how to get around the rule. The
        Model is the party being constrained here, and page text can steer it, so
        the message names what was refused rather than what would be permitted.
    .PARAMETER Reason
        The reason from Resolve-DpBrowserUrlDecision.
    .PARAMETER TargetHost
        The host, when there was one worth naming.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Reason,

        [AllowEmptyString()]
        [string]$TargetHost
    )

    $where = if ([string]::IsNullOrWhiteSpace($TargetHost)) { 'that address' } else { $TargetHost }

    switch ($Reason) {
        'scheme' { 'DeskPilot only opens https web addresses in the browser. It cannot open local files, scripts or other schemes.' }
        'userinfo' { 'That address carries a user name and password in it, which DeskPilot never sends. Ask the user to sign in themselves.' }
        'ip-literal' { 'That address is a numeric one rather than a site name, so DeskPilot will not open it.' }
        'single-label-host' { "'$where' is not a public web address, so DeskPilot will not open it." }
        'private-host' { "'$where' is on the local network, which the browser is not allowed to reach." }
        'too-long' { 'That address is far too long to be a web address.' }
        'control-character' { 'That address contains characters that are not valid in a web address.' }
        'empty' { 'An address is required.' }
        default { "DeskPilot could not use '$where' as a web address." }
    }
}
