function Test-DpToolCallApprovalSupport {
    <#
    .SYNOPSIS
        Inspects the imported Engine's declared pre-dispatch callback parameter.
    .DESCRIPTION
        Makes no provider call and runs no Tool. A declared ScriptBlock parameter
        is an interface capability, not a live enforcement or isolation proof.
    .PARAMETER Runspace
        The idle Engine Runspace to inspect.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )
    $probe = [powershell]::Create()
    $probe.Runspace = $Runspace
    try {
        $null = $probe.AddScript(@'
$command = Get-Command -Name Invoke-Shp -CommandType Function -ErrorAction SilentlyContinue
[bool]($command -and $command.Parameters.ContainsKey('ToolCallApprover') -and
    $command.Parameters['ToolCallApprover'].ParameterType -eq [scriptblock])
'@)
        $result = $probe.Invoke()
        if ($probe.HadErrors -or $result.Count -ne 1) {
            Write-Warning 'The Engine ToolCallApprover contract could not be inspected.'
            return $false
        }
        [bool]$result[0].PSObject.BaseObject
    }
    catch {
        Write-Warning 'The Engine ToolCallApprover contract could not be inspected.'
        $false
    }
    finally { $probe.Dispose() }
}
