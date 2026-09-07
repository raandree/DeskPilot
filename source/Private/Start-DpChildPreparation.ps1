function Start-DpChildPreparation {
    <#
    .SYNOPSIS
        Starts explicit child setup or recovery outside the accept loop.
    .PARAMETER Action
        Prepare immutable images, check health, or reconcile owned resources.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The explicit ArgumentList is bound by param($Payload) in the separate job, including definitions restored within that job.')]
    [OutputType([bool])]
    param([Parameter(Mandatory)][ValidateSet('prepare', 'check', 'cleanup', 'remove')][string]$Action)

    $state = $script:DeskPilot
    $child = $state.Child
    if ($child.Controller -or ($state.TurnRunning -and -not $child.CleanupBlocked)) { throw 'Stop active work before child runtime changes.' }
    if ($child.SetupJob -and $child.SetupJob.State -in @('NotStarted', 'Running')) { return $false }
    if (-not $PSCmdlet.ShouldProcess('Owned child runtime', $Action)) { return $false }
    if ($Action -eq 'remove') {
        $state.Settings.childExecution.enabled = $false
        Save-DpSettings -Settings $state.Settings -Directory $state.DataDir
    }
    $definitions = @('Invoke-DpDockerControl', 'Install-DpTerminalRuntime', 'Install-DpChildRuntime',
        'Remove-DpChildRun', 'Uninstall-DpChildRuntime', 'Get-DpChildRuntimeHealth' | ForEach-Object {
            @{ name = $_; definition = (Get-Command -Name $_ -CommandType Function -ErrorAction Stop).Definition }
        })
    $payload = @{
        definitions = $definitions; childRoot = Get-DpChildAssetRoot; terminalRoot = Get-DpIsolationAssetRoot
        data = [string]$state.DataDir; engine = [string]$state.Engine.ModulePath; action = $Action; runtime = $child.Runtime
    }
    $child.Error = ''
    $child.SetupJob = Start-Job -ArgumentList $payload -ScriptBlock {
        param($Payload)
        $ErrorActionPreference = 'Stop'
        $script:ChildAssetRoot = $Payload.childRoot
        $script:TerminalAssetRoot = $Payload.terminalRoot
        function Get-DpChildAssetRoot { $script:ChildAssetRoot }
        function Get-DpIsolationAssetRoot { $script:TerminalAssetRoot }
        foreach ($definition in $Payload.definitions) {
            . ([scriptblock]::Create("function $($definition.name) { $($definition.definition) }"))
        }
        $runtime = $Payload.runtime
        if ($Payload.action -eq 'prepare') { $runtime = Install-DpChildRuntime -DataDirectory $Payload.data -EngineModulePath $Payload.engine }
        if ($Payload.action -eq 'cleanup') { $null = Remove-DpChildRun -DataDirectory $Payload.data -ExpireCompleted -Confirm:$false }
        if ($Payload.action -eq 'remove') {
            $null = Uninstall-DpChildRuntime -DataDirectory $Payload.data -Confirm:$false
            $runtime = $null
        }
        $health = if ($runtime -and $runtime.schemaVersion -eq 2) { Get-DpChildRuntimeHealth -Runtime $runtime -DataDirectory $Payload.data }
        elseif ($Payload.action -eq 'remove') { @{ ready = $false; cleanupClear = $true; checkedUtc = [datetime]::UtcNow.ToString('o') } }
        else { $null }
        @{ Runtime = $runtime; Health = $health }
    }
    $true
}
