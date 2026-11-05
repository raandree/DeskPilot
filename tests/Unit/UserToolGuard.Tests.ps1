#requires -Version 7.0

# FIND-017: the Engine dispatches a User Tool by splatting the Model's JSON
# arguments onto the registered command. An advanced function also accepts the
# PowerShell common parameters, their aliases and their prefixes, and
# -OutVariable, -ErrorVariable and their siblings write into variables of the
# Engine's own scope - including the ones that keep a disabled Tool from
# running and that ask for approval. Protect-DpUserTool puts a plain function
# under every name DeskPilot registers.

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    $script:guardEngine = @(
        if ($env:DESKPILOT_TEST_ENGINE_PATH) { Get-Module -ListAvailable -Name $env:DESKPILOT_TEST_ENGINE_PATH }
        Get-Module -ListAvailable ShellPilot | Sort-Object Version -Descending
    ) | Where-Object { $_.ExportedFunctions.ContainsKey('Invoke-ShpSubagent') } | Select-Object -First 1
}

BeforeDiscovery {
    $script:hasGuardEngine = [bool](@(
            if ($env:DESKPILOT_TEST_ENGINE_PATH) { Get-Module -ListAvailable -Name $env:DESKPILOT_TEST_ENGINE_PATH }
            Get-Module -ListAvailable ShellPilot
        ) | Where-Object { $_.ExportedFunctions.ContainsKey('Invoke-ShpSubagent') })

    $script:CommonParameterKeys = @(
        'OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'PipelineVariable', 'OutBuffer',
        'ov', 'ev', 'wv', 'iv', 'OutVar', 'ErrorVar', 'InformationAction', 'infa', 'ErrorAction', 'Verbose', 'WhatIf',
        'NoSuchArgument'
    ) | ForEach-Object { @{ Key = $_ } }
}

Describe 'Protect-DpUserTool' -Tag 'Unit' {
    BeforeAll {
        # A Tool like DeskPilot's own: advanced, with a mandatory argument, a
        # validated one, a switch, an array and a default.
        $script:sampleTool = @'
function global:Invoke-SampleTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('quick', 'deep')][string]$Mode = 'quick',
        [switch]$Strict,
        [string[]]$Path,
        [int]$Limit = 7
    )
    $global:SampleCalls++
    "prompt=$Prompt mode=$Mode strict=$([bool]$Strict) path=$($Path -join '|') limit=$Limit"
}
'@
        function script:Invoke-GuardFixture {
            param(
                [Parameter(Mandatory)][hashtable]$Splat,
                [string]$Tool = $script:sampleTool,
                [string]$Redeclare
            )
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $shell = [powershell]::Create()
            $shell.Runspace = $runspace
            try {
                $guard = "function global:Protect-DpUserTool {`n$((Get-Command -Name Protect-DpUserTool -CommandType Function).Definition)`n}"
                $null = $shell.AddScript(@'
param($Guard, $Tool, $Redeclare, $Splat)
. ([scriptblock]::Create($Guard))
. ([scriptblock]::Create($Tool))
Protect-DpUserTool -Name 'Invoke-SampleTool'
if ($Redeclare) {
    . ([scriptblock]::Create($Redeclare))
    Protect-DpUserTool -Name 'Invoke-SampleTool'
}
$global:SampleCalls = 0
# The Engine's own call site: the same scope holds the variables it gates on.
$sentinel = 'ORIGINAL'
$output = (& 'Invoke-SampleTool' @Splat 2>&1 | Out-String).Trim()
$guarded = Get-Command -Name 'Invoke-SampleTool' -CommandType Function
[pscustomobject]@{
    Output     = $output
    Sentinel   = $sentinel
    Calls      = $global:SampleCalls
    Advanced   = $guarded.CmdletBinding
    Parameters = @($guarded.Parameters.Keys)
    Core       = (Get-Command -Name 'Invoke-SampleToolCore' -CommandType Function).CmdletBinding
}
'@).AddArgument($guard).AddArgument($Tool).AddArgument($Redeclare).AddArgument($Splat)
                $result = @($shell.Invoke())
                if ($result.Count -eq 0) { throw $shell.Streams.Error[0] }
                $result[-1]
            }
            finally { $shell.Dispose(); $runspace.Dispose() }
        }
    }

    It 'leaves a plain function with only the Tool''s own parameters under the registered name' {
        $run = Invoke-GuardFixture -Splat @{ Prompt = 'x' }

        $run.Advanced | Should -BeFalse
        $run.Core | Should -BeTrue
        @($run.Parameters | Sort-Object) | Should -Be @('Limit', 'Mode', 'Path', 'Prompt', 'Strict')
    }

    It 'refuses <Key> without running the Tool or writing the caller''s variables' -ForEach $script:CommonParameterKeys {
        $run = Invoke-GuardFixture -Splat @{ Prompt = 'x'; $Key = 'sentinel' }

        $run.Sentinel | Should -BeExactly 'ORIGINAL'
        $run.Calls | Should -Be 0
        $run.Output | Should -Match 'refused'
        $run.Output | Should -Match ([regex]::Escape($Key))
    }

    It 'forwards the Tool''s own arguments, prefixes included, and leaves its defaults to it' {
        $run = Invoke-GuardFixture -Splat @{ Pro = 'audit'; Strict = $true; Path = @('a', 'b') }

        $run.Output | Should -BeExactly 'prompt=audit mode=quick strict=True path=a|b limit=7'
        $run.Calls | Should -Be 1
    }

    It 'keeps the Tool''s own validation' {
        $invalid = Invoke-GuardFixture -Splat @{ Prompt = 'x'; Mode = 'reckless' }
        $missing = Invoke-GuardFixture -Splat @{ Mode = 'deep' }

        $invalid.Output | Should -Match 'reckless'
        $invalid.Calls | Should -Be 0
        $missing.Output | Should -Match 'Prompt'
        $missing.Calls | Should -Be 0
    }

    It 'guards the Tool again after it is declared again, as every Turn does' {
        $second = $script:sampleTool.Replace('"prompt=$Prompt', '"second prompt=$Prompt')
        $run = Invoke-GuardFixture -Splat @{ Prompt = 'x'; OutVariable = 'sentinel' } -Redeclare $second
        $ok = Invoke-GuardFixture -Splat @{ Prompt = 'x' } -Redeclare $second

        $run.Sentinel | Should -BeExactly 'ORIGINAL'
        $run.Advanced | Should -BeFalse
        $ok.Output | Should -Match '^second prompt=x'
    }

    It 'refuses a command name it could not guard safely' {
        { Protect-DpUserTool -Name 'Invoke-Sample; Remove-Item' } | Should -Throw
    }
}

