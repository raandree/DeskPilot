function Test-DpRequestOrigin {
    <#
    .SYNOPSIS
        Confirms that an API request names the loopback Host Server origin.
    .DESCRIPTION
        Requires a loopback Host header. When Origin is present, it must be an
        HTTP loopback origin with the same host and port. Requests without Origin
        remain valid for local scripts, but an explicit cross-site fetch signal is
        refused. The per-launch token remains a separate mandatory control.
    .PARAMETER Headers
        Parsed HTTP request headers.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Headers
    )

    $hostHeader = [string]$Headers['Host']
    if ([string]::IsNullOrWhiteSpace($hostHeader)) { return $false }
    try { $hostUri = [uri]("http://$hostHeader") } catch { return $false }
    $loopbackNames = @('127.0.0.1', 'localhost', '::1')
    if ($loopbackNames -notcontains $hostUri.Host.ToLowerInvariant()) { return $false }

    $fetchSite = [string]$Headers['Sec-Fetch-Site']
    if ($fetchSite -eq 'cross-site') { return $false }

    $originHeader = [string]$Headers['Origin']
    if ([string]::IsNullOrWhiteSpace($originHeader)) { return $true }
    if ($originHeader -eq 'null') { return $false }
    try { $originUri = [uri]$originHeader } catch { return $false }
    if ($originUri.Scheme -ne 'http') { return $false }
    if ($loopbackNames -notcontains $originUri.Host.ToLowerInvariant()) { return $false }
    $originUri.Host.Equals($hostUri.Host, [System.StringComparison]::OrdinalIgnoreCase) -and
        $originUri.Port -eq $hostUri.Port
}