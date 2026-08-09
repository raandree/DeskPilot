function Read-DpIntercomSecret {
    <#
    .SYNOPSIS
        Reads the stored Intercom bot token.
    .DESCRIPTION
        Loads intercom.secret from the data directory and returns the plain token
        for in-memory use by the pump. Returns an empty string when no token is
        stored, when the file is unreadable, or when a DPAPI-protected token was
        written by a different Windows account (which is the protection working,
        not a fault).

        Callers must never place the returned value in a route response, a log
        line, or an error message - the token is a bearer credential and appears
        in every Telegram request URL.
    .PARAMETER Directory
        The data directory.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Directory
    )

    $path = Join-Path -Path $Directory -ChildPath 'intercom.secret'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }

    try {
        $record = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not read the Intercom secret: $_"
        return ''
    }

    $stored = [string](Get-DpPropertyValue -InputObject $record -Name @('token') -Default '')
    if ([string]::IsNullOrWhiteSpace($stored)) { return '' }

    $protected = [bool](Get-DpPropertyValue -InputObject $record -Name @('protected') -Default $false)

    try {
        $bytes = [Convert]::FromBase64String($stored)
        if ($protected) {
            $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, $scope)
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        Write-Verbose "The stored Intercom token could not be read (a different Windows account may have written it): $_"
        return ''
    }
}
