BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Terminal Turn approval routes' {
    BeforeEach {
        $script:prior = $script:DeskPilot
        $script:bridge = [pscustomobject]@{ Answer = ''; Cancelled = $false }
        $script:bridge | Add-Member -MemberType ScriptMethod -Name SubmitAnswer -Value {
            param($ConversationId, $RequestId, $Answer)
            if ($this.Cancelled -or $ConversationId -cne 'c-1' -or $RequestId -cne 'request-1') { return $false }
            $this.Answer = $Answer
            $true
        }
        $script:bridge | Add-Member -MemberType ScriptMethod -Name Cancel -Value { $this.Cancelled = $true }
        $settings = Get-DpDefaultSettings
        $settings.permissions.terminal = $true
        $settings.perCallApproval = $true
        $request = New-DpApprovalRequest -Tool 'run_terminal_command' -Class 'Terminal' -Argument @{
            command = 'npm test'; workingDirectory = $TestDrive; policyId = 'policy-1'
        } -ProjectName 'Alpha' -ConversationId 'c-1' -TurnId 't-1'
        $script:DeskPilot = @{
            TurnRunning = $true; CancelRequested = $false; Settings = $settings; DataDir = $TestDrive
            Conversations = @{ 'c-1' = @{ id = 'c-1' }; 'c-2' = @{ id = 'c-2' } }
            Engine = @{ ApprovalBridge = $script:bridge; TerminalSession = $null }
            PendingApproval = @{ id = 'request-1'; conversationId = 'c-1'; request = $request }
            Diagnostics = @{ Log = New-DpDiagnosticLog }
        }
        $script:stream = [IO.MemoryStream]::new()
        Mock Save-DpSettings {}
    }

    AfterEach {
        $script:stream.Dispose()
        $script:DeskPilot = $script:prior
    }

    It 'passes explicit Turn scope only for the matching live Terminal request' {
        Invoke-DpRouteHandler -Name submitApproval -RouteParams @{ id = 'c-1' } -Body @{
            requestId = 'request-1'; decision = 'approve'; scope = 'turn'
        } -Stream $script:stream

        [Text.Encoding]::UTF8.GetString($script:stream.ToArray()) | Should -Match '^HTTP/1.1 202'
        ($script:bridge.Answer | ConvertFrom-Json).scope | Should -BeExactly 'turn'
        $script:DeskPilot.PendingApproval | Should -BeNullOrEmpty
    }

    It 'keeps omitted scope backward compatible as once' {
        Invoke-DpRouteHandler -Name submitApproval -RouteParams @{ id = 'c-1' } -Body @{
            requestId = 'request-1'; decision = 'approve'
        } -Stream $script:stream

        [Text.Encoding]::UTF8.GetString($script:stream.ToArray()) | Should -Match '^HTTP/1.1 202'
        ($script:bridge.Answer | ConvertFrom-Json).scope | Should -BeExactly 'once'
    }

    It 'refuses Turn scope for <Case>' -ForEach @(
        @{ Case = 'browser navigation'; Change = 'class'; Value = 'BrowserNavigation' }
        @{ Case = 'browser action'; Change = 'class'; Value = 'BrowserAction' }
        @{ Case = 'MCP'; Change = 'class'; Value = 'Mcp' }
        @{ Case = 'File write'; Change = 'class'; Value = 'FileWrite' }
        @{ Case = 'missing pending request'; Change = 'pending'; Value = $null }
        @{ Case = 'a different request'; Change = 'request'; Value = 'request-2' }
        @{ Case = 'a different Conversation'; Change = 'conversation'; Value = 'c-2' }
        @{ Case = 'Terminal disabled'; Change = 'permission'; Value = 'terminal' }
        @{ Case = 'User Tools disabled'; Change = 'permission'; Value = 'userTools' }
        @{ Case = 'a denied action'; Change = 'decision'; Value = 'deny' }
        @{ Case = 'unknown scope'; Change = 'scope'; Value = 'permanent' }
        @{ Case = 'array scope'; Change = 'scope'; Value = @('turn') }
    ) {
        $body = @{ requestId = 'request-1'; decision = 'approve'; scope = 'turn' }
        $conversationId = 'c-1'
        switch ($Change) {
            'class' { $script:DeskPilot.PendingApproval.request.class = $Value }
            'pending' { $script:DeskPilot.PendingApproval = $null }
            'request' { $body.requestId = $Value }
            'conversation' { $conversationId = $Value }
            'permission' { $script:DeskPilot.Settings.permissions[$Value] = $false }
            'decision' { $body.decision = $Value }
            'scope' { $body.scope = $Value }
        }
        Invoke-DpRouteHandler -Name submitApproval -RouteParams @{ id = $conversationId } -Body $body -Stream $script:stream

        [Text.Encoding]::UTF8.GetString($script:stream.ToArray()) | Should -Match '^HTTP/1.1 (400|409)'
        $script:bridge.Answer | Should -BeNullOrEmpty
    }

    It 'retains the offered scope on a reloaded approval card' {
        Invoke-DpRouteHandler -Name getApproval -RouteParams @{ id = 'c-1' } -Stream $script:stream
        $response = [Text.Encoding]::UTF8.GetString($script:stream.ToArray())
        $body = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json

        @($body.allowedScopes) | Should -Be @('once', 'turn')
    }

    It 'revokes the active approval on <Case>' -ForEach @(
        @{ Case = 'Terminal Permission off'; Patch = @{ permissions = @{ terminal = $false } } }
        @{ Case = 'User Tools Permission off'; Patch = @{ permissions = @{ userTools = $false } } }
        @{ Case = 'approval disabled'; Patch = @{ perCallApproval = $false } }
        @{ Case = 'Project changed'; Patch = @{ workspaceFolder = 'C:\changed-project' } }
        @{ Case = 'execution mode changed'; Patch = @{ terminalExecution = @{ mode = 'isolated' } } }
        @{ Case = 'Project access changed'; Patch = @{ terminalExecution = @{ projectAccess = 'read-write' } } }
        @{ Case = 'network policy changed'; Patch = @{ terminalExecution = @{ network = 'allow-list'; allowedHosts = @('example.com') } } }
        @{ Case = 'allowed host changed'; Patch = @{ terminalExecution = @{ allowedHosts = @('example.com') } } }
        @{ Case = 'environment grant changed'; Patch = @{ terminalExecution = @{ environment = @(@{ name = 'DP_TOKEN'; secret = $true }) } } }
        @{ Case = 'execution limit changed'; Patch = @{ terminalExecution = @{ timeoutSeconds = 60 } } }
        @{ Case = 'CPU limit changed'; Patch = @{ terminalExecution = @{ cpuCount = 2.0 } } }
        @{ Case = 'memory limit changed'; Patch = @{ terminalExecution = @{ memoryMB = 2048 } } }
        @{ Case = 'process limit changed'; Patch = @{ terminalExecution = @{ processLimit = 65 } } }
        @{ Case = 'output limit changed'; Patch = @{ terminalExecution = @{ outputBytes = 2097152 } } }
        @{ Case = 'temporary storage limit changed'; Patch = @{ terminalExecution = @{ tempMB = 256 } } }
    ) {
        Invoke-DpRouteHandler -Name putSettings -Body $Patch -Stream $script:stream

        [Text.Encoding]::UTF8.GetString($script:stream.ToArray()) | Should -Match '^HTTP/1.1 200'
        $script:bridge.Cancelled | Should -BeTrue
        $script:DeskPilot.PendingApproval | Should -BeNullOrEmpty
    }

    It 'preserves the grant for unrelated Settings changes' {
        Invoke-DpRouteHandler -Name putSettings -Body @{ showThinking = $true } -Stream $script:stream

        [Text.Encoding]::UTF8.GetString($script:stream.ToArray()) | Should -Match '^HTTP/1.1 200'
        $script:bridge.Cancelled | Should -BeFalse
    }

    It 'revokes approval when Intercom selects a different Project' {
        $script:DeskPilot.Settings = Merge-DpSettings -Current $script:DeskPilot.Settings -Patch @{
            projects = @(@{ id = 'alpha'; name = 'Alpha'; path = $TestDrive }, @{ id = 'beta'; name = 'Beta'; path = (Join-Path $TestDrive 'beta') })
            selectedProjectId = 'alpha'
        }
        $script:DeskPilot.Intercom = @{ ReplyChatId = 'operator' }
        Mock Get-DpIntercomProjectList { @(@{ id = 'beta'; name = 'Beta'; path = (Join-Path $TestDrive 'beta'); remote = $false }) }
        Mock Test-DpIntercomChat { @{ group = $false } }
        Mock Send-DpIntercomMessage {}

        Switch-DpIntercomProject -ProjectId 'beta'

        $script:DeskPilot.Settings.selectedProjectId | Should -BeExactly 'beta'
        $script:bridge.Cancelled | Should -BeTrue
        $script:DeskPilot.PendingApproval | Should -BeNullOrEmpty
    }

    It 'revokes approval when Intercom registers and selects a Project' {
        $path = Join-Path $TestDrive 'registered-project'
        $null = New-Item -ItemType Directory -Path $path
        Mock Get-DpIntercomProjectList { @() }
        Mock Test-DpIntercomProject { @{ allowed = $true } }
        Mock Send-DpIntercomMessage {}

        New-DpIntercomProject -Path $path

        $script:DeskPilot.Settings.workspaceFolder | Should -BeExactly $path
        $script:bridge.Cancelled | Should -BeTrue
        $script:DeskPilot.PendingApproval | Should -BeNullOrEmpty
    }

    It 'revokes approval immediately when Intercom stops the Turn' {
        $script:DeskPilot.Intercom = @{ Counters = @{ received = 0; accepted = 0; rejected = 0 }; PendingQuestion = $null }
        $script:DeskPilot.Engine.UserPromptBridge = $null
        Mock Send-DpIntercomMessage {}
        Mock Add-DpIntercomLog {}

        Invoke-DpIntercomCommand -Command @{ kind = 'stop'; text = ''; chatId = 'operator'; fromName = 'Operator' }

        $script:DeskPilot.CancelRequested | Should -BeTrue
        $script:bridge.Cancelled | Should -BeTrue
    }
}