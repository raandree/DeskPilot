[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DataDirectory,
    [Parameter(Mandatory)][string]$ProjectDirectory,
    [Parameter(Mandatory)][string]$EngineModulePath
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$built = Get-ChildItem -LiteralPath (Join-Path $root 'output/module/DeskPilot') -Filter 'DeskPilot.psd1' -Recurse |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if (-not $built) { throw 'Build DeskPilot before the Turn approval HTTP proof.' }
$module = Import-Module -Name $built.FullName -PassThru -ErrorAction Stop
& $module {
    param($DataDirectory, $ProjectDirectory)
    $settings = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
        projects = @(@{ id = 'turn-approval'; name = 'Turn approval'; path = $ProjectDirectory })
        selectedProjectId = 'turn-approval'
        selectedAgent = $null
        pushInstructions = $false
        workspaceContext = $false
        memoryLearning = $false
        autoCompaction = $false
        taskTracking = $false
        maxToolIterations = 4
        responseRetryCount = 0
        perCallApproval = $true
        permissions = @{ terminal = $true; userTools = $true; file = $false; browsing = $false; askUser = $false; mcp = $false }
    }
    Save-DpSettings -Settings $settings -Directory $DataDirectory
    $script:ApprovalSmokeTokenPath = Join-Path $DataDirectory 'scripted-auth-marker'
    Set-Content -LiteralPath $script:ApprovalSmokeTokenPath -Value 'fixture' -Encoding ascii
    $script:ApprovalSmokeEngineFactory = (Get-Command Initialize-DpEngine).ScriptBlock
    function script:Initialize-DpEngine {
        param([string]$EngineModulePath)
        $engine = & $script:ApprovalSmokeEngineFactory -EngineModulePath $EngineModulePath
        $shell = [powershell]::Create()
        $shell.Runspace = $engine.Runspace
        try {
            $null = $shell.AddScript(@'
$module = Get-Module ShellPilot
& $module {
    $script:ApprovalSmokeCalls = 0
    function script:Get-ShpSessionToken {
        @{ token = 'fixture'; expires_at = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds(); endpoints = @{ api = 'https://fixture.invalid' } }
    }
    function script:Invoke-ShpHttpRequest { throw 'No network is permitted in the approval proof.' }
    function script:Invoke-ShpStreamRequest { throw 'No streaming network is permitted in the approval proof.' }
    function script:Invoke-CopilotTurn {
        $script:ApprovalSmokeCalls++
        $phase = (($script:ApprovalSmokeCalls - 1) % 3) + 1
        $calls = @()
        if ($phase -lt 3) {
            $arguments = @{ command = "Set-Content -LiteralPath proof-$phase.txt -Value approved-$phase" } | ConvertTo-Json -Compress
            $calls = @([pscustomobject]@{ Id = ('proof-' + $script:ApprovalSmokeCalls); Name = 'run_terminal_command'; Arguments = $arguments })
        }
        [pscustomobject]@{
            Mode = 'chat'; ModelName = 'gpt-4.1'; Content = 'Approval proof complete.'; Reasoning = ''
            FinishReason = $(if ($calls.Count) { 'tool_calls' } else { 'stop' })
            ToolCalls = $calls; AssistantMessage = @{ role = 'assistant'; content = 'Approval proof complete.' }
            PromptTokens = 10; CompletionTokens = 2; CachedTokens = 0; CacheWriteTokens = 0
            Response = @{ Headers = @{} }; Raw = @{}
        }
    }
}
function global:Get-ShpModel {
    [pscustomobject]@{ id = 'gpt-4.1'; name = 'gpt-4.1'; maxContextWindowTokens = 64000; maxOutputTokens = 4000; reasoningEfforts = @(); vision = $false }
}
function global:Get-ShpDefault { @{ Model = 'gpt-4.1' } }
'@)
            $null = $shell.Invoke()
            if ($shell.HadErrors) { throw 'The scripted approval provider could not be initialized.' }
        }
        finally { $shell.Dispose() }
        $engine.TokenPath = $script:ApprovalSmokeTokenPath
        $engine
    }
} $DataDirectory $ProjectDirectory

Start-DeskPilot -EngineModulePath $EngineModulePath -DataDir $DataDirectory -Port 0 -NoBrowser
