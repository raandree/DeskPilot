function Get-DpToolCallApprovalContract {
    <#
    .SYNOPSIS
        Identifies the Engine's supported pre-dispatch control interface.
    .DESCRIPTION
        Inspects parameter types without calling a provider or Tool. Prefer the
        current ToolCallControl contract while retaining the legacy adapter.
        Interface recognition is not a behavioral enforcement proof.
    .PARAMETER Runspace
        The idle Engine Runspace.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )
    if ($null -eq $Runspace) { return '' }
    $probe = [powershell]::Create()
    $probe.Runspace = $Runspace
    try {
        $null = $probe.AddScript(@'
$command = Get-Command -Name Invoke-Shp -CommandType Function -ErrorAction SilentlyContinue
if ($command -and $command.Parameters.ContainsKey('ToolCallControl') -and
    $command.Parameters['ToolCallControl'].ParameterType -eq [hashtable]) { 'ToolCallControl' }
elseif ($command -and $command.Parameters.ContainsKey('ToolCallApprover') -and
    $command.Parameters['ToolCallApprover'].ParameterType -eq [scriptblock]) { 'ToolCallApprover' }
else { '' }
'@)
        $result = $probe.Invoke()
        if ($probe.HadErrors -or $result.Count -ne 1) {
            Write-Warning 'The Engine pre-dispatch control interface could not be inspected.'
            return ''
        }
        [string]$result[0]
    }
    catch {
        Write-Warning 'The Engine pre-dispatch control interface could not be inspected.'
        ''
    }
    finally { $probe.Dispose() }
}
