#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Terminal execution policy' -Tag 'Unit' {
    It 'defaults to Local with read-only Project access, no network and no environment grants' {
        $policy = (Get-DpDefaultSettings).terminalExecution

        $policy.mode | Should -BeExactly 'local'
        $policy.projectAccess | Should -BeExactly 'read-only'
        $policy.network | Should -BeExactly 'off'
        @($policy.allowedHosts).Count | Should -Be 0
        @($policy.environment).Count | Should -Be 0
        $policy.timeoutSeconds | Should -Be 120
        $policy.memoryMB | Should -Be 1024
        $policy.cpuCount | Should -Be 1
        $policy.processLimit | Should -Be 64
        $policy.outputBytes | Should -Be 1048576
        $policy.tempMB | Should -Be 128
    }

    It 'accepts and normalizes an explicit HTTPS allow-list and environment names only' {
        $patch = @{
            terminalExecution = @{
                mode = 'isolated'
                projectAccess = 'read-write'
                network = 'allow-list'
                allowedHosts = @('Example.COM', 'example.com', 'api.example.org')
                environment = @(@{ name = 'DP_FIXTURE_SECRET'; secret = $true })
            }
        }
        $policy = (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch $patch).terminalExecution

        $policy.mode | Should -BeExactly 'isolated'
        $policy.projectAccess | Should -BeExactly 'read-write'
        $policy.allowedHosts | Should -HaveCount 2
        $policy.allowedHosts | Should -Contain 'example.com'
        $policy.environment[0].name | Should -BeExactly 'DP_FIXTURE_SECRET'
        $policy.environment[0].secret | Should -BeTrue
        $policy.environment[0].ContainsKey('value') | Should -BeFalse
    }

    It 'merges a mode change without mutating or discarding the existing policy' {
        $current = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
            terminalExecution = @{ allowedHosts = @('example.com'); environment = @(@{ name = 'DP_FIXTURE'; secret = $false }) }
        }
        $updated = Merge-DpSettings -Current $current -Patch @{ terminalExecution = @{ mode = 'isolated' } }
        $updated.terminalExecution.environment[0].secret = $true

        $current.terminalExecution.mode | Should -BeExactly 'local'
        $current.terminalExecution.environment[0].secret | Should -BeFalse
        $updated.terminalExecution.allowedHosts | Should -Contain 'example.com'
    }

    It 'rejects invalid policy <Field> without accepting unknown control options' -ForEach @(
        @{ Policy = @{ mode = 'automatic' }; Field = 'mode' }
        @{ Policy = @{ projectAccess = 'host' }; Field = 'projectAccess' }
        @{ Policy = @{ network = 'internet' }; Field = 'network' }
        @{ Policy = @{ network = 'allow-list'; allowedHosts = @() }; Field = 'allowedHosts' }
        @{ Policy = @{ allowedHosts = @('*.example.com') }; Field = 'allowedHosts' }
        @{ Policy = @{ allowedHosts = @('https://example.com/path') }; Field = 'allowedHosts' }
        @{ Policy = @{ allowedHosts = @('127.0.0.1') }; Field = 'allowedHosts' }
        @{ Policy = @{ allowedHosts = @('example.com:8443') }; Field = 'allowedHosts' }
        @{ Policy = @{ allowedHosts = @('metadata.google.internal') }; Field = 'allowedHosts' }
        @{ Policy = @{ environment = @(@{ name = 'PATH'; secret = $false }) }; Field = 'environment' }
        @{ Policy = @{ environment = @(@{ name = 'HTTPS_PROXY'; secret = $false }) }; Field = 'environment' }
        @{ Policy = @{ environment = @(@{ name = 'DP_SECRET'; secret = 'false' }) }; Field = 'environment' }
        @{ Policy = @{ environment = @(@{ name = 'DP_SECRET'; value = 'not-to-be-persisted' }) }; Field = 'environment' }
        @{ Policy = @{ environment = @(@{ name = 'DP_SECRET' }, @{ name = 'dp_secret' }) }; Field = 'environment' }
        @{ Policy = @{ memoryMB = 0 }; Field = 'memoryMB' }
        @{ Policy = @{ cpuCount = [double]::NaN }; Field = 'cpuCount' }
        @{ Policy = @{ processLimit = 3.5 }; Field = 'processLimit' }
        @{ Policy = @{ timeoutSeconds = 86400 }; Field = 'timeoutSeconds' }
        @{ Policy = @{ tempMB = 0 }; Field = 'tempMB' }
        @{ Policy = @{ outputBytes = 0 }; Field = 'outputBytes' }
        @{ Policy = @{ privileged = $true }; Field = 'privileged' }
    ) {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ terminalExecution = $Policy } } |
            Should -Throw -ExpectedMessage "*terminalExecution*$Field*"
    }
}

