function Test-DpTransientEngineError
{
    <#
    .SYNOPSIS
        Decides whether an Engine failure is transient and worth retrying.
    .DESCRIPTION
        The Copilot session-token exchange that ShellPilot performs at the start
        of every Turn intermittently returns 403 (and occasionally 429/5xx or a
        network timeout); retrying the call succeeds. This classifier flags those
        transient failures so Invoke-DpTurn can retry the Engine call before any
        answer has streamed, sparing the user a manual stop-and-resend. It walks
        the inner-exception chain and matches transient HTTP status codes and
        network conditions only. It deliberately does NOT match 401/Unauthorized
        (a genuine expired sign-in), so an expired token is surfaced for re-auth
        rather than retried pointlessly.
    .PARAMETER ErrorRecord
        The caught error: an ErrorRecord, an Exception, or a string.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [AllowNull()]
        $ErrorRecord
    )

    if ($null -eq $ErrorRecord) { return $false }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add([string]$ErrorRecord)

    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception }
        elseif ($ErrorRecord -is [System.Exception]) { $ErrorRecord }
        else { $null }
    $guard = 0
    while ($exception -and $guard -lt 20)
    {
        $parts.Add([string]$exception.Message)
        $exception = $exception.InnerException
        $guard++
    }

    $text = $parts -join ' '

    return [bool]($text -match '(?i)\b403\b|\b408\b|\b429\b|\b5\d\d\b|forbidden|too many requests|timed?\s*out|temporarily|service unavailable|bad gateway|gateway timeout|(?:connection|socket).{0,24}(?:reset|refused|closed|aborted)|unable to connect|no such host|network is unreachable')
}
