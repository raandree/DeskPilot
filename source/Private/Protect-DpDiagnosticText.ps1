function Protect-DpDiagnosticText {
    <#
    .SYNOPSIS
        Redacts secrets and bounds text before it enters diagnostics.
    .DESCRIPTION
        Applies the existing Intercom token filter, removes the Host Server
        session token, authorization values, credentialed URL user information,
        common secret query values, and common GitHub token shapes. The result is
        flattened and length-bounded so an exception cannot grow the log ring.
    .PARAMETER Text
        Text to make safe for diagnostics.
    .PARAMETER MaxLength
        Maximum retained character count.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateRange(16, 4000)]
        [int]$MaxLength = 500
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $safe = Hide-DpIntercomSecret -Text $Text
    $safe = $safe.Replace('<token>', '<redacted>')

    if ($script:DeskPilot -and $script:DeskPilot.ContainsKey('Token')) {
        $sessionToken = [string]$script:DeskPilot.Token
        if (-not [string]::IsNullOrWhiteSpace($sessionToken)) {
            $safe = $safe.Replace($sessionToken, '<redacted>')
        }
    }

    $safe = $safe -replace '(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', '<redacted>'
    $safe = $safe -replace '(?i)(https?://)[^/\s:@]+:[^@\s/]+@', '$1<redacted>@'
    $safe = $safe -replace '(?i)([?&](?:access_token|token|api[_-]?key|password|secret|sig)=)[^&#\s]+', '$1<redacted>'
    $safe = $safe -replace '(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b', '<redacted>'
    $safe = $safe -replace '(?i)\b(?:cookie|set-cookie)\s*[:=]\s*[^\r\n]+', 'cookie: <redacted>'

    $safe = ($safe -replace '\s+', ' ').Trim()
    if ($safe.Length -le $MaxLength) { return $safe }
    $safe.Substring(0, $MaxLength - 3) + '...'
}