Describe 'Terminal execution approval binding' -Tag 'Unit' {
    It 'shows and fingerprints the exact isolated policy without environment values' {
        $policy = ConvertTo-DpTerminalExecution -InputObject @{ mode = 'isolated'; environment = @(@{ name = 'DP_TOKEN'; secret = $true }) }
        $parameters = @{
            Tool = 'run_terminal_command'
            Class = 'Terminal'
            Argument = @{ command = 'npm install'; workingDirectory = '/project'; execution = $policy; policyId = 'policy-one' }
            ProjectName = 'Example'
            ConversationId = 'conversation'
            TurnId = 'turn'
        }
        $request = New-DpApprovalRequest @parameters

        $request.summary.execution.mode | Should -BeExactly 'isolated'
        $request.summary.execution.projectAccess | Should -BeExactly 'read-only'
        $request.summary.execution.network | Should -BeExactly 'off'
        $request.summary.execution.environment[0].secret | Should -BeTrue
        $request.risk | Should -Match 'Isolated'

        $parameters.Argument.execution.projectAccess = 'read-write'
        (New-DpApprovalRequest @parameters).fingerprint | Should -Not -Be $request.fingerprint
        $parameters.Argument.execution.projectAccess = 'read-only'
        $parameters.Argument.policyId = 'policy-two'
        (New-DpApprovalRequest @parameters).fingerprint | Should -Not -Be $request.fingerprint
    }

    It 'labels existing Terminal approvals as Local' {
        $request = New-DpApprovalRequest -Tool 'run_terminal_command' -Class Terminal -Argument @{ command = 'npm install' } -ConversationId conversation -TurnId turn

        $request.summary.execution.mode | Should -BeExactly 'local'
    }
}

Describe 'Isolated Turn preflight' -Tag 'Unit' {
    It 'requires dispatch enforcement even when Terminal Permission is off' {
        $previous = $script:DeskPilot
        $stream = [IO.MemoryStream]::new()
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $settings = Get-DpDefaultSettings
        $settings.terminalExecution.mode = 'isolated'
        $settings.permissions.terminal = $false
        $script:DeskPilot = @{ Settings = $settings; Engine = @{ Runspace = $runspace }; TurnRunning = $false; CancelRequested = $false }
        Mock Set-DpQuestionnaireTool { throw 'Engine Tool setup was reached without dispatch enforcement.' }
        try {
            Invoke-DpTurn -Conversation @{ id = 'inactive-isolation'; messages = [Collections.Generic.List[object]]::new(); history = @() } -Prompt 'inspect' -Stream $stream
            [Text.Encoding]::UTF8.GetString($stream.ToArray()) | Should -Match 'dispatch-enforcing Engine'
            Should -Invoke Set-DpQuestionnaireTool -Times 0 -Exactly
        }
        finally { $stream.Dispose(); $runspace.Dispose(); $script:DeskPilot = $previous }
    }

    It 'refuses <Reason> before Engine Tool setup' -ForEach @(
        @{ UserTools = $false; Reason = 'User Tools'; Expected = '*User Tools*' }
        @{ UserTools = $true; Reason = 'no selected Project'; Expected = '*selected Project*' }
    ) {
        $previous = $script:DeskPilot
        $stream = [IO.MemoryStream]::new()
        $settings = Get-DpDefaultSettings
        $settings.permissions.terminal = $true
        $settings.permissions.userTools = $UserTools
        $settings.terminalExecution.mode = 'isolated'
        $script:DeskPilot = @{
            Settings = $settings
            Engine = @{}
            TurnRunning = $false
            CancelRequested = $false
        }
        Mock Set-DpQuestionnaireTool { throw 'Engine Tool setup must not be reached.' }
        try {
            Invoke-DpTurn -Conversation @{ id = 'preflight'; messages = [Collections.Generic.List[object]]::new(); history = @() } -Prompt 'inspect' -Stream $stream
            $text = [Text.Encoding]::UTF8.GetString($stream.ToArray())

            $text | Should -BeLike $Expected
            $text | Should -Not -Match 'event: start'
            Should -Invoke Set-DpQuestionnaireTool -Times 0 -Exactly
        }
        finally {
            $stream.Dispose()
            $script:DeskPilot = $previous
        }
    }
}

