[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DataDirectory,
    [Parameter(Mandatory)][string]$ProjectDirectory,
    [switch]$ScriptedProvider
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
$built = Get-ChildItem -LiteralPath (Join-Path $root 'output' 'module' 'DeskPilot') -Filter DeskPilot.psd1 -Recurse |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if (-not $built) { throw 'Build DeskPilot before the HTTP smoke test.' }
$engine = Join-Path $root 'output' 'RequiredModules' 'ShellPilot' '0.4.1' 'ShellPilot.psd1'
if (-not (Test-Path -LiteralPath $engine)) { throw 'The dispatch-enforcing test Engine is unavailable.' }
$module = Import-Module -Name $built.FullName -Force -PassThru
& $module {
    param($DataDirectory, $ProjectDirectory)
    $settings = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
        projects = @(@{ id = 'isolation-smoke'; name = 'Isolation smoke'; path = $ProjectDirectory })
        selectedProjectId = 'isolation-smoke'
        selectedAgent = $null
        agentsRoot = $null
        skillRoots = @()
        instructionRoots = @()
        promptRoots = @()
        pushInstructions = $false
        workspaceContext = $false
        memoryLearning = $false
        autoCompaction = $false
        taskTracking = $false
        maxToolIterations = 5
        responseRetryCount = 0
        permissions = @{ terminal = $true; userTools = $true; file = $false; browsing = $false; askUser = $false; mcp = $false }
        terminalExecution = @{ mode = 'isolated'; projectAccess = 'read-write' }
    }
    Save-DpSettings -Settings $settings -Directory $DataDirectory
    $null = Install-DpTerminalRuntime -DataDirectory $DataDirectory
} $DataDirectory $ProjectDirectory

if ($ScriptedProvider) {
    & $module {
        param($DataDirectory)
        $script:SmokeTokenPath = Join-Path $DataDirectory 'scripted-auth-marker'
        Set-Content -LiteralPath $script:SmokeTokenPath -Value 'fixture' -Encoding ascii
        $script:SmokeEngineFactory = (Get-Command Initialize-DpEngine).ScriptBlock
        function script:Initialize-DpEngine {
            param([string]$EngineModulePath)
            $engine = & $script:SmokeEngineFactory -EngineModulePath $EngineModulePath
            $shell = [powershell]::Create()
            $shell.Runspace = $engine.Runspace
            try {
                $null = $shell.AddScript(@'
$module = Get-Module ShellPilot
& $module {
    $script:SmokeCalls = 0
    function script:Get-ShpSessionToken {
        @{ token = 'fixture'; expires_at = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds(); endpoints = @{ api = 'https://fixture.invalid' } }
    }
    function script:Get-ShpModel {
        [pscustomobject]@{ id = 'gpt-4.1'; name = 'gpt-4.1'; maxContextWindowTokens = 64000; maxOutputTokens = 4000; reasoningEfforts = @(); vision = $false }
    }
    function script:Get-ShpDefault { @{ Model = 'gpt-4.1' } }
    function script:Invoke-ShpHttpRequest { throw 'Network request outside the scripted provider fixture.' }
    function script:Invoke-ShpStreamRequest { throw 'Streaming request outside the scripted provider fixture.' }
    function script:Invoke-CopilotTurn {
        $script:SmokeCalls++
        $calls = @()
        if ($script:SmokeCalls -eq 1) {
            $arguments = @{ command = "Set-Content -Path /project/proof.txt -Value 'isolated-proof'; Write-Output `$IsLinux" } | ConvertTo-Json -Compress
            $calls = @([pscustomobject]@{ Id = 'smoke-command'; Name = 'run_terminal_command'; Arguments = $arguments })
        }
        [pscustomobject]@{
            Mode = 'chat'; ModelName = 'gpt-4.1'; Content = 'True'; Reasoning = ''
            FinishReason = $(if ($calls.Count) { 'tool_calls' } else { 'stop' })
            ToolCalls = $calls; AssistantMessage = @{ role = 'assistant'; content = 'True' }
            PromptTokens = 10; CompletionTokens = 10; CachedTokens = 0; CacheWriteTokens = 0
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
                if ($shell.HadErrors) { throw 'The scripted provider fixture could not be initialized.' }
            }
            finally { $shell.Dispose() }
            $engine.TokenPath = $script:SmokeTokenPath
            $engine
        }
    } $DataDirectory
}

Start-DeskPilot -EngineModulePath $engine -DataDir $DataDirectory -Port 0 -NoBrowser
