<#
.SYNOPSIS
    Runs the trusted, independently owned child provider transport.
.DESCRIPTION
    Only this process resolves Engine credentials. It registers no Tools and
    receives commands only from its authenticated Host Server channel. The
    Engine performs counting, admission, HTTP, normalization, and pricing.
.PARAMETER EngineModulePath
    The Host Server verified Engine manifest in the prepared runtime.
.PARAMETER RuntimeAssembly
    The verified assembly containing the bounded authenticated bridge.
.PARAMETER LeaseSeconds
    The independent Host Server lease, never renewed by provider data.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EngineModulePath,
    [string]$RuntimeAssembly = (Join-Path $PSScriptRoot 'ChildRuntime.dll'),
    [ValidateRange(1,30)][int]$LeaseSeconds = 15
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$bridge = $null
$context = $null
$engine = $null
try {
    Add-Type -Path $RuntimeAssembly -ErrorAction Stop
    $bridge = [DeskPilot.Child.EngineBridge]::Start($LeaseSeconds, 4194304)
    $configuration = $bridge.Configuration | ConvertFrom-Json -AsHashtable -Depth 24
    if ($configuration.profile -cne 'single-child-v3' -or $configuration.budgetMode -cne 'provider-estimate' -or
        $configuration.model -cne 'claude-haiku-4.5') { throw 'Unsupported child provider profile.' }
    Import-Module -Name $EngineModulePath -Force -ErrorAction Stop
    $engine = Get-Module ShellPilot
    . (Join-Path $PSScriptRoot 'ChildTools.ps1')
    $definitions = @(Get-DpChildToolDefinition -File ([bool]$configuration.permissions.file) -Terminal ([bool]$configuration.permissions.terminal) -Writable ($configuration.projectAccess -ceq 'read-write'))
    $parameters = @{
        Model = $configuration.model
        Tools = @($definitions | ForEach-Object { $_.Schema })
        Limits = @{
            MaxInputTokens = $configuration.inputTokens
            MaxTotalTokens = $configuration.totalTokens
            MaxCostUSD = $configuration.costUSD
        }
        MaxRequests = $configuration.iterations
        MaxRequestBytes = $configuration.requestBytes
        MaxResponseBytes = $configuration.outputBytes
        MaxCountBytes = $configuration.eventBytes
        MaxOutputTokens = $configuration.outputTokens
        DurationSeconds = $configuration.durationSeconds
        BeforeGeneration = {
            param($Prepared, $Usage)
            $reserved = @{
                stage = 'reserved'
                requestId = $Prepared.RequestId
                requestDigest = $Prepared.RequestDigest
                usage = $Usage
            } | ConvertTo-Json -Depth 12 -Compress
            $decision = $bridge.Invoke('provider', $reserved) | ConvertFrom-Json -AsHashtable -Depth 8
            $decision.Count -eq 1 -and $decision.admitted -is [bool] -and $decision.admitted
        }
    }
    if ($configuration.tokenPath) { $parameters.TokenPath = [string]$configuration.tokenPath }
    $context = & $engine { param($Parameters) New-ShpChildProviderContext @Parameters } $parameters
    $payload = @{
        stage = 'ready'
        usage = & $engine { param($Context) Get-ShpChildProviderUsage -Context $Context } $context
    }
    while (-not $context.Closed) {
        $command = $bridge.Invoke('provider', ($payload | ConvertTo-Json -Depth 24 -Compress)) |
            ConvertFrom-Json -AsHashtable -Depth 24
        if ($command.Count -ne 2 -or $command.action -cne 'invoke' -or $command.request -isnot [hashtable]) {
            throw 'Unsupported Host Server provider command.'
        }
        $response = & $engine {
            param($Context, $Request)
            Invoke-ShpChildProviderRequest -Context $Context -Request $Request
        } $context $command.request
        $payload = @{
            stage = 'response'
            requestId = $command.request.RequestId
            response = $response
            usage = & $engine { param($Context) Get-ShpChildProviderUsage -Context $Context } $context
        }
    }
} catch {
    $failure = $_
    $code = switch (($failure.FullyQualifiedErrorId -split ',')[0]) {
        'ShpRequestBudgetOverrun' { 'budget-overrun' }
        'ShpRequestUsageUnknown' { 'usage-unknown' }
        'ShpChildAdmissionRevoked' { 'admission-revoked' }
        'ShpRequestPricingUnavailable' { 'pricing-unavailable' }
        'ShpCountShapeUnsupported' { 'unsupported-request' }
        default { 'provider-failed' }
    }
    if ($bridge) {
        $usage = if ($context) { & $engine { param($Context) Get-ShpChildProviderUsage -Context $Context } $context } else { $null }
        $bridge.Complete((@{ status = 'failed'; code = $code; usage = $usage } | ConvertTo-Json -Depth 12 -Compress))
    }
} finally {
    if ($context) {
        $context.Closed = $true
        $context.Cancellation.Cancel()
        $context.Headers.Clear()
        $context.Client.Dispose()
        $context.Cancellation.Dispose()
    }
    if ($bridge) { $bridge.Dispose() }
}
