function Get-DpMcpFingerprint {
    <#
    .SYNOPSIS
        Produces a stable fingerprint of one configured MCP server row.
    .DESCRIPTION
        The reconciler leaves an unchanged row attached, so it needs to answer
        "is this the same server the Engine is already running?" without
        restarting a working process to find out. The fingerprint covers exactly
        the fields that decide what gets launched and what it may offer; the
        row's id and enabled flag are not among them, because neither changes
        the running server.

        Environment variable *values* are covered even though they are never
        persisted: the value is read from the Host Server's environment at
        registration, so a token that has since changed has to re-attach the
        server or the child keeps the stale one. Only a hash of the value is
        used, so a secret never reaches the fingerprint, a log or the API.
    .PARAMETER Server
        One normalised server row from ConvertTo-DpMcpServer.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    $envParts = foreach ($key in @($Server.envKeys | Sort-Object)) {
        $value = [System.Environment]::GetEnvironmentVariable($key)
        $marker = if ($null -eq $value) {
            'unset'
        }
        else {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
            [System.Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData($bytes))
        }
        '{0}={1}' -f $key, $marker
    }

    $parts = @(
        [string]$Server.name
        [string]$Server.source
        [string]$Server.command
        (@($Server.args) -join "`u{1}")
        [string]$Server.cwd
        [string]$Server.path
        (@($Server.tools | Sort-Object) -join "`u{1}")
        (@($envParts) -join "`u{1}")
    )

    $parts -join "`u{2}"
}
