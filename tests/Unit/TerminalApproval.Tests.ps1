#requires -Version 7.0

# Per-call approval for Terminal commands, per the signed-off Design Concept
# (.memory-bank/topics/design-per-call-approval.md).
#
# The boundary is the pairing: DeskPilot registers its own run_command while
# Invoke-Shp is given -DisableTerminal, so the Model has no built-in to prefer.
# The safe-list decides whether the user is interrupted; everything it does not
# recognise prompts, and there is no Turn-wide grant.

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    # Initialize-DpUserPromptBridge owns the Add-Type for DeskPilot.UserPromptBridge;
    # a throwaway runspace registers the type so the tests can build bridges directly.
    $bootstrapRunspace = [runspacefactory]::CreateRunspace()
    $bootstrapRunspace.Open()
    $null = Initialize-DpUserPromptBridge -Runspace $bootstrapRunspace
    $bootstrapRunspace.Dispose()

    function New-DpTestRequest {
        param(
            [string]$Command = 'Get-ChildItem',
            [string]$WorkingDirectory = 'C:\projects\alpha',
            [string]$ConversationId = 'c-1',
            [string]$TurnId = 't-1'
        )
        New-DpApprovalRequest -Tool 'run_command' -Class 'Terminal' `
            -Argument @{ command = $Command; workingDirectory = $WorkingDirectory } `
            -ProjectName 'Alpha' -ConversationId $ConversationId -TurnId $TurnId
    }

    # Scriptblocks have runspace affinity, so the Tool has to be re-declared from
    # its definition inside the runspace under test - which is exactly how it is
    # injected into the Engine Runspace in production.
    function Get-DpToolDefinition {
        @('Get-DpPropertyValue', 'New-DpApprovalRequest', 'Test-DpCommandSafe', 'Invoke-DpTerminalApprovalTool') |
            ForEach-Object { "function global:$_ {`n$((Get-Command $_).Definition)`n}" }
    }
}

Describe 'New-DpApprovalRequest' -Tag 'Unit' {
    It 'summarizes only allow-listed fields' {
        $request = New-DpApprovalRequest -Tool 'run_command' -Class 'Terminal' `
            -Argument @{ command = 'git status'; workingDirectory = 'C:\p'; token = 'ghp_secret'; env = @{ AWS_SECRET = 'x' } } `
            -ProjectName 'Alpha' -ConversationId 'c-1' -TurnId 't-1'

        $request.summary.command | Should -Be 'git status'
        $request.summary.workingDirectory | Should -Be 'C:\p'
        $request.summary.project | Should -Be 'Alpha'
        ($request | ConvertTo-Json -Depth 6) | Should -Not -Match 'ghp_secret'
        ($request | ConvertTo-Json -Depth 6) | Should -Not -Match 'AWS_SECRET'
    }

    It 'produces a stable fingerprint for the same action' {
        (New-DpTestRequest).fingerprint | Should -Be (New-DpTestRequest).fingerprint
        (New-DpTestRequest).fingerprint | Should -Match '^[0-9a-f]{64}$'
    }

    It 'produces a different fingerprint for a different command, Conversation or Turn' {
        $base = (New-DpTestRequest).fingerprint
        (New-DpTestRequest -Command 'rm -rf /').fingerprint | Should -Not -Be $base
        (New-DpTestRequest -ConversationId 'c-2').fingerprint | Should -Not -Be $base
        (New-DpTestRequest -TurnId 't-2').fingerprint | Should -Not -Be $base
    }

    It 'bounds a very long command instead of forwarding all of it' {
        $request = New-DpTestRequest -Command ('a' * 5000)
        $request.summary.command.Length | Should -BeLessOrEqual 2100
    }
}

