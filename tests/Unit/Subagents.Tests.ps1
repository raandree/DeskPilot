#requires -Version 7.0

# Subagents: the Model hands one self-contained task to a model-invocable Agent
# through DeskPilot's run_subagent Tool. The Engine's bounded Subagent contract
# (ShellPilot spec 045) runs it synchronously, as a strict subset of the Turn
# that dispatched it. See .memory-bank/decisions/0012-bounded-subagents.md.

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function script:New-TestAgentFile {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$FileName,
            [Parameter(Mandatory)][string]$Front,
            [string]$Body = 'You are a focused helper.'
        )
        if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }
        $path = Join-Path $Root $FileName
        Set-Content -LiteralPath $path -Value "---`n$Front`n---`n$Body" -Encoding utf8
        $path
    }

    # The attenuated request Invoke-ShpSubagent hands its Invoker, with every key
    # its own dispatcher reads.
    function script:New-TestSubagentRequest {
        param([bool]$ToolBound = $false, [string[]]$Tool = @())
        @{
            Prompt              = 'Audit the docs folder.'
            SystemPrompt        = 'You are a reviewer.'
            Agent               = 'reviewer'
            Tool                = $Tool
            ToolBound           = $ToolBound
            DisableFileAccess   = $false
            DisableTerminal     = $true
            DisableBrowsing     = $true
            DisableMcp          = $false
            DisableUserTools    = $false
            DisableUserPrompts  = $true
            NonInteractive      = $true
            AllowPrivateNetwork = $false
            DisableRedaction    = $false
            ToolPolicy          = [pscustomobject]@{ PSTypeName = 'ShellPilot.ToolPolicy'; Rule = @() }
            ToolCallControl     = @{ SchemaVersion = 1; FailPosture = 'Closed'; PreToolCall = { param($Request) @{ Decision = 'deny' } } }
            ExecutionContract   = $null
            ApiBase             = ''
            MaxBudgetUSD        = 0.5
            MaxToolIterations   = 12
            TraceParent         = '00-0123456789abcdef0123456789abcdef-0123456789abcdef-01'
            TraceId             = '0123456789abcdef0123456789abcdef'
            SpanId              = '0123456789abcdef'
            Depth               = 1
            Deadline            = [datetime]::UtcNow.AddMinutes(10)
            CancellationToken   = [System.Threading.CancellationToken]::None
        }
    }

    $script:subagentEngine = @(
        if ($env:DESKPILOT_TEST_ENGINE_PATH) { Get-Module -ListAvailable -Name $env:DESKPILOT_TEST_ENGINE_PATH }
        Get-Module -ListAvailable ShellPilot | Sort-Object Version -Descending
    ) | Where-Object { $_.ExportedFunctions.ContainsKey('Invoke-ShpSubagent') } | Select-Object -First 1

    function script:New-SubagentEngineRunspace {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        try {
            $null = $shell.AddCommand('Import-Module').AddParameter('Name', $script:subagentEngine.Path).AddParameter('ErrorAction', 'Stop')
            $shell.Invoke() | Out-Null
            if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
        }
        finally { $shell.Dispose() }
        $runspace
    }
}

BeforeDiscovery {
    $script:hasSubagentEngine = [bool](@(
            if ($env:DESKPILOT_TEST_ENGINE_PATH) { Get-Module -ListAvailable -Name $env:DESKPILOT_TEST_ENGINE_PATH }
            Get-Module -ListAvailable ShellPilot
        ) | Where-Object { $_.ExportedFunctions.ContainsKey('Invoke-ShpSubagent') })
}

