function Set-DpEngineLocation {
    <#
    .SYNOPSIS
        Points the Engine Runspace at the Workspace Folder for the next Turn.
    .DESCRIPTION
        Creates the Workspace Folder if it does not exist, then sets both the
        runspace's PowerShell location ($PWD) and the process .NET current
        directory so the Engine's File and Terminal Tools resolve relative paths
        there. Best-effort: a failure (for example an invalid path or a denied
        directory creation) is swallowed so the Turn still runs from the previous
        working directory, and the system prompt still states the intended path.
    .PARAMETER Path
        The Workspace Folder path.
    .OUTPUTS
        System.Boolean

        $true when the location was applied; $false when it could not be.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $runspace = $script:DeskPilot.Engine.Runspace
    if (-not $runspace) { return $false }

    $shell = [powershell]::Create()
    try {
        $shell.Runspace = $runspace
        $null = $shell.AddScript({
                param($Target)
                if (-not (Test-Path -LiteralPath $Target)) {
                    New-Item -ItemType Directory -Path $Target -Force -ErrorAction Stop | Out-Null
                }
                Set-Location -LiteralPath $Target
                [System.Environment]::CurrentDirectory = (Get-Location).ProviderPath
            }).AddArgument($Path)
        $shell.Invoke() | Out-Null
        return (-not $shell.HadErrors)
    }
    catch {
        return $false
    }
    finally {
        $shell.Dispose()
    }
}