Describe 'Every DeskPilot User Tool registration' -Tag 'Unit' {
    It 'is followed by Protect-DpUserTool for the same command' {
        $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
        $registered = [System.Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem -Path $privateRoot -Filter '*.ps1') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -notmatch 'Register-ShpTool\b') { continue }
            $names = @(
                [regex]::Matches($text, "Register-ShpTool\s+-Command\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
                [regex]::Matches($text, "(?m)^\s*Command\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
            ) | Sort-Object -Unique
            foreach ($name in $names) {
                $registered.Add($name)
                $text | Should -Match ("Protect-DpUserTool -Name '" + [regex]::Escape($name) + "'") -Because "$($file.Name) registers $name with the Engine"
            }
        }

        @($registered | Sort-Object -Unique) | Should -Be @(
            'Invoke-DpBrowserTool', 'Invoke-DpFileSearchTool', 'Invoke-DpQuestionnaireTool', 'Invoke-DpReplaceInFileTool',
            'Invoke-DpSubagentTool', 'Invoke-DpTerminalApprovalTool', 'Invoke-DpTextSearchTool'
        )
    }
}

Describe 'User Tool arguments through the Engine' -Tag 'Unit' -Skip:(-not $script:hasGuardEngine) {
    # The real Engine dispatches every call and DeskPilot registers its real Tools.
    # Only the provider is scripted, and the native Terminal and file writer are
    # inert stubs that record whether they were reached.
    BeforeAll {
        # The Engine refuses its Copilot backend when $env:CI is set, unless this
        # opt-in is present. Nothing here reaches Copilot - the provider is
        # scripted and both network paths throw - so the opt-in only gets the
        # fixture past that gate on a CI runner. Restored in AfterAll.
        $script:previousCopilotInCi = $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI
        $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = '1'
        if (-not ('DeskPilot.Tests.GuardApprovalBridge' -as [type])) {
            Add-Type -TypeDefinition @'
namespace DeskPilot.Tests {
    public sealed class GuardApprovalBridge {
        public bool Enabled = true;
        public bool Cancelled;
        public string Next = "{\"decision\":\"deny\",\"scope\":\"once\"}";
        public System.Collections.Generic.List<string> Questions = new System.Collections.Generic.List<string>();
        public void CaptureQuestion(string text) {
            Questions.Add(text);
            Next = text.Contains("search_files") ? "{\"decision\":\"approve\",\"scope\":\"once\"}" : "{\"decision\":\"deny\",\"scope\":\"once\"}";
        }
        public string RequestAnswer(int seconds) { return Next; }
    }
}
'@
        }
        $script:providerBody = @'
$call = @{}
foreach ($key in $PSBoundParameters.Keys) { $call[$key] = $PSBoundParameters[$key] }
$global:DpProviderCalls.Add($call)
if ($global:DpProviderScript.Count -eq 0) { throw 'The scripted provider ran out of responses.' }
$next = $global:DpProviderScript.Dequeue()
$calls = @(foreach ($c in @($next.ToolCalls)) { if ($c) { [pscustomobject]@{ Id = $c.Id; Name = $c.Name; Arguments = ($c.Arguments | ConvertTo-Json -Compress) } } })
[pscustomobject]@{
    Mode = 'chat'; ModelName = [string]$PSBoundParameters['Model']; Content = [string]$next.Content
    FinishReason = $(if ($calls.Count) { 'tool_calls' } else { 'stop' }); ToolCalls = $calls
    AssistantMessage = @{ role = 'assistant'; content = [string]$next.Content }
    PromptTokens = 10; CompletionTokens = 5; CachedTokens = 0; CacheWriteTokens = 0
    Response = @{ Headers = @{} }; Raw = @{}
}
'@
        $script:engineFixture = @'
param($Body)
$engine = Get-Module ShellPilot
$metadata = [System.Management.Automation.CommandMetadata]::new((& $engine { Get-Command -Name Invoke-CopilotTurn -CommandType Function }))
$binding = [System.Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($metadata)
$parameterBlock = [System.Management.Automation.ProxyCommand]::GetParamBlock($metadata)
$stub = "function script:Invoke-CopilotTurn {`n$binding`nparam($parameterBlock)`n$Body`n}"
& $engine { param($Text) . ([scriptblock]::Create($Text)) } $stub
& $engine {
    function script:Get-ShpSessionToken { [pscustomobject]@{ token = 'fixture-session'; expires_at = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); endpoints = [pscustomobject]@{ api = 'https://provider.invalid' } } }
    function script:Invoke-ShpHttpRequest { throw 'Network must not be used by this fixture.' }
    function script:Invoke-ShpStreamRequest { throw 'Network must not be used by this fixture.' }
    function script:Invoke-RunCommandTool { $global:DpNativeDispatch.Add('run_command'); 'NATIVE run_command' }
    function script:Invoke-WriteFileTool { $global:DpNativeDispatch.Add('write_file'); 'NATIVE write_file' }
}
$global:DpProviderCalls = [System.Collections.Generic.List[object]]::new()
$global:DpProviderScript = [System.Collections.Generic.Queue[object]]::new()
$global:DpNativeDispatch = [System.Collections.Generic.List[string]]::new()
'@
    }

    BeforeEach {
        $script:guardRunspace = [runspacefactory]::CreateRunspace()
        $script:guardRunspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $script:guardRunspace
        try {
            $null = $shell.AddCommand('Import-Module').AddParameter('Name', $script:guardEngine.Path).AddParameter('ErrorAction', 'Stop').AddStatement()
            $null = $shell.AddScript($script:engineFixture).AddArgument($script:providerBody)
            $shell.Invoke() | Out-Null
            if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
        }
        finally { $shell.Dispose() }
    }

    AfterEach { $script:guardRunspace.Dispose() }

    AfterAll {
        if ($null -eq $script:previousCopilotInCi) { Remove-Item -Path Env:\SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI -ErrorAction SilentlyContinue }
        else { $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = $script:previousCopilotInCi }
    }

    It 'keeps a disabled Tool disabled and every approval asked when a call smuggles common parameters' {
        $workspace = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $workspace
        $target = Join-Path $workspace 'written.md'
        Initialize-DpWorkspaceTool -Runspace $script:guardRunspace -Root $workspace | Should -BeTrue
        $bridge = [DeskPilot.Tests.GuardApprovalBridge]::new()
        $approvalContext = @{
            conversationId = 'c_0123456789'; turnId = 'm_abcdef0123'; project = 'Fixture'; workingDirectory = $workspace
            permissions = @{ file = $true; mcp = $true; terminal = $false; userTools = $true; askUser = $false; browsing = $false }
            workspaceToolsOwned = $true; terminalApprovalActive = $false
        }
        $binding = Initialize-DpToolCallApproval -Runspace $script:guardRunspace -Context $approvalContext -Bridge $bridge -TimeoutSeconds 5
        $parameters = @{
            Prompt = 'Find the notes.'; Model = 'gpt-4o'; History = @(); DisableStreaming = $true; NonInteractive = $true
            DisableUserPrompts = $true; DisableTerminal = $true; DisableBrowsing = $true; MaxToolIterations = 6; Confirm = $false
            ToolCallControl = $binding.ToolCallControl
        }
        $responses = @(
            @{ Content = ''; ToolCalls = @(@{ Id = 't1'; Name = 'search_files'; Arguments = @{ pattern = '*.md'; OutVariable = 'knownToolName'; ErrorVariable = 'resolvedToolControl' } }) }
            @{ Content = ''; ToolCalls = @(@{ Id = 't2'; Name = 'write_file'; Arguments = @{ path = $target; content = 'WRITTEN' } }) }
            @{ Content = ''; ToolCalls = @(@{ Id = 't3'; Name = 'run_command'; Arguments = @{ command = 'echo reached' } }) }
            @{ Content = 'Done.'; ToolCalls = @() }
        )

        $shell = [powershell]::Create()
        $shell.Runspace = $script:guardRunspace
        try {
            $null = $shell.AddScript(@'
param($Responses, $Parameters)
foreach ($response in $Responses) { $global:DpProviderScript.Enqueue([pscustomobject]$response) }
$result = Invoke-Shp @Parameters
[pscustomobject]@{ Result = $result; Calls = @($global:DpProviderCalls); Native = @($global:DpNativeDispatch) }
'@).AddArgument($responses).AddArgument($parameters)
            $output = @($shell.Invoke())
            if ($output.Count -eq 0 -or ($shell.HadErrors -and $null -eq $output[-1].Result)) { throw $shell.Streams.Error[0] }
            $run = $output[-1]
        }
        finally { $shell.Dispose() }

        @($run.Native) | Should -BeNullOrEmpty -Because 'neither the native file writer nor the disabled Terminal may be reached'
        Test-Path -LiteralPath $target | Should -BeFalse
        $run.Result.Content | Should -BeExactly 'Done.'
        $conversation = $run.Calls[-1].Conversation | ConvertTo-Json -Depth 12
        $conversation | Should -Match 'refused'
        $conversation | Should -Match 'OutVariable'
        $conversation | Should -Match "run_command' tool is disabled for this call"
        @($bridge.Questions | Where-Object { $_ -match 'write_file' }) | Should -HaveCount 1 -Because 'the write still met the approval control'

        # The Model is still offered the schema of the advanced function.
        $offered = @(@($run.Calls[0].Tools) | Where-Object { $_.function.name -eq 'search_files' })
        $offered | Should -HaveCount 1
        @($offered[0].function.parameters.required) | Should -Be @('pattern')
        $offered[0].function.parameters.properties['maxResults'].type | Should -BeExactly 'integer'
    }

    It 'keeps the Terminal Tool''s schema when isolation registers it a second time' {
        # Register-ShpTool builds the schema from whatever function holds the name,
        # so a guard installed before the second registration would hand the Model
        # an untyped schema with nothing required.
        $context = @{ conversationId = 'c_0123456789'; turnId = 'm_abcdef0123'; project = 'Fixture'; workingDirectory = [string]$TestDrive; policyId = 'p1' }
        $terminalParams = @{
            Runspace        = $script:guardRunspace
            Context         = $context
            SafeCommand     = @()
            TimeoutMinutes  = 1
            Bridge          = [DeskPilot.Tests.GuardApprovalBridge]::new()
            IsolatedSession = [pscustomobject]@{ Name = 'inert' }
        }
        $null = Initialize-DpTerminalTool @terminalParams

        $shell = [powershell]::Create()
        $shell.Runspace = $script:guardRunspace
        try {
            $null = $shell.AddScript(@'
$schema = & (Get-Module ShellPilot) { $script:ShpUserTools['run_terminal_command'].Schema }
[pscustomobject]@{ Schema = $schema; Advanced = (Get-Command -Name 'Invoke-DpTerminalApprovalTool' -CommandType Function).CmdletBinding }
'@)
            $state = @($shell.Invoke())[-1]
        }
        finally { $shell.Dispose() }

        $state.Advanced | Should -BeFalse
        $state.Schema.function.description | Should -Match 'disposable Linux container'
        @($state.Schema.function.parameters.required) | Should -Be @('Command')
        $state.Schema.function.parameters.properties['TimeoutSeconds'].type | Should -BeExactly 'integer'
    }
}