Describe 'Terminal runtime routes and persisted policy' -Tag 'Unit' {
    It 'returns a partial runtime failure report under StrictMode' {
        $previous = $script:DeskPilot
        $script:DeskPilot = @{
            DataDir = $TestDrive; TurnRunning = $false; TerminalSetupJob = $null
            TerminalRuntime = @{ ready = $false; state = 'degraded'; issues = @('Preparation failed.') }
        }
        try {
            $status = & { Set-StrictMode -Version Latest; Get-DpTerminalStatus }
            $status.ready | Should -BeFalse
            $status.state | Should -BeExactly 'degraded'
            $status.issues | Should -Contain 'Preparation failed.'
            $status.image | Should -BeNullOrEmpty
        }
        finally { $script:DeskPilot = $previous }
    }

    It 'initializes the optional Terminal controller in fresh Engine state' {
        $module = Get-Module -ListAvailable ShellPilot | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) { Set-ItResult -Skipped -Because 'A local Engine is required for its initialization contract.'; return }
        $engine = Initialize-DpEngine -EngineModulePath $module.Path
        try {
            $engine.ContainsKey('TerminalSession') | Should -BeTrue
            $engine.TerminalSession | Should -BeNullOrEmpty
        }
        finally {
            $engine.ApprovalBridge.Dispose()
            $engine.UserPromptBridge.Dispose()
            $engine.Runspace.Dispose()
        }
    }

    It 'refuses runtime action <Route> during a Turn' -ForEach @(
        @{ Route = 'installTerminalRuntime' }
        @{ Route = 'cleanupTerminalRuntime' }
        @{ Route = 'uninstallTerminalRuntime' }
    ) {
        $previous = $script:DeskPilot
        $script:DeskPilot = @{ TurnRunning = $true; DataDir = $TestDrive }
        $stream = [IO.MemoryStream]::new()
        Mock Install-DpTerminalRuntime { throw 'Installation must not run during a Turn.' }
        try {
            Invoke-DpRouteHandler -Name $Route -Stream $stream
            [Text.Encoding]::UTF8.GetString($stream.ToArray()) | Should -Match '^HTTP/1.1 409'
            Should -Invoke Install-DpTerminalRuntime -Times 0 -Exactly
        }
        finally { $stream.Dispose(); $script:DeskPilot = $previous }
    }

    It 'returns an allow-listed runtime report rather than copying unknown state' {
        $previous = $script:DeskPilot
        $script:DeskPilot = @{ TurnRunning = $false; DataDir = $TestDrive }
        $stream = [IO.MemoryStream]::new()
        Mock Get-DpTerminalRuntime { @{ ready = $true; state = 'healthy'; powerShellVersion = '7.6.5'; unexpected = 'private-state-marker' } }
        try {
            Invoke-DpRouteHandler -Name 'getTerminalRuntime' -Stream $stream
            $response = [Text.Encoding]::UTF8.GetString($stream.ToArray())
            $response | Should -Match '7.6.5'
            $response | Should -Not -Match 'private-state-marker'
        }
        finally { $stream.Dispose(); $script:DeskPilot = $previous }
    }

    It 'never recovers a damaged Isolated policy by selecting Local defaults' {
        @{ terminalExecution = @{ mode = 'isolated'; network = 'unrestricted' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $TestDrive 'settings.json') -Encoding utf8

        { Import-DpSettings -Directory $TestDrive -ErrorAction SilentlyContinue } | Should -Throw '*Terminal execution policy*'
    }
}

Describe 'Isolated writes in pending-change routes' -Tag 'Unit' {
    BeforeEach {
        $script:priorDeskPilot = $script:DeskPilot
        $script:changeRoot = Join-Path $TestDrive 'changes-project'
        $null = New-Item -Path $script:changeRoot -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $script:changeRoot 'proof.txt') -Value 'changed'
        $store = @{}
        $null = Add-DpChangeEntry -Store $store -Root $script:changeRoot -Paths @('proof.txt') -ConversationId 'test'
        $script:DeskPilot = @{ Settings = @{ workspaceFolder = $script:changeRoot }; Changes = $store; Conversations = @{}; DataDir = $null }
        $script:changeStream = [IO.MemoryStream]::new()
    }

    AfterEach { $script:changeStream.Dispose(); $script:DeskPilot = $script:priorDeskPilot }

    It 'projects actual stored entries as files rather than a nested array' {
        Invoke-DpRouteHandler -Name 'pendingChanges' -Stream $script:changeStream
        $response = [Text.Encoding]::UTF8.GetString($script:changeStream.ToArray())
        $payload = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $payload.fileCount | Should -Be 1
        $payload.files[0].rel | Should -BeExactly 'proof.txt'
    }

    It 'passes individual stored entries into Undo' {
        $script:undoEntries = @()
        Mock Invoke-DpChangeUndo {
            param($Entries)
            $script:undoEntries = $Entries
            @{ restored = @(); removed = @(); skipped = @(); error = $null }
        }
        Invoke-DpRouteHandler -Name 'undoChanges' -Body ([pscustomobject]@{ paths = @('proof.txt') }) -Stream $script:changeStream
        $script:undoEntries | Should -HaveCount 1
        $script:undoEntries[0] | Should -BeOfType [hashtable]
        $script:undoEntries[0].rel | Should -BeExactly 'proof.txt'
    }
}
