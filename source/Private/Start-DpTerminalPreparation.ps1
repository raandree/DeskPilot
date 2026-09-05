function Start-DpTerminalPreparation {
    <#
    .SYNOPSIS
        Starts explicit runtime preparation outside the Host Server accept loop.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $state = $script:DeskPilot
    Update-DpTerminalPreparation
    $job = Get-DpPropertyValue -InputObject $state -Name 'TerminalSetupJob'
    if ($job -and $job.State -in @('NotStarted', 'Running')) { return $false }
    $definitions = @('Invoke-DpDockerControl', 'Install-DpTerminalRuntime' | ForEach-Object {
        @{ name = $_; definition = (Get-Command -Name $_ -CommandType Function -ErrorAction Stop).Definition }
    })
    $payload = @{ definitions = $definitions; root = (Get-DpIsolationAssetRoot); data = [string]$state.DataDir }
    $state.TerminalSetupJob = Start-Job -ArgumentList $payload -ScriptBlock {
        param($Payload)
        $ErrorActionPreference = 'Stop'
        $script:TerminalAssetRoot = $Payload.root
        function Get-DpIsolationAssetRoot { $script:TerminalAssetRoot }
        foreach ($definition in $Payload.definitions) {
            . ([scriptblock]::Create("function $($definition.name) { $($definition.definition) }"))
        }
        Install-DpTerminalRuntime -DataDirectory $Payload.data
    }
    $true
}