Describe 'Read-DpAgentFile Subagent fields' {
    BeforeEach {
        $script:fieldRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'reads an inline tools list and an inline agents list' {
        $front = "name: lead`ndescription: d`ntools: ['read/readFile', `"search`", edit/editFiles]`nagents: ['technical-writer', 'legal-researcher']"
        $m = Read-DpAgentFile -Path (New-TestAgentFile -Root $script:fieldRoot -FileName 'lead.agent.md' -Front $front)

        @($m.tools) | Should -Be @('read/readFile', 'search', 'edit/editFiles')
        @($m.agents) | Should -Be @('technical-writer', 'legal-researcher')
    }

    It 'reads block lists without picking up indented keys of other sections' {
        $front = "name: lead`ndescription: d`nagents:`n  - training-writer`n  - 'technical-writer'`nhandoffs:`n  - label: Write docs`n    agent: technical-writer`n    send: false"
        $m = Read-DpAgentFile -Path (New-TestAgentFile -Root $script:fieldRoot -FileName 'block.agent.md' -Front $front)

        @($m.agents) | Should -Be @('training-writer', 'technical-writer')
        $m.tools | Should -BeNullOrEmpty
    }

    It 'tells an absent agents list apart from a declared empty one' {
        $absent = Read-DpAgentFile -Path (New-TestAgentFile -Root $script:fieldRoot -FileName 'absent.agent.md' -Front "name: a`ndescription: d")
        $empty = Read-DpAgentFile -Path (New-TestAgentFile -Root $script:fieldRoot -FileName 'empty.agent.md' -Front "name: e`ndescription: d`nagents: []")

        $null -eq $absent.agents | Should -BeTrue
        $null -eq $empty.agents | Should -BeFalse
        @($empty.agents).Count | Should -Be 0
    }

    It 'reads disable-model-invocation and user-invocable as <Expected>' -ForEach @(
        @{ Line = 'disable-model-invocation: true'; Key = 'disableModelInvocation'; Expected = $true }
        @{ Line = "disable-model-invocation: 'true'"; Key = 'disableModelInvocation'; Expected = $true }
        @{ Line = 'disable-model-invocation: false'; Key = 'disableModelInvocation'; Expected = $false }
        @{ Line = 'user-invocable: false'; Key = 'userInvocable'; Expected = $false }
        @{ Line = 'user-invocable: true'; Key = 'userInvocable'; Expected = $true }
    ) {
        $m = Read-DpAgentFile -Path (New-TestAgentFile -Root $script:fieldRoot -FileName 'flag.agent.md' -Front "name: f`ndescription: d`n$Line")
        $m[$Key] | Should -Be $Expected
    }

    It 'defaults to model-invocable and user-invocable when the flags are absent' {
        $m = Read-DpAgentFile -Path (New-TestAgentFile -Root $script:fieldRoot -FileName 'plain.agent.md' -Front "name: p`ndescription: d")
        $m.disableModelInvocation | Should -BeFalse
        $m.userInvocable | Should -BeTrue
    }

    It 'keeps the fields it already returned' {
        $m = Read-DpAgentFile -Path (New-TestAgentFile -Root $script:fieldRoot -FileName 'keep.agent.md' -Front "name: k`ndescription: kept`ntools: [read_file]" -Body 'Body text.')
        $m.name | Should -Be 'k'
        $m.description | Should -Be 'kept'
        $m.body | Should -Be 'Body text.'
        @($m.tools) | Should -Be @('read_file')
    }
}

Describe 'Get-DpSubagentAssetRoot' {
    It 'finds the bundled general-purpose definition the Engine can validate' {
        $root = Get-DpSubagentAssetRoot
        $path = Join-Path $root 'general-purpose.agent.md'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $definition = Read-DpAgentFile -Path $path
        $definition.name | Should -BeExactly 'general-purpose'
        $definition.description | Should -Not -BeNullOrEmpty
        $definition.body | Should -Match 'final'
        $definition.disableModelInvocation | Should -BeFalse
    }
}

Describe 'Get-DpSubagentCatalog' {
    BeforeEach {
        $script:catalogRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:builtInRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-TestAgentFile -Root $script:builtInRoot -FileName 'general-purpose.agent.md' -Front "name: general-purpose`ndescription: Built-in helper."
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'beta.agent.md' -Front "name: beta`ndescription: Second helper."
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'alpha.agent.md' -Front "name: alpha`ndescription: First helper."
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'private.agent.md' -Front "name: private`ndescription: Only for people.`ndisable-model-invocation: true"
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'nodesc.agent.md' -Front 'name: nodesc'
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'noname.agent.md' -Front 'description: Nameless.'
        Set-Content -LiteralPath (Join-Path $script:catalogRoot 'notes.md') -Value 'not an agent' -Encoding utf8
        $script:catalogParams = @{ Root = $script:catalogRoot; BuiltInRoot = $script:builtInRoot }
    }

    It 'offers the built-in first, then every model-invocable Agent the Engine can validate' {
        $catalog = Get-DpSubagentCatalog @script:catalogParams

        $catalog.allowed | Should -BeTrue
        @($catalog.entries.name) | Should -Be @('general-purpose', 'alpha', 'beta')
        $catalog.entries[0].builtIn | Should -BeTrue
        $catalog.entries[0].root | Should -Be $script:builtInRoot
        $catalog.entries[1].builtIn | Should -BeFalse
        $catalog.entries[1].path | Should -Be (Join-Path $script:catalogRoot 'alpha.agent.md')
        $catalog.entries[1].root | Should -Be $script:catalogRoot
        $catalog.entries[1].description | Should -BeExactly 'First helper.'
    }

    It 'lets a user Agent named general-purpose replace the built-in' {
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'mine.agent.md' -Front "name: General-Purpose`ndescription: Mine."
        $catalog = Get-DpSubagentCatalog @script:catalogParams

        @($catalog.entries | Where-Object { $_.name -eq 'general-purpose' }).Count | Should -Be 1
        ($catalog.entries | Where-Object { $_.name -eq 'general-purpose' }).builtIn | Should -BeFalse
    }

    It 'honours the selected Agent''s agents list: <Case>' -ForEach @(
        @{ Case = 'absent'; Front = "name: lead`ndescription: d"; Allowed = $true; Expected = @('general-purpose', 'alpha', 'beta', 'lead') }
        @{ Case = 'wildcard'; Front = "name: lead`ndescription: d`nagents: ['*']"; Allowed = $true; Expected = @('general-purpose', 'alpha', 'beta', 'lead') }
        @{ Case = 'named'; Front = "name: lead`ndescription: d`nagents: [Beta]"; Allowed = $true; Expected = @('general-purpose', 'beta') }
        @{ Case = 'empty'; Front = "name: lead`ndescription: d`nagents: []"; Allowed = $false; Expected = @() }
    ) {
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'lead.agent.md' -Front $Front
        $catalog = Get-DpSubagentCatalog @script:catalogParams -SelectedAgent 'lead.agent.md'

        $catalog.allowed | Should -Be $Allowed
        @($catalog.entries | ForEach-Object { $_.name }) | Should -Be $Expected
        if (-not $Allowed) { $catalog.reason | Should -Match 'agents: \[\]' }
    }

    It 'keeps the first of two Agents that share a name' {
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'zeta.agent.md' -Front "name: ALPHA`ndescription: Later duplicate."
        $catalog = Get-DpSubagentCatalog @script:catalogParams

        @($catalog.entries | Where-Object { $_.name -eq 'alpha' }).Count | Should -Be 1
        ($catalog.entries | Where-Object { $_.name -eq 'alpha' }).description | Should -BeExactly 'First helper.'
    }

    It 'flattens a description and keeps a name the Tool description can carry safely' {
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'long.agent.md' -Front ("name: long`ndescription: Line one.`t`u{0007}Line two " + ('x' * 400))
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'odd.agent.md' -Front "name: bad name`" injected`ndescription: d"
        $catalog = Get-DpSubagentCatalog @script:catalogParams

        $long = $catalog.entries | Where-Object { $_.name -eq 'long' }
        $long.description.Length | Should -BeLessOrEqual 200
        $long.description | Should -Not -Match '[\x00-\x1f]'
        $long.description | Should -Match '^Line one\. Line two'
        @($catalog.entries.name) | Should -Not -Contain 'bad name" injected'
    }

    It 'leaves out a definition over the Engine''s 256 KiB cap' {
        $null = New-TestAgentFile -Root $script:catalogRoot -FileName 'huge.agent.md' -Front "name: huge`ndescription: d" -Body ('y' * 270000)
        @((Get-DpSubagentCatalog @script:catalogParams).entries.name) | Should -Not -Contain 'huge'
    }

    It 'still offers the built-in when the Agents folder is unset or missing' {
        @((Get-DpSubagentCatalog -Root '' -BuiltInRoot $script:builtInRoot).entries.name) | Should -Be @('general-purpose')
        @((Get-DpSubagentCatalog -Root (Join-Path $TestDrive 'missing') -BuiltInRoot $script:builtInRoot).entries.name) | Should -Be @('general-purpose')
    }

    It 'caps the catalog so the Tool description stays bounded' {
        foreach ($n in 1..30) { $null = New-TestAgentFile -Root $script:catalogRoot -FileName ('a{0:d2}.agent.md' -f $n) -Front ("name: a{0:d2}`ndescription: d" -f $n) }
        @((Get-DpSubagentCatalog @script:catalogParams -MaxEntries 8).entries).Count | Should -Be 8
    }
}

Describe 'ConvertTo-DpSubagentTurnParameter' {
    BeforeAll {
        $script:turn = @{
            model            = 'claude-opus-5.5'
            reasoningEffort  = 'high'
            workingDirectory = 'C:\work\alpha'
            excludeTool      = @('run_subagent', 'ask_questions')
        }
    }

    It 'runs the Subagent on the Turn''s Model and reasoning effort, not the Engine''s session default' {
        $p = ConvertTo-DpSubagentTurnParameter -Request (New-TestSubagentRequest) -Turn $script:turn
        $p.Model | Should -BeExactly 'claude-opus-5.5'
        $p.ReasoningEffort | Should -BeExactly 'high'
    }

    It 'leaves Model and reasoning effort to the Engine when the Turn has none' {
        $p = ConvertTo-DpSubagentTurnParameter -Request (New-TestSubagentRequest) -Turn @{ workingDirectory = 'C:\w' }
        $p.ContainsKey('Model') | Should -BeFalse
        $p.ContainsKey('ReasoningEffort') | Should -BeFalse
    }

    It 'keeps a Subagent from replacing the Turn''s Task List' {
        (ConvertTo-DpSubagentTurnParameter -Request (New-TestSubagentRequest) -Turn $script:turn).DisableTodoList | Should -BeTrue
    }

    It 'withholds run_subagent and ask_questions from an unbound tool set' {
        $p = ConvertTo-DpSubagentTurnParameter -Request (New-TestSubagentRequest) -Turn $script:turn
        $p.ContainsKey('Tool') | Should -BeFalse
        @($p.ExcludeTool) | Should -Be @('run_subagent', 'ask_questions')
    }

    It 'removes them from a bound tool set instead, and keeps an emptied set bound' {
        $bound = ConvertTo-DpSubagentTurnParameter -Request (New-TestSubagentRequest -ToolBound $true -Tool @('read_file', 'run_subagent')) -Turn $script:turn
        @($bound.Tool) | Should -Be @('read_file')
        $bound.ContainsKey('ExcludeTool') | Should -BeFalse

        $emptied = ConvertTo-DpSubagentTurnParameter -Request (New-TestSubagentRequest -ToolBound $true -Tool @('ask_questions')) -Turn $script:turn
        $emptied.ContainsKey('Tool') | Should -BeTrue
        @($emptied.Tool).Count | Should -Be 0
    }

    It 'hands the inherited controls over as the objects themselves' {
        $request = New-TestSubagentRequest
        $p = ConvertTo-DpSubagentTurnParameter -Request $request -Turn $script:turn
        [object]::ReferenceEquals($p.ToolCallControl, $request.ToolCallControl) | Should -BeTrue
        [object]::ReferenceEquals($p.ToolPolicy, $request.ToolPolicy) | Should -BeTrue
        $p.DisableTerminal | Should -BeTrue
        $p.DisableBrowsing | Should -BeTrue
        $p.ContainsKey('DisableFileAccess') | Should -BeFalse
        $p.DisableUserPrompts | Should -BeTrue
        $p.NonInteractive | Should -BeTrue
        $p.DisableStreaming | Should -BeTrue
        @($p.History).Count | Should -Be 0
        $p.Deadline | Should -Be $request.Deadline
        $p.MaxToolIterations | Should -Be 12
        $p.MaxBudgetUSD | Should -Be 0.5
    }

    It 'appends the working directory to the Agent body without replacing it' {
        $p = ConvertTo-DpSubagentTurnParameter -Request (New-TestSubagentRequest) -Turn $script:turn
        $p.AppendSystemPrompt | Should -Match '^You are a reviewer\.'
        $p.AppendSystemPrompt | Should -Match ([regex]::Escape('C:\work\alpha'))
        $p.Prompt | Should -BeExactly 'Audit the docs folder.'
    }
}

Describe 'ConvertTo-DpSubagentTurnParameter parity with the Engine dispatcher' -Skip:(-not $script:hasSubagentEngine) {
    # DeskPilot's Invoker replaces the Engine's own Invoke-ShpSubagentTurn so that
    # it can choose the Model and withhold Tools. Every control the Engine binds
    # must therefore be bound here too, with the very same object: a missed key is
    # a Subagent that runs without a gate its Turn ran under.
    BeforeAll {
        $script:parityRunspace = New-SubagentEngineRunspace
        $script:captureEngine = {
            param($Request)
            $shell = [powershell]::Create()
            $shell.Runspace = $script:parityRunspace
            try {
                $null = $shell.AddScript(@'
param($Request)
$engine = Get-Module ShellPilot
$metadata = [System.Management.Automation.CommandMetadata]::new((Get-Command -Module ShellPilot -Name Invoke-Shp))
$binding = [System.Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($metadata)
$parameterBlock = [System.Management.Automation.ProxyCommand]::GetParamBlock($metadata)
$stub = "function script:Invoke-Shp {`n$binding`nparam($parameterBlock)`n`$global:DpEngineBound = @{}`nforeach (`$key in `$PSBoundParameters.Keys) { `$global:DpEngineBound[`$key] = `$PSBoundParameters[`$key] }`n}"
& $engine { param($Text) . ([scriptblock]::Create($Text)) } $stub
& $engine { param($Request) Invoke-ShpSubagentTurn -Request $Request } $Request
$global:DpEngineBound
'@).AddArgument($Request)
                $bound = @($shell.Invoke())
                if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
                $bound[-1]
            }
            finally { $shell.Dispose() }
        }
    }

    AfterAll { if ($script:parityRunspace) { $script:parityRunspace.Dispose() } }

    It 'binds every parameter the Engine binds, to the same value, for a <Case> tool set' -ForEach @(
        @{ Case = 'unbound'; ToolBound = $false; Tool = @() }
        @{ Case = 'bound'; ToolBound = $true; Tool = @('read_file', 'search_text') }
    ) {
        $request = New-TestSubagentRequest -ToolBound $ToolBound -Tool $Tool
        $engineBound = & $script:captureEngine $request
        $mine = ConvertTo-DpSubagentTurnParameter -Request $request -Turn @{ model = 'gpt-4o'; workingDirectory = 'C:\w'; excludeTool = @('run_subagent') }

        $engineBound.Count | Should -BeGreaterThan 8
        foreach ($key in $engineBound.Keys) {
            $mine.ContainsKey($key) | Should -BeTrue -Because "the Engine binds -$key"
            $expected = $engineBound[$key]
            $actual = $mine[$key]
            if ($expected -is [System.Management.Automation.SwitchParameter]) { [bool]$actual | Should -Be $expected.IsPresent -Because "-$key"; continue }
            if ($key -eq 'AppendSystemPrompt') { $actual.StartsWith([string]$expected) | Should -BeTrue -Because 'the Agent body leads'; continue }
            if ($key -eq 'Tool') { @($actual | Where-Object { $_ -notin @($expected) }).Count | Should -Be 0 -Because 'a Tool list may only narrow'; continue }
            if ($expected -is [string] -or $expected -is [ValueType]) { $actual | Should -Be $expected -Because "-$key"; continue }
            if ($expected -is [array]) { @($actual) | Should -Be @($expected) -Because "-$key"; continue }
            [object]::ReferenceEquals($actual, $expected) | Should -BeTrue -Because "-$key must be the inherited object itself"
        }
        foreach ($key in $mine.Keys) {
            if ($engineBound.ContainsKey($key)) { continue }
            $key | Should -BeIn @('Model', 'ReasoningEffort', 'DisableTodoList', 'ExcludeTool') -Because 'DeskPilot may only add narrowing or Turn-identity parameters'
        }
    }
}

Describe 'Subagents Permission' {
    It 'is off by default, like every Permission that adds Model calls the user did not ask for' {
        $permissions = (Get-DpDefaultSettings).permissions
        $permissions.ContainsKey('subagents') | Should -BeTrue
        $permissions.subagents | Should -Be $false
    }

    It 'can be switched on and off through Settings' {
        $on = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ permissions = @{ subagents = $true } }
        $on.permissions.subagents | Should -BeTrue
        (Merge-DpSettings -Current $on -Patch ([pscustomobject]@{ permissions = [pscustomobject]@{ subagents = $false } })).permissions.subagents | Should -BeFalse
    }

    It 'loads a settings file written before the Permission existed as off' {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $directory | Out-Null
        Set-Content -LiteralPath (Join-Path $directory 'settings.json') -Value '{"permissions":{"file":true,"terminal":false}}' -Encoding utf8
        $loaded = (Import-DpSettings -Directory $directory).permissions
        $loaded.ContainsKey('subagents') | Should -BeTrue
        $loaded.subagents | Should -Be $false
    }

    It 'tells the window whether the Engine can run Subagents: <Supported>' -ForEach @(
        @{ Supported = $true }
        @{ Supported = $false }
    ) {
        $prior = Get-Variable -Name DeskPilot -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $stream = [System.IO.MemoryStream]::new()
        try {
            $script:DeskPilot = @{
                Version = '0.0.1'; Settings = Get-DpDefaultSettings
                Engine = @{ Imported = $true; ImportError = ''; ModulePath = ''; TokenPath = (Join-Path $TestDrive 'no-token'); SubagentSupported = $Supported }
            }
            Invoke-DpRouteHandler -Name health -Stream $stream
            $response = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
            $response | Should -Match '^HTTP/1.1 200'
            (($response -split "\r?\n\r?\n", 2)[1] | ConvertFrom-Json).subagentsSupported | Should -Be $Supported
        }
        finally { $stream.Dispose(); $script:DeskPilot = $prior }
    }
}

Describe 'Get-DpSubagentLimit' {
    It 'gives a Subagent the Turn''s iteration cap, at most <Expected>' -ForEach @(
        @{ Cap = 50; Expected = 30 }
        @{ Cap = 12; Expected = 12 }
        @{ Cap = 0; Expected = 1 }
    ) {
        (Get-DpSubagentLimit -MaxToolIterations $Cap).maxIterations | Should -Be $Expected
    }

    It 'bounds runs, cost, time and text for every Turn' {
        $limit = Get-DpSubagentLimit
        $limit.maxRuns | Should -Be 5
        $limit.maxChildUSD | Should -Be 0.5
        $limit.maxTurnUSD | Should -Be 2.0
        $limit.maxDurationSec | Should -Be 900
        $limit.maxPromptChars | Should -BeGreaterThan $limit.maxInputChars
        $limit.maxAnswerChars | Should -BeGreaterThan $limit.maxOutputChars
    }
}

Describe 'New-DpSubagentContext' {
    BeforeEach {
        $script:ctxSettings = Get-DpDefaultSettings
        $script:ctxSettings.permissions.subagents = $true
        $script:ctxSettings.maxToolIterations = 20
        $script:ctxControl = @{ SchemaVersion = 1; FailPosture = 'Closed' }
        $script:ctxParams = @{
            Settings         = $script:ctxSettings
            TurnParameter    = @{ Prompt = 'p'; Model = 'gpt-4o'; ReasoningEffort = 'low'; DisableTerminal = $true; DisableBrowsing = $true; ToolCallControl = $script:ctxControl }
            Catalog          = @{ allowed = $true; reason = ''; entries = @(@{ name = 'general-purpose'; description = 'd'; path = 'C:\gp.agent.md'; root = 'C:\'; builtIn = $true }) }
            WorkingDirectory = 'C:\work'
            EngineSupported  = $true
        }
    }

    It 'gives the Subagent this Turn''s switches and the very approval control it runs under' {
        $result = New-DpSubagentContext @script:ctxParams

        $result.enabled | Should -BeTrue
        $result.context.capability.DisableTerminal | Should -BeTrue
        $result.context.capability.DisableBrowsing | Should -BeTrue
        $result.context.capability.DisableFileAccess | Should -BeFalse
        [object]::ReferenceEquals($result.context.capability.ToolCallControl, $script:ctxControl) | Should -BeTrue
        $result.context.turn.model | Should -BeExactly 'gpt-4o'
        $result.context.turn.reasoningEffort | Should -BeExactly 'low'
        $result.context.turn.workingDirectory | Should -BeExactly 'C:\work'
        @($result.context.catalog.name) | Should -Be @('general-purpose')
        $result.context.limits.maxIterations | Should -Be 20
        $result.context.state.runs | Should -Be 0
        $result.context.state.spentUSD | Should -Be 0
        $result.context.state.active | Should -BeNullOrEmpty
    }

    It 'withholds ask_questions from a Subagent only when the Turn registered it' {
        @((New-DpSubagentContext @script:ctxParams).context.turn.excludeTool) | Should -Be @('run_subagent', 'ask_questions')
        $script:ctxSettings.permissions.askUser = $false
        @((New-DpSubagentContext @script:ctxParams).context.turn.excludeTool) | Should -Be @('run_subagent')
    }

    It 'leaves no Turn parameter undecided for a Subagent' {
        # A Subagent inherits only what New-DpSubagentContext hands the Engine.
        # Every key New-DpTurnParameter can set is accounted for here: carried to
        # the Subagent, translated by DeskPilot's Invoker, or replaced by the
        # Subagent's own context. A restriction added to the Turn later fails this
        # test until someone decides what a Subagent does with it.
        $carried = @('DisableBrowsing', 'DisableFileAccess', 'DisableMcp', 'DisableTerminal', 'DisableUserTools')
        $translated = @('Model', 'ReasoningEffort', 'MaxToolIterations', 'DisableTodoList', 'DisableUserPrompts')
        $ownContext = @('Prompt', 'History', 'Image', 'SystemPrompt', 'SkillPath', 'InstructionRoot')

        $closed = Get-DpDefaultSettings
        foreach ($name in @($closed.permissions.Keys)) { $closed.permissions[$name] = $false }
        $closed.skillRoots = @('skills')
        $closed.instructionRoots = @('instructions')
        $closed.reasoningEffort = 'high'
        $closed.maxToolIterations = 12
        $closed.taskTracking = $false
        $open = Get-DpDefaultSettings
        foreach ($name in @($open.permissions.Keys)) { $open.permissions[$name] = $true }
        $open.perCallApproval = $true
        $keys = foreach ($settings in $closed, $open) {
            $turnParams = @{
                Prompt = 'p'; Settings = $settings; Image = @('shot.png'); History = @(@{ role = 'user'; content = 'h' })
                Model = 'gpt-4o'; ModelReasoningEfforts = @('high'); McpSupported = $true; AgentSystemPrompt = 'persona'
            }
            @((New-DpTurnParameter @turnParams).Keys)
        }

        $undecided = @($keys | Sort-Object -Unique | Where-Object { $_ -notin ($carried + $translated + $ownContext) })
        $undecided | Should -BeNullOrEmpty -Because 'New-DpSubagentContext has to decide whether a Subagent inherits each Turn parameter'
    }

    It 'carries every restriction a closed Turn sets' {
        $settings = Get-DpDefaultSettings
        foreach ($name in @($settings.permissions.Keys)) { $settings.permissions[$name] = $false }
        $settings.permissions.subagents = $true
        $settings.permissions.userTools = $true
        $turnParameter = New-DpTurnParameter -Prompt 'p' -Settings $settings -McpSupported
        $script:ctxParams.Settings = $settings
        $script:ctxParams.TurnParameter = $turnParameter

        $capability = (New-DpSubagentContext @script:ctxParams).context.capability

        foreach ($key in @('DisableBrowsing', 'DisableFileAccess', 'DisableMcp', 'DisableTerminal')) {
            $turnParameter[$key] | Should -BeTrue -Because "a closed Turn sets $key"
            $capability[$key] | Should -BeTrue -Because "a Subagent must inherit $key"
        }
    }

    It 'stays off when <Case>' -ForEach @(
        @{ Case = 'the Subagents Permission is off'; Change = { $script:ctxSettings.permissions.subagents = $false }; Reason = 'Permission' }
        @{ Case = 'User Tools are off'; Change = { $script:ctxSettings.permissions.userTools = $false }; Reason = 'User Tools' }
        @{ Case = 'the Engine has no Subagent contract'; Change = { $script:ctxParams.EngineSupported = $false }; Reason = 'Engine' }
        @{ Case = 'approval rides on the legacy approver a Subagent cannot inherit'; Change = { $script:ctxParams.TurnParameter.Remove('ToolCallControl'); $script:ctxParams.TurnParameter.ToolCallApprover = { $true } }; Reason = 'inherit' }
        @{ Case = 'the selected Agent dispatches none'; Change = { $script:ctxParams.Catalog = @{ allowed = $false; reason = 'The selected Agent declares agents: [], so it dispatches no Subagent.'; entries = @() } }; Reason = 'agents: \[\]' }
        @{ Case = 'no Subagent is available'; Change = { $script:ctxParams.Catalog = @{ allowed = $true; reason = ''; entries = @() } }; Reason = 'No Subagent' }
    ) {
        & $Change
        $result = New-DpSubagentContext @script:ctxParams
        $result.enabled | Should -BeFalse
        $result.context | Should -BeNullOrEmpty
        $result.reason | Should -Match $Reason
    }
}

Describe 'Get-DpSubagentToolDescription' {
    It 'names every Subagent, the default and the per-Turn limit' {
        $catalog = @(
            @{ name = 'general-purpose'; description = 'General helper.' }
            @{ name = 'reviewer'; description = 'Reviews a diff.' }
        )
        $text = Get-DpSubagentToolDescription -Catalog $catalog -Limit (Get-DpSubagentLimit)

        $text | Should -Match '(?m)^- general-purpose: General helper\.$'
        $text | Should -Match '(?m)^- reviewer: Reviews a diff\.$'
        $text | Should -Match 'prompt \(string, required\)'
        $text | Should -Match 'agent \(string, optional\)'
        $text | Should -Match 'description \(string, optional\)'
        $text | Should -Match 'omit it for general-purpose'
        $text | Should -Match 'At most 5 Subagent runs'
        $text | Should -Match 'cannot ask the user'
        $text | Should -Match 'same Permissions and approvals'
    }
}

Describe 'Invoke-DpSubagentTool' {
    BeforeAll {
        $script:toolDefinitions = (@('ConvertTo-DpSubagentTurnParameter', 'Invoke-DpSubagentTool') |
                ForEach-Object { "function global:$_ {`n$((Get-Command $_).Definition)`n}" }) -join "`n"

        # A stand-in for the Engine: it records how it was called and runs the
        # Invoker the way Invoke-ShpSubagent does, so the Subagent's Invoke-Shp call
        # DeskPilot builds is observable too. Text, not scriptblocks: a
        # scriptblock belongs to the runspace that created it.
        $script:engineCompleted = @'
param($DefinitionPath, $Root, $Prompt, $Parent, $Capability, $Budget, $Invoker)
$global:FakeSubagentCalls.Add([pscustomobject]@{ DefinitionPath = $DefinitionPath; Root = $Root; Prompt = $Prompt; Parent = $Parent; Capability = $Capability; Budget = $Budget })
$request = @{ Prompt = $Prompt; SystemPrompt = 'Agent body.'; Tool = @(); ToolBound = $false; MaxToolIterations = 7; TraceParent = 't'; MaxBudgetUSD = 0.5; DisableTerminal = $true }
$turnResult = & $Invoker $request
[pscustomobject]@{ Answer = [string]$turnResult.Content; Refused = $false; Cancelled = $false; Reason = ''; Evidence = [pscustomobject]@{ Iterations = 3; ToolCallCount = 2; CostUSD = 0.0 } }
'@
        $script:subagentShp = @'
param($Prompt, $History, $NonInteractive, $DisableUserPrompts, $DisableStreaming, $MaxToolIterations, $TraceParent, $AppendSystemPrompt,
    $MaxBudgetUSD, $DisableTerminal, $DisableBrowsing, $DisableFileAccess, $DisableMcp, $DisableUserTools, $ToolCallControl, $ToolPolicy,
    $Deadline, $CancellationToken, $Model, $ReasoningEffort, $DisableTodoList, $ExcludeTool, $Tool)
$bound = @{}
foreach ($key in $PSBoundParameters.Keys) { $bound[$key] = $PSBoundParameters[$key] }
$global:FakeShpCalls.Add($bound)
[pscustomobject]@{ Content = $global:FakeSubagentAnswer; CostUSD = $global:FakeSubagentCost; FilesWritten = @('C:\work\alpha\notes.md'); ToolCalls = @('a', 'b'); Iterations = 3 }
'@

        function script:Invoke-SubagentToolFixture {
            param(
                [Parameter(Mandatory)][hashtable]$Context,
                [hashtable]$Arguments = @{ Prompt = 'Audit the docs folder.' },
                [string]$Engine = $script:engineCompleted,
                [string]$SubagentAnswer = 'The docs are current.',
                [AllowNull()][object]$SubagentCost = 0.0125,
                [string]$ToolList = "param([string]`$Origin) @([pscustomobject]@{ Name = 'run_subagent' }, [pscustomobject]@{ Name = 'ask_questions' })",
                [string]$Usage
            )
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $shell = [powershell]::Create()
            $shell.Runspace = $runspace
            try {
                $null = $shell.AddScript(@'
param($Definitions, $Context, $Engine, $SubagentShp, $Arguments, $SubagentAnswer, $SubagentCost, $ToolList, $Usage)
. ([scriptblock]::Create($Definitions))
. ([scriptblock]::Create("function global:Invoke-ShpSubagent {`n$Engine`n}"))
. ([scriptblock]::Create("function global:Invoke-Shp {`n$SubagentShp`n}"))
. ([scriptblock]::Create("function global:Get-ShpTool {`n$ToolList`n}"))
if ($Usage) { . ([scriptblock]::Create("function global:Get-ShpUsage {`n$Usage`n}")) }
$global:FakeUsageReads = 0
$global:FakeSubagentCalls = [System.Collections.Generic.List[object]]::new()
$global:FakeShpCalls = [System.Collections.Generic.List[object]]::new()
$global:FakeSubagentAnswer = $SubagentAnswer
$global:FakeSubagentCost = $SubagentCost
Set-Variable -Name DeskPilotSubagentContext -Scope Global -Value $Context
$json = Invoke-DpSubagentTool @Arguments
[pscustomobject]@{ Json = $json; Subagent = @($global:FakeSubagentCalls); Shp = @($global:FakeShpCalls) }
'@).AddArgument($script:toolDefinitions).AddArgument($Context).AddArgument($Engine).AddArgument($script:subagentShp).AddArgument($Arguments).AddArgument($SubagentAnswer).AddArgument($SubagentCost).AddArgument($ToolList).AddArgument($Usage)
                $output = @($shell.Invoke())
                if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
                [pscustomobject]@{
                    Reply    = ($output[-1].Json | ConvertFrom-Json)
                    Subagent = $output[-1].Subagent
                    Shp      = $output[-1].Shp
                    Records  = @($shell.Streams.Information | Where-Object { @($_.Tags) -contains 'DeskPilotSubagent' } | ForEach-Object { $_.MessageData })
                }
            }
            finally { $shell.Dispose(); $runspace.Dispose() }
        }

        function script:New-ToolContext {
            $limit = Get-DpSubagentLimit -MaxToolIterations 12
            @{
                catalog    = @(
                    @{ name = 'general-purpose'; description = 'General helper.'; path = 'C:\bundle\general-purpose.agent.md'; root = 'C:\bundle'; builtIn = $true }
                    @{ name = 'reviewer'; description = 'Reviews.'; path = 'C:\agents\reviewer.agent.md'; root = 'C:\agents'; builtIn = $false }
                )
                capability = @{ DisableFileAccess = $false; DisableTerminal = $true; DisableBrowsing = $false; DisableMcp = $false; DisableUserTools = $false; ToolCallControl = @{ SchemaVersion = 1 } }
                turn       = @{ model = 'gpt-4o'; reasoningEffort = ''; workingDirectory = 'C:\work\alpha'; excludeTool = @('run_subagent', 'ask_questions', 'not_registered') }
                limits     = $limit
                state      = @{ runs = 0; spentUSD = 0.0; active = $null }
            }
        }
    }

    It 'dispatches the named catalog entry under the Turn''s capability and reports the answer' {
        $context = New-ToolContext
        $run = Invoke-SubagentToolFixture -Context $context -Arguments @{ Prompt = 'Review the diff.'; Agent = 'reviewer'; Description = 'diff review' }

        $run.Reply.status | Should -BeExactly 'completed'
        $run.Reply.agent | Should -BeExactly 'reviewer'
        $run.Reply.answer | Should -BeExactly 'The docs are current.'
        $run.Subagent | Should -HaveCount 1
        $run.Subagent[0].DefinitionPath | Should -BeExactly 'C:\agents\reviewer.agent.md'
        $run.Subagent[0].Root | Should -BeExactly 'C:\agents'
        $run.Subagent[0].Prompt | Should -BeExactly 'Review the diff.'
        [object]::ReferenceEquals($run.Subagent[0].Parent.Capability, $context.capability) | Should -BeTrue
        $run.Subagent[0].Capability.ContainsKey('Tool') | Should -BeTrue
        $null -eq $run.Subagent[0].Capability.Tool | Should -BeTrue
        $run.Subagent[0].Budget.MaxDepth | Should -Be 1
        $run.Subagent[0].Budget.MaxConcurrency | Should -Be 1
        $run.Subagent[0].Budget.MaxFanOut | Should -Be 1
        $run.Subagent[0].Budget.MaxChildIterations | Should -Be 12
        $run.Subagent[0].Budget.MaxChildUSD | Should -Be 0.5
        $run.Subagent[0].Budget.MaxDurationSec | Should -Be 900
    }

    It 'runs the Subagent on the Turn''s Model and withholds only the Tools the Engine knows' {
        $run = Invoke-SubagentToolFixture -Context (New-ToolContext)

        $run.Shp | Should -HaveCount 1
        $run.Shp[0].Model | Should -BeExactly 'gpt-4o'
        $run.Shp[0].DisableTodoList | Should -BeTrue
        @($run.Shp[0].ExcludeTool) | Should -Be @('run_subagent', 'ask_questions')
        $run.Shp[0].AppendSystemPrompt | Should -Match ([regex]::Escape('C:\work\alpha'))
    }

    It 'defaults to general-purpose and records the run before and after it' {
        $run = Invoke-SubagentToolFixture -Context (New-ToolContext) -Arguments @{ Prompt = 'Audit the docs folder.'; Description = "docs`n  audit" }

        $run.Subagent[0].DefinitionPath | Should -BeExactly 'C:\bundle\general-purpose.agent.md'
        $run.Records | Should -HaveCount 2
        $run.Records[0].Phase | Should -BeExactly 'started'
        $run.Records[0].Agent | Should -BeExactly 'general-purpose'
        $run.Records[0].Description | Should -BeExactly 'docs audit'
        $run.Records[0].Input | Should -BeExactly 'Audit the docs folder.'
        $run.Records[0].Id | Should -Match '^a_[0-9a-f]{16}$'
        $run.Records[1].Phase | Should -BeExactly 'finished'
        $run.Records[1].Id | Should -BeExactly $run.Records[0].Id
        $run.Records[1].Status | Should -BeExactly 'completed'
        $run.Records[1].Output | Should -BeExactly 'The docs are current.'
        $run.Records[1].CostUSD | Should -Be 0.0125
        $run.Records[1].Iterations | Should -Be 3
        $run.Records[1].ToolCalls | Should -Be 2
        @($run.Records[1].FilesWritten) | Should -Be @('C:\work\alpha\notes.md')
        $run.Records[1].DurationMs | Should -BeGreaterOrEqual 0
        $run.Records[1].EngineCalls | Should -Be 1
    }

    It 'charges the Turn ledger and frees the slot afterwards' {
        $context = New-ToolContext
        $null = Invoke-SubagentToolFixture -Context $context
        $context.state.runs | Should -Be 1
        $context.state.spentUSD | Should -Be 0.0125
        $context.state.active | Should -BeNullOrEmpty
    }

    It 'keeps an unpriced run unknown instead of free' {
        $context = New-ToolContext
        $run = Invoke-SubagentToolFixture -Context $context -SubagentCost $null
        $null -eq $run.Records[1].CostUSD | Should -BeTrue
        $context.state.spentUSD | Should -Be 0
    }

    It 'runs nothing when the Engine cannot list its Tools, because nothing could be withheld' {
        # The withheld names are filtered by that list, so an unreadable list
        # used to withhold nothing: run_subagent and ask_questions reached the
        # Subagent.
        $context = New-ToolContext
        $unreadable = "param([string]`$Origin) throw 'The Tool registry is unavailable.'"
        $run = Invoke-SubagentToolFixture -Context $context -ToolList $unreadable

        $run.Reply.status | Should -BeExactly 'failed'
        $run.Reply.error | Should -Match 'withheld'
        $run.Subagent | Should -HaveCount 0
        $run.Shp | Should -HaveCount 0
        @($run.Records.Phase) | Should -Be @('started', 'finished')
        $context.state.runs | Should -Be 0
        $context.state.active | Should -BeNullOrEmpty
    }

    It 'treats a non-terminating Tool list error as unreadable too' {
        $context = New-ToolContext
        $unreadable = "param([string]`$Origin) Write-Error 'The Tool registry is unavailable.'"
        $run = Invoke-SubagentToolFixture -Context $context -ToolList $unreadable

        $run.Reply.status | Should -BeExactly 'failed'
        $run.Shp | Should -HaveCount 0
    }

    It 'announces and accounts for a run even when its caller asks to ignore information' {
        # FIND-018: InformationAction Ignore dropped both records, so the run left
        # no card, no Engine call and no written file in the Turn's account.
        $context = New-ToolContext
        $run = Invoke-SubagentToolFixture -Context $context -Arguments @{ Prompt = 'Audit the docs folder.'; InformationAction = 'Ignore' }

        @($run.Records.Phase) | Should -Be @('started', 'finished')
        @($run.Records[1].FilesWritten) | Should -Be @('C:\work\alpha\notes.md')
    }

    It 'charges a run that throws with what the Engine measured it spent' {
        # FIND-019: a Subagent that hit its iteration cap or deadline threw after
        # spending, returned no result, and charged nothing to the Turn's cap.
        $context = New-ToolContext
        $usage = "param([switch]`$Summary) `$global:FakeUsageReads++; [pscustomobject]@{ Calls = `$global:FakeUsageReads; CostUSD = 1.0 + 0.3 * (`$global:FakeUsageReads - 1) }"
        $throwing = "param(`$DefinitionPath, `$Root, `$Prompt, `$Parent, `$Capability, `$Budget, `$Invoker)`nthrow 'The Subagent reached its iteration cap.'"
        $run = Invoke-SubagentToolFixture -Context $context -Engine $throwing -Usage $usage

        $run.Reply.status | Should -BeExactly 'failed'
        $run.Records[1].CostUSD | Should -Be 0.3
        $context.state.spentUSD | Should -Be 0.3
    }

    It 'charges the larger of what a run reported and what the Engine measured' {
        $context = New-ToolContext
        $usage = "param([switch]`$Summary) `$global:FakeUsageReads++; [pscustomobject]@{ Calls = `$global:FakeUsageReads; CostUSD = 0.5 + 0.02 * (`$global:FakeUsageReads - 1) }"
        $run = Invoke-SubagentToolFixture -Context $context -Usage $usage -SubagentCost 0.0125

        $run.Reply.status | Should -BeExactly 'completed'
        $run.Records[1].CostUSD | Should -Be 0.02
        $context.state.spentUSD | Should -Be 0.02
    }

    It 'refuses <Case> without dispatching anything' -ForEach @(
        @{ Case = 'an Agent outside the catalog'; Arguments = @{ Prompt = 'x'; Agent = '..\..\secrets' }; Prepare = {}; Reason = "no Subagent called.*general-purpose, reviewer" }
        @{ Case = 'a Subagent inside a Subagent'; Arguments = @{ Prompt = 'x' }; Prepare = { param($c) $c.state.active = 'a_0000000000000000' }; Reason = 'cannot dispatch another Subagent' }
        @{ Case = 'a run past the per-Turn count'; Arguments = @{ Prompt = 'x' }; Prepare = { param($c) $c.state.runs = 5 }; Reason = 'already run 5 Subagents' }
        @{ Case = 'a run past the Turn budget'; Arguments = @{ Prompt = 'x' }; Prepare = { param($c) $c.state.spentUSD = 2.0 }; Reason = 'budget of USD 2' }
        @{ Case = 'a task past the length cap'; Arguments = @{ Prompt = ('t' * 20001) }; Prepare = {}; Reason = 'at most 20000' }
    ) {
        $context = New-ToolContext
        & $Prepare $context
        $run = Invoke-SubagentToolFixture -Context $context -Arguments $Arguments

        $run.Reply.status | Should -BeExactly 'refused'
        $run.Reply.error | Should -Match $Reason
        $run.Subagent | Should -HaveCount 0
        $run.Shp | Should -HaveCount 0
        @($run.Records.Phase) | Should -Be @('started', 'finished')
        $run.Records[1].Status | Should -BeExactly 'refused'
    }

    It 'reports an Engine outcome of <Expected> as <Expected>' -ForEach @(
        @{ Expected = 'failed'; Result = '[pscustomobject]@{ Answer = $null; Refused = $true; Cancelled = $false; Reason = ''The Subagent failed: boom''; Evidence = $null }' }
        @{ Expected = 'refused'; Result = '[pscustomobject]@{ Answer = $null; Refused = $true; Cancelled = $false; Reason = ''This parent already dispatched 1 children, the fan-out cap.''; Evidence = $null }' }
        @{ Expected = 'cancelled'; Result = '[pscustomobject]@{ Answer = $null; Refused = $true; Cancelled = $true; Reason = ''The Subagent was cancelled: stop''; Evidence = $null }' }
        @{ Expected = 'failed'; Result = 'throw ''The agent definition was refused: no description''' }
    ) {
        $context = New-ToolContext
        $run = Invoke-SubagentToolFixture -Context $context -Engine "param(`$DefinitionPath, `$Root, `$Prompt, `$Parent, `$Capability, `$Budget, `$Invoker)`n$Result"

        $run.Reply.status | Should -BeExactly $Expected
        $run.Reply.error | Should -Not -BeNullOrEmpty
        $run.Records[1].Status | Should -BeExactly $Expected
        $context.state.active | Should -BeNullOrEmpty
    }

    It 'bounds what it shows and what it returns' {
        $context = New-ToolContext
        $longTask = 'q' * 15000
        $longAnswer = 'r' * 70000
        $run = Invoke-SubagentToolFixture -Context $context -Arguments @{ Prompt = $longTask; Description = ('label ' * 40) } -SubagentAnswer $longAnswer

        $run.Records[0].Input.Length | Should -BeLessThan 8100
        $run.Records[0].Description.Length | Should -BeLessOrEqual 80
        $run.Records[1].Output.Length | Should -BeLessThan 20100
        $run.Reply.answer.Length | Should -BeLessThan 60100
        $run.Reply.answer | Should -Match 'more characters not shown'
    }
}

Describe 'Test-DpSubagentSupport' {
    It 'is false for a runspace without the Engine''s Subagent contract' {
        # Autoloading would import an installed ShellPilot on the probe's behalf.
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        try {
            $null = $shell.AddScript('$global:PSModuleAutoLoadingPreference = ''None''')
            $shell.Invoke() | Out-Null
            Test-DpSubagentSupport -Runspace $runspace | Should -BeFalse
        }
        finally { $shell.Dispose(); $runspace.Dispose() }
    }

    It 'is true for an Engine that has it' -Skip:(-not $script:hasSubagentEngine) {
        $runspace = New-SubagentEngineRunspace
        try { Test-DpSubagentSupport -Runspace $runspace | Should -BeTrue }
        finally { $runspace.Dispose() }
    }
}

Describe 'Set-DpSubagentTool' -Skip:(-not $script:hasSubagentEngine) {
    BeforeEach {
        $script:registrationRunspace = New-SubagentEngineRunspace
        $script:registrationContext = @{
            catalog    = @(@{ name = 'general-purpose'; description = 'General helper.'; path = 'C:\b\general-purpose.agent.md'; root = 'C:\b'; builtIn = $true })
            capability = @{ DisableTerminal = $true }
            turn       = @{ model = 'gpt-4o'; workingDirectory = 'C:\w'; excludeTool = @('run_subagent') }
            limits     = (Get-DpSubagentLimit)
            state      = @{ runs = 0; spentUSD = 0.0; active = $null }
        }
        $script:readRegistration = {
            $shell = [powershell]::Create()
            $shell.Runspace = $script:registrationRunspace
            try {
                $null = $shell.AddScript('[pscustomobject]@{ Tool = @(Get-ShpTool -Origin User | Where-Object Name -EQ ''run_subagent''); Context = $global:DeskPilotSubagentContext; Command = [bool](Get-Command Invoke-DpSubagentTool -ErrorAction SilentlyContinue) }')
                @($shell.Invoke())[-1]
            }
            finally { $shell.Dispose() }
        }
    }

    AfterEach { $script:registrationRunspace.Dispose() }

    It 'registers run_subagent with its contract and the Turn''s context' {
        Set-DpSubagentTool -Runspace $script:registrationRunspace -Enabled $true -Context $script:registrationContext | Should -BeTrue

        $state = & $script:readRegistration
        $state.Tool | Should -HaveCount 1
        $state.Tool[0].Description | Should -Match '(?m)^- general-purpose: General helper\.$'
        $state.Tool[0].Description | Should -Match 'prompt \(string, required\)'
        $state.Command | Should -BeTrue
        [object]::ReferenceEquals($state.Context, $script:registrationContext) | Should -BeTrue
    }

    It 'removes the Tool and its context when the Turn does not offer it' {
        $null = Set-DpSubagentTool -Runspace $script:registrationRunspace -Enabled $true -Context $script:registrationContext
        Set-DpSubagentTool -Runspace $script:registrationRunspace -Enabled $false | Should -BeFalse

        $state = & $script:readRegistration
        $state.Tool | Should -HaveCount 0
        $state.Context | Should -BeNullOrEmpty
    }
}

Describe 'run_subagent through the Engine' -Skip:(-not $script:hasSubagentEngine) {
    # The real Engine dispatches the parent Turn, run_subagent, Invoke-ShpSubagent
    # and the Subagent's Turn. Only the provider is scripted: Invoke-CopilotTurn is
    # replaced inside the Engine by a stub with its exact parameters, credentials
    # are a fixture and both network paths throw.
    BeforeAll {
        if (-not ('DeskPilot.Tests.SubagentApprovalBridge' -as [type])) {
            Add-Type -TypeDefinition @'
namespace DeskPilot.Tests {
    public sealed class SubagentApprovalBridge {
        public bool Enabled = true;
        public bool Cancelled;
        public System.Collections.Generic.List<string> Questions = new System.Collections.Generic.List<string>();
        public System.Collections.Generic.Queue<string> Replies = new System.Collections.Generic.Queue<string>();
        public void CaptureQuestion(string text) { Questions.Add(text); }
        public string RequestAnswer(int seconds) { return Replies.Count > 0 ? Replies.Dequeue() : "{\"decision\":\"deny\",\"scope\":\"once\"}"; }
    }
}
'@
        }
        # The body of the stand-in for the Engine's private Invoke-CopilotTurn: it
        # records each provider call and answers from a queued script.
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
        $script:scriptedProvider = @'
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
}
$global:DpProviderCalls = [System.Collections.Generic.List[object]]::new()
$global:DpProviderScript = [System.Collections.Generic.Queue[object]]::new()
'@

        function script:Invoke-ScriptedTurn {
            param([Parameter(Mandatory)]$Runspace, [Parameter(Mandatory)][object[]]$Responses, [Parameter(Mandatory)][hashtable]$Parameters)
            $shell = [powershell]::Create()
            $shell.Runspace = $Runspace
            try {
                $null = $shell.AddScript(@'
param($Responses, $Parameters)
foreach ($response in $Responses) { $global:DpProviderScript.Enqueue([pscustomobject]$response) }
$result = Invoke-Shp @Parameters
[pscustomobject]@{ Result = $result; Calls = @($global:DpProviderCalls) }
'@).AddArgument($Responses).AddArgument($Parameters)
                $output = @($shell.Invoke())
                if ($shell.HadErrors -and $output.Count -eq 0) { throw $shell.Streams.Error[0] }
                [pscustomobject]@{
                    Result  = $output[-1].Result
                    Calls   = $output[-1].Calls
                    Records = @($shell.Streams.Information | Where-Object { @($_.Tags) -contains 'ShpProgress' -or @($_.Tags) -contains 'DeskPilotSubagent' -or @($_.Tags) -contains 'DeskPilotApproval' })
                }
            }
            finally { $shell.Dispose() }
        }

        function script:Get-OfferedToolName {
            param($Call)
            @(@($Call.Tools) | ForEach-Object { if ($_.function) { [string]$_.function.name } else { [string]$_.name } })
        }
    }

    BeforeEach {
        $script:e2eRunspace = New-SubagentEngineRunspace
        $shell = [powershell]::Create()
        $shell.Runspace = $script:e2eRunspace
        try {
            $null = $shell.AddScript($script:scriptedProvider).AddArgument($script:providerBody)
            $shell.Invoke() | Out-Null
            if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
        }
        finally { $shell.Dispose() }
        $script:e2eSettings = Get-DpDefaultSettings
        $script:e2eSettings.permissions.subagents = $true
        $script:e2eSettings.permissions.askUser = $false
        $script:e2eTarget = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.md')
    }

    AfterEach { $script:e2eRunspace.Dispose() }

    It 'runs a Subagent under the Turn''s own approval control and hands its report to the parent' {
        $bridge = [DeskPilot.Tests.SubagentApprovalBridge]::new()
        $bridge.Replies.Enqueue('{"decision":"approve","scope":"once"}')
        $bridge.Replies.Enqueue('{"decision":"deny","scope":"once"}')
        $approvalContext = @{
            conversationId = 'c_0123456789'; turnId = 'm_abcdef0123'; project = 'Fixture'; workingDirectory = [string]$TestDrive
            permissions = @{ file = $true; mcp = $true; terminal = $false; userTools = $true; askUser = $false; browsing = $false }
            workspaceToolsOwned = $false; terminalApprovalActive = $false
        }
        $binding = Initialize-DpToolCallApproval -Runspace $script:e2eRunspace -Context $approvalContext -Bridge $bridge -TimeoutSeconds 5
        $turnParameter = @{
            Prompt = 'Audit the docs with a Subagent.'; Model = 'gpt-4o'; History = @(); DisableStreaming = $true; NonInteractive = $true
            DisableUserPrompts = $true; DisableTerminal = $true; DisableBrowsing = $true; MaxToolIterations = 5; Confirm = $false
            ToolCallControl = $binding.ToolCallControl
        }
        $subagent = New-DpSubagentContext -Settings $script:e2eSettings -TurnParameter $turnParameter -Catalog (Get-DpSubagentCatalog -Root '') -WorkingDirectory ([string]$TestDrive) -EngineSupported $true
        Set-DpSubagentTool -Runspace $script:e2eRunspace -Enabled $true -Context $subagent.context | Should -BeTrue

        $run = Invoke-ScriptedTurn -Runspace $script:e2eRunspace -Parameters $turnParameter -Responses @(
            @{ Content = ''; ToolCalls = @(@{ Id = 'p1'; Name = 'run_subagent'; Arguments = @{ agent = 'general-purpose'; description = 'docs audit'; prompt = 'Write the audit to the file.' } }) }
            @{ Content = ''; ToolCalls = @(@{ Id = 'c1'; Name = 'write_file'; Arguments = @{ path = $script:e2eTarget; content = 'SUBAGENT-CONTENT-SENTINEL' } }) }
            @{ Content = 'The write was declined, so nothing changed.'; ToolCalls = @() }
            @{ Content = 'Parent done.'; ToolCalls = @() }
        )

        $run.Result.Content | Should -BeExactly 'Parent done.'
        $run.Calls | Should -HaveCount 4
        Test-Path -LiteralPath $script:e2eTarget | Should -BeFalse

        # The dispatch and the Subagent's own write both met the Turn's approval.
        $bridge.Questions | Should -HaveCount 2
        ($bridge.Questions[0] | ConvertFrom-Json).summary.action | Should -BeExactly 'run_subagent'
        ($bridge.Questions[1] | ConvertFrom-Json).tool | Should -BeExactly 'write_file'
        $bridge.Questions[1] | Should -Not -Match 'SUBAGENT-CONTENT-SENTINEL'

        # The Subagent ran on the Turn's Model, without the withheld Tools, as the Agent.
        $subagentCall = $run.Calls[1]
        $subagentCall.Model | Should -BeExactly 'gpt-4o'
        $offered = Get-OfferedToolName -Call $subagentCall
        $offered | Should -Contain 'write_file'
        $offered | Should -Not -Contain 'run_subagent'
        $offered | Should -Not -Contain 'manage_todo_list'
        ($subagentCall.Conversation | ConvertTo-Json -Depth 8) | Should -Match 'You are a Subagent'
        ($subagentCall.Conversation | ConvertTo-Json -Depth 8) | Should -Match 'Your working directory is'
        Get-OfferedToolName -Call $run.Calls[0] | Should -Contain 'run_subagent'

        # The parent received the report as the Tool result.
        ($run.Calls[3].Conversation | ConvertTo-Json -Depth 8) | Should -Match 'The write was declined'

        # The window's account: the dispatch, the run, the Subagent's Tool and its approval, in order.
        $sequence = @($run.Records | ForEach-Object {
                $data = $_.MessageData
                if (@($_.Tags) -contains 'DeskPilotSubagent') { "subagent:$($data.Phase)" }
                elseif (@($_.Tags) -contains 'DeskPilotApproval') { "approval:$($data.Status)" }
                elseif ($data.Kind -eq 'ToolCall') { "tool:$($data.Name)" }
            })
        # The Engine announces a Tool call after its pre-call decision.
        $sequence | Should -Be @('approval:requested', 'approval:approved', 'tool:run_subagent', 'subagent:started', 'approval:requested', 'approval:denied', 'tool:write_file', 'subagent:finished')
        $finished = ($run.Records | Where-Object { @($_.Tags) -contains 'DeskPilotSubagent' })[-1].MessageData
        $finished.Status | Should -BeExactly 'completed'
        $finished.Output | Should -BeExactly 'The write was declined, so nothing changed.'
        $finished.Agent | Should -BeExactly 'general-purpose'
        $subagent.context.state.runs | Should -Be 1
        $subagent.context.state.active | Should -BeNullOrEmpty
    }

    It 'refuses a Subagent''s own run_subagent call in the Engine' {
        $turnParameter = @{
            Prompt = 'Delegate twice.'; Model = 'gpt-4o'; History = @(); DisableStreaming = $true; NonInteractive = $true
            DisableUserPrompts = $true; DisableTerminal = $true; DisableBrowsing = $true; MaxToolIterations = 5; Confirm = $false
        }
        $subagent = New-DpSubagentContext -Settings $script:e2eSettings -TurnParameter $turnParameter -Catalog (Get-DpSubagentCatalog -Root '') -WorkingDirectory ([string]$TestDrive) -EngineSupported $true
        $null = Set-DpSubagentTool -Runspace $script:e2eRunspace -Enabled $true -Context $subagent.context

        $run = Invoke-ScriptedTurn -Runspace $script:e2eRunspace -Parameters $turnParameter -Responses @(
            @{ Content = ''; ToolCalls = @(@{ Id = 'p1'; Name = 'run_subagent'; Arguments = @{ prompt = 'Split this further.' } }) }
            @{ Content = ''; ToolCalls = @(@{ Id = 'c1'; Name = 'run_subagent'; Arguments = @{ prompt = 'Nested.' } }) }
            @{ Content = 'I could not delegate further.'; ToolCalls = @() }
            @{ Content = 'Parent done.'; ToolCalls = @() }
        )

        $run.Result.Content | Should -BeExactly 'Parent done.'
        @($run.Records | Where-Object { @($_.Tags) -contains 'DeskPilotSubagent' -and $_.MessageData.Phase -eq 'started' }) | Should -HaveCount 1
        ($run.Calls[2].Conversation | ConvertTo-Json -Depth 8) | Should -Match 'disabled for this call'
        $subagent.context.state.runs | Should -Be 1
    }
}

Describe 'Terminal approval inside a Subagent' {
    # Decision 0011: a Turn-wide Terminal grant is never inherited by delegated
    # work. A Subagent's command is asked about once, every time, and its card
    # cannot create a grant the parent would then run under.
    It 'neither uses nor creates a Turn-wide grant while a Subagent runs' {
        $bootstrap = [runspacefactory]::CreateRunspace()
        $bootstrap.Open()
        try { $null = Initialize-DpUserPromptBridge -Runspace $bootstrap }
        finally { $bootstrap.Dispose() }
        $bridge = [DeskPilot.UserPromptBridge]::new()
        $bridge.BeginTurn('c-1')
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $marker = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $definitions = @('Get-DpPropertyValue', 'ConvertTo-DpTerminalExecution', 'New-DpApprovalRequest', 'Test-DpCommandSafe', 'Invoke-DpTerminalApprovalTool') |
            ForEach-Object { "function global:$_ {`n$((Get-Command $_).Definition)`n}" }
        $scriptText = @'
param($Bridge, $Marker)
$global:DeskPilotApprovalBridge = $Bridge
$global:DeskPilotApprovalContext = @{ conversationId = 'c-1'; turnId = 't-1'; project = 'Alpha'; workingDirectory = 'C:\projects\alpha'; policyId = 'policy-1' }
$global:DeskPilotSafeCommand = @()
$global:DeskPilotApprovalTimeoutMinutes = 1
$global:DeskPilotTerminalMarker = $Marker
$global:DeskPilotTerminalExecutor = {
    param($Command, $WorkingDirectory, $TimeoutSeconds)
    Add-Content -LiteralPath $global:DeskPilotTerminalMarker -Value $Command
    '{"exitCode":0}'
}
__DEFINITIONS__
Invoke-DpTerminalApprovalTool -Command 'npm test'
$global:DeskPilotSubagentContext = @{ state = @{ active = 'a_0123456789abcdef' } }
Invoke-DpTerminalApprovalTool -Command 'npm run build'
Invoke-DpTerminalApprovalTool -Command 'npm run lint'
$global:DeskPilotSubagentContext.state.active = $null
Invoke-DpTerminalApprovalTool -Command 'npm run format'
'@.Replace('__DEFINITIONS__', ($definitions -join "`n"))
        $answers = @('turn', 'turn', 'once')
        $questions = [System.Collections.Generic.List[object]]::new()
        try {
            $null = $shell.AddScript($scriptText).AddArgument($bridge).AddArgument($marker)
            $invocation = $shell.BeginInvoke()
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not $invocation.IsCompleted -and $clock.Elapsed.TotalSeconds -lt 15) {
                $pending = $bridge.GetPendingRequest()
                if ($pending) {
                    $questions.Add(($pending.Question | ConvertFrom-Json))
                    $scope = $answers[[Math]::Min($questions.Count, $answers.Count) - 1]
                    $null = $bridge.SubmitAnswer('c-1', $pending.Id, (@{ decision = 'approve'; scope = $scope } | ConvertTo-Json -Compress))
                }
                $null = $invocation.AsyncWaitHandle.WaitOne(10)
            }
            $invocation.IsCompleted | Should -BeTrue
            $results = @($shell.EndInvoke($invocation) | ForEach-Object { $_ | ConvertFrom-Json })
            $shell.HadErrors | Should -BeFalse -Because ($shell.Streams.Error | Out-String)

            $questions | Should -HaveCount 3 -Because 'both Subagent commands are asked about despite the parent''s grant'
            @($questions[0].allowedScopes) | Should -Be @('once', 'turn')
            @($questions[1].allowedScopes) | Should -Be @('once')
            @($questions[2].allowedScopes) | Should -Be @('once')
            @($results.approved) | Should -Be @($true, $false, $true, $true)
            $results[1].error | Should -Match 'once'
            @(Get-Content -LiteralPath $marker) | Should -Be @('npm test', 'npm run lint', 'npm run format')
        }
        finally {
            $bridge.Cancel()
            $shell.Dispose()
            $runspace.Dispose()
            $bridge.Dispose()
        }
    }
}

Describe 'ConvertTo-DpActivityAction for run_subagent' {
    It 'names the Subagent and never the task' {
        $action = ConvertTo-DpActivityAction -Tool 'run_subagent' -Arguments '{"agent":"reviewer","prompt":"PRIVATE task text"}'
        $action.kind | Should -BeExactly 'agent'
        $action.detail | Should -BeExactly 'reviewer'
        ($action | ConvertTo-Json -Compress) | Should -Not -Match 'PRIVATE'
    }
}

Describe 'Get-DpStreamFrame for Subagent records' {
    BeforeAll {
        function script:New-SubagentRecord {
            param([hashtable]$Data)
            [pscustomobject]@{ Tags = @('DeskPilotSubagent'); MessageData = [pscustomobject]$Data; TimeGenerated = [datetime]'2026-10-02T10:00:00Z' }
        }
    }

    It 'leaves the run_subagent call itself to the run''s own records' {
        $record = [pscustomobject]@{ Tags = @('ShpProgress'); MessageData = [pscustomobject]@{ Kind = 'ToolCall'; Name = 'run_subagent'; Arguments = '{"agent":"reviewer"}' } }
        Get-DpStreamFrame -Record $record | Should -BeNullOrEmpty
    }

    It 'announces a started run as a running agent action' {
        $decision = Get-DpStreamFrame -Record (New-SubagentRecord @{ Phase = 'started'; Id = 'a_0123456789abcdef'; Agent = 'reviewer'; Description = 'diff review'; Input = 'Review the diff.' })

        $decision.event | Should -BeExactly 'activity'
        $decision.data.kind | Should -BeExactly 'agent'
        $decision.data.tool | Should -BeExactly 'run_subagent'
        $decision.data.id | Should -BeExactly 'a_0123456789abcdef'
        $decision.data.detail | Should -BeExactly 'reviewer'
        $decision.data.description | Should -BeExactly 'diff review'
        $decision.data.input | Should -BeExactly 'Review the diff.'
        $decision.data.status | Should -BeExactly 'running'
        $decision.data.phase | Should -BeExactly 'started'
        $decision.data.timestamp | Should -Match '^2026-10-02T10:00:00'
        [object]::ReferenceEquals($decision.Action, $decision.data) | Should -BeTrue
    }

    It 'accounts for a finished run and hands its files and Engine calls to the Turn, not the window' {
        $decision = Get-DpStreamFrame -Record (New-SubagentRecord @{
                Phase = 'finished'; Id = 'a_0123456789abcdef'; Agent = 'reviewer'; Status = 'completed'; Output = 'All good.'; Reason = ''
                DurationMs = 1500; Iterations = 4; ToolCalls = 3; CostUSD = 0.0042; EngineCalls = 1; FilesWritten = @('docs\a.md', 'docs\b.md')
            })

        $decision.data.status | Should -BeExactly 'completed'
        $decision.data.output | Should -BeExactly 'All good.'
        $decision.data.durationMs | Should -Be 1500
        $decision.data.iterations | Should -Be 4
        $decision.data.toolCalls | Should -Be 3
        $decision.data.costUSD | Should -Be 0.0042
        $decision.data.phase | Should -BeExactly 'finished'
        $decision.data.ContainsKey('filesWritten') | Should -BeFalse
        @($decision.FilesWritten) | Should -Be @('docs\a.md', 'docs\b.md')
        $decision.EngineCalls | Should -Be 1
        $decision.Iterations | Should -Be 4
    }

    It 'keeps an unknown cost unknown' {
        $decision = Get-DpStreamFrame -Record (New-SubagentRecord @{ Phase = 'finished'; Id = 'a_0123456789abcdef'; Agent = 'x'; Status = 'failed'; Reason = 'boom'; CostUSD = $null })
        $decision.data.ContainsKey('costUSD') | Should -BeTrue
        $null -eq $decision.data.costUSD | Should -BeTrue
        $decision.data.reason | Should -BeExactly 'boom'
    }

    It 'ignores a record without the shape run_subagent writes: <Case>' -ForEach @(
        @{ Case = 'a forged id'; Data = @{ Phase = 'started'; Id = '../../x'; Agent = 'a' } }
        @{ Case = 'an unknown phase'; Data = @{ Phase = 'paused'; Id = 'a_0123456789abcdef'; Agent = 'a' } }
        @{ Case = 'an unknown status'; Data = @{ Phase = 'finished'; Id = 'a_0123456789abcdef'; Agent = 'a'; Status = 'approved' } }
        @{ Case = 'no agent'; Data = @{ Phase = 'started'; Id = 'a_0123456789abcdef' } }
    ) {
        Get-DpStreamFrame -Record (New-SubagentRecord $Data) | Should -BeNullOrEmpty
    }

    It 'bounds text it did not write itself' {
        $decision = Get-DpStreamFrame -Record (New-SubagentRecord @{
                Phase = 'finished'; Id = 'a_0123456789abcdef'; Agent = ('n' * 300); Status = 'refused'; Reason = ('r' * 2000); Output = ('o' * 50000); Description = "two`nlines"
            })
        $decision.event | Should -BeExactly 'activity'
        $decision.data.detail | Should -Match '^n+…$'
        $decision.data.detail.Length | Should -BeLessOrEqual 64
        $decision.data.reason | Should -Match '^r+…$'
        $decision.data.reason.Length | Should -BeLessOrEqual 500
        $decision.data.output | Should -Match '^o+…$'
        $decision.data.output.Length | Should -BeLessOrEqual 20200
        $decision.data.description | Should -BeExactly 'two lines'
    }
}

Describe 'Merge-DpRetriedTurnUsage with Subagent runs' {
    BeforeAll {
        $script:mergeFinal = @{ promptTokens = 80; completionTokens = 25; totalTokens = 105; costUSD = 0.009; credits = 0.9; iterations = 3; priced = $true }
        $script:mergeBefore = [pscustomobject]@{ Calls = 2; PromptTokens = 100; CompletionTokens = 20; TotalTokens = 120; CostUSD = 0.01; Credits = 1.0 }
    }

    It 'counts every Subagent round-trip, not one per Engine call' {
        $after = [pscustomobject]@{ Calls = 5; PromptTokens = 400; CompletionTokens = 90; TotalTokens = 490; CostUSD = 0.05; Credits = 5.0 }
        $usage = Merge-DpRetriedTurnUsage -Usage $script:mergeFinal -Before $script:mergeBefore -After $after -AdditionalCalls 2 -AdditionalIterations 6

        $usage.promptTokens | Should -Be 300
        $usage.completionTokens | Should -Be 70
        $usage.costUSD | Should -Be 0.04
        $usage.credits | Should -Be 4
        $usage.iterations | Should -Be 9
    }

    It 'still adds a retried attempt beside the Subagent runs' {
        $after = [pscustomobject]@{ Calls = 6; PromptTokens = 400; CompletionTokens = 90; TotalTokens = 490; CostUSD = 0.05; Credits = 5.0 }
        (Merge-DpRetriedTurnUsage -Usage $script:mergeFinal -Before $script:mergeBefore -After $after -AdditionalCalls 2 -AdditionalIterations 6).iterations | Should -Be 10
    }
}

Describe 'Subagent runs in a Turn' -Tag 'Unit' {
    BeforeEach {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $setup = [powershell]::Create()
        $setup.Runspace = $runspace
        $null = $setup.AddScript(@'
function global:Invoke-Shp {
    [CmdletBinding()]
    param($Prompt, $History, $SystemPrompt, $Model, $MaxToolIterations, [switch]$DisableTerminal)
    $progress = { param($Data) Write-Information -Tags 'ShpProgress' -MessageData ([pscustomobject]$Data) }
    $subagent = { param($Data) Write-Information -Tags 'DeskPilotSubagent' -MessageData ([pscustomobject]$Data) }
    & $progress @{ Kind = 'ToolCall'; Name = 'run_subagent'; Arguments = '{"agent":"general-purpose","prompt":"PRIVATE-TASK"}' }
    & $subagent @{ Phase = 'started'; Id = 'a_0123456789abcdef'; Agent = 'general-purpose'; Description = 'docs audit'; Input = 'Audit the docs.' }
    & $progress @{ Kind = 'ToolCall'; Name = 'write_file'; Arguments = '{"path":"docs/notes.md"}' }
    & $progress @{ Kind = 'TodoList'; TodoList = @([pscustomobject]@{ id = 1; title = 'Subagent task'; status = 'in-progress' }) }
    if ($global:TurnFixtureMode -eq 'stopped') { Start-Sleep -Seconds 5 }
    & $subagent @{
        Phase = 'finished'; Id = 'a_0123456789abcdef'; Agent = 'general-purpose'; Status = 'completed'; Output = 'Docs are current.'; Reason = ''
        DurationMs = 1200; Iterations = 4; ToolCalls = 1; CostUSD = 0.004; EngineCalls = 1; FilesWritten = @('docs/notes.md')
    }
    & $progress @{ Kind = 'ToolCall'; Name = 'read_file'; Arguments = '{"path":"README.md"}' }
    [pscustomobject]@{
        Content = 'Parent answer.'; Usage = @{ PromptTokens = 10; CompletionTokens = 4; TotalTokens = 14 }
        CostUSD = 0.005; Credits = 0.5; Iterations = 2; ToolCalls = @(); History = @(); FilesWritten = @()
    }
}
'@)
        $setup.Invoke() | Out-Null
        if ($setup.HadErrors) { throw $setup.Streams.Error[0] }
        $setup.Dispose()

        $settings = Get-DpDefaultSettings
        $settings.model = 'fixture'
        $settings.pushInstructions = $false
        $settings.workspaceContext = $false
        $settings.responseRetryCount = 0
        $settings.turnTranscript = $false
        $settings.skillRoots = @()
        $settings.instructionRoots = @()
        $settings.promptRoots = @()
        $settings.agentsRoot = ''
        $settings.permissions.subagents = $true
        $script:DeskPilot = @{
            Settings = $settings
            Engine = @{
                Runspace = $runspace; UserPromptBridge = $null; ApprovalBridge = $null
                McpSupported = $false; SubagentSupported = $true; BrowserState = $null; TerminalSession = $null
            }
            Diagnostics = @{ Log = (New-DpDiagnosticLog -MaxEntries 100 -MaxBytes 32768) }
            Intercom = $null
            Memory = @{ text = ''; updatedUtc = $null }
            DataDir = $null
            Version = '0.0.1'
            DefaultModel = 'fixture'
            Models = @()
            TurnRunning = $false
            CancelRequested = $false
            PendingApproval = $null
            PendingUserPrompt = $null
        }
        $conversation = New-DpConversation -Title 'Fixture'
        $stream = [System.IO.MemoryStream]::new()
        $script:RequestedOutcome = ''
        $script:usageProbes = 0

        Mock Set-DpQuestionnaireTool { $false }
        Mock Set-DpWorkspaceTool { $false }
        Mock Set-DpTerminalTool { $false }
        Mock Set-DpSubagentTool { $Enabled }
        Mock Get-DpBrowserRuntime { @{ ready = $false; runtimeRoot = '' } }
        Mock Get-DpBrowserState { $null }
        Mock Set-DpBrowserTool { $false }
        Mock Test-DpBrowserActive { $false }
        Mock Get-DpDataDir { [string]$TestDrive }
        Mock Invoke-DpEngineCommand { $null }
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpUsage' } {
            $script:usageProbes++
            if ($script:usageProbes -eq 1) { [pscustomobject]@{ Calls = 4; PromptTokens = 100; CompletionTokens = 20; TotalTokens = 120; CostUSD = 0.010; Credits = 1.0 } }
            else { [pscustomobject]@{ Calls = 6; PromptTokens = 160; CompletionTokens = 35; TotalTokens = 195; CostUSD = 0.019; Credits = 1.9 } }
        }
        Mock Set-DpEngineLocation { $true }
        Mock Get-DpEngineWorkingDir { [string]$TestDrive }
        Mock Get-DpEngineEditedFile { @() }
        Mock Update-DpUsage {}
        Mock Close-DpBrowserSession {}
        Mock Invoke-DpPendingRequest {
            if ($script:RequestedOutcome -eq 'stopped') { $script:DeskPilot.CancelRequested = $true }
        }

        function script:Get-ActivityFrame {
            param([string]$Wire)
            @([regex]::Matches($Wire, '(?m)^event: activity\r?\ndata: (.+)$') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
        }
    }

    AfterEach {
        $runspace.Close()
        $runspace.Dispose()
        $stream.Dispose()
    }

    It 'offers run_subagent with the Turn''s capability' {
        $runspace.SessionStateProxy.SetVariable('TurnFixtureMode', 'completed')
        Invoke-DpTurn -Conversation $conversation -Prompt 'Audit the docs.' -Stream $stream

        Should -Invoke Set-DpSubagentTool -Times 1 -Exactly -ParameterFilter {
            $Enabled -and $Context.turn.model -eq 'fixture' -and $Context.capability.DisableTerminal -and @($Context.catalog.name) -contains 'general-purpose'
        }
    }

    It 'nests the Subagent''s Tool calls under its run and keeps the Turn''s Task List' {
        $runspace.SessionStateProxy.SetVariable('TurnFixtureMode', 'completed')
        Invoke-DpTurn -Conversation $conversation -Prompt 'Audit the docs.' -Stream $stream
        $wire = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())

        $wire | Should -Match 'event: done'
        $wire | Should -Not -Match 'event: tasks'
        $wire | Should -Not -Match 'PRIVATE-TASK'
        $frames = Get-ActivityFrame -Wire $wire
        $place = {
            param($Frame)
            if ($Frame.PSObject.Properties['phase']) { $Frame.phase }
            elseif ($Frame.PSObject.Properties['parentId']) { 'nested' }
            else { 'top' }
        }
        @($frames | ForEach-Object { '{0}:{1}' -f $_.kind, (& $place $_) }) |
            Should -Be @('agent:started', 'write:nested', 'agent:finished', 'read:top')
        ($frames | Where-Object kind -EQ 'write').parentId | Should -BeExactly 'a_0123456789abcdef'

        $message = $conversation.messages[-1]
        @($message.activity.actions) | Should -HaveCount 2
        $run = $message.activity.actions[0]
        $run.kind | Should -BeExactly 'agent'
        $run.status | Should -BeExactly 'completed'
        $run.input | Should -BeExactly 'Audit the docs.'
        $run.output | Should -BeExactly 'Docs are current.'
        $run.description | Should -BeExactly 'docs audit'
        @($run.actions) | Should -HaveCount 1
        $run.actions[0].kind | Should -BeExactly 'write'
        $run.actions[0].detail | Should -BeExactly 'docs/notes.md'
        $message.activity.actions[1].kind | Should -BeExactly 'read'
        @($message.tasks).Count | Should -Be 0
        @($message.activity.filesWritten) | Should -Contain 'docs/notes.md'
    }

    It 'counts the Subagent''s Engine calls in the Turn''s Usage' {
        $runspace.SessionStateProxy.SetVariable('TurnFixtureMode', 'completed')
        Invoke-DpTurn -Conversation $conversation -Prompt 'Audit the docs.' -Stream $stream

        $usage = $conversation.messages[-1].usage
        $usage.promptTokens | Should -Be 60
        $usage.completionTokens | Should -Be 15
        $usage.costUSD | Should -Be 0.009
        $usage.iterations | Should -Be 6
        $observed = @(Get-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log | Where-Object eventId -EQ 'tool.observed')
        @($observed.context.action) | Should -Contain 'agent'
    }

    It 'marks a Subagent that a Stop interrupted as stopped' {
        $script:RequestedOutcome = 'stopped'
        $runspace.SessionStateProxy.SetVariable('TurnFixtureMode', 'stopped')
        Invoke-DpTurn -Conversation $conversation -Prompt 'Audit the docs.' -Stream $stream

        $message = $conversation.messages[-1]
        $message.stopped | Should -BeTrue
        $message.activity.actions[0].kind | Should -BeExactly 'agent'
        $message.activity.actions[0].status | Should -BeExactly 'stopped'
    }
}
