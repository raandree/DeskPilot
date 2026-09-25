#requires -Version 7.0

BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Modern Engine approval interface' {
    It 'recognizes <Contract> only with its actual <ParameterType> parameter type' -ForEach @(
        @{ Contract = 'ToolCallControl'; ParameterType = 'hashtable'; Expected = $true }
        @{ Contract = 'ToolCallControl'; ParameterType = 'scriptblock'; Expected = $false }
        @{ Contract = 'ToolCallApprover'; ParameterType = 'scriptblock'; Expected = $true }
        @{ Contract = 'ToolCallApprover'; ParameterType = 'hashtable'; Expected = $false }
    ) {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        try {
            $null = $shell.AddScript(('function global:Invoke-Shp {{ param([{0}]${1}) }}' -f $ParameterType, $Contract))
            $shell.Invoke() | Out-Null
            Test-DpToolCallApprovalSupport -Runspace $runspace | Should -Be $Expected
        }
        finally { $shell.Dispose(); $runspace.Dispose() }
    }
}

Describe 'Modern Engine decision translation' {
    BeforeEach {
        $context = @{
            conversationId = 'c_0123456789'; turnId = 'm_abcdef0123'
            project = 'Fixture'; workingDirectory = [string]$TestDrive
            permissions = @{ file = $true; mcp = $true; userTools = $true; terminal = $false; askUser = $true; browsing = $true }
            workspaceToolsOwned = $true; terminalApprovalActive = $false
        }
        $bridge = [pscustomobject]@{ Enabled = $true; Cancelled = $false; Captured = ''; Requests = 0; Reply = '{"decision":"approve","scope":"once"}' }
        $bridge | Add-Member ScriptMethod CaptureQuestion { param($text); $this.Captured = $text }
        $bridge | Add-Member ScriptMethod RequestAnswer { param($seconds); $this.Requests++; $this.Reply }
        $request = @{
            SchemaVersion = 1; Phase = 'Pre'; Tool = 'write_file'; Origin = 'BuiltIn'; Trust = 'ModuleAuthored'
            RunId = 'run-1'; TurnId = 'iteration-1'; RequestId = 'request-1'; ToolCallId = 'call-1'; Server = ''
            OriginalArguments = '{"path":"unapproved.txt","content":"private-original"}'
            EffectiveArguments = '{"path":"approved.txt","content":"private-effective"}'
        }
    }

    It 'maps an allowed File change to the current decision vocabulary and effective bytes' {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        $decision = Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge
        $decision.Decision | Should -BeExactly 'allow'
        $bridge.Requests | Should -Be 1
        $card = $bridge.Captured | ConvertFrom-Json
        $card.summary.filePath | Should -BeExactly (Join-Path $TestDrive 'approved.txt')
        $bridge.Captured | Should -Not -Match 'unapproved|private-original|private-effective'
        $decision.ContainsKey('Arguments') | Should -BeFalse
    }

    It 'does not collapse two effective actions that have the same original arguments' {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        $null = Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge
        $fingerprint = ($bridge.Captured | ConvertFrom-Json).fingerprint
        $request.EffectiveArguments = '{"path":"approved.txt","content":"different-effective"}'
        $null = Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge
        ($bridge.Captured | ConvertFrom-Json).fingerprint | Should -Not -BeExactly $fingerprint
    }

    It 'requires a prompt for MCP and resolves the original identity from captured registration metadata' {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        $request.Tool = 'mcp_fixture_admin_tools_list'; $request.Origin = 'Mcp'; $request.Trust = 'ThirdParty'; $request.Server = 'fixture'
        $request.EffectiveArguments = '{}'
        $map = @{ mcp_fixture_admin_tools_list = @{ Server = 'fixture'; Tool = 'admin.tools.list' } }
        $decision = Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge -McpToolMap $map
        $decision.Decision | Should -BeExactly 'allow'
        $bridge.Requests | Should -Be 1
        ($bridge.Captured | ConvertFrom-Json).summary.action | Should -BeExactly 'fixture / admin.tools.list'
    }

    It 'refuses an unknown MCP identity instead of reversing a lossy namespaced name' {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        $request.Tool = 'mcp_fixture_admin_tools_list'; $request.Origin = 'Mcp'; $request.Trust = 'ThirdParty'; $request.Server = 'other'
        $map = @{ mcp_fixture_admin_tools_list = @{ Server = 'fixture'; Tool = 'admin.tools.list' } }
        (Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge -McpToolMap $map).Decision | Should -BeExactly 'deny'
        $bridge.Requests | Should -Be 0
    }

    It 'preserves read-only built-in behavior while checking its category Permission' {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        $request.Tool = 'read_file'
        (Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge).Decision | Should -BeExactly 'allow'
        $context.permissions.file = $false
        (Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge).Decision | Should -BeExactly 'deny'
        $bridge.Requests | Should -Be 0
    }

    It 'does not waive owned edit Tool authorization when User Tools is disabled' {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        $request.Tool = 'replace_in_file'; $request.Origin = 'User'; $request.Trust = 'CallerRegistered'
        $context.permissions.userTools = $false
        (Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge).Decision | Should -BeExactly 'deny'
        $bridge.Requests | Should -Be 0
    }

    It 'fails closed for unsupported <Field> metadata' -ForEach @(
        @{ Field = 'SchemaVersion'; Value = 2 }
        @{ Field = 'SchemaVersion'; Value = '1' }
        @{ Field = 'Phase'; Value = 'Post' }
        @{ Field = 'Trust'; Value = 'Unknown' }
        @{ Field = 'Origin'; Value = 'Unknown' }
        @{ Field = 'Tool'; Value = 'unknown_builtin' }
        @{ Field = 'EffectiveArguments'; Value = '[1,2]' }
        @{ Field = 'EffectiveArguments'; Value = '{broken' }
        @{ Field = 'EffectiveArguments'; Value = ('x' * 262145) }
        @{ Field = 'ToolCallId'; Value = '' }
    ) {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        $request[$Field] = $Value
        (Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge).Decision | Should -BeExactly 'deny'
        $bridge.Requests | Should -Be 0
    }

    It 'validates <_> before allowing a read-only Tool' -ForEach @('RunId', 'TurnId', 'RequestId') {
        $request.Tool = 'read_file'
        $request[$_] = ''
        (Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge).Decision | Should -BeExactly 'deny'
        $bridge.Requests | Should -Be 0
    }

    It 'retains cancellation, user denial and once-only scope semantics' -ForEach @('cancel', 'deny', 'turn') {
        [bool](Get-Command Invoke-DpToolCallControl -ErrorAction SilentlyContinue) | Should -BeTrue
        switch ($_) {
            cancel { $bridge.Cancelled = $true }
            deny { $bridge.Reply = '{"decision":"deny"}' }
            turn { $bridge.Reply = '{"decision":"approve","scope":"turn"}' }
        }
        (Invoke-DpToolCallControl -Request $request -Context $context -Bridge $bridge).Decision | Should -BeExactly 'deny'
    }
}
