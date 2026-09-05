function Test-DpTerminalDispatch {
    <#
    .SYNOPSIS
        Checks whether the imported Engine enforces disabled built-in Tools.
    .PARAMETER Runspace
        The idle Engine Runspace for the next Turn.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )

    if ($null -eq $Runspace) { return $false }
    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript(@'
$engine = Get-Module -Name ShellPilot | Select-Object -First 1
if (-not $engine) { return $false }
& $engine {
    $command = Get-Command -Name Invoke-Shp -CommandType Function -ErrorAction SilentlyContinue
    [bool]($command -and $command.Definition -match 'offeredBuiltInTool')
}
'@)
        $result = @($shell.Invoke())
        -not $shell.HadErrors -and $result.Count -eq 1 -and [bool]$result[0]
    }
    catch { Write-Verbose 'The Engine dispatch capability could not be inspected.'; $false }
    finally { $shell.Dispose() }
}