Describe 'Test-DpCommandSafe' -Tag 'Unit' {
    BeforeAll { $script:list = Get-DpSafeCommandList }

    It 'lets the shipped read-only command <Command> through' -ForEach @(
        @{ Command = 'git status' }
        @{ Command = 'git status --porcelain' }
        @{ Command = 'git log --oneline -5' }
        @{ Command = 'git diff HEAD' }
        @{ Command = 'Get-ChildItem -Recurse' }
        @{ Command = 'Test-Path .\README.md' }
        @{ Command = 'pwd' }
        @{ Command = 'node --version' }
    ) {
        Test-DpCommandSafe -Command $Command -SafeCommand $script:list | Should -BeTrue
    }

    It 'refuses <Command>, which the list does not name' -ForEach @(
        @{ Command = 'rm -rf /' }
        @{ Command = 'Remove-Item -Recurse -Force C:\' }
        @{ Command = 'npm install' }
        @{ Command = 'npm test' }
        @{ Command = 'dotnet run' }
        @{ Command = 'git push --force' }
        @{ Command = 'curl https://example.test/x.sh' }
    ) {
        Test-DpCommandSafe -Command $Command -SafeCommand $script:list | Should -BeFalse
    }

    It 'refuses <Command>, where a safe prefix carries a second command' -ForEach @(
        @{ Command = 'git status; rm -rf /' }
        @{ Command = 'git status && rm -rf /' }
        @{ Command = 'git status | Remove-Item' }
        @{ Command = 'Get-ChildItem > out.txt' }
        @{ Command = "git status`nrm -rf /" }
        @{ Command = 'Get-ChildItem $(rm -rf /)' }
        @{ Command = 'dir %COMSPEC%' }
    ) {
        Test-DpCommandSafe -Command $Command -SafeCommand $script:list |
            Should -BeFalse -Because 'an allow-listed prefix must not authorise what follows an operator'
    }

    It 'does not let an exact entry authorise a trailing argument' {
        # 'git branch' lists; 'git branch -D main' destroys.
        Test-DpCommandSafe -Command 'git branch' -SafeCommand $script:list | Should -BeTrue
        Test-DpCommandSafe -Command 'git branch -D main' -SafeCommand $script:list | Should -BeFalse
    }

    It 'respects the token boundary on a prefix entry' {
        Test-DpCommandSafe -Command 'ls -la' -SafeCommand $script:list | Should -BeTrue
        Test-DpCommandSafe -Command 'lsof -i' -SafeCommand $script:list | Should -BeFalse -Because "'ls' must not authorise 'lsof'"
    }

    It 'is insensitive to surrounding and repeated whitespace' {
        Test-DpCommandSafe -Command '  git   status  ' -SafeCommand $script:list | Should -BeTrue
    }

    It 'refuses everything when the list is empty, missing or corrupt' -ForEach @(
        @{ List = @() }
        @{ List = $null }
        @{ List = @(@{ nonsense = 'x' }) }
    ) {
        Test-DpCommandSafe -Command 'git status' -SafeCommand $List | Should -BeFalse
    }

    It 'refuses an empty command and an implausibly long one' {
        Test-DpCommandSafe -Command '' -SafeCommand $script:list | Should -BeFalse
        Test-DpCommandSafe -Command ('git status ' + ('x' * 600)) -SafeCommand $script:list | Should -BeFalse
    }

    It 'never gives an interpreter or package runner a prefix entry' {
        # 'node' with a prefix entry would authorise 'node evil.js'. These may
        # appear only as fixed version probes, which cannot carry a payload.
        $runners = @('node', 'npm', 'npx', 'yarn', 'pnpm', 'dotnet', 'python', 'python3', 'pwsh', 'powershell', 'bash', 'sh', 'cmd', 'ruby', 'perl', 'cargo', 'go', 'java', 'mvn', 'gradle', 'make', 'pip')

        foreach ($entry in Get-DpSafeCommandList) {
            $first = ($entry.command -split '\s+')[0]
            if ($runners -notcontains $first) { continue }

            $entry.match | Should -Be 'exact' -Because "$($entry.command) starts with the runner '$first'"
            $entry.command | Should -Match '\s--version$' -Because "$($entry.command) may only be a version probe"
        }
    }

    It 'names no subcommand that runs repository-controlled code' {
        # npm test, dotnet run and friends execute whatever the checkout says to.
        foreach ($entry in Get-DpSafeCommandList) {
            $tokens = @($entry.command -split '\s+' | Select-Object -Skip 1)
            foreach ($token in $tokens) {
                $token | Should -Not -Match '(?i)^(test|run|install|exec|start|build|publish|push|restore|add|rm|remove|clean)$' -Because "$($entry.command) must not execute anything"
            }
        }
    }
}

Describe 'Invoke-DpTerminalApprovalTool' -Tag 'Unit' {
    BeforeEach {
        $script:marker = Join-Path $TestDrive ('ran-' + [guid]::NewGuid().ToString('N') + '.txt')
        $script:bridge = New-Object -TypeName 'DeskPilot.UserPromptBridge'
        $script:bridge.BeginTurn('c-1')
        $global:DeskPilotTerminalExecutor = {
            param($Command, $WorkingDirectory, $TimeoutSeconds)
            Set-Content -LiteralPath $script:marker -Value $Command -Encoding utf8
            '{"exitCode":0,"stdout":"done"}'
        }
        $global:DeskPilotApprovalBridge = $script:bridge
        $global:DeskPilotSafeCommand = Get-DpSafeCommandList
        $global:DeskPilotApprovalTimeoutMinutes = 15
        $global:DeskPilotApprovalContext = @{ conversationId = 'c-1'; turnId = 't-1'; project = 'Alpha'; workingDirectory = 'C:\projects\alpha' }
    }

    AfterEach {
        $script:bridge.Dispose()
        Remove-Variable -Name DeskPilotTerminalExecutor, DeskPilotApprovalBridge, DeskPilotSafeCommand, DeskPilotApprovalTimeoutMinutes, DeskPilotApprovalContext -Scope Global -ErrorAction SilentlyContinue
    }

    It 'runs a safe-list command without asking' {
        $result = Invoke-DpTerminalApprovalTool -Command 'git status'

        Test-Path -LiteralPath $script:marker | Should -BeTrue
        $script:bridge.Waiting | Should -BeFalse -Because 'a recognised read must not interrupt the user'
        ($result | ConvertFrom-Json).approved | Should -BeTrue
    }

    It 'asks before running a command the safe-list does not cover' {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalBridge', $script:bridge)
        $runspace.SessionStateProxy.SetVariable('DeskPilotSafeCommand', $global:DeskPilotSafeCommand)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalTimeoutMinutes', 15)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalContext', $global:DeskPilotApprovalContext)
        $runspace.SessionStateProxy.SetVariable('DeskPilotTerminalMarker', $script:marker)
        $executor = '$global:DeskPilotTerminalExecutor = { param($Command, $WorkingDirectory, $TimeoutSeconds) Set-Content -LiteralPath $global:DeskPilotTerminalMarker -Value $Command -Encoding utf8; ''{"exitCode":0}'' }'

        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        try {
            $null = $shell.AddScript(((Get-DpToolDefinition) -join "`n") + "`n$executor`nInvoke-DpTerminalApprovalTool -Command 'npm install left-pad'")
            $async = $shell.BeginInvoke()

            $pending = $null
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            while (-not $pending -and [datetime]::UtcNow -lt $deadline) {
                $pending = $script:bridge.GetPendingRequest()
                if (-not $pending) { Start-Sleep -Milliseconds 20 }
            }

            $pending | Should -Not -BeNullOrEmpty -Because 'the Tool must ask before it acts'
            Test-Path -LiteralPath $script:marker | Should -BeFalse -Because 'the command must not run while approval is pending'

            $null = $script:bridge.SubmitAnswer('c-1', $pending.Id, (@{ decision = 'approve' } | ConvertTo-Json -Compress))
            $null = $shell.EndInvoke($async)

            Test-Path -LiteralPath $script:marker | Should -BeTrue
        }
        finally {
            $shell.Dispose()
            $runspace.Dispose()
        }
    }

    It 'carries the denial note back to the Agent and runs nothing' {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalBridge', $script:bridge)
        $runspace.SessionStateProxy.SetVariable('DeskPilotSafeCommand', $global:DeskPilotSafeCommand)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalTimeoutMinutes', 15)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalContext', $global:DeskPilotApprovalContext)
        $runspace.SessionStateProxy.SetVariable('DeskPilotTerminalMarker', $script:marker)
        $executor = '$global:DeskPilotTerminalExecutor = { param($Command, $WorkingDirectory, $TimeoutSeconds) Set-Content -LiteralPath $global:DeskPilotTerminalMarker -Value $Command -Encoding utf8; ''{"exitCode":0}'' }'

        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        try {
            $null = $shell.AddScript(((Get-DpToolDefinition) -join "`n") + "`n$executor`nInvoke-DpTerminalApprovalTool -Command 'git push --force'")
            $async = $shell.BeginInvoke()

            $pending = $null
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            while (-not $pending -and [datetime]::UtcNow -lt $deadline) {
                $pending = $script:bridge.GetPendingRequest()
                if (-not $pending) { Start-Sleep -Milliseconds 20 }
            }
            $pending | Should -Not -BeNullOrEmpty

            $answer = @{ decision = 'deny'; note = 'use --dry-run first' } | ConvertTo-Json -Compress
            $null = $script:bridge.SubmitAnswer('c-1', $pending.Id, $answer)
            $result = ($shell.EndInvoke($async) | Select-Object -First 1)

            Test-Path -LiteralPath $script:marker | Should -BeFalse
            $shell.HadErrors | Should -BeFalse -Because 'a denial is a Tool result, not a failed Turn'
            $parsed = $result | ConvertFrom-Json
            $parsed.approved | Should -BeFalse
            $parsed.error | Should -Match ([regex]::Escape('use --dry-run first'))
        }
        finally {
            $shell.Dispose()
            $runspace.Dispose()
        }
    }

    It 'denies and frees the bridge when nobody answers in time' {
        $script:bridge.CaptureQuestion('probe')

        $expired = $false
        try { $null = $script:bridge.RequestAnswer(1) } catch [System.TimeoutException] { $expired = $true }

        $expired | Should -BeTrue -Because 'an unanswered approval must fail closed rather than hold the Engine'
        $script:bridge.Waiting | Should -BeFalse -Because 'the bridge must be reusable after a timeout'
        Test-Path -LiteralPath $script:marker | Should -BeFalse
    }

    It 'refuses without running anything when the bridge is not active' {
        $script:bridge.EndTurn()

        $result = Invoke-DpTerminalApprovalTool -Command 'git push --force'

        Test-Path -LiteralPath $script:marker | Should -BeFalse
        ($result | ConvertFrom-Json).approved | Should -BeFalse
    }

    It 'refuses without running anything when no executor is injected' {
        Remove-Variable -Name DeskPilotTerminalExecutor -Scope Global

        $result = Invoke-DpTerminalApprovalTool -Command 'git status'

        Test-Path -LiteralPath $script:marker | Should -BeFalse
        ($result | ConvertFrom-Json).approved | Should -BeFalse
    }

    It 'prompts even for a would-be-safe command when the safe-list is missing' {
        Remove-Variable -Name DeskPilotSafeCommand -Scope Global
        $script:bridge.EndTurn()

        # With no bridge to ask, that prompt becomes a refusal - never a silent run.
        $result = Invoke-DpTerminalApprovalTool -Command 'git status'

        Test-Path -LiteralPath $script:marker | Should -BeFalse
        ($result | ConvertFrom-Json).approved | Should -BeFalse
    }
}

