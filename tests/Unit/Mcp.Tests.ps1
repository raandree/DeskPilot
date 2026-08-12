#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'ConvertTo-DpMcpServer' {
    It 'normalises a command row and defaults what was not given' {
        $server = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        $server.name | Should -Be 'files'
        $server.source | Should -Be 'command'
        $server.command | Should -Be 'npx'
        $server.enabled | Should -BeTrue
        $server.id | Should -Match '^mcp'
        $server.args | Should -HaveCount 0
        $server.tools | Should -HaveCount 0
    }

    It 'keeps arguments in order and as separate elements' {
        $server = ConvertTo-DpMcpServer -InputObject @{
            name    = 'files'
            command = 'npx'
            args    = @('-y', '@modelcontextprotocol/server-filesystem', 'C:\work with space')
        }
        $server.args | Should -HaveCount 3
        $server.args[2] | Should -Be 'C:\work with space'
    }

    It 'accepts a PSCustomObject as it arrives from JSON' {
        $server = ConvertTo-DpMcpServer -InputObject ([pscustomobject]@{ name = 'gh'; command = 'npx'; enabled = $false })
        $server.name | Should -Be 'gh'
        $server.enabled | Should -BeFalse
    }

    It 'infers the file source from a path' {
        $server = ConvertTo-DpMcpServer -InputObject @{ path = 'C:\mcp.json' }
        $server.source | Should -Be 'file'
    }

    It 'allows a file row with no name, which attaches every entry in the file' {
        $server = ConvertTo-DpMcpServer -InputObject @{ source = 'file'; path = 'C:\mcp.json' }
        $server.name | Should -BeNullOrEmpty
    }

    It 'requires a name for a command row' {
        { ConvertTo-DpMcpServer -InputObject @{ command = 'npx' } } | Should -Throw '*needs a name*'
    }

    It 'requires a command for a command row' {
        { ConvertTo-DpMcpServer -InputObject @{ name = 'files' } } | Should -Throw '*needs a command*'
    }

    It 'requires a path for a file row' {
        { ConvertTo-DpMcpServer -InputObject @{ source = 'file'; name = 'files' } } | Should -Throw '*configuration file*'
    }

    It 'refuses a name the Engine would have to sanitise' -ForEach @(
        @{ Name = 'my server' }
        @{ Name = 'files/read' }
        @{ Name = 'ünïcode' }
        @{ Name = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
    ) {
        { ConvertTo-DpMcpServer -InputObject @{ name = $Name; command = 'npx' } } | Should -Throw '*Invalid MCP server name*'
    }

    It 'refuses an environment variable name that is not one' {
        { ConvertTo-DpMcpServer -InputObject @{ name = 'gh'; command = 'npx'; envKeys = @('GITHUB TOKEN') } } |
            Should -Throw '*Invalid environment variable name*'
    }

    It 'refuses a tool name outside the MCP character set' {
        { ConvertTo-DpMcpServer -InputObject @{ name = 'gh'; command = 'npx'; tools = @('search issues') } } |
            Should -Throw '*Invalid tool name*'
    }

    It 'never carries an environment value, only the key' {
        $server = ConvertTo-DpMcpServer -InputObject @{
            name    = 'gh'
            command = 'npx'
            envKeys = @('GITHUB_TOKEN')
            env     = @{ GITHUB_TOKEN = 'ghp_secret' }
        }
        $server.envKeys | Should -Be @('GITHUB_TOKEN')
        ($server.Values | Where-Object { "$_" -match 'ghp_secret' }) | Should -BeNullOrEmpty
        $server.Keys | Should -Not -Contain 'env'
    }

    It 'drops a duplicate environment key' {
        $server = ConvertTo-DpMcpServer -InputObject @{ name = 'gh'; command = 'npx'; envKeys = @('A', 'A', 'B') }
        $server.envKeys | Should -HaveCount 2
    }
}

