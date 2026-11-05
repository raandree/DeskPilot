function Initialize-DpSubagentTool {
    <#
    .SYNOPSIS
        Registers DeskPilot's run_subagent Tool in the Engine Runspace.
    .DESCRIPTION
        Re-declares Invoke-DpSubagentTool and the parameter translation it uses
        inside the Engine Runspace from their own definitions, as the other owned
        Tools are injected: the runspace has ShellPilot imported and DeskPilot
        not, and scriptblocks belong to the runspace that created them.

        The Turn's Subagent context travels as a runspace global rather than as a
        Tool parameter. As a parameter it would be a field in the JSON schema the
        Model fills in, which would let it hand itself a definition path, a
        capability or a budget.

        The Engine is probed first, so an Engine without the bounded Subagent
        contract fails here, loudly, rather than as a Tool that refuses every
        call for reasons the user cannot see.
    .PARAMETER Runspace
        The idle Engine Runspace with ShellPilot imported.
    .PARAMETER Context
        The Turn's Subagent context from New-DpSubagentContext.
    .PARAMETER Description
        The Tool description from Get-DpSubagentToolDescription.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace,

        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-DpSubagentSupport -Runspace $Runspace)) {
        throw 'This Engine has no bounded Subagent contract (Invoke-ShpSubagent with an Invoker), so run_subagent was not registered.'
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('param($Context, $Description)')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotSubagentContext -Scope Global -Value $Context')
    foreach ($name in @('Protect-DpUserTool', 'ConvertTo-DpSubagentTurnParameter', 'Invoke-DpSubagentTool')) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        [void]$builder.AppendLine("function global:$name {")
        [void]$builder.AppendLine($command.Definition)
        [void]$builder.AppendLine('}')
    }
    [void]$builder.AppendLine("Register-ShpTool -Command 'Invoke-DpSubagentTool' -ToolName 'run_subagent' -Description `$Description -Confirm:`$false")
    # The schema is built from the advanced function above; the Model's arguments
    # then reach a plain function that binds only the Tool's own parameters.
    [void]$builder.AppendLine("Protect-DpUserTool -Name 'Invoke-DpSubagentTool'")

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript($builder.ToString()).AddArgument($Context).AddArgument($Description)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not register run_subagent.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $true
}