Describe 'Per-call approval wiring' -Tag 'Unit' {
    BeforeAll {
        function New-DpApprovalSettings {
            param([bool]$Approval = $true, [bool]$Terminal = $true, [bool]$UserTools = $true)
            $settings = Get-DpDefaultSettings
            $settings.perCallApproval = $Approval
            $settings.permissions.terminal = $Terminal
            $settings.permissions.userTools = $UserTools
            $settings
        }
    }

    It 'is active only when approval, Terminal and Your Tools are all on' -ForEach @(
        @{ Approval = $true; Terminal = $true; UserTools = $true; Expected = $true }
        @{ Approval = $false; Terminal = $true; UserTools = $true; Expected = $false }
        @{ Approval = $true; Terminal = $false; UserTools = $true; Expected = $false }
        @{ Approval = $true; Terminal = $true; UserTools = $false; Expected = $false }
    ) {
        $settings = New-DpApprovalSettings -Approval $Approval -Terminal $Terminal -UserTools $UserTools
        Test-DpApprovalActive -Settings $settings | Should -Be $Expected
    }

    It 'passes -DisableTerminal so the Engine is not asked to run commands itself' {
        # This proves only that DeskPilot builds the parameter. That the Engine
        # then declines to run its own run_command is the Engine's behaviour and
        # is proved against a real Engine in 'Terminal tool registration' below -
        # an earlier version of this test carried the Engine claim in its name and
        # asserted nothing of the kind, which is how the gap survived review.
        $params = New-DpTurnParameter -Prompt 'hi' -Settings (New-DpApprovalSettings)

        $params.ContainsKey('DisableTerminal') | Should -BeTrue
        $params.DisableTerminal | Should -BeTrue
    }

    It 'leaves the Engine terminal alone when approval is off but Terminal is on' {
        $params = New-DpTurnParameter -Prompt 'hi' -Settings (New-DpApprovalSettings -Approval $false)

        $params.ContainsKey('DisableTerminal') | Should -BeFalse
    }

    It 'still disables the terminal when Terminal Permission itself is off' {
        # Terminal off is stricter than approval, and must stay stricter.
        $params = New-DpTurnParameter -Prompt 'hi' -Settings (New-DpApprovalSettings -Terminal $false)

        $params.DisableTerminal | Should -BeTrue
    }

    It 'stands approval down rather than removing the terminal when Your Tools is off' {
        # -DisableUserTools would take the gated Tool away with it, so approval
        # cannot be the reason the terminal disappears.
        $settings = New-DpApprovalSettings -UserTools $false
        $params = New-DpTurnParameter -Prompt 'hi' -Settings $settings

        $params.DisableUserTools | Should -BeTrue
        $params.ContainsKey('DisableTerminal') | Should -BeFalse
    }

    It 'keeps group approval off until it is asked for on its own' {
        # Letting a group instruct DeskPilot and letting a group authorise a
        # command DeskPilot stopped for are separate amounts of trust.
        (Get-DpDefaultSettings).intercom.groupApproval | Should -BeFalse
    }
}

