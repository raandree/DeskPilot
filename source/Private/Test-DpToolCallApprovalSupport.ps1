function Test-DpToolCallApprovalSupport {
    <#
    .SYNOPSIS
        Inspects the imported Engine's declared pre-dispatch callback parameter.
    .DESCRIPTION
        Recognizes either supported contract by parameter type without calling a
        provider or Tool. This is not a behavioral enforcement or isolation proof.
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
    -not [string]::IsNullOrEmpty((Get-DpToolCallApprovalContract -Runspace $Runspace))
}
