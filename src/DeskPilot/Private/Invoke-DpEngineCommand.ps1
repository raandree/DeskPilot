function Invoke-DpEngineCommand {
    <#
    .SYNOPSIS
        Runs a command on the Engine Runspace and returns its output.
    .DESCRIPTION
        Executes a single Engine cmdlet (such as Get-ShpModel) on the shared
        Engine Runspace with the given parameters and returns the collected
        output. Throws if the Engine wrote a terminating error.
    .PARAMETER Command
        The Engine cmdlet name to run.
    .PARAMETER Parameter
        A hashtable of parameters to pass to the cmdlet.
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [hashtable]$Parameter = @{}
    )

    $runspace = $script:DeskPilot.Engine.Runspace
    if (-not $runspace) { throw 'Engine runspace is not initialised.' }

    $shell = [powershell]::Create()
    try {
        $shell.Runspace = $runspace
        $null = $shell.AddCommand($Command)
        foreach ($key in $Parameter.Keys) { $null = $shell.AddParameter($key, $Parameter[$key]) }
        $output = $shell.Invoke()
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            if ($firstError) { throw $firstError }
        }
        $output
    }
    finally {
        $shell.Dispose()
    }
}
