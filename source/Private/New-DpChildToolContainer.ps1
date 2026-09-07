function New-DpChildToolContainer {
    <#
    .SYNOPSIS
        Creates a private quota-backed child Tool container.
    .PARAMETER Runtime
        The explicitly prepared runtime record.
    .PARAMETER DataDirectory
        The installation-owned control directory.
    .PARAMETER Policy
        The validated child execution policy.
    .PARAMETER HostProcess
        The pre-owned aggregate host process budget, required for V3.
    .PARAMETER ProviderStart
        Trusted process arguments used to create a suspended, durably owned
        provider. Cannot be combined with an existing HostProcess.
    .OUTPUTS
        DeskPilot.Child.ToolContainer
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Runtime,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][hashtable]$Policy,
        [object]$HostProcess,
        [Diagnostics.ProcessStartInfo]$ProviderStart
    )

    $validated = ConvertTo-DpChildExecution -InputObject $Policy
    if ($HostProcess -and $ProviderStart) { throw 'Only one trusted host process owner is allowed.' }
    if ($validated.profile -eq 'single-child-v3' -and -not $HostProcess -and -not $ProviderStart) {
        throw 'V3 requires a pre-owned aggregate host process budget.'
    }
    if ($Runtime.image -notmatch '^sha256:[a-f0-9]{64}$') {
        throw 'The prepared child runtime identity could not be verified.'
    }
    Import-DpChildRuntime -Runtime $Runtime
    $docker = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Docker/Docker/resources/bin/docker.exe'
    if ($PSCmdlet.ShouldProcess('Private child Tool storage', 'Create quota-backed container')) {
        $policyJson = $validated | ConvertTo-Json -Depth 6 -Compress
        if ($ProviderStart) {
            [DeskPilot.Child.ToolContainer]::new($docker, $Runtime.image, $DataDirectory, $policyJson, $ProviderStart)
        } elseif ($HostProcess) {
            [DeskPilot.Child.ToolContainer]::new($docker, $Runtime.image, $DataDirectory, $policyJson, $HostProcess)
        } else {
            [DeskPilot.Child.ToolContainer]::new($docker, $Runtime.image, $DataDirectory, $policyJson)
        }
    }
}