Describe 'Terminal tool registration' -Tag 'Unit' {
    # Against a real Engine, because the thing being proved is what the Engine
    # does with the registration - not what DeskPilot asked for.
    BeforeAll {
        function script:Test-EngineEnforcesDisabledTool {
            param($Module)
            $rootModule = Join-Path $Module.ModuleBase 'ShellPilot.psm1'
            (Test-Path -LiteralPath $rootModule) -and
                ((Get-Content -LiteralPath $rootModule -Raw) -match 'offeredBuiltInTool')
        }

        # The gated Tool needs an Engine that refuses to dispatch a built-in the
        # Turn disabled, so the newest Engine is not automatically the right one.
        # Skipping when none is installed states the dependency instead of hiding
        # it behind a green run against an Engine that cannot honour the gate.
        $script:engineModule = Get-Module -ListAvailable ShellPilot |
            Where-Object { Test-EngineEnforcesDisabledTool -Module $_ } |
            Sort-Object Version -Descending |
            Select-Object -First 1

        function script:New-EngineRunspace {
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $importShell = [powershell]::Create()
            $importShell.Runspace = $runspace
            $null = $importShell.AddCommand('Import-Module').AddParameter('Name', $script:engineModule.Path)
            $importShell.Invoke() | Out-Null
            $importShell.Dispose()
            $runspace
        }

        function script:Get-RegisteredTool {
            param($Runspace)
            $probeShell = [powershell]::Create()
            $probeShell.Runspace = $Runspace
            $null = $probeShell.AddCommand('Get-ShpTool')
            $registered = @($probeShell.Invoke())
            $probeShell.Dispose()
            @($registered)
        }

        function script:New-TerminalToolContext {
            @{ conversationId = 'c-1'; turnId = 't-1'; project = 'Alpha'; workingDirectory = $TestDrive }
        }
    }

    BeforeEach {
        if (-not $script:engineModule) {
            Set-ItResult -Skipped -Because 'no installed ShellPilot refuses to dispatch a disabled built-in, so the gate cannot be honoured or tested'
        }
    }

    # The name is the whole boundary. ShellPilot dispatches its built-ins from
    # literal switch clauses and reaches registered tools only through that
    # switch's default, so a tool named run_command is advertised, then never
    # invoked while the built-in runs the command ungated.
    It 'never claims a built-in tool name' {
        $runspace = New-EngineRunspace
        try {
            $bridge = New-Object DeskPilot.UserPromptBridge
            Initialize-DpTerminalTool -Runspace $runspace -Context (New-TerminalToolContext) `
                -SafeCommand @() -TimeoutMinutes 1 -Bridge $bridge | Should -BeTrue

            $registered = Get-RegisteredTool -Runspace $runspace
            @($registered.Name) | Should -Not -Contain 'run_command'
            @($registered.Name) | Should -Contain 'run_terminal_command'
        }
        finally {
            $runspace.Dispose()
        }
    }

    It 'describes the approval contract in the tool description' {
        # ShellPilot derives the schema from parameter metadata, so the argument
        # contract and the fact that a decline is final live in the description.
        $runspace = New-EngineRunspace
        try {
            $bridge = New-Object DeskPilot.UserPromptBridge
            $null = Initialize-DpTerminalTool -Runspace $runspace -Context (New-TerminalToolContext) `
                -SafeCommand @() -TimeoutMinutes 1 -Bridge $bridge

            $tool = Get-RegisteredTool -Runspace $runspace | Where-Object Name -eq 'run_terminal_command'
            $tool.Description | Should -Match 'approval'
            $tool.Description | Should -Match 'command \(string, required\)'
        }
        finally {
            $runspace.Dispose()
        }
    }

    It 'removes the tool it registered when approval stands down' {
        $runspace = New-EngineRunspace
        try {
            $bridge = New-Object DeskPilot.UserPromptBridge
            $null = Initialize-DpTerminalTool -Runspace $runspace -Context (New-TerminalToolContext) `
                -SafeCommand @() -TimeoutMinutes 1 -Bridge $bridge
            @((Get-RegisteredTool -Runspace $runspace).Name) | Should -Contain 'run_terminal_command'

            Set-DpTerminalTool -Runspace $runspace -Enabled $false | Should -BeTrue
            @((Get-RegisteredTool -Runspace $runspace).Name) | Should -Not -Contain 'run_terminal_command'
        }
        finally {
            $runspace.Dispose()
        }
    }
}

Describe 'Terminal tool Engine capability probe' -Tag 'Unit' {
    # The gate is only a gate if the Engine refuses to dispatch the built-in the
    # Turn disabled. An Engine without that refusal runs a stray run_command
    # beside the gate, so registration must fail loudly there rather than leave
    # approval reporting as active. Proved against a real older Engine when one
    # is installed, because a probe nobody has seen reject anything is decoration.
    It 'refuses to register against an Engine that still dispatches disabled built-ins' {
        $legacy = Get-Module -ListAvailable ShellPilot |
            Where-Object {
                $rootModule = Join-Path $_.ModuleBase 'ShellPilot.psm1'
                (Test-Path -LiteralPath $rootModule) -and
                    ((Get-Content -LiteralPath $rootModule -Raw) -notmatch 'offeredBuiltInTool')
            } |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if (-not $legacy) {
            Set-ItResult -Skipped -Because 'no ShellPilot without the dispatch fix is installed to test against'
            return
        }

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        try {
            $importShell = [powershell]::Create()
            $importShell.Runspace = $runspace
            $null = $importShell.AddCommand('Import-Module').AddParameter('Name', $legacy.Path)
            $importShell.Invoke() | Out-Null
            $importShell.Dispose()

            $bridge = New-Object DeskPilot.UserPromptBridge
            { Initialize-DpTerminalTool -Runspace $runspace `
                    -Context @{ conversationId = 'c-1'; turnId = 't-1'; project = 'Alpha'; workingDirectory = $TestDrive } `
                    -SafeCommand @() -TimeoutMinutes 1 -Bridge $bridge } |
                Should -Throw -ExpectedMessage '*dispatches disabled built-in tools*'

            $probeShell = [powershell]::Create()
            $probeShell.Runspace = $runspace
            $null = $probeShell.AddCommand('Get-ShpTool')
            $registered = @($probeShell.Invoke())
            $probeShell.Dispose()
            @($registered.Name) | Should -Not -Contain 'run_terminal_command'
        }
        finally {
            $runspace.Dispose()
        }
    }
}

Describe 'Per-call approval Settings' -Tag 'Unit' {
    It 'ships approval off until the browser surface lands' {
        (Get-DpDefaultSettings).perCallApproval | Should -BeFalse
    }

    It 'defaults the approval timeout to 15 minutes and bounds it' {
        (Get-DpDefaultSettings).approvalTimeoutMinutes | Should -Be 15
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ approvalTimeoutMinutes = 60 }).approvalTimeoutMinutes | Should -Be 60
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ approvalTimeoutMinutes = 0 } } | Should -Throw '*approvalTimeoutMinutes*'
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ approvalTimeoutMinutes = 5000 } } | Should -Throw '*approvalTimeoutMinutes*'
    }

    It 'starts with no user additions to the safe-list' {
        @((Get-DpDefaultSettings).safeCommands).Count | Should -Be 0
    }

    It 'accepts a well-formed user addition' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ safeCommands = @(@{ command = 'just --list'; match = 'exact' }) }
        $merged.safeCommands[0].command | Should -Be 'just --list'
        $merged.safeCommands[0].match | Should -Be 'exact'
    }

    It 'refuses a user addition carrying a shell operator' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ safeCommands = @(@{ command = 'git status; rm -rf /'; match = 'prefix' }) } } |
            Should -Throw '*shell operator*'
    }

    It 'refuses an unknown match mode and an empty command' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ safeCommands = @(@{ command = 'ls'; match = 'regex' }) } } | Should -Throw '*match*'
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ safeCommands = @(@{ command = '  '; match = 'exact' }) } } | Should -Throw '*command*'
    }
}
