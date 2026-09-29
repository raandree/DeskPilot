#requires -Version 7.0

BeforeDiscovery { $script:hasCompatibilityEngine = -not [string]::IsNullOrWhiteSpace($env:DESKPILOT_TEST_ENGINE_PATH) }

Describe 'Actual Engine pre-call approval integration' -Skip:(-not $script:hasCompatibilityEngine) {
    BeforeAll {
        Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        $script:compatibilityManifest = $env:DESKPILOT_TEST_ENGINE_PATH
        Test-Path -LiteralPath $script:compatibilityManifest -PathType Leaf | Should -BeTrue
        if (-not ('DeskPilot.Tests.ModernApprovalBridge' -as [type])) {
            Add-Type -TypeDefinition @'
namespace DeskPilot.Tests {
    public sealed class ModernApprovalBridge {
        public bool Enabled = true;
        public bool Cancelled;
        public int Requests;
        public string Captured;
        public string Reply = "{\"decision\":\"approve\",\"scope\":\"once\"}";
        public void CaptureQuestion(string text) { Captured = text; }
        public string RequestAnswer(int seconds) { Requests++; return Reply; }
    }
}
'@
        }
    }

    BeforeEach {
        $runspace = [runspacefactory]::CreateRunspace(); $runspace.Open()
        $shell = [powershell]::Create(); $shell.Runspace = $runspace
        $null = $shell.AddCommand('Import-Module').AddParameter('Name', $script:compatibilityManifest).AddParameter('ErrorAction', 'Stop')
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
        $shell.Commands.Clear()
        $null = $shell.AddScript(@'
$engine = Get-Module ShellPilot
& $engine {
    function script:Get-ShpSessionToken { throw 'Credentials must not be read by this integration fixture.' }
    function script:Invoke-ShpHttpRequest { throw 'Network must not be used by this integration fixture.' }
    function script:Invoke-ShpStreamRequest { throw 'Network must not be used by this integration fixture.' }
    $mcpTool = ConvertTo-ShpMcpToolSchema -Alias 'fixture' -Tool ([pscustomobject]@{
        name = 'admin.tools.list'; description = 'Inert fixture'; inputSchema = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} }
    })
    $script:ShpMcpServers = [ordered]@{ fixture = @{ Name = 'fixture'; State = 'Ready'; Tools = @($mcpTool) } }
}
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
        $shell.Commands.Clear()
        $bridge = [DeskPilot.Tests.ModernApprovalBridge]::new()
        $context = @{
            conversationId = 'c_0123456789'; turnId = 'm_abcdef0123'; project = 'Fixture'
            workingDirectory = [string]$TestDrive
            permissions = @{ file = $true; mcp = $true; terminal = $false; userTools = $true; askUser = $true; browsing = $true }
            workspaceToolsOwned = $false; terminalApprovalActive = $false
        }
    }

    AfterEach { $shell.Dispose(); $runspace.Dispose() }

    It 'uses the modern contract and enforces <Decision> for <Tool>' -ForEach @(
        @{ Tool = 'write_file'; Decision = 'approve'; ExpectedCalls = 1; ExpectedDenied = 0; ExpectedTarget = 'FileMutation'; PolicyDenied = $false; ExpectedRequests = 1 }
        @{ Tool = 'write_file'; Decision = 'deny'; ExpectedCalls = 0; ExpectedDenied = 1; ExpectedTarget = ''; PolicyDenied = $false; ExpectedRequests = 1 }
        @{ Tool = 'mcp_fixture_admin_tools_list'; Decision = 'approve'; ExpectedCalls = 1; ExpectedDenied = 0; ExpectedTarget = 'fixture/admin.tools.list'; PolicyDenied = $false; ExpectedRequests = 1 }
        @{ Tool = 'mcp_fixture_admin_tools_list'; Decision = 'deny'; ExpectedCalls = 0; ExpectedDenied = 1; ExpectedTarget = ''; PolicyDenied = $false; ExpectedRequests = 1 }
        @{ Tool = 'write_file'; Decision = 'approve'; ExpectedCalls = 0; ExpectedDenied = 1; ExpectedTarget = ''; PolicyDenied = $true; ExpectedRequests = 0 }
    ) {
        Get-DpToolCallApprovalContract -Runspace $runspace | Should -BeExactly 'ToolCallControl'
        $bridge.Reply = @{ decision = $Decision; scope = 'once' } | ConvertTo-Json -Compress
        $binding = Initialize-DpToolCallApproval -Runspace $runspace -Context $context -Bridge $bridge
        $null = $shell.AddScript(@'
param($Binding, $Tool, $FixturePath, [bool]$PolicyDenied)
if ($PolicyDenied) { Set-ShpToolPolicy -Rule @('Read(./**)') -Confirm:$false }
$global:DpIntegrationTool = $Tool
$global:DpIntegrationArguments = @{ path = (Join-Path $FixturePath 'never-written.txt'); content = 'INTEGRATION-CONTENT-SENTINEL' } | ConvertTo-Json -Compress
$global:DpIntegrationRequests = 0
$global:DpIntegrationEffects = 0
$global:DpIntegrationTarget = ''
$transport = {
    param($Request)
    $global:DpIntegrationRequests++
    $calls = @()
    if ($global:DpIntegrationRequests -eq 1) {
        $calls = @([pscustomobject]@{ Id = 'integration-call'; Name = $global:DpIntegrationTool; Arguments = $global:DpIntegrationArguments })
    }
    [pscustomobject]@{
        Mode = 'chat'; ModelName = 'gpt-4o'; Content = 'Fixture complete.'
        FinishReason = $(if ($calls.Count) { 'tool_calls' } else { 'stop' }); ToolCalls = $calls
        AssistantMessage = @{ role = 'assistant'; content = 'Fixture complete.' }
        PromptTokens = 1; CompletionTokens = 1; CachedTokens = 0; CacheWriteTokens = 0
        Response = @{ Headers = @{} }; Raw = @{}
    }
}
$parameters = @{
    Prompt = 'Exercise the host decision adapter.'; Model = 'gpt-4o'; History = @()
    DisableTerminal = $true; DisableBrowsing = $true; DisableUserPrompts = $true; DisableUserTools = $true
    DisableTodoList = $true; DisableStreaming = $true; MaxOutputTokens = 8; MaxContextWindowTokens = 0; MaxToolIterations = 3
    RequestTransport = $transport; Confirm = $false
    ExecutionContract = {
        param($Request)
        $global:DpIntegrationEffects++
        $global:DpIntegrationTarget = if ($Request.Kind -ceq 'McpTool') { $Request.Target } else { $Request.Kind }
        @{ Executed = $true; Result = '{"fixture":true}' }
    }
}
foreach ($key in $Binding.Keys) { $parameters[$key] = $Binding[$key] }
$result = Invoke-Shp @parameters
[pscustomobject]@{
    Calls = $global:DpIntegrationEffects; Target = $global:DpIntegrationTarget
    Denied = @($result.ToolCallsDenied).Count; Decisions = @($result.ToolCallDecisions)
}
'@).AddArgument($binding).AddArgument($Tool).AddArgument([string]$TestDrive).AddArgument([bool]$PolicyDenied)
        $result = @($shell.Invoke())
        $shell.HadErrors | Should -BeFalse -Because ($shell.Streams.Error | Out-String)
        $result | Should -HaveCount 1
        $result[0].Calls | Should -Be $ExpectedCalls
        $result[0].Denied | Should -Be $ExpectedDenied
        $result[0].Target | Should -BeExactly $ExpectedTarget
        $bridge.Requests | Should -Be $ExpectedRequests
        $bridge.Captured | Should -Not -Match 'INTEGRATION-CONTENT-SENTINEL'
        if (-not $PolicyDenied) { $result[0].Decisions[0].FailPosture | Should -BeExactly 'Closed' }
        if ($Tool -like 'mcp_*') { ($bridge.Captured | ConvertFrom-Json).summary.action | Should -BeExactly 'fixture / admin.tools.list' }
        Test-Path -LiteralPath (Join-Path $TestDrive 'never-written.txt') | Should -BeFalse
    }

    It 'recognizes the real disabled-Terminal behavior without a source identifier' {
        Test-DpTerminalDispatch -Runspace $runspace | Should -BeTrue
    }
}