Describe 'Get-DpMcpRegisterParameter' {
    BeforeAll {
        $env:DP_MCP_TEST_TOKEN = 'test-value'
    }
    AfterAll {
        Remove-Item Env:\DP_MCP_TEST_TOKEN -ErrorAction SilentlyContinue
    }

    It 'maps a command row onto the Engine command parameter set' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx'; args = @('-y', 'pkg'); cwd = 'C:\work' }
        $parameter = Get-DpMcpRegisterParameter -Server $row
        $parameter.Name | Should -Be 'files'
        $parameter.Command | Should -Be 'npx'
        $parameter.Argument | Should -Be @('-y', 'pkg')
        $parameter.WorkingDirectory | Should -Be 'C:\work'
        $parameter.Force | Should -BeTrue
        $parameter.Keys | Should -Not -Contain 'Path'
    }

    It 'maps a file row onto the Engine path parameter set' {
        $row = ConvertTo-DpMcpServer -InputObject @{ source = 'file'; path = 'C:\mcp.json'; name = 'files' }
        $parameter = Get-DpMcpRegisterParameter -Server $row
        $parameter.Path | Should -Be 'C:\mcp.json'
        $parameter.Name | Should -Be 'files'
        $parameter.Keys | Should -Not -Contain 'Command'
    }

    It 'omits the name for a file row that attaches every entry' {
        $row = ConvertTo-DpMcpServer -InputObject @{ source = 'file'; path = 'C:\mcp.json' }
        (Get-DpMcpRegisterParameter -Server $row).Keys | Should -Not -Contain 'Name'
    }

    It 'resolves an environment value from the host environment at registration' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'gh'; command = 'npx'; envKeys = @('DP_MCP_TEST_TOKEN') }
        (Get-DpMcpRegisterParameter -Server $row).Environment['DP_MCP_TEST_TOKEN'] | Should -Be 'test-value'
    }

    It 'leaves out a variable that is not set rather than passing an empty one' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'gh'; command = 'npx'; envKeys = @('DP_MCP_DEFINITELY_UNSET') }
        (Get-DpMcpRegisterParameter -Server $row).Keys | Should -Not -Contain 'Environment'
    }

    It 'narrows the offered tools only when the row names some' {
        $bare = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        (Get-DpMcpRegisterParameter -Server $bare).Keys | Should -Not -Contain 'ToolName'

        $narrowed = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx'; tools = @('read_text_file') }
        (Get-DpMcpRegisterParameter -Server $narrowed).ToolName | Should -Be @('read_text_file')
    }
}

Describe 'Get-DpMcpFingerprint' {
    BeforeAll {
        $env:DP_MCP_FP_TOKEN = 'first'
    }
    AfterAll {
        Remove-Item Env:\DP_MCP_FP_TOKEN -ErrorAction SilentlyContinue
    }

    It 'is stable for the same definition' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx'; args = @('-y', 'pkg') }
        Get-DpMcpFingerprint -Server $row | Should -Be (Get-DpMcpFingerprint -Server $row)
    }

    It 'changes when an argument changes' {
        $before = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx'; args = @('-y', 'pkg') }
        $after = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx'; args = @('-y', 'other') }
        Get-DpMcpFingerprint -Server $before | Should -Not -Be (Get-DpMcpFingerprint -Server $after)
    }

    It 'changes when an environment value changes, so a rotated token re-attaches' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'gh'; command = 'npx'; envKeys = @('DP_MCP_FP_TOKEN') }
        $before = Get-DpMcpFingerprint -Server $row
        $env:DP_MCP_FP_TOKEN = 'second'
        Get-DpMcpFingerprint -Server $row | Should -Not -Be $before
    }

    It 'never contains the environment value itself' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'gh'; command = 'npx'; envKeys = @('DP_MCP_FP_TOKEN') }
        Get-DpMcpFingerprint -Server $row | Should -Not -Match 'first|second'
    }

    It 'ignores the row id and the enabled flag' {
        $a = ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx'; enabled = $true }
        $b = ConvertTo-DpMcpServer -InputObject @{ id = 'mcp2'; name = 'files'; command = 'npx'; enabled = $false }
        Get-DpMcpFingerprint -Server $a | Should -Be (Get-DpMcpFingerprint -Server $b)
    }
}

