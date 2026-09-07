function New-DpChildRunController {
    <#
    .SYNOPSIS
        Creates the complete child controller from verified prepared artifacts.
    .PARAMETER Runtime
        Explicitly prepared immutable runtime record.
    .PARAMETER DataDirectory
        Installation-owned bounded run storage.
    .PARAMETER Request
        Frozen Host Server launch authority and selected input.
    .OUTPUTS
        DeskPilot.Child.RunController
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Runtime,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][hashtable]$Request
    )
    $Request.policy = ConvertTo-DpChildExecution -InputObject $Request.policy
    if ($Runtime.schemaVersion -ne 2 -or $Runtime.engineImage -cnotmatch '^sha256:[a-f0-9]{64}$' -or
        $Runtime.image -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Complete child runtime preparation is missing.' }
    $source = Get-DpChildAssetRoot
    foreach ($name in $Runtime.hashes.Keys) {
        if ([IO.Path]::GetFileName($name) -cne $name -or
            (Get-FileHash -LiteralPath (Join-Path $source $name)).Hash -cne $Runtime.hashes[$name]) {
            throw 'The prepared child implementation no longer matches source.'
        }
    }
    foreach ($relative in $Runtime.engineHashes.Keys) {
        if ($relative -cnotin @('ShellPilot.psd1', 'ShellPilot.psm1', 'ShellPilot.Format.ps1xml', 'data/PriceTable.psd1') -or
            (Get-FileHash -LiteralPath (Join-Path (Split-Path $Runtime.engineManifest) $relative)).Hash -cne $Runtime.engineHashes[$relative]) {
            throw 'The prepared Engine bytes no longer match their identity.'
        }
    }
    foreach ($name in @('Start-DpChildProvider.ps1', 'ChildTools.ps1')) {
        if ((Get-FileHash -LiteralPath (Join-Path (Split-Path $Runtime.providerEntry) $name)).Hash -cne $Runtime.hashes[$name]) {
            throw 'The prepared trusted provider implementation changed.'
        }
    }
    Import-DpChildRuntime -Runtime $Runtime -ExactAssembly
    if ($PSCmdlet.ShouldProcess('One private child run', 'Start complete isolated execution')) {
        [DeskPilot.Child.RunController]::new(($Runtime | ConvertTo-Json -Depth 12 -Compress), $DataDirectory, ($Request | ConvertTo-Json -Depth 16 -Compress))
    }
}
