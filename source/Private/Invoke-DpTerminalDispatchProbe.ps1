function Invoke-DpTerminalDispatchProbe {
    <#
    .SYNOPSIS
        Proves disabled-Terminal refusal and a positive control in an isolated Engine.
    .DESCRIPTION
        Uses scripted provider responses and an inert executor, never a Model,
        command process or credential. Modern Engines use their owned transport
        and execution contracts; older supported Engines use the same test seams
        as the retained dispatch regressions. The caller's Runspace is untouched.
    .PARAMETER ModulePath
        The imported Engine's root module path.
    .PARAMETER DefinitionHash
        Digest of the loaded Invoke-Shp definition, checked again after import.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$DefinitionHash
    )
    $result = Invoke-DpDiagnosticProbe -Id 'terminal-dispatch' -Label 'Engine Terminal dispatch' -TimeoutMilliseconds 5000 -Argument @($ModulePath, $DefinitionHash) -Probe {
        param($ModulePath, $DefinitionHash)
        $ErrorActionPreference = 'Stop'
        Import-Module -Name $ModulePath -Force -ErrorAction Stop
        $engine = Get-Module -Name ShellPilot | Select-Object -First 1
        if (-not $engine) { throw 'The Engine module did not load for the dispatch check.' }
        $command = Get-Command -Name Invoke-Shp -Module ShellPilot -ErrorAction Stop
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $loadedHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($command.Definition))).Replace('-', '') }
        finally { $sha.Dispose() }
        if ($loadedHash -cne $DefinitionHash) { throw 'The imported Engine changed; restart before approving Terminal work.' }

        $state = @{ requests = 0; calls = 0 }
        $transport = {
            $state.requests++
            $calls = @()
            if ($state.requests -eq 1) {
                $calls = @([pscustomobject]@{ Id = 'dispatch-proof'; Name = 'run_command'; Arguments = '{"command":"Write-Output DeskPilotDispatchProof"}' })
            }
            [pscustomobject]@{
                Mode = 'chat'; ModelName = 'gpt-4o'; Content = 'Dispatch proof.'
                FinishReason = $(if ($calls.Count) { 'tool_calls' } else { 'stop' }); ToolCalls = $calls
                AssistantMessage = @{ role = 'assistant'; content = 'Dispatch proof.' }
                PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
                Response = @{ Headers = @{} }; Raw = @{}
            }
        }.GetNewClosure()
        $executor = {
            param($Request)
            if ($Request.Kind -cne 'Terminal' -or $Request.Tool -cne 'run_command') {
                return @{ Denied = $true; Reason = 'Only the inert Terminal proof is permitted.' }
            }
            $state.calls++
            @{ Executed = $true; Result = '{"exitCode":0,"stdout":"DeskPilotDispatchProof"}' }
        }.GetNewClosure()
        $modern = $command.Parameters.ContainsKey('RequestTransport') -and
            $command.Parameters['RequestTransport'].ParameterType -eq [scriptblock] -and
            $command.Parameters.ContainsKey('ExecutionContract') -and
            $command.Parameters['ExecutionContract'].ParameterType -eq [scriptblock]
        if (-not $modern) {
            if (-not $command.Parameters.ContainsKey('ApiBase')) { throw 'The Engine has no supported no-provider dispatch test seam.' }
            & $engine {
                param($Transport, $State)
                $script:DpProbeTransport = $Transport
                $script:DpProbeState = $State
                function script:Get-ShpSessionToken {
                    @{ token = 'inert-dispatch-proof'; expires_at = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds(); endpoints = @{ api = 'https://provider.invalid' } }
                }
                function script:Invoke-ShpHttpRequest { throw 'Network access is forbidden during the dispatch proof.' }
                function script:Invoke-ShpStreamRequest { throw 'Streaming network is forbidden during the dispatch proof.' }
                function script:Invoke-CopilotTurn { & $script:DpProbeTransport }
                function script:Invoke-RunCommandTool {
                    $script:DpProbeState.calls++
                    '{"exitCode":0,"stdout":"DeskPilotDispatchProof"}'
                }
            } $transport $state
        }
        foreach ($disabled in @($true, $false)) {
            $state.calls = 0
            $state.requests = 0
            $parameters = @{
                Prompt = 'Prove the disabled Terminal boundary with inert responses.'
                Model = 'gpt-4o'; History = @(); DisableTerminal = $disabled
                DisableBrowsing = $true; DisableFileAccess = $true; DisableUserPrompts = $true
                DisableUserTools = $true; DisableMcp = $true; DisableTodoList = $true
                DisableStreaming = $true; MaxContextWindowTokens = 0; MaxToolIterations = 3
                MaxOutputTokens = 8; Confirm = $false
            }
            foreach ($key in @($parameters.Keys)) {
                if (-not $command.Parameters.ContainsKey($key)) { $parameters.Remove($key) }
            }
            if (-not $parameters.ContainsKey('DisableTerminal') -or -not $parameters.ContainsKey('History')) {
                throw 'The Engine cannot express the required isolated dispatch test.'
            }
            if ($modern) {
                $parameters.RequestTransport = $transport
                $parameters.ExecutionContract = $executor
            } else { $parameters.ApiBase = 'https://provider.invalid' }
            if ($command.Parameters.ContainsKey('NoAutomaticRetry')) { $parameters.NoAutomaticRetry = $true }
            $response = Invoke-Shp @parameters
            $expectedCalls = if ($disabled) { 0 } else { 1 }
            $expectedDenied = if ($disabled) { 1 } else { 0 }
            if ($state.requests -ne 2 -or $state.calls -ne $expectedCalls -or
                @($response.ToolCallsDenied).Count -ne $expectedDenied -or @($response.ToolCalls).Count -ne 1) {
                throw 'The Engine did not pass both disabled refusal and the positive dispatch control.'
            }
        }
        @{ state = 'healthy'; explanation = 'Disabled Terminal refusal and positive inert dispatch were verified.'; action = '' }
    }
    if ($result.state -cne 'healthy') { Write-Verbose $result.explanation }
    $result.state -ceq 'healthy'
}