Describe 'ConvertTo-DpMcpServerView' {
    It 'maps the Engine record onto the panel shape' {
        $view = ConvertTo-DpMcpServerView -InputObject ([pscustomobject]@{
                Name             = 'files'
                State            = 'Ready'
                Running          = $true
                Transport        = 'stdio'
                Era              = 'legacy'
                ProtocolVersion  = '2025-11-25'
                ToolCount        = 2
                Tools            = @('mcp_files_read', 'mcp_files_write')
                EnvironmentKey   = @('GITHUB_TOKEN')
                SandboxRequested = $true
                ServerName       = 'filesystem'
                ProcessId        = 4242
                FaultReason      = ''
            })
        $view.name | Should -Be 'files'
        $view.toolCount | Should -Be 2
        $view.tools | Should -HaveCount 2
        $view.sandboxRequested | Should -BeTrue
        $view.environmentKeys | Should -Be @('GITHUB_TOKEN')
        $view.processId | Should -Be '4242'
    }

    It 'returns nothing for a missing record' {
        ConvertTo-DpMcpServerView -InputObject $null | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DpActivityAction for MCP tools' {
    It 'gives a tool from an attached server its own kind' {
        $action = ConvertTo-DpActivityAction -Tool 'mcp_files_read_text_file' -Arguments '{"path":"C:\\secret.txt"}'
        $action.kind | Should -Be 'mcp'
        $action.tool | Should -Be 'mcp_files_read_text_file'
    }

    It 'derives no detail from a third-party argument shape' {
        $action = ConvertTo-DpActivityAction -Tool 'mcp_gh_search_issues' -Arguments '{"query":"is:open","token":"ghp_secret"}'
        $action.detail | Should -BeNullOrEmpty
    }

    It 'still classifies a built-in tool as before' {
        (ConvertTo-DpActivityAction -Tool 'read_file' -Arguments '{"path":"a.txt"}').kind | Should -Be 'read'
    }
}

Describe 'Merge-DpSettings with MCP settings' {
    BeforeEach {
        $current = Get-DpDefaultSettings
    }

    It 'defaults to no servers and the permission on' {
        $current.mcpServers | Should -HaveCount 0
        $current.permissions.mcp | Should -BeTrue
    }

    It 'accepts and normalises a configured server' {
        $merged = Merge-DpSettings -Current $current -Patch @{
            mcpServers = @(@{ name = 'files'; command = 'npx'; args = @('-y', 'pkg') })
        }
        $merged.mcpServers | Should -HaveCount 1
        $merged.mcpServers[0].name | Should -Be 'files'
        $merged.mcpServers[0].source | Should -Be 'command'
    }

    It 'refuses two servers sharing one name' {
        { Merge-DpSettings -Current $current -Patch @{
                mcpServers = @(
                    @{ name = 'files'; command = 'npx' }
                    @{ name = 'files'; command = 'node' }
                )
            } } | Should -Throw '*Duplicate MCP server name*'
    }

    It 'allows several unnamed file rows' {
        $merged = Merge-DpSettings -Current $current -Patch @{
            mcpServers = @(
                @{ source = 'file'; path = 'C:\a.json' }
                @{ source = 'file'; path = 'C:\b.json' }
            )
        }
        $merged.mcpServers | Should -HaveCount 2
    }

    It 'bounds how many servers can be configured' {
        $many = 1..21 | ForEach-Object { @{ name = "s$_"; command = 'npx' } }
        { Merge-DpSettings -Current $current -Patch @{ mcpServers = $many } } | Should -Throw '*At most 20*'
    }

    It 'rejects a bad row instead of dropping it' {
        { Merge-DpSettings -Current $current -Patch @{ mcpServers = @(@{ name = 'files' }) } } |
            Should -Throw '*needs a command*'
    }

    It 'accepts the mcp permission and still rejects an unknown one' {
        (Merge-DpSettings -Current $current -Patch @{ permissions = @{ mcp = $false } }).permissions.mcp | Should -BeFalse
        { Merge-DpSettings -Current $current -Patch @{ permissions = @{ nope = $true } } } | Should -Throw '*Unknown permission*'
    }

    It 'carries a configured server through an unrelated patch' {
        $withServer = Merge-DpSettings -Current $current -Patch @{ mcpServers = @(@{ name = 'files'; command = 'npx' }) }
        (Merge-DpSettings -Current $withServer -Patch @{ showThinking = $true }).mcpServers | Should -HaveCount 1
    }
}

Describe 'Get-DpMcpContext' {
    It 'says nothing at all on an Engine without MCP' {
        Get-DpMcpContext -Server @() | Should -BeNullOrEmpty
    }

    It 'states that none are attached, and that another program''s config is not DeskPilot''s' {
        $text = Get-DpMcpContext -Server @() -Supported
        $text | Should -Match 'No MCP servers are attached'
        $text | Should -Match 'mcp\.json'
        $text | Should -Match 'not.*DeskPilot'
    }

    It 'names each attached server, its tool count and its prefix' {
        $text = Get-DpMcpContext -Supported -Server @(
            @{ name = 'files'; toolCount = 12; running = $true; state = 'Ready' }
            @{ name = 'gh'; toolCount = 5; running = $true; state = 'Ready' }
        )
        $text | Should -Match 'files: 12 tool'
        $text | Should -Match 'mcp_files_\*'
        $text | Should -Match 'gh: 5 tool'
        $text | Should -Not -Match 'No MCP servers are attached'
    }

    It 'marks a stopped server rather than offering it as usable' {
        $text = Get-DpMcpContext -Supported -Server @(
            @{ name = 'files'; toolCount = 0; running = $false; state = 'Faulted' }
        )
        $text | Should -Match 'stopped'
    }

    It 'says the tool list is fixed, because the Engine freezes it at attachment' {
        $text = Get-DpMcpContext -Supported -Server @(@{ name = 'files'; toolCount = 1; running = $true; state = 'Ready' })
        $text | Should -Match 'fixed when it was attached'
    }
}

Describe 'New-DpTurnParameter and the MCP permission' {
    BeforeEach {
        $settings = Get-DpDefaultSettings
    }

    It 'passes no switch while the permission is on' {
        $params = New-DpTurnParameter -Prompt 'hi' -Settings $settings -McpSupported
        $params.Keys | Should -Not -Contain 'DisableMcp'
    }

    It 'withholds MCP tools for the Turn when the permission is off' {
        $settings.permissions.mcp = $false
        (New-DpTurnParameter -Prompt 'hi' -Settings $settings -McpSupported).DisableMcp | Should -BeTrue
    }

    It 'never sends the switch to an Engine that does not have it' {
        $settings.permissions.mcp = $false
        (New-DpTurnParameter -Prompt 'hi' -Settings $settings).Keys | Should -Not -Contain 'DisableMcp'
    }

    It 'leaves the other permission switches alone' {
        $settings.permissions.mcp = $false
        $params = New-DpTurnParameter -Prompt 'hi' -Settings $settings -McpSupported
        $params.Keys | Should -Not -Contain 'DisableUserTools'
        $params.DisableTerminal | Should -BeTrue
    }

    It 'puts DeskPilot''s MCP position in the system prompt' {
        $context = Get-DpMcpContext -Server @() -Supported
        $params = New-DpTurnParameter -Prompt 'hi' -Settings $settings -McpSupported -McpContext $context
        $params.SystemPrompt | Should -Match 'No MCP servers are attached'
    }

    It 'omits the block on an Engine that has no MCP at all' {
        $params = New-DpTurnParameter -Prompt 'hi' -Settings $settings -McpContext 'MCP servers attached to DeskPilot:'
        $params.SystemPrompt | Should -Not -Match 'MCP servers attached'
    }
}

Describe 'Sync-DpMcpServer' {
    BeforeEach {
        $script:live = @()
        $script:registered = [System.Collections.Generic.List[hashtable]]::new()
        $script:unregistered = [System.Collections.Generic.List[string]]::new()
        $script:DeskPilot = @{
            Engine = @{ McpSupported = $true }
            Mcp    = @{ Rows = @{} }
        }

        Mock Invoke-DpEngineCommand {
            switch ($Command) {
                'Get-ShpMcpServer' { return $script:live }
                'Register-ShpMcpServer' {
                    $script:registered.Add($Parameter)
                    $name = if ($Parameter.ContainsKey('Name')) { $Parameter.Name } else { 'fromfile' }
                    $script:live = @($script:live) + [pscustomobject]@{
                        Name = $name; State = 'Ready'; Running = $true; ToolCount = 3
                        Tools = @("mcp_${name}_alpha"); Era = 'legacy'; ProtocolVersion = '2025-11-25'
                    }
                    return @()
                }
                'Unregister-ShpMcpServer' {
                    $script:unregistered.Add([string]$Parameter.Name)
                    $script:live = @($script:live | Where-Object { $_.Name -ne $Parameter.Name })
                    return @()
                }
            }
            return @()
        }
    }

    It 'does nothing at all on an Engine without MCP' {
        $script:DeskPilot.Engine.McpSupported = $false
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        Sync-DpMcpServer -Server @($row) | Should -HaveCount 0
        Should -Invoke Invoke-DpEngineCommand -Times 0
    }

    It 'attaches a newly configured server and reports its tools' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        $result = @(Sync-DpMcpServer -Server @($row))
        $result | Should -HaveCount 1
        $result[0].ok | Should -BeTrue
        $result[0].servers[0].name | Should -Be 'files'
        $script:registered | Should -HaveCount 1
    }

    It 'leaves an unchanged server running instead of restarting it' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        $null = Sync-DpMcpServer -Server @($row)
        $null = Sync-DpMcpServer -Server @($row)
        $script:registered | Should -HaveCount 1
    }

    It 're-attaches an unchanged server when a refresh is forced' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        $null = Sync-DpMcpServer -Server @($row)
        $null = Sync-DpMcpServer -Server @($row) -Force
        $script:registered | Should -HaveCount 2
    }

    It 're-attaches a server whose definition changed' {
        $before = ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx' }
        $null = Sync-DpMcpServer -Server @($before)
        $after = ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx'; args = @('-y') }
        $null = Sync-DpMcpServer -Server @($after)
        $script:registered | Should -HaveCount 2
    }

    It 'detaches a server the user removed' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        $null = Sync-DpMcpServer -Server @($row)
        $null = Sync-DpMcpServer -Server @()
        $script:unregistered | Should -Contain 'files'
        $script:live | Should -HaveCount 0
    }

    It 'detaches a server the user switched off but keeps the row' {
        $row = ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx' }
        $null = Sync-DpMcpServer -Server @($row)
        $off = ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx'; enabled = $false }
        $result = @(Sync-DpMcpServer -Server @($off))
        $script:unregistered | Should -Contain 'files'
        $result | Should -HaveCount 1
        $result[0].servers | Should -HaveCount 0
    }

    It 'detaches a leftover server no configured row owns' {
        $script:live = @([pscustomobject]@{ Name = 'orphan'; State = 'Ready'; Running = $true; ToolCount = 1 })
        $null = Sync-DpMcpServer -Server @()
        $script:unregistered | Should -Contain 'orphan'
    }

    It 're-attaches a server that has faulted' {
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        $null = Sync-DpMcpServer -Server @($row)
        $script:live = @([pscustomobject]@{ Name = 'files'; State = 'Faulted'; Running = $false; ToolCount = 0 })
        $null = Sync-DpMcpServer -Server @($row)
        $script:registered | Should -HaveCount 2
    }

    It 'reports a failed registration against its row without throwing' {
        Mock Invoke-DpEngineCommand {
            switch ($Command) {
                'Get-ShpMcpServer' { return @() }
                'Register-ShpMcpServer' { throw 'the server exited before it answered' }
            }
            return @()
        }
        $row = ConvertTo-DpMcpServer -InputObject @{ name = 'files'; command = 'npx' }
        $result = @(Sync-DpMcpServer -Server @($row))
        $result[0].ok | Should -BeFalse
        $result[0].error | Should -Match 'exited before it answered'
    }
}

