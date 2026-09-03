function Set-DpEngineLocation {
    <#
    .SYNOPSIS
        Points the Engine Runspace at the Workspace Folder for the next Turn.
    .DESCRIPTION
        Sets the runspace's PowerShell location ($PWD), creating the Workspace
        Folder first if it does not exist, so the Engine's File and Terminal
        Tools resolve relative paths there.

        It deliberately does NOT set [System.Environment]::CurrentDirectory.
        That value is process-global, so it cannot describe two Turns at once,
        and measurement showed nothing needs it: with $PWD and the process value
        pointed at different folders, read_file, list_directory, write_file and
        run_command all followed $PWD, a child process inherited $PWD, and an MCP
        server starts from $PWD as well. Only a raw .NET call with a relative
        path followed the process value, and neither DeskPilot nor the Engine
        makes one. Writing it therefore changed no Tool behaviour while being the
        one piece of state concurrent Turns would fight over.

        Best-effort: a failure (for example an invalid path or a denied directory
        creation) is swallowed so the Turn still runs from the previous working
        directory, and the system prompt still states the intended path.
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
