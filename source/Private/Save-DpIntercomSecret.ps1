function Save-DpIntercomSecret {
    <#
    .SYNOPSIS
        Stores the Intercom bot token outside Settings, protected at rest.
    .DESCRIPTION
        Writes the bot token to intercom.secret in the data directory. It is
        deliberately not part of settings.json: a Settings backup, export or
        import must never carry a bearer credential that grants control of the
        machine.

        On Windows the token is encrypted with DPAPI (CurrentUser), so only this
        Windows account can read it back. Elsewhere it is stored obfuscated with
        owner-only file permissions and the record says protected = false, so the
        UI can tell the truth about it.

        An empty or whitespace token removes the file, which is how the UI clears
        a configured token.
    .PARAMETER Token
        The bot token to store, or an empty string to remove the stored one.
    .PARAMETER Directory
        The data directory.
    .OUTPUTS
        System.Boolean - whether a token is configured after this call.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Directory
    )

    $path = Join-Path -Path $Directory -ChildPath 'intercom.secret'

    if ([string]::IsNullOrWhiteSpace($Token)) {
        if ($PSCmdlet.ShouldProcess($path, 'Remove the stored Intercom token')) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($path, 'Store the Intercom token')) { return $false }

    $trimmed = $Token.Trim()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($trimmed)
    $record = if ($IsWindows) {
        $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
        @{ protected = $true; token = [Convert]::ToBase64String($protectedBytes) }
    }
    else {
        @{ protected = $false; token = [Convert]::ToBase64String($bytes) }
    }

    if (-not (Test-Path -LiteralPath $Directory)) {
        $null = New-Item -ItemType Directory -Path $Directory -Force
    }

    # Atomic write, matching every other store in the data directory.
    $temp = "$path.tmp"
    ($record | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $temp -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $temp -Destination $path -Force

    if (-not $IsWindows) {
        try { [System.IO.File]::SetUnixFileMode($path, 'UserRead, UserWrite') } catch { $null = $_ }
    }

    $true
}
