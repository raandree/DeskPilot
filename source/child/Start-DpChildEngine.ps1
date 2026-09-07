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
$phase = 'bridge'
try {
    Add-Type -Path $RuntimeAssembly -ErrorAction Stop
    $bridge = [DeskPilot.Child.EngineBridge]::Start($LeaseSeconds, 4194304)
    $configuration = $bridge.Configuration | ConvertFrom-Json -AsHashtable -Depth 24
    if ($configuration.profile -cne 'single-child-v3' -or $configuration.budgetMode -cne 'provider-estimate' -or
        $configuration.model -cne 'claude-haiku-4.5' -or $configuration.prompt -isnot [string] -or
        $configuration.agentBody -isnot [string]) { throw 'Unsupported child profile.' }
    $phase = 'import'
    Import-Module -Name $EngineModulePath -Force -ErrorAction Stop
    $phase = 'tool-registration'
    . (Join-Path $PSScriptRoot 'ChildTools.ps1')
    $definitions = @(Get-DpChildToolDefinition -File ([bool]$configuration.permissions.file) -Terminal ([bool]$configuration.permissions.terminal) -Writable ($configuration.projectAccess -ceq 'read-write'))
    foreach ($definition in $definitions) {
        Register-ShpTool -Command $definition.Command -ToolName $definition.Name -Description $definition.Description -Confirm:$false
    }
    $parameters = @{
        Prompt = $configuration.prompt
        Model = $configuration.model
        SystemPrompt = $configuration.agentBody
        History = @()
        DisableBrowsing = $true; DisableFileAccess = $true; DisableTerminal = $true
        DisableUserPrompts = $true; DisableMcp = $true; DisableTodoList = $true
        DisableStreaming = $true; DisableProgressEvents = $true
        MaxContextWindowTokens = 0; MaxOutputTokens = [int]$configuration.outputTokens
        MaxToolIterations = [int]$configuration.iterations
        NoAutomaticRetry = $true
        RequestTransport = {
            param($Request)
            $json = $Request | ConvertTo-Json -Depth 24 -Compress
            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $configuration.requestBytes) { throw 'Child request exceeded its byte ceiling.' }
            $reply = [DeskPilot.Child.EngineBridge]::Current.Invoke('provider', $json) | ConvertFrom-Json -AsHashtable -Depth 24
            if (-not $reply.ok) { throw 'The trusted provider refused continuation.' }
            $reply.response | ConvertTo-Json -Depth 24 -Compress | ConvertFrom-Json -Depth 24
        }
        Confirm = $false
    }
    $phase = 'invoke'
    $result = Invoke-Shp @parameters
    $phase = 'result'
    $final = @{
        status = 'completed'; content = [string]$result.Content
        commandsRun = @($result.CommandsRun); filesWritten = @(); filesRead = @($result.FilesRead)
    } | ConvertTo-Json -Depth 12 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($final) -gt $configuration.resultBytes) { throw 'Child result exceeded its byte ceiling.' }
    $bridge.Complete($final)
} catch {
    if ($bridge) {
        $bridge.Complete((@{ status = 'failed'; code = 'child_engine_failed'; phase = $phase; category = [string]$_.CategoryInfo.Category; line = $_.InvocationInfo.ScriptLineNumber } | ConvertTo-Json -Compress))
    }
} finally {
    if ($bridge) { $bridge.Dispose() }
}