Describe 'Get-DpMcpState' {
    BeforeEach {
        $script:DeskPilot = @{
            Engine = @{ McpSupported = $true }
            Mcp    = @{ Rows = @{ 'mcp1' = @{ fingerprint = 'x'; names = @('files') } } }
        }
        Mock Invoke-DpEngineCommand {
            @([pscustomobject]@{ Name = 'files'; State = 'Ready'; Running = $true; ToolCount = 3; Tools = @('mcp_files_read') })
        }
    }

    It 'pairs a configured row with the server it attached' {
        $settings = Get-DpDefaultSettings
        $settings.mcpServers = @(ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx' })
        $payload = Get-DpMcpState -Settings $settings
        $payload.supported | Should -BeTrue
        $payload.enabled | Should -BeTrue
        $payload.servers | Should -HaveCount 1
        $payload.servers[0].attached[0].toolCount | Should -Be 3
    }

    It 'reports a row that never started with no attached server' {
        $script:DeskPilot.Mcp.Rows = @{}
        $settings = Get-DpDefaultSettings
        $settings.mcpServers = @(ConvertTo-DpMcpServer -InputObject @{ id = 'mcp9'; name = 'broken'; command = 'nope' })
        $payload = Get-DpMcpState -Settings $settings
        $payload.servers[0].attached | Should -HaveCount 0
    }

    It 'carries a sync failure onto the row that caused it' {
        $settings = Get-DpDefaultSettings
        $settings.mcpServers = @(ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx' })
        $payload = Get-DpMcpState -Settings $settings -SyncResult @(@{ id = 'mcp1'; name = 'files'; ok = $false; error = 'boom' })
        $payload.servers[0].error | Should -Be 'boom'
    }

    It 'reports an Engine without MCP support and asks the Engine nothing' {
        $script:DeskPilot.Engine.McpSupported = $false
        $payload = Get-DpMcpState -Settings (Get-DpDefaultSettings)
        $payload.supported | Should -BeFalse
        Should -Invoke Invoke-DpEngineCommand -Times 0
    }

    It 'never emits an environment value' {
        $settings = Get-DpDefaultSettings
        $settings.mcpServers = @(ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx'; envKeys = @('GITHUB_TOKEN') })
        ($payload = Get-DpMcpState -Settings $settings) | Out-Null
        ($payload | ConvertTo-Json -Depth 8) | Should -Not -Match 'ghp_'
        $payload.servers[0].envKeys | Should -Be @('GITHUB_TOKEN')
    }
}
