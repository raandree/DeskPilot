function Test-DpAuthError
{
    <#
    .SYNOPSIS
        Decides whether an Engine failure is an authentication problem.
    .DESCRIPTION
        When the cached GitHub token is missing or expired, the Engine's
        Get-ShpModel / Invoke-Shp fail while exchanging the token (HTTP 401/403)
        or because the token file is absent. This classifier lets the models
        route answer with an actionable "sign in again" (401 auth_required)
        instead of a generic engine error, so the UI can re-trigger the
        device-code flow. It walks the whole inner-exception chain so a wrapped
        401 is still recognised, and matches only auth signals (status codes and
        the Engine's own token messages) so a transient network failure is NOT
        misread as an expired sign-in.
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

    return [bool]($text -match '(?i)\b401\b|\b403\b|unauthorized|forbidden|session token exchange failed|token file not found|Initialize-Shp|bad credentials|invalid token')
}
