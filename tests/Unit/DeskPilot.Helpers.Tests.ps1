#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Get-DpUpdateNotice' {
    It 'returns a notice when the Gallery version is newer' {
        $notice = Get-DpUpdateNotice -CurrentVersion '0.2.0' -LatestVersion '0.3.0'
        $notice | Should -Not -BeNullOrEmpty
        $notice | Should -Match '0\.3\.0'
        $notice | Should -Match 'Update-Module DeskPilot'
    }
    It 'returns null when the running version is current' {
        Get-DpUpdateNotice -CurrentVersion '0.3.0' -LatestVersion '0.3.0' | Should -BeNullOrEmpty
    }
    It 'returns null when the running version is newer than the Gallery' {
        Get-DpUpdateNotice -CurrentVersion '0.4.0' -LatestVersion '0.3.0' | Should -BeNullOrEmpty
    }
    It 'returns null when the latest version is unknown or unparseable' -ForEach @(
        @{ Latest = '' }
        @{ Latest = $null }
        @{ Latest = 'not-a-version' }
    ) {
        Get-DpUpdateNotice -CurrentVersion '0.2.0' -LatestVersion $Latest | Should -BeNullOrEmpty
    }
    It 'returns null when the current version is unparseable' {
        Get-DpUpdateNotice -CurrentVersion 'x' -LatestVersion '0.3.0' | Should -BeNullOrEmpty
    }
}

Describe 'Get-DpDefaultSettings' {
    It 'returns Terminal off and Browsing/File on by default' {
        $s = Get-DpDefaultSettings
        $s.permissions.terminal | Should -BeFalse
        $s.permissions.browsing | Should -BeTrue
        $s.permissions.file | Should -BeTrue
    }
    It 'defaults the tool-iteration cap to 25' {
        (Get-DpDefaultSettings).maxToolIterations | Should -Be 25
    }
    It 'includes a promptRoots array alongside the other Copilot roots' {
        $s = Get-DpDefaultSettings
        $s.ContainsKey('promptRoots') | Should -BeTrue
        , $s.promptRoots | Should -BeOfType [System.Array]
    }
    It 'defaults auto-compaction on at 80% keeping the last 4 messages' {
        $s = Get-DpDefaultSettings
        $s.autoCompaction | Should -BeTrue
        $s.compactionThreshold | Should -Be 0.8
        $s.compactionKeepRecent | Should -Be 4
    }
}

Describe 'Merge-DpSettings' {
    It 'merges a model and a single permission without disturbing others' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{
                model       = 'claude-opus-4.8'
                permissions = [pscustomobject]@{ terminal = $true }
            })
        $merged.model | Should -Be 'claude-opus-4.8'
        $merged.permissions.terminal | Should -BeTrue
        $merged.permissions.file | Should -BeTrue
    }
    It 'does not mutate the input Current object' {
        $current = Get-DpDefaultSettings
        $null = Merge-DpSettings -Current $current -Patch ([pscustomobject]@{ permissions = [pscustomobject]@{ terminal = $true } })
        $current.permissions.terminal | Should -BeFalse
    }
    It 'throws on an unknown setting' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ nope = 1 }) } |
            Should -Throw -ExpectedMessage "*Unknown setting 'nope'.*"
    }
    It 'throws on an unknown permission' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ permissions = [pscustomobject]@{ fly = $true } }) } |
            Should -Throw -ExpectedMessage "*Unknown permission 'fly'.*"
    }
    It 'rejects an invalid reasoning effort' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ reasoningEffort = 'turbo' }) } |
            Should -Throw -ExpectedMessage '*Invalid reasoningEffort*'
    }
    It 'rejects a tool-iteration cap below 1' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ maxToolIterations = 0 }) } |
            Should -Throw -ExpectedMessage '*at least 1*'
    }
}

Describe 'Merge-DpSettings auto-compaction' {
    It 'toggles autoCompaction off and on' {
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ autoCompaction = $false })).autoCompaction | Should -BeFalse
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ autoCompaction = $true })).autoCompaction | Should -BeTrue
    }
    It 'accepts an in-range threshold and rounds it to two decimals' {
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ compactionThreshold = 0.75 })).compactionThreshold | Should -Be 0.75
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ compactionThreshold = 0.833 })).compactionThreshold | Should -Be 0.83
    }
    It 'rejects a threshold below 0.5 or above 0.95' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ compactionThreshold = 0.4 }) } |
            Should -Throw -ExpectedMessage '*between 0.5 and 0.95*'
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ compactionThreshold = 0.99 }) } |
            Should -Throw -ExpectedMessage '*between 0.5 and 0.95*'
    }
    It 'accepts an in-range keep-recent count' {
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ compactionKeepRecent = 12 })).compactionKeepRecent | Should -Be 12
    }
    It 'rejects a keep-recent count below 2 or above 100' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ compactionKeepRecent = 1 }) } |
            Should -Throw -ExpectedMessage '*between 2 and 100*'
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ compactionKeepRecent = 101 }) } |
            Should -Throw -ExpectedMessage '*between 2 and 100*'
    }
}

Describe 'ConvertTo-DpSseFrame' {
    It 'builds an event/data frame terminated by a blank line' {
        $frame = ConvertTo-DpSseFrame -EventName 'delta' -Data @{ text = 'hi' }
        $frame | Should -Be "event: delta`ndata: {`"text`":`"hi`"}`n`n"
    }
    It 'flattens newlines in the payload' {
        $frame = ConvertTo-DpSseFrame -EventName 'x' -Data "line1`nline2"
        $frame | Should -Not -Match "data:.*`n.*line2"
    }
}

Describe 'Get-DpRouteMatch' {
    BeforeAll {
        $routes = @(
            @{ Method = 'GET'; Pattern = '/api/conversations'; Name = 'list' }
            @{ Method = 'GET'; Pattern = '/api/conversations/{id}'; Name = 'get' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/messages'; Name = 'post' }
        )
    }
    It 'captures a path parameter' {
        $m = Get-DpRouteMatch -Method 'POST' -Path '/api/conversations/c_9/messages' -Route $routes
        $m.Route.Name | Should -Be 'post'
        $m.Params.id | Should -Be 'c_9'
    }
    It 'does not let a placeholder span a slash' {
        $m = Get-DpRouteMatch -Method 'GET' -Path '/api/conversations/c_1' -Route $routes
        $m.Route.Name | Should -Be 'get'
    }
    It 'returns null when nothing matches' {
        Get-DpRouteMatch -Method 'GET' -Path '/api/none' -Route $routes | Should -BeNullOrEmpty
    }
    It 'respects the HTTP method' {
        Get-DpRouteMatch -Method 'DELETE' -Path '/api/conversations' -Route $routes | Should -BeNullOrEmpty
    }
}

Describe 'New-DpId' {
    It 'prefixes the id' {
        New-DpId -Prefix 'c' | Should -Match '^c_[0-9a-f]{10}$'
    }
}

Describe 'New-DpConversation' {
    It 'creates an empty Conversation with timestamps' {
        $c = New-DpConversation -Title 'Hello'
        $c.title | Should -Be 'Hello'
        $c.messages.Count | Should -Be 0
        $c.id | Should -Match '^c_'
        $c.createdUtc | Should -Not -BeNullOrEmpty
    }
    It 'defaults the organisational flags off and colour unset' {
        $c = New-DpConversation -Title 'Flags'
        $c.pinned | Should -BeFalse
        $c.archived | Should -BeFalse
        $c.unread | Should -BeFalse
        $c.color | Should -BeNullOrEmpty
        $c.compactedUtc | Should -BeNullOrEmpty
    }
}

Describe 'Copy-DpConversation' {
    It 'duplicates title, messages and history into a fresh Conversation' {
        $src = New-DpConversation -Title 'Original' -Model 'm1'
        $src.messages.Add(@{ id = 'm_1'; role = 'user'; text = 'hi' })
        $src.history.Add(@{ role = 'user'; content = 'hi' })
        $src.color = 'blue'
        $src.compactedUtc = '2026-07-07T10:00:00.0000000Z'

        $copy = Copy-DpConversation -Conversation $src

        $copy.id | Should -Not -Be $src.id
        $copy.id | Should -Match '^c_'
        $copy.title | Should -Be 'Copy of Original'
        $copy.titleLocked | Should -BeTrue
        $copy.model | Should -Be 'm1'
        $copy.color | Should -Be 'blue'
        $copy.pinned | Should -BeFalse
        $copy.archived | Should -BeFalse
        $copy.unread | Should -BeFalse
        # A duplicate starts fresh: it inherits no compaction marker.
        $copy.compactedUtc | Should -BeNullOrEmpty
        $copy.messages.Count | Should -Be 1
        $copy.history.Count | Should -Be 1
    }
    It 'shares no state with the source (deep copy)' {
        $src = New-DpConversation -Title 'Original'
        $src.messages.Add(@{ id = 'm_1'; role = 'user'; text = 'hi' })
        $copy = Copy-DpConversation -Conversation $src
        # A new list plus detached objects: neither appends nor edits leak back.
        $copy.messages.Add(@{ id = 'm_2'; role = 'assistant'; text = 'yo' })
        $copy.messages[0].text = 'changed'
        $src.messages.Count | Should -Be 1
        $src.messages[0].text | Should -Be 'hi'
        $copy.messages.Count | Should -Be 2
    }
    It 'honours a custom title prefix' {
        $src = New-DpConversation -Title 'Thing'
        (Copy-DpConversation -Conversation $src -TitlePrefix 'Fork of ').title | Should -Be 'Fork of Thing'
    }
    It 'produces appendable message and history lists' {
        $copy = Copy-DpConversation -Conversation (New-DpConversation -Title 'X')
        { $copy.messages.Add(@{ id = 'm_1' }) } | Should -Not -Throw
        { $copy.history.Add(@{ role = 'user'; content = 'x' }) } | Should -Not -Throw
    }
}

Describe 'New-DpTurnParameter' {
    It 'passes a Disable switch only for a Permission that is off' {
        $p = New-DpTurnParameter -Prompt 'hi' -Settings (Get-DpDefaultSettings)
        $p.ContainsKey('DisableTerminal') | Should -BeTrue
        $p.ContainsKey('DisableBrowsing') | Should -BeFalse
        $p.ContainsKey('DisableFileAccess') | Should -BeFalse
    }
    It 'omits History when empty and includes it when present' {
        (New-DpTurnParameter -Prompt 'hi' -History @() -Settings (Get-DpDefaultSettings)).ContainsKey('History') | Should -BeFalse
        (New-DpTurnParameter -Prompt 'hi' -History @(@{ role = 'user'; content = 'x' }) -Settings (Get-DpDefaultSettings)).ContainsKey('History') | Should -BeTrue
    }
    It 'lets a Conversation Model override the Settings Model' {
        $s = Get-DpDefaultSettings
        $s.model = 'settings-model'
        (New-DpTurnParameter -Prompt 'hi' -Settings $s -Model 'conv-model').Model | Should -Be 'conv-model'
    }
    It 'omits SystemPrompt when no Workspace Folder is set' {
        (New-DpTurnParameter -Prompt 'hi' -Settings (Get-DpDefaultSettings)).ContainsKey('SystemPrompt') | Should -BeFalse
    }
    It 'injects a SystemPrompt naming the Workspace Folder when one is set' {
        $s = Get-DpDefaultSettings
        $s.workspaceFolder = 'C:\a'
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        $p.ContainsKey('SystemPrompt') | Should -BeTrue
        $p.SystemPrompt | Should -Match 'working directory'
        $p.SystemPrompt | Should -Match ([regex]::Escape('C:\a'))
    }
    It 'does not disable the Task List tool when taskTracking is on (the Engine offers it by default)' {
        $p = New-DpTurnParameter -Prompt 'hi' -Settings (Get-DpDefaultSettings)
        $p.ContainsKey('DisableTodoList') | Should -BeFalse
    }
    It 'disables the Task List tool (DisableTodoList) when taskTracking is off' {
        $s = Get-DpDefaultSettings
        $s.taskTracking = $false
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        $p.ContainsKey('DisableTodoList') | Should -BeTrue
        $p.DisableTodoList | Should -BeTrue
    }
    It 'never passes DisableProgressEvents' {
        (New-DpTurnParameter -Prompt 'hi' -Settings (Get-DpDefaultSettings)).ContainsKey('DisableProgressEvents') | Should -BeFalse
    }
    It 'passes ReasoningEffort when the effective Model advertises the chosen effort' {
        $s = Get-DpDefaultSettings
        $s.reasoningEffort = 'max'
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s -ModelReasoningEfforts @('minimal', 'low', 'medium', 'high', 'max')
        $p.ContainsKey('ReasoningEffort') | Should -BeTrue
        $p.ReasoningEffort | Should -Be 'max'
    }
    It 'suppresses ReasoningEffort when the effective Model supports none (e.g. claude-haiku-4.5)' {
        $s = Get-DpDefaultSettings
        $s.reasoningEffort = 'max'
        (New-DpTurnParameter -Prompt 'hi' -Settings $s -ModelReasoningEfforts @()).ContainsKey('ReasoningEffort') | Should -BeFalse
    }
    It 'suppresses ReasoningEffort when the Model advertises a subset that excludes the chosen effort' {
        $s = Get-DpDefaultSettings
        $s.reasoningEffort = 'max'
        (New-DpTurnParameter -Prompt 'hi' -Settings $s -ModelReasoningEfforts @('low', 'medium', 'high')).ContainsKey('ReasoningEffort') | Should -BeFalse
    }
    It 'suppresses ReasoningEffort when the Model capabilities are unknown (no efforts supplied)' {
        $s = Get-DpDefaultSettings
        $s.reasoningEffort = 'high'
        (New-DpTurnParameter -Prompt 'hi' -Settings $s).ContainsKey('ReasoningEffort') | Should -BeFalse
    }
    It 'omits ReasoningEffort when the Setting is unset even if the Model supports efforts' {
        (New-DpTurnParameter -Prompt 'hi' -Settings (Get-DpDefaultSettings) -ModelReasoningEfforts @('low', 'high', 'max')).ContainsKey('ReasoningEffort') | Should -BeFalse
    }
}

Describe 'Get-DpPropertyValue' {
    It 'returns the first present candidate' {
        $o = [pscustomobject]@{ Content = 'hello' }
        Get-DpPropertyValue -InputObject $o -Name @('Text', 'Content') | Should -Be 'hello'
    }
    It 'returns the default when no candidate is present' {
        Get-DpPropertyValue -InputObject ([pscustomobject]@{ a = 1 }) -Name @('x') -Default 'fallback' | Should -Be 'fallback'
    }
    It 'returns the default for a null input' {
        Get-DpPropertyValue -InputObject $null -Name @('x') -Default 7 | Should -Be 7
    }
}

Describe 'ConvertFrom-DpEngineResult' {
    It 'maps content, activity and usage' {
        $result = [pscustomobject]@{
            Content   = 'the answer'
            FilesRead = @('a.txt', 'b.txt')
            Usage     = [pscustomobject]@{ PromptTokens = 10; CompletionTokens = 5 }
            CostUSD   = 0.0123
        }
        $m = ConvertFrom-DpEngineResult -Result $result
        $m.content | Should -Be 'the answer'
        $m.activity.filesRead.Count | Should -Be 2
        $m.usage.totalTokens | Should -Be 15
        $m.usage.costUSD | Should -Be 0.0123
    }
    It 'returns an empty shape for a null result' {
        $m = ConvertFrom-DpEngineResult -Result $null
        $m.content | Should -Be ''
        $m.usage.totalTokens | Should -Be 0
    }
    It 'does not throw and yields empty arrays when the result has no tool activity' {
        # Regression: under Set-StrictMode -Version Latest, an empty
        # "@(...) | ForEach-Object" pipeline collapsed to $null and .Count threw.
        $result = [pscustomobject]@{ Content = 'hi'; Usage = [pscustomobject]@{ TotalTokens = 3 } }
        { ConvertFrom-DpEngineResult -Result $result } | Should -Not -Throw
        $m = ConvertFrom-DpEngineResult -Result $result
        @($m.activity.filesRead).Count | Should -Be 0
        @($m.activity.pagesFetched).Count | Should -Be 0
        @($m.activity.commandsRun).Count | Should -Be 0
        $m.content | Should -Be 'hi'
    }
    It 'maps result.TodoList to a normalised Task List' {
        $result = [pscustomobject]@{
            Content  = 'done'
            TodoList = @(
                [pscustomobject]@{ id = 1; title = 'Read files'; status = 'completed' }
                [pscustomobject]@{ id = 2; title = 'Write memo'; status = 'in-progress' }
            )
        }
        $m = ConvertFrom-DpEngineResult -Result $result
        @($m.tasks).Count | Should -Be 2
        $m.tasks[0].status | Should -Be 'completed'
        $m.tasks[1].status | Should -Be 'in-progress'
    }
    It 'yields an empty Task List when TodoList is missing, empty or the result is null' {
        @((ConvertFrom-DpEngineResult -Result ([pscustomobject]@{ Content = 'hi' })).tasks).Count | Should -Be 0
        @((ConvertFrom-DpEngineResult -Result ([pscustomobject]@{ Content = 'hi'; TodoList = @() })).tasks).Count | Should -Be 0
        @((ConvertFrom-DpEngineResult -Result $null).tasks).Count | Should -Be 0
    }
}

Describe 'ConvertTo-DpTaskList' {
    It 'tolerates a null input and yields an empty Task List' {
        # The function returns a single array via unary comma, so callers must
        # not re-wrap with @() when probing Count.
        $result = ConvertTo-DpTaskList -InputObject $null
        $result.Count | Should -Be 0
    }
    It 'coerces an unknown or missing status to not-started' {
        $r = ConvertTo-DpTaskList -InputObject @(
            [pscustomobject]@{ id = 1; title = 'a'; status = 'wat' }
            [pscustomobject]@{ id = 2; title = 'b' }
        )
        $r[0].status | Should -Be 'not-started'
        $r[1].status | Should -Be 'not-started'
    }
    It 'keeps only the first in-progress Task and demotes the rest' {
        $r = ConvertTo-DpTaskList -InputObject @(
            [pscustomobject]@{ id = 1; title = 'a'; status = 'in-progress' }
            [pscustomobject]@{ id = 2; title = 'b'; status = 'in-progress' }
            [pscustomobject]@{ id = 3; title = 'c'; status = 'in-progress' }
        )
        @($r | Where-Object { $_.status -eq 'in-progress' }).Count | Should -Be 1
        $r[0].status | Should -Be 'in-progress'
        $r[1].status | Should -Be 'not-started'
        $r[2].status | Should -Be 'not-started'
    }
    It 'trims whitespace and caps a title at 200 characters' {
        $long = 'x' * 250
        $r = ConvertTo-DpTaskList -InputObject @([pscustomobject]@{ id = 1; title = "  $long  "; status = 'completed' })
        $r[0].title.Length | Should -Be 200
    }
    It 'drops a Task whose title is empty or whitespace' {
        $r = ConvertTo-DpTaskList -InputObject @(
            [pscustomobject]@{ id = 1; title = '   '; status = 'completed' }
            [pscustomobject]@{ id = 2; title = 'real'; status = 'completed' }
        )
        @($r).Count | Should -Be 1
        $r[0].title | Should -Be 'real'
    }
    It 'preserves input order' {
        $r = ConvertTo-DpTaskList -InputObject @(
            [pscustomobject]@{ id = 9; title = 'first'; status = 'completed' }
            [pscustomobject]@{ id = 4; title = 'second'; status = 'not-started' }
        )
        $r[0].title | Should -Be 'first'
        $r[1].title | Should -Be 'second'
    }
    It 'assigns sequential ids when ids are missing or not positive integers' {
        $r = ConvertTo-DpTaskList -InputObject @(
            [pscustomobject]@{ title = 'a'; status = 'completed' }
            [pscustomobject]@{ id = 0; title = 'b'; status = 'completed' }
            [pscustomobject]@{ id = -3; title = 'c'; status = 'completed' }
        )
        $r[0].id | Should -Be 1
        $r[1].id | Should -Be 2
        $r[2].id | Should -Be 3
    }
    It 'keeps a positive integer id' {
        $r = ConvertTo-DpTaskList -InputObject @([pscustomobject]@{ id = 42; title = 'a'; status = 'completed' })
        $r[0].id | Should -Be 42
    }
    It 'accepts hashtable-shaped items as well as PSCustomObjects' {
        $r = ConvertTo-DpTaskList -InputObject @(
            @{ id = 1; title = 'hash'; status = 'in-progress' }
            [pscustomobject]@{ id = 2; title = 'pso'; status = 'completed' }
        )
        @($r).Count | Should -Be 2
        $r[0].title | Should -Be 'hash'
        $r[0].status | Should -Be 'in-progress'
        $r[1].title | Should -Be 'pso'
    }
}

Describe 'Get-DpStreamFrame' {
    It 'emits a tasks frame (and no delta) for a ShpProgress TodoList record' {
        $rec = [pscustomobject]@{
            Tags        = @('ShpProgress')
            MessageData = [pscustomobject]@{ Kind = 'TodoList'; TodoList = @([pscustomobject]@{ id = 1; title = 'Plan'; status = 'in-progress' }) }
        }
        $d = Get-DpStreamFrame -Record $rec
        $d.event | Should -Be 'tasks'
        @($d.data.tasks).Count | Should -Be 1
        $d.data.tasks[0].status | Should -Be 'in-progress'
    }
    It 'produces no frame for a ShpProgress ToolCall record' {
        $rec = [pscustomobject]@{
            Tags        = @('ShpProgress')
            MessageData = [pscustomobject]@{ Kind = 'ToolCall'; Name = 'read_file'; Arguments = '{}' }
        }
        Get-DpStreamFrame -Record $rec | Should -BeNullOrEmpty
    }
    It 'ignores an unknown ShpProgress Kind for forward-compatibility' {
        $rec = [pscustomobject]@{ Tags = @('ShpProgress'); MessageData = [pscustomobject]@{ Kind = 'SomethingNew' } }
        Get-DpStreamFrame -Record $rec | Should -BeNullOrEmpty
    }
    It 'emits a delta for an ordinary (non-ShpProgress) host record' {
        $rec = [pscustomobject]@{
            Tags        = @('PSHOST')
            MessageData = [System.Management.Automation.HostInformationMessage]@{ Message = 'hello'; ForegroundColor = [System.ConsoleColor]::White }
        }
        $d = Get-DpStreamFrame -Record $rec
        $d.event | Should -Be 'delta'
        $d.data.text | Should -Be 'hello'
    }
    It 'routes a coloured trace line to reasoning only when ShowThinking is set' {
        $rec = [pscustomobject]@{
            Tags        = @('PSHOST')
            MessageData = [System.Management.Automation.HostInformationMessage]@{ Message = '-> read_file({})'; ForegroundColor = [System.ConsoleColor]::Cyan }
        }
        Get-DpStreamFrame -Record $rec | Should -BeNullOrEmpty
        (Get-DpStreamFrame -Record $rec -ShowThinking).event | Should -Be 'reasoning'
    }
    It 'returns nothing for a null record or empty text' {
        Get-DpStreamFrame -Record $null | Should -BeNullOrEmpty
        $blank = [pscustomobject]@{ Tags = @('PSHOST'); MessageData = [System.Management.Automation.HostInformationMessage]@{ Message = ''; ForegroundColor = [System.ConsoleColor]::White } }
        Get-DpStreamFrame -Record $blank | Should -BeNullOrEmpty
    }
    It 're-attaches a newline to a complete-line reasoning trace so lines do not glue' {
        $rec = [pscustomobject]@{
            Tags        = @('PSHOST')
            MessageData = [System.Management.Automation.HostInformationMessage]@{ Message = '=== iteration 1 (chat) ==='; ForegroundColor = [System.ConsoleColor]::DarkCyan; NoNewLine = $false }
        }
        $d = Get-DpStreamFrame -Record $rec -ShowThinking
        $d.event | Should -Be 'reasoning'
        $d.data.text | Should -Be "=== iteration 1 (chat) ===`n"
    }
    It 'does not add a newline to a -NoNewline streamed token (concatenates as the Engine intended)' {
        $rec = [pscustomobject]@{
            Tags        = @('PSHOST')
            MessageData = [System.Management.Automation.HostInformationMessage]@{ Message = 'tok'; ForegroundColor = [System.ConsoleColor]::White; NoNewLine = $true }
        }
        $d = Get-DpStreamFrame -Record $rec
        $d.event | Should -Be 'delta'
        $d.data.text | Should -Be 'tok'
    }
    It 're-attaches a newline to a complete-line answer (delta) write' {
        $rec = [pscustomobject]@{
            Tags        = @('PSHOST')
            MessageData = [System.Management.Automation.HostInformationMessage]@{ Message = 'a full answer line'; ForegroundColor = [System.ConsoleColor]::White; NoNewLine = $false }
        }
        $d = Get-DpStreamFrame -Record $rec
        $d.event | Should -Be 'delta'
        $d.data.text | Should -Be "a full answer line`n"
    }
    It 'leaves an unspecified NoNewLine ($null) untouched (no trailing newline)' {
        $rec = [pscustomobject]@{
            Tags        = @('PSHOST')
            MessageData = [System.Management.Automation.HostInformationMessage]@{ Message = 'hello'; ForegroundColor = [System.ConsoleColor]::White }
        }
        (Get-DpStreamFrame -Record $rec).data.text | Should -Be 'hello'
    }
}

Describe 'Get-DpStaticContent' {
    BeforeAll {
        Set-Content -Path (Join-Path $TestDrive 'index.html') -Value '<html></html>' -NoNewline
    }
    It 'serves an existing file' {
        $r = Get-DpStaticContent -WebRoot $TestDrive -RequestPath '/index.html'
        $r.Found | Should -BeTrue
        $r.ContentType | Should -Be 'text/html; charset=utf-8'
    }
    It 'serves index.html for the root path' {
        (Get-DpStaticContent -WebRoot $TestDrive -RequestPath '/').Found | Should -BeTrue
    }
    It 'blocks path traversal outside the web root' {
        (Get-DpStaticContent -WebRoot $TestDrive -RequestPath '/../../secret.txt').Found | Should -BeFalse
    }
    It 'reports missing files' {
        (Get-DpStaticContent -WebRoot $TestDrive -RequestPath '/nope.js').Found | Should -BeFalse
    }
}

Describe 'New-DpLifetimeUsage' {
    It 'returns a zeroed counter stamped with a sinceUtc' {
        $u = New-DpLifetimeUsage
        $u.credits | Should -Be 0
        $u.costUSD | Should -Be 0
        $u.turns | Should -Be 0
        $u.sinceUtc | Should -Not -BeNullOrEmpty
    }
}

Describe 'Conversation store persistence' {
    It 'round-trips Conversations through disk and rehydrates appendable messages' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $conv = New-DpConversation -Title 'Persisted' -Model 'm1'
        $conv.messages.Add(@{ id = 'm_1'; role = 'user'; text = 'hello' })
        $conv.history.Add(@{ role = 'user'; content = 'hello' })
        $store = @{ $conv.id = $conv }

        Save-DpConversationStore -Store $store -Directory $dir
        (Test-Path (Join-Path $dir 'conversations.json')) | Should -BeTrue

        $loaded = Import-DpConversationStore -Directory $dir
        $loaded.Count | Should -Be 1
        $reloaded = $loaded[$conv.id]
        $reloaded.title | Should -Be 'Persisted'
        $reloaded.messages.Count | Should -Be 1
        # Messages must be appendable after load (List, not a fixed array).
        { $reloaded.messages.Add(@{ id = 'm_2'; role = 'assistant'; text = 'hi' }) } | Should -Not -Throw
        $reloaded.messages.Count | Should -Be 2
    }
    It 'round-trips the unread flag and colour label' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $conv = New-DpConversation -Title 'Flagged'
        $conv.unread = $true
        $conv.color = 'teal'
        Save-DpConversationStore -Store @{ $conv.id = $conv } -Directory $dir
        $loaded = Import-DpConversationStore -Directory $dir
        $loaded[$conv.id].unread | Should -BeTrue
        $loaded[$conv.id].color | Should -Be 'teal'
    }
    It 'round-trips the compactedUtc marker' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $conv = New-DpConversation -Title 'Compacted'
        $conv.compactedUtc = '2026-07-07T10:00:00.0000000Z'
        Save-DpConversationStore -Store @{ $conv.id = $conv } -Directory $dir
        $loaded = Import-DpConversationStore -Directory $dir
        $loaded[$conv.id].compactedUtc | Should -Be '2026-07-07T10:00:00.0000000Z'
    }
    It 'preserves ISO timestamps across a load/save cycle' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $conv = New-DpConversation -Title 'Timed'
        Save-DpConversationStore -Store @{ $conv.id = $conv } -Directory $dir
        $loaded = Import-DpConversationStore -Directory $dir
        $loaded[$conv.id].createdUtc | Should -Be $conv.createdUtc
    }
    It 'returns an empty store when no file exists' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        (Import-DpConversationStore -Directory $dir).Count | Should -Be 0
    }
}

Describe 'Lifetime usage persistence' {
    It 'round-trips the lifetime counter through disk' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $usage = New-DpLifetimeUsage
        $usage.credits = 12.5
        $usage.costUSD = 0.34
        $usage.totalTokens = 4200
        $usage.turns = 7
        Save-DpLifetimeUsage -Usage $usage -Directory $dir

        $loaded = Import-DpLifetimeUsage -Directory $dir
        $loaded.credits | Should -Be 12.5
        $loaded.costUSD | Should -Be 0.34
        $loaded.totalTokens | Should -Be 4200
        $loaded.turns | Should -Be 7
        ([datetime]$loaded.sinceUtc) | Should -Be ([datetime]$usage.sinceUtc)
    }
    It 'returns a fresh zeroed counter when no file exists' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $u = Import-DpLifetimeUsage -Directory $dir
        $u.credits | Should -Be 0
        $u.turns | Should -Be 0
    }
}

Describe 'Get-DpUsagePayload' {
    BeforeAll {
        $script:DeskPilot = @{
            Usage         = @{ promptTokens = 10; completionTokens = 5; totalTokens = 15; costUSD = 0.01; credits = 0.5; turns = 1; byModel = @{ 'm1' = @{ totalTokens = 15; costUSD = 0.01 } } }
            LifetimeUsage = @{ promptTokens = 100; completionTokens = 50; totalTokens = 150; costUSD = 0.2; credits = 9.5; turns = 12; sinceUtc = '2026-06-01T00:00:00Z' }
        }
    }
    It 'reports session and lifetime counters separately' {
        $p = Get-DpUsagePayload
        $p.session.credits | Should -Be 0.5
        $p.session.turns | Should -Be 1
        $p.lifetime.credits | Should -Be 9.5
        $p.lifetime.turns | Should -Be 12
        $p.lifetime.sinceUtc | Should -Be '2026-06-01T00:00:00Z'
    }
    It 'includes the session per-Model breakdown' {
        $p = Get-DpUsagePayload
        @($p.byModel).Count | Should -Be 1
        $p.byModel[0].model | Should -Be 'm1'
    }
}


Describe 'Settings persistence' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
    }

    It 'returns defaults when settings.json is missing' {
        $s = Import-DpSettings -Directory $script:dir
        $s.permissions.terminal | Should -BeFalse
        $s.permissions.browsing | Should -BeTrue
    }

    It 'round-trips permissions and the selected Project via Save / Import' {
        $base = Get-DpDefaultSettings
        $base.permissions.terminal = $true
        $withProject = Merge-DpSettings -Current $base -Patch @{ projects = @(@{ name = 'Demo'; path = 'C:\projects\demo' }) }
        $projectId = $withProject.projects[0].id
        $selected = Merge-DpSettings -Current $withProject -Patch @{ selectedProjectId = $projectId }
        Save-DpSettings -Settings $selected -Directory $script:dir
        $loaded = Import-DpSettings -Directory $script:dir
        $loaded.permissions.terminal | Should -BeTrue
        @($loaded.projects).Count | Should -Be 1
        $loaded.projects[0].name | Should -Be 'Demo'
        $loaded.selectedProjectId | Should -Be $projectId
        $loaded.workspaceFolder | Should -Be 'C:\projects\demo'
    }

    It 'preserves a freshly added permission across restarts' {
        $s = Get-DpDefaultSettings
        $s.permissions.file = $false
        Save-DpSettings -Settings $s -Directory $script:dir
        (Import-DpSettings -Directory $script:dir).permissions.file | Should -BeFalse
    }
}

Describe 'Multipart parsing' {
    BeforeAll {
        function New-MultipartBody {
            param([string]$Boundary, [hashtable[]]$Parts)
            $ms = [System.IO.MemoryStream]::new()
            $enc = [System.Text.Encoding]::ASCII
            foreach ($p in $Parts) {
                $headers = "--$Boundary`r`nContent-Disposition: form-data; name=`"$($p.Name)`""
                if ($p.FileName) { $headers += "; filename=`"$($p.FileName)`"" }
                $headers += "`r`n"
                if ($p.ContentType) { $headers += "Content-Type: $($p.ContentType)`r`n" }
                $headers += "`r`n"
                $hb = $enc.GetBytes($headers)
                $ms.Write($hb, 0, $hb.Length)
                $ms.Write($p.Bytes, 0, $p.Bytes.Length)
                $tail = $enc.GetBytes("`r`n")
                $ms.Write($tail, 0, $tail.Length)
            }
            $end = $enc.GetBytes("--$Boundary--`r`n")
            $ms.Write($end, 0, $end.Length)
            $ms.ToArray()
        }
    }

    It 'extracts the boundary from a Content-Type header' {
        Get-DpMultipartBoundary -ContentType 'multipart/form-data; boundary=----WebKitX' | Should -Be '----WebKitX'
    }

    It 'returns $null when the header has no boundary' {
        Get-DpMultipartBoundary -ContentType 'application/json' | Should -BeNullOrEmpty
    }

    It 'parses a text file part byte-for-byte' {
        $boundary = '----TestBoundary'
        $payload = [byte[]](0..255)
        $bytes = New-MultipartBody -Boundary $boundary -Parts @(@{ Name = 'files'; FileName = 'a.bin'; ContentType = 'application/octet-stream'; Bytes = $payload })
        $parts = Read-DpMultipartParts -Bytes $bytes -Boundary $boundary
        @($parts).Count | Should -Be 1
        $parts[0].FileName | Should -Be 'a.bin'
        $parts[0].Content.Length | Should -Be $payload.Length
        for ($i = 0; $i -lt $payload.Length; $i++) { $parts[0].Content[$i] | Should -Be $payload[$i] }
    }

    It 'parses multiple file parts' {
        $boundary = '----TwoFiles'
        $a = [System.Text.Encoding]::UTF8.GetBytes('hello')
        $b = [System.Text.Encoding]::UTF8.GetBytes('world!!')
        $bytes = New-MultipartBody -Boundary $boundary -Parts @(
            @{ Name = 'files'; FileName = 'a.txt'; ContentType = 'text/plain'; Bytes = $a }
            @{ Name = 'files'; FileName = 'b.txt'; ContentType = 'text/plain'; Bytes = $b }
        )
        $parts = Read-DpMultipartParts -Bytes $bytes -Boundary $boundary
        @($parts).Count | Should -Be 2
        [System.Text.Encoding]::UTF8.GetString($parts[0].Content) | Should -Be 'hello'
        [System.Text.Encoding]::UTF8.GetString($parts[1].Content) | Should -Be 'world!!'
    }
}

Describe 'Get-DpUniqueFilePath' {
    It 'returns the desired path when no collision exists' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Get-DpUniqueFilePath -Directory $dir -Name 'report.pdf' | Should -Be (Join-Path $dir 'report.pdf')
    }

    It 'appends " (n)" before the extension on collision' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'report.pdf') -Value 'a'
        Set-Content -Path (Join-Path $dir 'report (1).pdf') -Value 'b'
        Get-DpUniqueFilePath -Directory $dir -Name 'report.pdf' | Should -Be (Join-Path $dir 'report (2).pdf')
    }

    It 'sanitises path-separator characters' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $result = Get-DpUniqueFilePath -Directory $dir -Name 'a/b\c.txt'
        Split-Path -Leaf $result | Should -Be 'a_b_c.txt'
    }
}

Describe 'Get-DpUploadDir' {
    It 'returns the Workspace Folder when one is active' {
        Get-DpUploadDir -WorkspaceFolder 'C:\projects\demo' | Should -Be 'C:\projects\demo'
    }
    It 'falls back to an uploads folder in the data directory when no Project is selected' {
        $fakeData = Join-Path $TestDrive 'data'
        Mock Get-DpDataDir { $fakeData }
        Get-DpUploadDir -WorkspaceFolder $null | Should -Be (Join-Path $fakeData 'uploads')
    }
    It 'falls back when the Workspace Folder is whitespace' {
        $fakeData = Join-Path $TestDrive 'data-ws'
        Mock Get-DpDataDir { $fakeData }
        Get-DpUploadDir -WorkspaceFolder '   ' | Should -Be (Join-Path $fakeData 'uploads')
    }
}

Describe 'Get-DpEngineWorkingDir' {
    It 'returns the Workspace Folder when a Project is active' {
        Get-DpEngineWorkingDir -WorkspaceFolder 'C:\projects\demo' | Should -Be 'C:\projects\demo'
    }
    It 'falls back to a workspace folder in the data directory when no Project is selected' {
        $fakeData = Join-Path $TestDrive 'data-eng'
        Mock Get-DpDataDir { $fakeData }
        Get-DpEngineWorkingDir -WorkspaceFolder $null | Should -Be (Join-Path $fakeData 'workspace')
    }
    It 'falls back when the Workspace Folder is whitespace (does not leak the launch directory)' {
        $fakeData = Join-Path $TestDrive 'data-eng-ws'
        Mock Get-DpDataDir { $fakeData }
        Get-DpEngineWorkingDir -WorkspaceFolder '   ' | Should -Be (Join-Path $fakeData 'workspace')
    }
}

Describe 'Get-DpCopilotDefaults prompt roots' {
    It 'includes a prompts root when ~/.copilot/prompts exists' {
        $home2 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $home2 '.copilot/prompts') -Force | Out-Null
        @((Get-DpCopilotDefaults -HomeDirectory $home2).promptRoots).Count | Should -Be 1
    }
    It 'omits the prompts root when the folder is absent' {
        $home2 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $home2 '.copilot') -Force | Out-Null
        @((Get-DpCopilotDefaults -HomeDirectory $home2).promptRoots).Count | Should -Be 0
    }
}

Describe 'Merge-DpSettings prompt roots' {
    It 'accepts and stores promptRoots' {
        $m = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ promptRoots = @('C:\a', 'C:\b') })
        @($m.promptRoots).Count | Should -Be 2
        $m.promptRoots[0] | Should -Be 'C:\a'
    }
}

Describe 'Customizations' {
    BeforeAll {
        # A read-only customization tree shared by the list/resolve/read tests.
        $script:cRoot = Join-Path $TestDrive 'cust-read'
        $script:cAgents = Join-Path $script:cRoot 'agents'
        $script:cSkills = Join-Path $script:cRoot 'skills'
        $script:cInstr = Join-Path $script:cRoot 'instructions'
        $script:cPrompts = Join-Path $script:cRoot 'prompts'
        New-Item -ItemType Directory -Path $script:cAgents, $script:cSkills, $script:cInstr, $script:cPrompts -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:cAgents 'legal.agent.md') -Value "---`nname: Legal Researcher`ndescription: German law.`n---`n`n# body" -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:cSkills 'pdf-tools') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:cSkills 'pdf-tools/SKILL.md') -Value "---`ndescription: PDF.`n---`n# skill" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:cInstr 'csharp.instructions.md') -Value "---`ndescription: C#.`n---`n# rules" -NoNewline
        $script:cSettings = @{
            agentsRoot       = $script:cAgents
            skillRoots       = @($script:cSkills)
            instructionRoots = @($script:cInstr)
            promptRoots      = @($script:cPrompts)
        }
    }

    Context 'Get-DpCustomizationCatalog' {
        It 'defines the four categories in order' {
            ((Get-DpCustomizationCatalog).id -join ',') | Should -Be 'agent,skill,instruction,prompt'
        }
        It 'marks skill as nested and agent as single' {
            $cat = Get-DpCustomizationCatalog
            ($cat | Where-Object id -EQ 'skill').nested | Should -BeTrue
            ($cat | Where-Object id -EQ 'agent').single | Should -BeTrue
            ($cat | Where-Object id -EQ 'instruction').single | Should -BeFalse
        }
    }

    Context 'Get-DpCustomizationRoot' {
        It 'returns the single agent root' {
            @(Get-DpCustomizationRoot -Settings $script:cSettings -Category 'agent').Count | Should -Be 1
        }
        It 'returns an empty array for an unknown category' {
            @(Get-DpCustomizationRoot -Settings $script:cSettings -Category 'nope').Count | Should -Be 0
        }
        It 'de-duplicates repeated roots' {
            @(Get-DpCustomizationRoot -Settings @{ skillRoots = @($script:cSkills, $script:cSkills) } -Category 'skill').Count | Should -Be 1
        }
    }

    Context 'Get-DpCustomizationList' {
        It 'counts each category from its roots' {
            $list = Get-DpCustomizationList -Settings $script:cSettings -HomeDirectory $script:cRoot
            ($list.categories | Where-Object id -EQ 'agent').count | Should -Be 1
            ($list.categories | Where-Object id -EQ 'skill').count | Should -Be 1
            ($list.categories | Where-Object id -EQ 'instruction').count | Should -Be 1
            ($list.categories | Where-Object id -EQ 'prompt').count | Should -Be 0
        }
        It 'names an agent from frontmatter and a skill from its folder' {
            $list = Get-DpCustomizationList -Settings $script:cSettings -HomeDirectory $script:cRoot
            ($list.categories | Where-Object id -EQ 'agent').items[0].name | Should -Be 'Legal Researcher'
            ($list.categories | Where-Object id -EQ 'skill').items[0].name | Should -Be 'pdf-tools'
        }
        It 'classifies files under ~/.copilot as User scope' {
            $home2 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $userAgents = Join-Path $home2 '.copilot/agents'
            New-Item -ItemType Directory -Path $userAgents -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $userAgents 'x.agent.md') -Value '# x' -NoNewline
            $list = Get-DpCustomizationList -Settings @{ agentsRoot = $userAgents; skillRoots = @(); instructionRoots = @(); promptRoots = @() } -HomeDirectory $home2
            ($list.categories | Where-Object id -EQ 'agent').items[0].scope | Should -Be 'User'
        }
        It 'returns zero counts when roots are unset' {
            $list = Get-DpCustomizationList -Settings @{ agentsRoot = $null; skillRoots = @(); instructionRoots = @(); promptRoots = @() }
            ($list.categories | Where-Object id -EQ 'agent').count | Should -Be 0
        }
    }

    Context 'Resolve-DpCustomizationPath' {
        It 'accepts a valid agent file inside the root' {
            (Resolve-DpCustomizationPath -Settings $script:cSettings -Category 'agent' -Path (Join-Path $script:cAgents 'legal.agent.md')).ok | Should -BeTrue
        }
        It 'accepts a SKILL.md inside a skill root' {
            (Resolve-DpCustomizationPath -Settings $script:cSettings -Category 'skill' -Path (Join-Path $script:cSkills 'pdf-tools/SKILL.md')).ok | Should -BeTrue
        }
        It 'refuses a path that escapes the root' {
            $r = Resolve-DpCustomizationPath -Settings $script:cSettings -Category 'agent' -Path (Join-Path $script:cAgents '..\..\evil.agent.md')
            $r.ok | Should -BeFalse
            $r.error | Should -Match 'Outside'
        }
        It 'refuses a wrong file pattern' {
            $r = Resolve-DpCustomizationPath -Settings $script:cSettings -Category 'agent' -Path (Join-Path $script:cAgents 'legal.txt')
            $r.ok | Should -BeFalse
            $r.error | Should -Match 'valid agent'
        }
        It 'refuses a non-SKILL file in a skill root' {
            (Resolve-DpCustomizationPath -Settings $script:cSettings -Category 'skill' -Path (Join-Path $script:cSkills 'pdf-tools/notes.md')).ok | Should -BeFalse
        }
        It 'refuses an unknown category' {
            (Resolve-DpCustomizationPath -Settings $script:cSettings -Category 'nope' -Path 'x').ok | Should -BeFalse
        }
    }

    Context 'Get-DpCustomizationContent' {
        It 'reads an existing agent file' {
            $c = Get-DpCustomizationContent -Settings $script:cSettings -Category 'agent' -Path (Join-Path $script:cAgents 'legal.agent.md')
            $c.error | Should -BeNullOrEmpty
            $c.text | Should -Match 'Legal Researcher'
        }
        It 'reports an error for a path outside the roots' {
            (Get-DpCustomizationContent -Settings $script:cSettings -Category 'agent' -Path (Join-Path $TestDrive 'outside.agent.md')).error | Should -Not -BeNullOrEmpty
        }
        It 'flags an over-cap file as truncated' {
            $tmpRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
            $big = Join-Path $tmpRoot 'big.agent.md'
            Set-Content -LiteralPath $big -Value ('x' * 50) -NoNewline
            $c = Get-DpCustomizationContent -Settings @{ agentsRoot = $tmpRoot } -Category 'agent' -Path $big -MaxBytes 10
            $c.truncated | Should -BeTrue
            $c.text.Length | Should -Be 10
        }
    }

    Context 'Save-DpCustomizationContent' {
        BeforeEach {
            $script:sRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:sRoot -Force | Out-Null
            $script:sSettings = @{ agentsRoot = $script:sRoot }
        }
        It 'overwrites an existing file atomically' {
            $p = Join-Path $script:sRoot 'save-me.agent.md'
            Set-Content -LiteralPath $p -Value 'old' -NoNewline
            (Save-DpCustomizationContent -Settings $script:sSettings -Category 'agent' -Path $p -Text 'new text').ok | Should -BeTrue
            (Get-Content -LiteralPath $p -Raw) | Should -Be 'new text'
        }
        It 'refuses to write outside the root' {
            { Save-DpCustomizationContent -Settings $script:sSettings -Category 'agent' -Path (Join-Path $TestDrive 'evil.agent.md') -Text 'x' } | Should -Throw
        }
        It 'refuses to create a missing file (save is edit-only)' {
            { Save-DpCustomizationContent -Settings $script:sSettings -Category 'agent' -Path (Join-Path $script:sRoot 'ghost.agent.md') -Text 'x' } |
                Should -Throw -ExpectedMessage '*not found*'
        }
    }

    Context 'New-DpCustomization' {
        BeforeEach {
            $script:nRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:nRoot -Force | Out-Null
            $script:nSettings = @{ agentsRoot = $script:nRoot; skillRoots = @($script:nRoot); promptRoots = @($script:nRoot) }
        }
        It 'creates a flat prompt file from the scaffold' {
            $new = New-DpCustomization -Settings $script:nSettings -Category 'prompt' -Name 'standup'
            Test-Path -LiteralPath $new.path | Should -BeTrue
            [System.IO.Path]::GetFileName($new.path) | Should -Be 'standup.prompt.md'
        }
        It 'creates a skill folder with a SKILL.md' {
            $new = New-DpCustomization -Settings $script:nSettings -Category 'skill' -Name 'fresh-skill'
            [System.IO.Path]::GetFileName($new.path) | Should -Be 'SKILL.md'
            (Split-Path -Leaf (Split-Path -Parent $new.path)) | Should -Be 'fresh-skill'
        }
        It 'rejects an invalid name' {
            { New-DpCustomization -Settings $script:nSettings -Category 'agent' -Name '../escape' } | Should -Throw
        }
        It 'rejects a duplicate' {
            $null = New-DpCustomization -Settings $script:nSettings -Category 'prompt' -Name 'dup'
            { New-DpCustomization -Settings $script:nSettings -Category 'prompt' -Name 'dup' } |
                Should -Throw -ExpectedMessage '*already exists*'
        }
        It 'throws when no root is configured' {
            { New-DpCustomization -Settings @{ agentsRoot = $null } -Category 'agent' -Name 'x' } |
                Should -Throw -ExpectedMessage '*Configure*'
        }
    }
}


Describe 'Projects (Merge-DpSettings)' {
    It 'registers a Project with a generated id and leaf-name default' {
        $s = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(@{ path = 'C:\work\my-app' }) }
        @($s.projects).Count | Should -Be 1
        $s.projects[0].id | Should -Match '^p_'
        $s.projects[0].name | Should -Be 'my-app'
        $s.selectedProjectId | Should -BeNullOrEmpty
        $s.workspaceFolder | Should -BeNullOrEmpty
    }

    It 'derives workspaceFolder from the selected Project' {
        $s1 = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(@{ id = 'p_one'; name = 'One'; path = 'C:\one' }) }
        $s2 = Merge-DpSettings -Current $s1 -Patch @{ selectedProjectId = 'p_one' }
        $s2.workspaceFolder | Should -Be 'C:\one'
    }

    It 'rejects selecting an unknown Project' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ selectedProjectId = 'p_missing' } } | Should -Throw
    }

    It 'clears a stale selection when its Project is removed' {
        $s1 = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(@{ id = 'p_a'; name = 'A'; path = 'C:\a' }); selectedProjectId = 'p_a' }
        $s1.workspaceFolder | Should -Be 'C:\a'
        $s2 = Merge-DpSettings -Current $s1 -Patch @{ projects = @() }
        $s2.selectedProjectId | Should -BeNullOrEmpty
        $s2.workspaceFolder | Should -BeNullOrEmpty
    }

    It 'closes the active Project when selectedProjectId is set to null, keeping it registered' {
        $s1 = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(@{ id = 'p_a'; name = 'A'; path = 'C:\a' }); selectedProjectId = 'p_a' }
        $s1.workspaceFolder | Should -Be 'C:\a'
        $s2 = Merge-DpSettings -Current $s1 -Patch @{ selectedProjectId = $null }
        $s2.selectedProjectId | Should -BeNullOrEmpty
        $s2.workspaceFolder | Should -BeNullOrEmpty
        @($s2.projects).Count | Should -Be 1
        $s2.projects[0].id | Should -Be 'p_a'
    }

    It 'migrates a legacy workspaceFolder into a selected Project' {
        $s = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ workspaceFolder = 'C:\legacy\ws' }
        @($s.projects).Count | Should -Be 1
        $s.projects[0].name | Should -Be 'ws'
        $s.selectedProjectId | Should -Be $s.projects[0].id
        $s.workspaceFolder | Should -Be 'C:\legacy\ws'
    }

    It 'does not duplicate a Project when the same legacy path is migrated twice' {
        $s1 = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ workspaceFolder = 'C:\dup' }
        $s2 = Merge-DpSettings -Current $s1 -Patch @{ workspaceFolder = 'C:\dup' }
        @($s2.projects).Count | Should -Be 1
    }
}

Describe 'New-DpTurnParameter project prompt' {
    It 'names the selected Project in the SystemPrompt' {
        $s = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(@{ id = 'p_x'; name = 'MyProj'; path = 'C:\x' }); selectedProjectId = 'p_x' }
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        $p.SystemPrompt | Should -Match 'MyProj'
        $p.SystemPrompt | Should -Match ([regex]::Escape('C:\x'))
    }
}


Describe 'Get-DpDirectoryListing' {
    BeforeEach {
        $script:fsRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:fsRoot 'alpha') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:fsRoot 'beta') | Out-Null
    }

    It 'lists immediate sub-folders with name and full path' {
        $l = Get-DpDirectoryListing -Path $script:fsRoot
        @($l.entries).Count | Should -Be 2
        ($l.entries | ForEach-Object { $_.name }) | Should -Contain 'alpha'
        $l.entries[0].path | Should -Match ([regex]::Escape($script:fsRoot))
    }

    It 'reports the parent and leaf name' {
        $l = Get-DpDirectoryListing -Path (Join-Path $script:fsRoot 'alpha')
        $l.name | Should -Be 'alpha'
        $l.parent | Should -Be $script:fsRoot
    }

    It 'always returns drives and the home folder' {
        $l = Get-DpDirectoryListing -Path $script:fsRoot
        @($l.drives).Count | Should -BeGreaterThan 0
        $l.home | Should -Be $HOME
    }

    It 'falls back to home for an empty path' {
        $l = Get-DpDirectoryListing -Path ''
        $l.path | Should -Be ([System.IO.Path]::GetFullPath($HOME))
        $l.entries | Should -BeOfType [hashtable] -Because 'entries is an array of folder records'
    }

    It 'falls back to home for a non-existent path without throwing' {
        { Get-DpDirectoryListing -Path 'Z:\definitely\not\here\xyz' } | Should -Not -Throw
        (Get-DpDirectoryListing -Path 'Z:\definitely\not\here\xyz').path | Should -Be ([System.IO.Path]::GetFullPath($HOME))
    }
}

Describe 'New-DpDirectory' {
    BeforeEach {
        $script:mkRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:mkRoot | Out-Null
    }

    It 'creates a sub-folder and returns its resolved path' {
        $created = New-DpDirectory -Parent $script:mkRoot -Name 'gamma'
        $created | Should -Be (Join-Path $script:mkRoot 'gamma')
        Test-Path -LiteralPath $created | Should -BeTrue
    }

    It 'is idempotent for an existing folder' {
        New-DpDirectory -Parent $script:mkRoot -Name 'dup' | Out-Null
        { New-DpDirectory -Parent $script:mkRoot -Name 'dup' } | Should -Not -Throw
    }

    It 'rejects a name containing a path separator' {
        { New-DpDirectory -Parent $script:mkRoot -Name 'a/b' } | Should -Throw
        { New-DpDirectory -Parent $script:mkRoot -Name 'a\b' } | Should -Throw
    }

    It 'rejects a name containing a parent reference' {
        { New-DpDirectory -Parent $script:mkRoot -Name '..' } | Should -Throw
    }

    It 'rejects a missing parent' {
        { New-DpDirectory -Parent (Join-Path $script:mkRoot 'nope') -Name 'x' } | Should -Throw
    }
}


Describe 'Get-DpCopilotDefaults' {
    BeforeEach {
        $script:cpRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:cpRoot '.copilot/skills') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:cpRoot '.copilot/agents') -Force | Out-Null
    }

    It 'returns the skills and agents folders that exist' {
        $d = Get-DpCopilotDefaults -HomeDirectory $script:cpRoot
        @($d.skillRoots).Count | Should -Be 1
        $d.skillRoots[0] | Should -Be (Join-Path $script:cpRoot '.copilot/skills')
        $d.agentsRoot | Should -Be (Join-Path $script:cpRoot '.copilot/agents')
    }

    It 'omits a sub-folder that does not exist' {
        $d = Get-DpCopilotDefaults -HomeDirectory $script:cpRoot
        @($d.instructionRoots).Count | Should -Be 0
    }

    It 'returns empty defaults when .copilot is absent' {
        $bare = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bare | Out-Null
        $d = Get-DpCopilotDefaults -HomeDirectory $bare
        @($d.skillRoots).Count | Should -Be 0
        $d.agentsRoot | Should -BeNullOrEmpty
    }
}

Describe 'Read-DpAgentFile' {
    It 'parses name, single-line description and body' {
        $f = Join-Path $TestDrive 'one.agent.md'
        Set-Content -LiteralPath $f -Value "---`nname: my-agent`ndescription: A helpful agent.`n---`nYou are helpful." -Encoding utf8
        $m = Read-DpAgentFile -Path $f
        $m.name | Should -Be 'my-agent'
        $m.description | Should -Be 'A helpful agent.'
        $m.body | Should -Be 'You are helpful.'
    }

    It 'joins a folded block-scalar description' {
        $f = Join-Path $TestDrive 'two.agent.md'
        Set-Content -LiteralPath $f -Value "---`nname: folded`ndescription: >-`n  Line one`n  line two`n---`nBody here." -Encoding utf8
        $m = Read-DpAgentFile -Path $f
        $m.description | Should -Be 'Line one line two'
        $m.body | Should -Be 'Body here.'
    }

    It 'returns the whole content as body when there is no frontmatter' {
        $f = Join-Path $TestDrive 'three.agent.md'
        Set-Content -LiteralPath $f -Value 'Just a persona, no frontmatter.' -Encoding utf8
        $m = Read-DpAgentFile -Path $f
        $m.name | Should -BeNullOrEmpty
        $m.body | Should -Be 'Just a persona, no frontmatter.'
    }
}

Describe 'Get-DpAgentList' {
    BeforeEach {
        $script:agRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:agRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $script:agRoot 'beta.agent.md') -Value "---`nname: Beta`ndescription: Second.`n---`nB" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:agRoot 'alpha.agent.md') -Value "---`nname: Alpha`ndescription: First.`n---`nA" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:agRoot 'notes.md') -Value 'ignored' -Encoding utf8
    }

    It 'lists only *.agent.md files, sorted, with id/name/description' {
        $list = Get-DpAgentList -Root $script:agRoot
        @($list).Count | Should -Be 2
        $list[0].id | Should -Be 'alpha.agent.md'
        $list[0].name | Should -Be 'Alpha'
        $list[1].name | Should -Be 'Beta'
    }

    It 'is pipe-safe (each record flows individually)' {
        $names = @(Get-DpAgentList -Root $script:agRoot | ForEach-Object { $_.name })
        $names.Count | Should -Be 2
        $names | Should -Contain 'Alpha'
    }

    It 'returns an empty array for a missing root' {
        @(Get-DpAgentList -Root 'X:\nope').Count | Should -Be 0
    }
}

Describe 'Get-DpAgentSystemPrompt' {
    BeforeEach {
        $script:spRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:spRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $script:spRoot 'p.agent.md') -Value "---`nname: P`n---`nThe persona body." -Encoding utf8
    }

    It 'returns the body for a known agent' {
        Get-DpAgentSystemPrompt -Root $script:spRoot -Id 'p.agent.md' | Should -Be 'The persona body.'
    }

    It 'returns null for an unknown agent' {
        Get-DpAgentSystemPrompt -Root $script:spRoot -Id 'missing.agent.md' | Should -BeNullOrEmpty
    }
}

Describe 'Settings agent + copilot defaults' {
    It 'accepts agentsRoot and selectedAgent through Merge' {
        $s = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ agentsRoot = 'C:\a\agents'; selectedAgent = 'x.agent.md' }
        $s.agentsRoot | Should -Be 'C:\a\agents'
        $s.selectedAgent | Should -Be 'x.agent.md'
    }

    It 'injects the agent persona into the Turn SystemPrompt' {
        $s = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ agentsRoot = 'C:\a'; selectedAgent = 'x.agent.md' }
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s -AgentSystemPrompt 'You are a tax expert.'
        $p.SystemPrompt | Should -Match 'tax expert'
    }
}

Describe 'Project de-duplication' {
    It 'rejects two projects with the same name' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(
                    @{ id = 'p1'; name = 'Demo'; path = 'C:\one' },
                    @{ id = 'p2'; name = 'Demo'; path = 'C:\two' }
                ) } } | Should -Throw -ExpectedMessage "*already exists*"
    }

    It 'rejects two projects with the same path (trailing slash ignored)' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(
                    @{ id = 'p1'; name = 'A'; path = 'C:\same' },
                    @{ id = 'p2'; name = 'B'; path = 'C:\same\' }
                ) } } | Should -Throw -ExpectedMessage "*already*"
    }

    It 'allows distinct projects' {
        $s = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(
                @{ id = 'p1'; name = 'A'; path = 'C:\one' },
                @{ id = 'p2'; name = 'B'; path = 'C:\two' }
            ) }
        @($s.projects).Count | Should -Be 2
    }
}


Describe 'Settings backup restore (Merge onto defaults)' {
    It 'restores a full settings object onto defaults, ignoring version + workspaceFolder' {
        $backupSettings = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
            projects          = @(@{ id = 'p_b'; name = 'Backup'; path = 'C:\bk' })
            selectedProjectId = 'p_b'
            permissions       = @{ terminal = $true }
            selectedAgent     = 'x.agent.md'
            agentsRoot        = 'C:\ag'
            maxToolIterations = 7
        }
        # Simulate a backup payload: add derived + meta keys the import strips.
        $patch = @{}
        foreach ($k in $backupSettings.Keys) { $patch[$k] = $backupSettings[$k] }
        $patch['version'] = 1
        $patch.Remove('version') | Out-Null
        $patch.Remove('workspaceFolder') | Out-Null
        $restored = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch $patch
        $restored.projects[0].name | Should -Be 'Backup'
        $restored.selectedProjectId | Should -Be 'p_b'
        $restored.workspaceFolder | Should -Be 'C:\bk'
        $restored.permissions.terminal | Should -BeTrue
        $restored.selectedAgent | Should -Be 'x.agent.md'
        $restored.maxToolIterations | Should -Be 7
    }

    It 'restoring onto defaults drops settings not present in the backup' {
        # Current state has a project; the backup has none -> restore clears it.
        $current = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ projects = @(@{ id = 'p_old'; name = 'Old'; path = 'C:\old' }); selectedProjectId = 'p_old' }
        $current.projects.Count | Should -Be 1
        $restored = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ permissions = @{ browsing = $false } }
        @($restored.projects).Count | Should -Be 0
        $restored.selectedProjectId | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DpDayKey' {
    It 'keeps an already-formatted yyyy-MM-dd string unchanged' {
        ConvertTo-DpDayKey -Value '2026-06-09' | Should -Be '2026-06-09'
    }
    It 'formats a [datetime] without timezone shift' {
        ConvertTo-DpDayKey -Value ([datetime]'2026-06-09T00:00:00') | Should -Be '2026-06-09'
    }
    It 'trims a longer ISO string to the date' {
        ConvertTo-DpDayKey -Value '2026-06-09T17:30:00Z' | Should -Be '2026-06-09'
    }
}

Describe 'Add-DpDailyUsage' {
    It 'accumulates two same-day turns into one bucket' {
        $a = Add-DpDailyUsage -Daily @() -Usage @{ credits = 0.3081; costUSD = 0.003081; totalTokens = 12 }
        $b = Add-DpDailyUsage -Daily $a -Usage @{ credits = 0.3094; costUSD = 0.003094; totalTokens = 12 }
        @($b).Count | Should -Be 1
        @($b)[0].credits | Should -Be 0.6175
        @($b)[0].turns | Should -Be 2
    }
    It 'keeps separate buckets for separate days' {
        $y = Add-DpDailyUsage -Daily @() -Usage @{ credits = 0.5; costUSD = 0.005; totalTokens = 10 } -Date ([datetime]::UtcNow.AddDays(-1))
        $two = Add-DpDailyUsage -Daily $y -Usage @{ credits = 0.2; costUSD = 0.002; totalTokens = 5 }
        @($two).Count | Should -Be 2
    }
    It 'rounds credits to 4 decimals (no float drift)' {
        $r = Add-DpDailyUsage -Daily @() -Usage @{ credits = 0.1; costUSD = 0.001; totalTokens = 1 }
        $r = Add-DpDailyUsage -Daily $r -Usage @{ credits = 0.2; costUSD = 0.002; totalTokens = 1 }
        @($r)[0].credits | Should -Be 0.3
    }
    It 'survives a JSON round-trip (PSCustomObject input)' {
        $a = Add-DpDailyUsage -Daily @() -Usage @{ credits = 0.5; costUSD = 0.005; totalTokens = 10 }
        $back = (@($a) | ConvertTo-Json -Depth 6) | ConvertFrom-Json
        $c = Add-DpDailyUsage -Daily $back -Usage @{ credits = 0.1; costUSD = 0.001; totalTokens = 3 }
        @($c).Count | Should -Be 1
        @($c)[0].credits | Should -Be 0.6
    }
    It 'trims entries older than the retain window' {
        $old = Add-DpDailyUsage -Daily @() -Usage @{ credits = 9; costUSD = 0.09; totalTokens = 1 } -Date ([datetime]::UtcNow.AddDays(-90))
        $now = Add-DpDailyUsage -Daily $old -Usage @{ credits = 0.1; costUSD = 0.001; totalTokens = 1 } -RetainDays 60
        @($now).Count | Should -Be 1
        @($now)[0].date | Should -Be ([datetime]::UtcNow.ToUniversalTime().ToString('yyyy-MM-dd'))
    }
}

Describe 'Get-DpGitStatus' {
    BeforeAll {
        function Ok($out) { @{ Ok = $true; ExitCode = 0; StdOut = $out; StdErr = '' } }
    }

    It 'reports a non-repo when not inside a work tree' {
        Mock -CommandName Invoke-DpGitCommand -MockWith { @{ Ok = $false; ExitCode = 128; StdOut = ''; StdErr = 'fatal' } }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        $s = Get-DpGitStatus -Path $dir
        $s.isRepo | Should -BeFalse
        $s.gitAvailable | Should -BeTrue
    }

    It 'flags git as unavailable on exit code -1' {
        Mock -CommandName Invoke-DpGitCommand -MockWith { @{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = 'missing' } }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        $s = Get-DpGitStatus -Path $dir
        $s.gitAvailable | Should -BeFalse
    }

    It 'parses the current branch and branch list' {
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            switch ($Arguments -join ' ') {
                'rev-parse --is-inside-work-tree' { Ok "true`n" }
                'rev-parse --show-toplevel' { Ok 'C:\repo' }
                'branch --show-current' { Ok "main`n" }
                'branch --format=%(refname:short)' { Ok "main`nfeature`ndev`n" }
                default { @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' } }
            }
        }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        $s = Get-DpGitStatus -Path $dir
        $s.isRepo | Should -BeTrue
        $s.branch | Should -Be 'main'
        $s.detached | Should -BeFalse
        @($s.branches).Count | Should -Be 3
        $s.branches | Should -Contain 'feature'
    }

    It 'reports a detached HEAD with a short commit id' {
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            switch ($Arguments -join ' ') {
                'rev-parse --is-inside-work-tree' { Ok "true`n" }
                'rev-parse --show-toplevel' { Ok 'C:\repo' }
                'branch --show-current' { Ok "`n" }
                'rev-parse --short HEAD' { Ok "a1b2c3d`n" }
                'branch --format=%(refname:short)' { Ok "main`n" }
                default { @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' } }
            }
        }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        $s = Get-DpGitStatus -Path $dir
        $s.detached | Should -BeTrue
        $s.branch | Should -Be 'a1b2c3d'
    }
}

Describe 'Get-DpFileContent' {
    BeforeAll {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
    }

    It 'reads a small text file as UTF-8' {
        $file = Join-Path $root 'note.txt'
        Set-Content -LiteralPath $file -Value 'hello world' -NoNewline -Encoding utf8
        $r = Get-DpFileContent -Root $root -Path $file
        $r.error | Should -BeNullOrEmpty
        $r.text | Should -Be 'hello world'
        $r.name | Should -Be 'note.txt'
        $r.binary | Should -BeFalse
        $r.truncated | Should -BeFalse
    }

    It 'strips a UTF-8 BOM from the decoded text' {
        $file = Join-Path $root 'bom.txt'
        $bytes = [byte[]]@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes('# Title')
        [System.IO.File]::WriteAllBytes($file, $bytes)
        $r = Get-DpFileContent -Root $root -Path $file
        $r.text | Should -Be '# Title'
    }

    It 'flags a file with NUL bytes as binary and returns no text' {
        $file = Join-Path $root 'blob.bin'
        [System.IO.File]::WriteAllBytes($file, [byte[]]@(1, 2, 0, 3, 4))
        $r = Get-DpFileContent -Root $root -Path $file
        $r.binary | Should -BeTrue
        $r.text | Should -BeNullOrEmpty
    }

    It 'truncates a file larger than MaxBytes' {
        $file = Join-Path $root 'big.txt'
        Set-Content -LiteralPath $file -Value ('a' * 50) -NoNewline -Encoding utf8
        $r = Get-DpFileContent -Root $root -Path $file -MaxBytes 10
        $r.truncated | Should -BeTrue
        $r.text.Length | Should -Be 10
        $r.bytes | Should -Be 50
    }

    It 'refuses a path outside the project root' {
        $outside = Join-Path $TestDrive 'outside.txt'
        Set-Content -LiteralPath $outside -Value 'secret' -NoNewline -Encoding utf8
        $r = Get-DpFileContent -Root $root -Path $outside
        $r.error | Should -Be 'Outside the project folder.'
        $r.text | Should -BeNullOrEmpty
    }

    It 'reports a missing file' {
        $r = Get-DpFileContent -Root $root -Path (Join-Path $root 'nope.txt')
        $r.error | Should -Be 'File not found.'
    }

    It 'reports when the project folder is missing' {
        $r = Get-DpFileContent -Root (Join-Path $TestDrive 'no-such-dir') -Path (Join-Path $TestDrive 'no-such-dir' 'x.txt')
        $r.error | Should -Be 'No project folder.'
    }
}


Describe 'New-DpConversation pin/archive defaults' {
    It 'creates a Conversation with pinned and archived false' {
        $c = New-DpConversation -Title 'X'
        $c.pinned | Should -BeFalse
        $c.archived | Should -BeFalse
    }
}

Describe 'Merge-DpSettings preferences' {
    It 'stores a trimmed preferences string' {
        $m = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ preferences = '  I am a paralegal.  ' })
        $m.preferences | Should -Be 'I am a paralegal.'
    }
    It 'clears preferences when blank' {
        $cur = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ preferences = 'x' })
        $m = Merge-DpSettings -Current $cur -Patch ([pscustomobject]@{ preferences = '   ' })
        $m.preferences | Should -BeNullOrEmpty
    }
    It 'rejects an over-long preferences string' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ preferences = ('a' * 8001) }) } |
            Should -Throw -ExpectedMessage '*8000 characters*'
    }
    It 'defaults preferences to null' {
        (Get-DpDefaultSettings).preferences | Should -BeNullOrEmpty
    }
}

Describe 'New-DpTurnParameter preferences injection' {
    It 'adds an About-the-user block to the system prompt when preferences are set' {
        $s = Get-DpDefaultSettings
        $s.preferences = 'Write in British English.'
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        $p.SystemPrompt | Should -Match 'About the user'
        $p.SystemPrompt | Should -Match 'British English'
    }
    It 'omits the block when preferences are empty' {
        $s = Get-DpDefaultSettings
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        ($p.ContainsKey('SystemPrompt') -and $p.SystemPrompt -match 'About the user') | Should -BeFalse
    }
}

Describe 'Get-DpFileFind' {
    BeforeAll {
        $root = Join-Path $TestDrive 'proj'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'readme.md') -Value '# r' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'src' 'app.js') -Value 'x' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $root '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root '.git' 'config') -Value 'g' -Encoding utf8
    }
    It 'lists files recursively with forward-slashed relative paths' {
        $r = Get-DpFileFind -Root $root
        $rels = $r.files | ForEach-Object { $_.rel }
        $rels | Should -Contain 'readme.md'
        $rels | Should -Contain 'src/app.js'
    }
    It 'skips noisy folders like .git' {
        $r = Get-DpFileFind -Root $root
        ($r.files | Where-Object { $_.rel -like '.git/*' }).Count | Should -Be 0
    }
    It 'filters by a case-insensitive query against the relative path' {
        $r = Get-DpFileFind -Root $root -Query 'APP'
        ($r.files | ForEach-Object { $_.rel }) | Should -Contain 'src/app.js'
        ($r.files | ForEach-Object { $_.rel }) | Should -Not -Contain 'readme.md'
    }
    It 'reports a missing project folder' {
        $r = Get-DpFileFind -Root (Join-Path $TestDrive 'nope')
        $r.error | Should -Be 'No project folder.'
    }
    It 'marks truncated when the cap is hit' {
        $r = Get-DpFileFind -Root $root -Limit 1
        $r.truncated | Should -BeTrue
        $r.files.Count | Should -Be 1
    }
}

Describe 'Get-DpAtelierHealth' {
    It 'reports a configured root that does not exist as not OK' {
        $s = Get-DpDefaultSettings
        $missing = Join-Path $TestDrive 'no-such-agents'
        $s.agentsRoot = $missing
        $h = Get-DpAtelierHealth -Settings $s -HomeDirectory $TestDrive
        $agentCat = $h.categories | Where-Object { $_.id -eq 'agent' }
        $agentCat.roots[0].exists | Should -BeFalse
        $agentCat.roots[0].error | Should -Not -BeNullOrEmpty
    }
    It 'counts discovered customizations in a present root' {
        $s = Get-DpDefaultSettings
        $agents = Join-Path $TestDrive 'agents'
        New-Item -ItemType Directory -Path $agents -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $agents 'a.agent.md') -Value "---`nname: A`n---`nbody" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $agents 'b.agent.md') -Value "---`nname: B`n---`nbody" -Encoding utf8
        $s.agentsRoot = $agents
        $h = Get-DpAtelierHealth -Settings $s -HomeDirectory $TestDrive
        $agentCat = $h.categories | Where-Object { $_.id -eq 'agent' }
        $agentCat.roots[0].exists | Should -BeTrue
        $agentCat.roots[0].count | Should -Be 2
    }
    It 'returns summary counts' {
        $h = Get-DpAtelierHealth -Settings (Get-DpDefaultSettings) -HomeDirectory $TestDrive
        $h.ContainsKey('okCount') | Should -BeTrue
        $h.ContainsKey('totalRoots') | Should -BeTrue
    }
}

Describe 'Invoke-DpAtelierSetup' {
    It 'returns a script_missing error when the source has no setup script' {
        $src = Join-Path $TestDrive 'atelier-empty'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $r = Invoke-DpAtelierSetup -SourcePath $src -IsWindowsPlatform $true -Launcher { param($p) }
        $r.Ok | Should -BeFalse
        $r.Code | Should -Be 'script_missing'
    }
    It 'does not launch on a non-Windows host but returns the downloaded path' {
        $src = Join-Path $TestDrive 'atelier-nix'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'Setup-CopilotSettings.ps1') -Value '# noop' -Encoding utf8
        $r = Invoke-DpAtelierSetup -SourcePath $src -IsWindowsPlatform $false -Launcher { param($p) throw 'should not run' }
        $r.Ok | Should -BeTrue
        $r.Launched | Should -BeFalse
        $r.SourcePath | Should -Be $src
    }
    It 'launches the setup script on Windows via the injected launcher' {
        $src = Join-Path $TestDrive 'atelier-win'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $scriptPath = Join-Path $src 'Setup-CopilotSettings.ps1'
        Set-Content -LiteralPath $scriptPath -Value '# noop' -Encoding utf8
        $captured = @{ path = $null }
        $r = Invoke-DpAtelierSetup -SourcePath $src -IsWindowsPlatform $true -Launcher { param($p) $captured.path = $p }
        $r.Ok | Should -BeTrue
        $r.Launched | Should -BeTrue
        $r.ScriptPath | Should -Be $scriptPath
        $captured.path | Should -Be $scriptPath
    }
    It 'reports a launch_failed code when the launcher throws' {
        $src = Join-Path $TestDrive 'atelier-fail'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'Setup-CopilotSettings.ps1') -Value '# noop' -Encoding utf8
        $r = Invoke-DpAtelierSetup -SourcePath $src -IsWindowsPlatform $true -Launcher { param($p) throw 'boom' }
        $r.Ok | Should -BeFalse
        $r.Code | Should -Be 'launch_failed'
    }
}

Describe 'Resolve-DpAgentsRoot' {
    It 'returns the configured Agents root unchanged when Settings has one' {
        $configured = Join-Path $TestDrive 'my-agents'
        $r = Resolve-DpAgentsRoot -Settings @{ agentsRoot = $configured } -HomeDirectory $TestDrive
        $r | Should -Be $configured
    }
    It 'falls back to ~/.copilot/agents when it exists and none is configured' {
        $copilotAgents = Join-Path $TestDrive '.copilot/agents'
        New-Item -ItemType Directory -Path $copilotAgents -Force | Out-Null
        $r = Resolve-DpAgentsRoot -Settings @{ agentsRoot = $null } -HomeDirectory $TestDrive
        $r | Should -Be $copilotAgents
    }
    It 'returns null when none is configured and ~/.copilot/agents does not exist' {
        $empty = Join-Path $TestDrive 'no-copilot-here'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Resolve-DpAgentsRoot -Settings @{ agentsRoot = '' } -HomeDirectory $empty | Should -BeNullOrEmpty
    }
}

Describe 'Get-DpGitDiff' {
    It 'reports no project folder when the root is missing' {
        $r = Get-DpGitDiff -Root (Join-Path $TestDrive 'no-such') -Path 'x.txt'
        $r.error | Should -Be 'No project folder.'
    }
    It 'refuses a path outside the project folder' {
        $root = Join-Path $TestDrive 'gd-root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $r = Get-DpGitDiff -Root $root -Path (Join-Path $TestDrive 'elsewhere.txt')
        $r.error | Should -Be 'Outside the project folder.'
    }
}

Describe 'Invoke-DpGitRestore' {
    It 'reports no project folder when the root is missing' {
        $r = Invoke-DpGitRestore -Root (Join-Path $TestDrive 'no-such') -Paths @('x.txt')
        $r.error | Should -Be 'No project folder.'
    }
    It 'errors on a non-git folder' {
        $root = Join-Path $TestDrive 'gr-root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $r = Invoke-DpGitRestore -Root $root -Paths @('x.txt')
        $r.error | Should -Not -BeNullOrEmpty
    }
}

Describe 'Git diff/restore against a real repository' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $repo = Join-Path $TestDrive 'realrepo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        git init -q | Out-Null
        git config user.email 'test@example.com' | Out-Null
        git config user.name 'Test' | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value "line one`n" -Encoding utf8
        git add . | Out-Null
        git commit -q -m 'init' | Out-Null
        Pop-Location
    }
    It 'shows a diff for a modified tracked file' {
        Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value "line one changed`n" -Encoding utf8
        $r = Get-DpGitDiff -Root $repo -Path 'tracked.txt'
        $r.isRepo | Should -BeTrue
        $r.diff | Should -Match 'line one changed'
    }
    It 'flags an untracked new file and returns its content' {
        Set-Content -LiteralPath (Join-Path $repo 'new.txt') -Value "brand new`n" -Encoding utf8
        $r = Get-DpGitDiff -Root $repo -Path 'new.txt'
        $r.untracked | Should -BeTrue
        $r.content | Should -Match 'brand new'
    }
    It 'restores a modified tracked file to HEAD and removes an untracked file' {
        Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value "dirty`n" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $repo 'created.txt') -Value "temp`n" -Encoding utf8
        $r = Invoke-DpGitRestore -Root $repo -Paths @('tracked.txt', 'created.txt')
        $r.restored | Should -Contain 'tracked.txt'
        $r.removed | Should -Contain 'created.txt'
        (Get-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Raw) | Should -Match 'line one'
        (Test-Path -LiteralPath (Join-Path $repo 'created.txt')) | Should -BeFalse
    }
}

Describe 'Reset-DpConversationForRerun' {
    BeforeEach {
        $script:conv = @{
            id = 'c1'; title = 'T'; pinned = $false; archived = $false
            messages = [System.Collections.Generic.List[object]]::new()
            history  = [System.Collections.Generic.List[object]]::new()
        }
        $conv.messages.Add(@{ id = 'm1'; role = 'user'; text = 'first' })
        $conv.messages.Add(@{ id = 'm2'; role = 'assistant'; text = 'answer one' })
        $conv.messages.Add(@{ id = 'm3'; role = 'user'; text = 'second' })
        $conv.messages.Add(@{ id = 'm4'; role = 'assistant'; text = 'answer two' })
    }
    It 'truncates to before the given user message and returns its text' {
        $prompt = Reset-DpConversationForRerun -Conversation $conv -FromMessageId 'm3'
        $prompt | Should -Be 'second'
        $conv.messages.Count | Should -Be 2
        $conv.messages[-1].id | Should -Be 'm2'
    }
    It 'rebuilds the engine history from the surviving messages' {
        $null = Reset-DpConversationForRerun -Conversation $conv -FromMessageId 'm3'
        $conv.history.Count | Should -Be 2
        $conv.history[0].role | Should -Be 'user'
        $conv.history[0].content | Should -Be 'first'
        $conv.history[1].role | Should -Be 'assistant'
    }
    It 'regenerate-style: truncating the last user message keeps the earlier exchange' {
        $prompt = Reset-DpConversationForRerun -Conversation $conv -FromMessageId 'm3'
        $prompt | Should -Be 'second'
        $conv.messages.Count | Should -Be 2
    }
    It 'returns null for an unknown id' {
        Reset-DpConversationForRerun -Conversation $conv -FromMessageId 'nope' | Should -BeNullOrEmpty
        $conv.messages.Count | Should -Be 4
    }
    It 'returns null when the id is an assistant message' {
        Reset-DpConversationForRerun -Conversation $conv -FromMessageId 'm2' | Should -BeNullOrEmpty
        $conv.messages.Count | Should -Be 4
    }
    It 'clears history when re-running the very first message' {
        $prompt = Reset-DpConversationForRerun -Conversation $conv -FromMessageId 'm1'
        $prompt | Should -Be 'first'
        $conv.messages.Count | Should -Be 0
        $conv.history.Count | Should -Be 0
    }
}

Describe 'Reference files and spend warning settings' {
    It 'stores trimmed, de-duplicated reference file paths' {
        $m = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ referenceFiles = @('  a.md ', 'b.md', 'a.md') })
        $m.referenceFiles | Should -Be @('a.md', 'b.md')
    }
    It 'accepts a non-negative cost budget and rejects a negative one' {
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ costBudgetUSD = 5 })).costBudgetUSD | Should -Be 5
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ costBudgetUSD = -1 }) } |
            Should -Throw -ExpectedMessage '*zero or greater*'
    }
    It 'defaults referenceFiles to an empty array and budget to 0' {
        $s = Get-DpDefaultSettings
        , $s.referenceFiles | Should -BeOfType [System.Array]
        $s.referenceFiles.Count | Should -Be 0
        $s.costBudgetUSD | Should -Be 0
    }
}

Describe 'New-DpTurnParameter reference files injection' {
    It 'lists reference file paths in the system prompt when set and a workspace is selected' {
        $s = Get-DpDefaultSettings
        $s.workspaceFolder = $TestDrive
        $s.referenceFiles = @('docs/style.md', 'data/contacts.csv')
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        $p.SystemPrompt | Should -Match 'Reference files'
        $p.SystemPrompt | Should -Match 'docs/style.md'
        $p.SystemPrompt | Should -Match 'data/contacts.csv'
    }
    It 'omits reference files when no workspace is selected' {
        $s = Get-DpDefaultSettings
        $s.referenceFiles = @('docs/style.md')
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        ($p.ContainsKey('SystemPrompt') -and $p.SystemPrompt -match 'Reference files') | Should -BeFalse
    }
}

Describe 'Resolve-DpEngineModule' {
    BeforeAll {
        # Ensure Install-Module is resolvable so Pester can mock it even after
        # Get-Module itself is mocked (otherwise the first mock setup that follows
        # a Get-Module mock fails to auto-load PowerShellGet).
        Import-Module PowerShellGet -ErrorAction SilentlyContinue
        function New-FakeModuleInfo {
            param([string]$Path, [string]$Version = '1.0.0')
            [pscustomobject]@{ Path = $Path; Version = [version]$Version }
        }
    }

    It 'returns an explicit path without consulting the Gallery' {
        Mock Get-Module { }
        Mock Install-Module { }
        $file = Join-Path $TestDrive 'ShellPilot.psd1'
        Set-Content -LiteralPath $file -Value '@{}' -NoNewline
        $r = Resolve-DpEngineModule -Path $file
        $r.Path | Should -Be ((Resolve-Path -LiteralPath $file).Path)
        $r.Installed | Should -BeFalse
        $r.Error | Should -BeNullOrEmpty
        Should -Invoke Get-Module -Times 0
        Should -Invoke Install-Module -Times 0
    }

    It 'reports an error for an explicit path that does not exist' {
        Mock Install-Module { }
        $r = Resolve-DpEngineModule -Path (Join-Path $TestDrive 'missing.psd1')
        $r.Path | Should -BeNullOrEmpty
        $r.Error | Should -Match 'not found'
        Should -Invoke Install-Module -Times 0
    }

    It 'uses an already-available module and does not install' {
        Mock Get-Module { New-FakeModuleInfo -Path 'C:\mods\ShellPilot\1.2.0\ShellPilot.psd1' -Version '1.2.0' }
        Mock Install-Module { }
        $r = Resolve-DpEngineModule
        $r.Path | Should -Be 'C:\mods\ShellPilot\1.2.0\ShellPilot.psd1'
        $r.Installed | Should -BeFalse
        Should -Invoke Install-Module -Times 0
    }

    It 'picks the newest available version' {
        Mock Get-Module {
            New-FakeModuleInfo -Path 'C:\mods\ShellPilot\1.0.0\ShellPilot.psd1' -Version '1.0.0'
            New-FakeModuleInfo -Path 'C:\mods\ShellPilot\2.5.0\ShellPilot.psd1' -Version '2.5.0'
        }
        Mock Install-Module { }
        (Resolve-DpEngineModule).Path | Should -Be 'C:\mods\ShellPilot\2.5.0\ShellPilot.psd1'
    }

    It 'installs from the Gallery into CurrentUser with prerelease allowed when missing' {
        $script:spInstalled = $false
        Mock Get-Module { if ($script:spInstalled) { New-FakeModuleInfo -Path 'C:\u\ShellPilot\0.1.0\ShellPilot.psd1' -Version '0.1.0' } }
        Mock Install-Module { $script:spInstalled = $true }
        $r = Resolve-DpEngineModule
        $r.Installed | Should -BeTrue
        $r.Path | Should -Be 'C:\u\ShellPilot\0.1.0\ShellPilot.psd1'
        $r.Error | Should -BeNullOrEmpty
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'ShellPilot' -and $Scope -eq 'CurrentUser' -and $AllowPrerelease
        }
    }

    It 'excludes prerelease when -StableOnly is set' {
        $script:spInstalled = $false
        Mock Get-Module { if ($script:spInstalled) { New-FakeModuleInfo -Path 'C:\u\ShellPilot\1.0.0\ShellPilot.psd1' } }
        Mock Install-Module { $script:spInstalled = $true }
        $r = Resolve-DpEngineModule -StableOnly
        $r.Installed | Should -BeTrue
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { -not $AllowPrerelease }
    }

    It 'does not install when -SkipInstall is set and the module is missing' {
        Mock Get-Module { }
        Mock Install-Module { }
        $r = Resolve-DpEngineModule -SkipInstall
        $r.Path | Should -BeNullOrEmpty
        $r.Installed | Should -BeFalse
        $r.Error | Should -Match 'skipped'
        Should -Invoke Install-Module -Times 0
    }

    It 'captures a Gallery install failure as an error' {
        Mock Get-Module { }
        Mock Install-Module { throw 'no network' }
        $r = Resolve-DpEngineModule
        $r.Installed | Should -BeFalse
        $r.Path | Should -BeNullOrEmpty
        $r.Error | Should -Match 'Failed to install'
    }

    It 'errors when the module installs but cannot be located afterwards' {
        Mock Get-Module { }
        Mock Install-Module { }
        $r = Resolve-DpEngineModule
        $r.Installed | Should -BeTrue
        $r.Path | Should -BeNullOrEmpty
        $r.Error | Should -Match 'could not be located'
    }
}

Describe 'Get-DpDefaultBranch' {
    BeforeAll {
        function Ok($out) { @{ Ok = $true; ExitCode = 0; StdOut = $out; StdErr = '' } }
        function Fail { @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' } }
        $script:dbDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dbDir | Out-Null
    }

    It 'returns the remote HEAD short name when origin/HEAD is set' {
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            if (($Arguments -join ' ') -match 'symbolic-ref') { return Ok "origin/main`n" }
            Fail
        }
        Get-DpDefaultBranch -Path $script:dbDir | Should -Be 'main'
    }

    It 'falls back to a local main when origin/HEAD is unset' {
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            $j = $Arguments -join ' '
            if ($j -match 'symbolic-ref') { return Fail }
            if ($j -match 'refs/heads/main') { return Ok '' }
            Fail
        }
        Get-DpDefaultBranch -Path $script:dbDir | Should -Be 'main'
    }

    It 'falls back to master when only master exists' {
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            $j = $Arguments -join ' '
            if ($j -match 'symbolic-ref') { return Fail }
            if ($j -match 'refs/heads/main') { return Fail }
            if ($j -match 'refs/heads/master') { return Ok '' }
            Fail
        }
        Get-DpDefaultBranch -Path $script:dbDir | Should -Be 'master'
    }

    It 'returns null when no default can be determined' {
        Mock -CommandName Invoke-DpGitCommand -MockWith { Fail }
        Get-DpDefaultBranch -Path $script:dbDir | Should -BeNullOrEmpty
    }

    It 'returns null for a missing folder without calling git' {
        Mock -CommandName Invoke-DpGitCommand -MockWith { Fail }
        Get-DpDefaultBranch -Path (Join-Path $TestDrive 'no-such-dir-xyz') | Should -BeNullOrEmpty
        Should -Invoke Invoke-DpGitCommand -Times 0
    }
}

Describe 'Invoke-DpGitFetch' {
    BeforeAll {
        function Ok($out) { @{ Ok = $true; ExitCode = 0; StdOut = $out; StdErr = '' } }
        $script:fDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:fDir | Out-Null
    }

    It 'reports no remote when none is configured' {
        Mock -CommandName Invoke-DpGitCommand -MockWith { Ok '' }
        $r = Invoke-DpGitFetch -Path $script:fDir
        $r.hasRemote | Should -BeFalse
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'No remote'
    }

    It 'fetches when a remote exists' {
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            $j = $Arguments -join ' '
            if ($j -eq 'remote') { return Ok "origin`n" }
            if ($j -match 'fetch') { return Ok '' }
            @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' }
        }
        $r = Invoke-DpGitFetch -Path $script:fDir
        $r.hasRemote | Should -BeTrue
        $r.ok | Should -BeTrue
    }

    It 'captures a fetch failure (offline / auth)' {
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            $j = $Arguments -join ' '
            if ($j -eq 'remote') { return Ok "origin`n" }
            if ($j -match 'fetch') { return @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = 'could not read from remote' } }
            @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' }
        }
        $r = Invoke-DpGitFetch -Path $script:fDir
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'could not read'
    }

    It 'reports a missing folder' {
        $r = Invoke-DpGitFetch -Path (Join-Path $TestDrive 'no-such-fetch')
        $r.error | Should -Be 'No project folder.'
    }
}

Describe 'Get-DpBranchList' {
    BeforeAll {
        function Ok($out) { @{ Ok = $true; ExitCode = 0; StdOut = $out; StdErr = '' } }
        $script:blDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:blDir | Out-Null
    }

    It 'returns isRepo false for a non-repo' {
        Mock -CommandName Get-DpGitStatus -MockWith { @{ gitAvailable = $true; isRepo = $false; branch = $null; detached = $false; branches = @(); root = $null; error = 'not a repo' } }
        (Get-DpBranchList -Path $script:blDir).isRepo | Should -BeFalse
    }

    It 'flags merged local branches against a local default (no remote)' {
        Mock -CommandName Get-DpGitStatus -MockWith { @{ gitAvailable = $true; isRepo = $true; branch = 'feature'; detached = $false; branches = @('main', 'feature', 'done'); root = 'C:\r'; error = $null } }
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            $j = $Arguments -join ' '
            if ($j -eq 'remote') { return Ok '' }
            if ($j -match 'symbolic-ref') { return @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' } }
            if ($j -match 'show-ref --verify --quiet refs/heads/main') { return Ok '' }
            if ($j -match 'for-each-ref --format=%\(refname:short\) refs/heads') { return Ok "main`nfeature`ndone`n" }
            if ($j -match 'branch -r --merged') { return Ok '' }
            if ($j -match 'branch --merged') { return Ok "main`ndone`n" }
            @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' }
        }
        $r = Get-DpBranchList -Path $script:blDir
        $r.isRepo | Should -BeTrue
        $r.currentBranch | Should -Be 'feature'
        $r.defaultBranch | Should -Be 'main'
        $r.hasRemote | Should -BeFalse
        @($r.branches).Count | Should -Be 3
        ($r.branches | Where-Object { $_.name -eq 'feature' }).merged | Should -BeFalse
        ($r.branches | Where-Object { $_.name -eq 'done' }).merged | Should -BeTrue
        ($r.branches | Where-Object { $_.name -eq 'main' }).isDefault | Should -BeTrue
        ($r.branches | Where-Object { $_.name -eq 'feature' }).isCurrent | Should -BeTrue
    }

    It 'includes remote-only branches and marks merged ones (origin/HEAD excluded)' {
        Mock -CommandName Get-DpGitStatus -MockWith { @{ gitAvailable = $true; isRepo = $true; branch = 'main'; detached = $false; branches = @('main', 'feature'); root = 'C:\r'; error = $null } }
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            $j = $Arguments -join ' '
            if ($j -eq 'remote') { return Ok "origin`n" }
            if ($j -match 'symbolic-ref') { return Ok "origin/main`n" }
            if ($j -match 'for-each-ref --format=%\(refname:short\) refs/heads') { return Ok "main`nfeature`n" }
            if ($j -match 'for-each-ref --format=%\(refname:short\) refs/remotes') { return Ok "origin/main`norigin/feature`norigin/release`norigin/HEAD`n" }
            if ($j -match 'branch -r --merged') { return Ok "origin/main`norigin/release`n" }
            if ($j -match 'branch --merged') { return Ok "main`n" }
            @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' }
        }
        $r = Get-DpBranchList -Path $script:blDir
        $r.hasRemote | Should -BeTrue
        $r.defaultBranch | Should -Be 'main'
        $remoteOnly = @($r.branches | Where-Object { $_.isRemote })
        $remoteOnly.Count | Should -Be 1
        $remoteOnly[0].name | Should -Be 'origin/release'
        $remoteOnly[0].shortName | Should -Be 'release'
        $remoteOnly[0].merged | Should -BeTrue
        @($r.branches | Where-Object { $_.name -like '*HEAD*' }).Count | Should -Be 0
    }

    It 'fetches first when -Fetch is set and a remote exists' {
        Mock -CommandName Get-DpGitStatus -MockWith { @{ gitAvailable = $true; isRepo = $true; branch = 'main'; detached = $false; branches = @('main'); root = 'C:\r'; error = $null } }
        Mock -CommandName Invoke-DpGitFetch -MockWith { @{ ok = $true; hasRemote = $true; error = $null } }
        Mock -CommandName Invoke-DpGitCommand -MockWith {
            $j = $Arguments -join ' '
            if ($j -eq 'remote') { return Ok "origin`n" }
            if ($j -match 'symbolic-ref') { return Ok "origin/main`n" }
            if ($j -match 'for-each-ref --format=%\(refname:short\) refs/heads') { return Ok "main`n" }
            if ($j -match 'for-each-ref --format=%\(refname:short\) refs/remotes') { return Ok "origin/main`n" }
            if ($j -match 'branch -r --merged') { return Ok "origin/main`n" }
            if ($j -match 'branch --merged') { return Ok "main`n" }
            @{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = '' }
        }
        $r = Get-DpBranchList -Path $script:blDir -Fetch
        $r.fetched | Should -BeTrue
        Should -Invoke Invoke-DpGitFetch -Times 1
    }
}

Describe 'New-DpMergePlanPrompt' {
    It 'includes the branches, file paths and JSON instructions' {
        $p = New-DpMergePlanPrompt -SourceBranch 'feature' -DefaultBranch 'main' -Files @(
            @{ rel = 'src/a.txt'; content = "<<<<<<< HEAD`nours`n=======`ntheirs`n>>>>>>> feature" }
        )
        $p | Should -Match 'feature'
        $p | Should -Match 'main'
        $p | Should -Match ([regex]::Escape('src/a.txt'))
        $p | Should -Match 'resolutions'
        $p | Should -Match 'json'
    }
    It 'handles an empty file list without throwing' {
        { New-DpMergePlanPrompt -SourceBranch 'f' -DefaultBranch 'main' -Files @() } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-DpMergePlan' {
    It 'parses a fenced json block with nested objects' {
        $text = "Here is the plan:`n``````json`n{ ""resolutions"": [ { ""path"": ""a.txt"", ""content"": ""hello world"" } ], ""notes"": ""merged both"" }`n```````n"
        $r = ConvertFrom-DpMergePlan -Text $text
        $r.ok | Should -BeTrue
        @($r.resolutions).Count | Should -Be 1
        $r.resolutions[0].path | Should -Be 'a.txt'
        $r.resolutions[0].content | Should -Be 'hello world'
        $r.notes | Should -Be 'merged both'
    }
    It 'parses bare json without a fence' {
        $r = ConvertFrom-DpMergePlan -Text '{ "resolutions": [ { "path": "b.txt", "content": "x" } ] }'
        $r.ok | Should -BeTrue
        $r.resolutions[0].path | Should -Be 'b.txt'
    }
    It 'parses multiple resolutions' {
        $r = ConvertFrom-DpMergePlan -Text '{ "resolutions": [ { "path": "a", "content": "1" }, { "path": "b", "content": "2" } ] }'
        @($r.resolutions).Count | Should -Be 2
    }
    It 'reports invalid json' {
        $r = ConvertFrom-DpMergePlan -Text '{ not json at all'
        $r.ok | Should -BeFalse
        $r.error | Should -Not -BeNullOrEmpty
    }
    It 'reports an empty response' {
        (ConvertFrom-DpMergePlan -Text '').ok | Should -BeFalse
    }
    It 'reports a plan with no resolutions' {
        $r = ConvertFrom-DpMergePlan -Text '{ "resolutions": [] }'
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'no file resolutions'
    }
    It 'skips a resolution missing a path or content' {
        $r = ConvertFrom-DpMergePlan -Text '{ "resolutions": [ { "path": "a.txt", "content": "ok" }, { "path": "" , "content": "x" }, { "content": "no path" } ] }'
        $r.ok | Should -BeTrue
        @($r.resolutions).Count | Should -Be 1
    }
}

Describe 'New-DpTitlePrompt' {
    It 'includes the user prompt and asks for a short title' {
        $p = New-DpTitlePrompt -Prompt 'Please add a dark mode toggle to the settings page'
        $p | Should -Match 'dark mode toggle'
        $p | Should -Match 'short title'
    }
    It 'truncates a very long prompt to 800 characters of input' {
        # 'Z' never appears in the instruction text, so counting it isolates the input.
        $p = New-DpTitlePrompt -Prompt ('Z' * 5000)
        ([regex]::Matches($p, 'Z')).Count | Should -Be 800
    }
    It 'accepts an empty prompt without throwing' {
        { New-DpTitlePrompt -Prompt '' } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-DpTitleResult' {
    It 'returns a plain title unchanged' {
        ConvertFrom-DpTitleResult -Text 'Chat renaming feature request' | Should -Be 'Chat renaming feature request'
    }
    It 'strips surrounding straight quotes' {
        ConvertFrom-DpTitleResult -Text '"Stop button malfunction"' | Should -Be 'Stop button malfunction'
    }
    It 'strips surrounding smart quotes' {
        $smart = [char]0x201C + 'Extend menu options' + [char]0x201D
        ConvertFrom-DpTitleResult -Text $smart | Should -Be 'Extend menu options'
    }
    It 'strips a leading Title: label' {
        ConvertFrom-DpTitleResult -Text 'Title: Merge changes to main' | Should -Be 'Merge changes to main'
    }
    It 'strips a Markdown heading marker' {
        ConvertFrom-DpTitleResult -Text '## Task cost inquiry' | Should -Be 'Task cost inquiry'
    }
    It 'unwraps a fenced code block' {
        $fence = '```'
        ConvertFrom-DpTitleResult -Text "$fence`nAnimate donut spinner`n$fence" | Should -Be 'Animate donut spinner'
    }
    It 'skips a leading label line and uses the next line' {
        ConvertFrom-DpTitleResult -Text "Here is a concise title:`nRemove prompt history" | Should -Be 'Remove prompt history'
    }
    It 'collapses whitespace and strips trailing punctuation' {
        ConvertFrom-DpTitleResult -Text 'Close   project   functionality.' | Should -Be 'Close project functionality'
    }
    It 'caps the word count' {
        ConvertFrom-DpTitleResult -Text 'one two three four five six seven eight nine ten' -MaxWords 4 | Should -Be 'one two three four'
    }
    It 'returns empty for null, empty, or whitespace' {
        ConvertFrom-DpTitleResult -Text $null | Should -Be ''
        ConvertFrom-DpTitleResult -Text '' | Should -Be ''
        ConvertFrom-DpTitleResult -Text '   ' | Should -Be ''
    }
    It 'applies a hard character cap with an ellipsis' {
        $r = ConvertFrom-DpTitleResult -Text ('word ' * 40) -MaxWords 40 -MaxLength 20
        $r.Length | Should -BeLessOrEqual 21
        $r[-1] | Should -Be ([char]0x2026)
    }
}

Describe 'Conversation title lock' {
    It 'defaults titleLocked to false on a new Conversation' {
        (New-DpConversation -Title 'X').titleLocked | Should -BeFalse
    }
    It 'round-trips titleLocked through Save and Import' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $conv = New-DpConversation -Title 'Locked one'
        $conv.titleLocked = $true
        Save-DpConversationStore -Store @{ $conv.id = $conv } -Directory $dir
        $loaded = Import-DpConversationStore -Directory $dir
        $loaded[$conv.id].titleLocked | Should -BeTrue
    }
    It 'defaults titleLocked to false for a legacy store without the field' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $legacy = @{ version = 1; conversations = @(@{ id = 'c_legacy'; title = 'Old'; createdUtc = '2026-01-01T00:00:00.0000000Z'; updatedUtc = '2026-01-01T00:00:00.0000000Z'; messages = @(); history = @() }) } | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath (Join-Path $dir 'conversations.json') -Value $legacy -Encoding utf8
        (Import-DpConversationStore -Directory $dir)['c_legacy'].titleLocked | Should -BeFalse
    }
}

Describe 'New-DpCompactionPrompt' {
    It 'renders the history into a transcript and asks for a summary' {
        $p = New-DpCompactionPrompt -History @(
            @{ role = 'user'; content = 'Refactor the parser module' },
            @{ role = 'assistant'; content = 'Updated Parser.ps1' }
        )
        $p | Should -Match 'Refactor the parser module'
        $p | Should -Match 'Parser\.ps1'
        $p | Should -Match 'Transcript:'
        $p | Should -Match '(?i)summar'
    }
    It 'renders both hashtable and PSCustomObject entries' {
        $p = New-DpCompactionPrompt -History @(
            @{ role = 'user'; content = 'hash entry marker' },
            [pscustomobject]@{ role = 'assistant'; content = 'object entry marker' }
        )
        $p | Should -Match 'hash entry marker'
        $p | Should -Match 'object entry marker'
    }
    It 'keeps the most recent content when the transcript exceeds the cap' {
        $hist = @(
            @{ role = 'user'; content = ('A' * 500) },
            @{ role = 'assistant'; content = 'RECENT_MARKER' }
        )
        $p = New-DpCompactionPrompt -History $hist -MaxInputChars 120
        $p | Should -Match 'RECENT_MARKER'
    }
    It 'accepts null or empty history without throwing' {
        { New-DpCompactionPrompt -History @() } | Should -Not -Throw
        { New-DpCompactionPrompt -History $null } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-DpCompactionResult' {
    It 'returns a plain multi-line summary trimmed' {
        ConvertFrom-DpCompactionResult -Text "  Line one`nLine two  " | Should -Be "Line one`nLine two"
    }
    It 'unwraps a fenced code block' {
        $fence = '```'
        ConvertFrom-DpCompactionResult -Text "$fence`nGoal: ship it`n$fence" | Should -Be 'Goal: ship it'
    }
    It 'drops a leading label line' {
        ConvertFrom-DpCompactionResult -Text "Summary:`n- point one`n- point two" | Should -Be "- point one`n- point two"
    }
    It 'collapses three or more blank lines' {
        ConvertFrom-DpCompactionResult -Text "a`n`n`n`nb" | Should -Be "a`n`nb"
    }
    It 'returns empty for null, empty or whitespace' {
        ConvertFrom-DpCompactionResult -Text $null | Should -Be ''
        ConvertFrom-DpCompactionResult -Text '' | Should -Be ''
        ConvertFrom-DpCompactionResult -Text '   ' | Should -Be ''
    }
    It 'applies a hard character cap with an ellipsis' {
        $r = ConvertFrom-DpCompactionResult -Text ('x' * 100) -MaxLength 20
        $r.Length | Should -Be 21
        $r[-1] | Should -Be ([char]0x2026)
    }
}

Describe 'Get-DpMemoryLimits' {
    It 'returns the User Profile and Agent Memory caps' {
        $l = Get-DpMemoryLimits
        $l.userProfile | Should -Be 8000
        $l.agentMemory | Should -Be 12000
    }
}

Describe 'Get-DpDefaultSettings memory' {
    It 'defaults memoryLearning on' {
        (Get-DpDefaultSettings).memoryLearning | Should -BeTrue
    }
}

Describe 'Merge-DpSettings memoryLearning' {
    It 'toggles memoryLearning off and on' {
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ memoryLearning = $false })).memoryLearning | Should -BeFalse
        (Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch ([pscustomobject]@{ memoryLearning = $true })).memoryLearning | Should -BeTrue
    }
}

Describe 'Agent memory store' {
    It 'returns an empty store when the file is missing' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $store = Import-DpMemoryStore -Directory $dir
        $store.text | Should -Be ''
        $store.updatedUtc | Should -BeNullOrEmpty
    }
    It 'round-trips text and updatedUtc through save and load' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $ts = [datetime]::Parse('2026-07-07T00:00:00Z').ToUniversalTime().ToString('o')
        Save-DpMemoryStore -Memory @{ text = "User likes Go`nUses Ubuntu"; updatedUtc = $ts } -Directory $dir
        $store = Import-DpMemoryStore -Directory $dir
        $store.text | Should -Be "User likes Go`nUses Ubuntu"
        # Normalised ISO-8601 UTC survives the JSON date-coercion round-trip.
        ([datetime]$store.updatedUtc).ToUniversalTime() | Should -Be ([datetime]::Parse('2026-07-07T00:00:00Z').ToUniversalTime())
    }
    It 'caps over-long text to the Agent Memory limit on load' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $cap = (Get-DpMemoryLimits).agentMemory
        Save-DpMemoryStore -Memory @{ text = ('y' * ($cap + 500)); updatedUtc = $null } -Directory $dir
        (Import-DpMemoryStore -Directory $dir).text.Length | Should -Be $cap
    }
}

Describe 'New-DpMemoryPrompt' {
    It 'includes the current notes and the recent exchange' {
        $p = New-DpMemoryPrompt -CurrentMemory 'User uses Go.' -Messages @(
            @{ role = 'user'; text = 'I always use poetry for Python.' }
            @{ role = 'assistant'; text = 'Noted.' }
        )
        $p | Should -Match 'User uses Go\.'
        $p | Should -Match 'poetry'
        $p | Should -Match 'NO_CHANGE'
        $p | Should -Match 'declarative facts'
    }
    It 'shows a no-notes placeholder when memory is empty' {
        (New-DpMemoryPrompt -CurrentMemory '' -Messages @(@{ role = 'user'; text = 'hi' })) | Should -Match 'no notes yet'
    }
    It 'accepts an empty or null message list without throwing' {
        { New-DpMemoryPrompt -CurrentMemory 'x' -Messages @() } | Should -Not -Throw
        { New-DpMemoryPrompt -CurrentMemory 'x' -Messages $null } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-DpMemoryResult' {
    It 'returns trimmed multi-line notes' {
        ConvertFrom-DpMemoryResult -Text "  a`nb  " | Should -Be "a`nb"
    }
    It 'unwraps a fenced code block' {
        $fence = '```'
        ConvertFrom-DpMemoryResult -Text "$fence`nUser likes tea`n$fence" | Should -Be 'User likes tea'
    }
    It 'treats the NO_CHANGE sentinel as no update' {
        ConvertFrom-DpMemoryResult -Text 'NO_CHANGE' | Should -Be ''
        ConvertFrom-DpMemoryResult -Text 'no change' | Should -Be ''
    }
    It 'returns empty for null or whitespace' {
        ConvertFrom-DpMemoryResult -Text $null | Should -Be ''
        ConvertFrom-DpMemoryResult -Text '   ' | Should -Be ''
    }
    It 'caps over-long output to the limit' {
        (ConvertFrom-DpMemoryResult -Text ('z' * 100) -MaxLength 40).Length | Should -BeLessOrEqual 40
    }
}

Describe 'New-DpTurnParameter agent memory injection' {
    It 'injects the agent memory as fenced reference notes when set' {
        $s = Get-DpDefaultSettings
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s -AgentMemory 'User deploys with Terraform.'
        $p.SystemPrompt | Should -Match 'saved notes about this user'
        $p.SystemPrompt | Should -Match 'Terraform'
        $p.SystemPrompt | Should -Match 'not as new'
    }
    It 'omits the memory block when no memory is set' {
        $s = Get-DpDefaultSettings
        $s.preferences = 'I am a tester.'
        $p = New-DpTurnParameter -Prompt 'hi' -Settings $s
        $p.SystemPrompt | Should -Match 'I am a tester'
        $p.SystemPrompt | Should -Not -Match 'saved notes about this user'
    }
}

Describe 'Get-DpMemoryPayload' {
    It 'reports both stores with caps and the learning flag' {
        $settings = Get-DpDefaultSettings
        $settings.preferences = 'I am a lawyer.'
        $settings.memoryLearning = $false
        $script:DeskPilot = @{
            Settings = $settings
            Memory   = @{ text = 'User is in Berlin.'; updatedUtc = '2026-07-07T00:00:00Z' }
        }
        $payload = Get-DpMemoryPayload
        $payload.userProfile.text | Should -Be 'I am a lawyer.'
        $payload.userProfile.cap | Should -Be 8000
        $payload.agentMemory.text | Should -Be 'User is in Berlin.'
        $payload.agentMemory.cap | Should -Be 12000
        $payload.agentMemory.chars | Should -Be ('User is in Berlin.'.Length)
        $payload.learning | Should -BeFalse
        $script:DeskPilot = $null
    }
}

Describe 'Compress-DpConversationHistory' {
    BeforeAll {
        $script:sixEntry = @(
            @{ role = 'user'; content = 'q1' }, @{ role = 'assistant'; content = 'a1' },
            @{ role = 'user'; content = 'q2' }, @{ role = 'assistant'; content = 'a2' },
            @{ role = 'user'; content = 'q3' }, @{ role = 'assistant'; content = 'a3' }
        )
    }
    It 'keeps the last KeepCount entries and prepends a summary pair' {
        $r = Compress-DpConversationHistory -History $script:sixEntry -Summary 'brief' -KeepCount 4
        $r.changed | Should -BeTrue
        $r.summarised | Should -Be 2
        $r.kept | Should -Be 4
        @($r.history).Count | Should -Be 6
        $r.history[0].role | Should -Be 'user'
        $r.history[1].role | Should -Be 'assistant'
        $r.history[1].content | Should -Be 'brief'
        $r.history[2].content | Should -Be 'q2'
        $r.history[5].content | Should -Be 'a3'
    }
    It 'leaves history unchanged when at or below KeepCount + 1 entries' {
        $short = @(@{ role = 'user'; content = 'hi' }, @{ role = 'assistant'; content = 'yo' })
        $r = Compress-DpConversationHistory -History $short -Summary 'brief' -KeepCount 4
        $r.changed | Should -BeFalse
        @($r.history).Count | Should -Be 2
    }
    It 'leaves history unchanged when the summary is empty' {
        $r = Compress-DpConversationHistory -History $script:sixEntry -Summary '   ' -KeepCount 4
        $r.changed | Should -BeFalse
        @($r.history).Count | Should -Be 6
    }
    It 'does not mutate the input history' {
        $copy = @($script:sixEntry)
        $null = Compress-DpConversationHistory -History $copy -Summary 'brief' -KeepCount 4
        @($copy).Count | Should -Be 6
        $copy[0].content | Should -Be 'q1'
    }
    It 'keeps no verbatim entries when KeepCount is zero' {
        $r = Compress-DpConversationHistory -History $script:sixEntry -Summary 'brief' -KeepCount 0
        $r.changed | Should -BeTrue
        $r.kept | Should -Be 0
        @($r.history).Count | Should -Be 2
        $r.summarised | Should -Be 6
    }
}

Describe 'Merge helper guards (no git required)' {
    It 'Get-DpMergePreview reports a missing project folder' {
        (Get-DpMergePreview -Root (Join-Path $TestDrive 'no-such-mp') -Branch 'feature').error | Should -Be 'No project folder.'
    }
    It 'Invoke-DpGitMerge reports a missing project folder' {
        (Invoke-DpGitMerge -Root (Join-Path $TestDrive 'no-such-mm') -Branch 'feature').error | Should -Be 'No project folder.'
    }
    It 'Invoke-DpMergeApply reports a missing project folder' {
        (Invoke-DpMergeApply -Root (Join-Path $TestDrive 'no-such-ma') -Resolutions @()).error | Should -Be 'No project folder.'
    }
    It 'Invoke-DpBranchCleanup reports a missing project folder' {
        (Invoke-DpBranchCleanup -Root (Join-Path $TestDrive 'no-such-bc') -Branch 'feature').error | Should -Be 'No project folder.'
    }
    It 'Invoke-DpGitMergeAbort reports a missing project folder' {
        (Invoke-DpGitMergeAbort -Root (Join-Path $TestDrive 'no-such-ab')).error | Should -Be 'No project folder.'
    }
    It 'Invoke-DpGitMergeUndo rejects an invalid commit id' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        (Invoke-DpGitMergeUndo -Root $dir -Sha 'xyz').error | Should -Be 'Invalid commit id.'
    }
}

Describe 'Merge Wizard against a real repository' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        function New-MergeRepo {
            param([string]$Path)
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            & git -C $Path init -q 2>$null
            & git -C $Path symbolic-ref HEAD refs/heads/main 2>$null
            & git -C $Path config user.email 'test@example.com' 2>$null
            & git -C $Path config user.name 'Test' 2>$null
            & git -C $Path config commit.gpgsign false 2>$null
        }
    }

    Context 'clean merge, preview and cleanup' {
        BeforeAll {
            $script:repoA = Join-Path $TestDrive 'mergeA'
            New-MergeRepo -Path $script:repoA
            Set-Content -LiteralPath (Join-Path $script:repoA 'base.txt') -Value "base`n" -NoNewline
            & git -C $script:repoA add . 2>$null
            & git -C $script:repoA commit -q -m 'init' 2>$null
            & git -C $script:repoA checkout -q -b feature 2>$null
            Set-Content -LiteralPath (Join-Path $script:repoA 'feature.txt') -Value "feature work`n" -NoNewline
            & git -C $script:repoA add . 2>$null
            & git -C $script:repoA commit -q -m 'add feature file' 2>$null
            & git -C $script:repoA checkout -q main 2>$null
        }

        It 'previews the incoming commits against the default branch' {
            $p = Get-DpMergePreview -Root $script:repoA -Branch 'feature'
            $p.isRepo | Should -BeTrue
            $p.defaultBranch | Should -Be 'main'
            $p.commitCount | Should -Be 1
            $p.commits[0].subject | Should -Be 'add feature file'
            $p.commits[0].sha | Should -Match '^[0-9a-f]{40}$'
            $p.fastForward | Should -BeTrue
            $p.alreadyMerged | Should -BeFalse
        }

        It 'blocks merging the default branch into itself' {
            (Get-DpMergePreview -Root $script:repoA -Branch 'main').sameBranch | Should -BeTrue
        }

        It 'merges the feature branch (fast-forward)' {
            $m = Invoke-DpGitMerge -Root $script:repoA -Branch 'feature'
            $m.status | Should -Be 'success'
            $m.fastForward | Should -BeTrue
            $m.mergedSha | Should -Match '^[0-9a-f]{40}$'
            Test-Path -LiteralPath (Join-Path $script:repoA 'feature.txt') | Should -BeTrue
        }

        It 'shows the branch as already merged afterwards' {
            $p = Get-DpMergePreview -Root $script:repoA -Branch 'feature'
            $p.alreadyMerged | Should -BeTrue
            $p.commitCount | Should -Be 0
        }

        It 'deletes the local branch on cleanup' {
            $cl = Invoke-DpBranchCleanup -Root $script:repoA -Branch 'feature'
            $cl.localDeleted | Should -BeTrue
            $cl.localError | Should -BeNullOrEmpty
            (& git -C $script:repoA branch --format='%(refname:short)' 2>$null) | Should -Not -Contain 'feature'
        }

        It 'reports no remote when remote cleanup is requested without a remote' {
            & git -C $script:repoA checkout -q -b tmp 2>$null
            & git -C $script:repoA checkout -q main 2>$null
            $cl = Invoke-DpBranchCleanup -Root $script:repoA -Branch 'tmp' -DeleteRemote -PushDefaultBranch
            $cl.localDeleted | Should -BeTrue
            $cl.remoteError | Should -Be 'No remote configured.'
            $cl.pushError | Should -Be 'No remote configured.'
        }
    }

    Context 'conflict, plan read, apply and undo' {
        BeforeAll {
            $script:repoB = Join-Path $TestDrive 'mergeB'
            New-MergeRepo -Path $script:repoB
            Set-Content -LiteralPath (Join-Path $script:repoB 'conflict.txt') -Value "line ours`n" -NoNewline
            & git -C $script:repoB add . 2>$null
            & git -C $script:repoB commit -q -m 'init' 2>$null
            & git -C $script:repoB checkout -q -b feat2 2>$null
            Set-Content -LiteralPath (Join-Path $script:repoB 'conflict.txt') -Value "line theirs`n" -NoNewline
            & git -C $script:repoB add . 2>$null
            & git -C $script:repoB commit -q -m 'theirs change' 2>$null
            & git -C $script:repoB checkout -q main 2>$null
            Set-Content -LiteralPath (Join-Path $script:repoB 'conflict.txt') -Value "line ours edited`n" -NoNewline
            & git -C $script:repoB add . 2>$null
            & git -C $script:repoB commit -q -m 'ours change' 2>$null
        }

        It 'returns conflict status with the conflicted file and a pre-merge sha' {
            $script:mergeB = Invoke-DpGitMerge -Root $script:repoB -Branch 'feat2'
            $script:mergeB.status | Should -Be 'conflict'
            $script:mergeB.conflictFiles | Should -Contain 'conflict.txt'
            $script:mergeB.preMergeSha | Should -Match '^[0-9a-f]{40}$'
        }

        It 'reads the conflicted file as text with markers' {
            $cf = Get-DpMergeConflict -Root $script:repoB
            $cf.inMerge | Should -BeTrue
            $entry = $cf.files | Where-Object { $_.rel -eq 'conflict.txt' }
            $entry.binary | Should -BeFalse
            $entry.content | Should -Match '<<<<<<<'
            $entry.content | Should -Match '>>>>>>>'
        }

        It 'applies a resolution and completes the merge commit' {
            $apply = Invoke-DpMergeApply -Root $script:repoB -Resolutions @(@{ path = 'conflict.txt'; content = "line resolved`n" })
            $apply.ok | Should -BeTrue
            $apply.mergedSha | Should -Match '^[0-9a-f]{40}$'
            $apply.remaining.Count | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $script:repoB 'conflict.txt') -Raw) | Should -Match 'line resolved'
        }

        It 'undoes the merge back to the pre-merge commit' {
            $undo = Invoke-DpGitMergeUndo -Root $script:repoB -Sha $script:mergeB.preMergeSha
            $undo.ok | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $script:repoB 'conflict.txt') -Raw) | Should -Match 'line ours edited'
        }
    }

    Context 'abort a conflicted merge' {
        BeforeAll {
            $script:repoC = Join-Path $TestDrive 'mergeC'
            New-MergeRepo -Path $script:repoC
            Set-Content -LiteralPath (Join-Path $script:repoC 'c.txt') -Value "ours`n" -NoNewline
            & git -C $script:repoC add . 2>$null
            & git -C $script:repoC commit -q -m 'init' 2>$null
            & git -C $script:repoC checkout -q -b other 2>$null
            Set-Content -LiteralPath (Join-Path $script:repoC 'c.txt') -Value "theirs`n" -NoNewline
            & git -C $script:repoC add . 2>$null
            & git -C $script:repoC commit -q -m 'theirs' 2>$null
            & git -C $script:repoC checkout -q main 2>$null
            Set-Content -LiteralPath (Join-Path $script:repoC 'c.txt') -Value "ours edited`n" -NoNewline
            & git -C $script:repoC add . 2>$null
            & git -C $script:repoC commit -q -m 'ours' 2>$null
        }

        It 'aborts and restores the pre-merge working tree' {
            (Invoke-DpGitMerge -Root $script:repoC -Branch 'other').status | Should -Be 'conflict'
            $abort = Invoke-DpGitMergeAbort -Root $script:repoC
            $abort.ok | Should -BeTrue
            (& git -C $script:repoC rev-parse --verify --quiet MERGE_HEAD 2>$null) | Should -BeNullOrEmpty
            (Get-Content -LiteralPath (Join-Path $script:repoC 'c.txt') -Raw) | Should -Match 'ours edited'
        }
    }
}

Describe 'Invoke-DpPendingRequest' {
    BeforeAll {
        # Preserve any real server state (there is none in a unit run) so these
        # tests can never leak a fake listener into a later Describe block.
        $script:savedDeskPilot = $script:DeskPilot

        function New-DpFakeListener
        {
            param([int]$Pending, [switch]$AlwaysPending)

            $listener = [pscustomobject]@{ Remaining = $Pending; Accepted = 0; Always = [bool]$AlwaysPending }
            $listener | Add-Member -MemberType ScriptMethod -Name Pending -Value {
                if ($this.Always) { return $true }
                return $this.Remaining -gt 0
            }
            $listener | Add-Member -MemberType ScriptMethod -Name AcceptTcpClient -Value {
                $this.Remaining--
                $this.Accepted++
                # Unconnected on purpose: Invoke-DpClient's GetStream() throws and
                # is swallowed, so no socket I/O happens, yet the client still
                # satisfies the [TcpClient] parameter and gets closed.
                [System.Net.Sockets.TcpClient]::new()
            }
            return $listener
        }
    }

    AfterEach { $script:DeskPilot = $null }
    AfterAll { $script:DeskPilot = $script:savedDeskPilot }

    It 'no-ops when there is no server state' {
        $script:DeskPilot = $null
        { Invoke-DpPendingRequest } | Should -Not -Throw
    }

    It 'no-ops when no listener is registered' {
        $script:DeskPilot = @{ Listener = $null }
        { Invoke-DpPendingRequest } | Should -Not -Throw
    }

    It 'does not accept anything when the backlog is empty' {
        $listener = New-DpFakeListener -Pending 0
        $script:DeskPilot = @{ Listener = $listener }
        Invoke-DpPendingRequest
        $listener.Accepted | Should -Be 0
    }

    It 'services every pending connection and stops once the backlog is drained' {
        $listener = New-DpFakeListener -Pending 3
        $script:DeskPilot = @{ Listener = $listener }
        Invoke-DpPendingRequest
        $listener.Accepted | Should -Be 3
        $listener.Pending() | Should -BeFalse
    }

    It 'never services more than the cap in a single call' {
        $listener = New-DpFakeListener -AlwaysPending
        $script:DeskPilot = @{ Listener = $listener }
        Invoke-DpPendingRequest -MaxRequests 4
        $listener.Accepted | Should -Be 4
    }
}

Describe 'Test-DpAuthError' {
    It 'flags a 401 / Unauthorized message' {
        Test-DpAuthError -ErrorRecord 'Response status code does not indicate success: 401 (Unauthorized).' | Should -BeTrue
    }
    It 'flags a 403 / Forbidden message' {
        Test-DpAuthError -ErrorRecord 'The remote server returned 403 (Forbidden).' | Should -BeTrue
    }
    It 'flags the Engine session-token exchange failure' {
        Test-DpAuthError -ErrorRecord 'Session token exchange failed: some detail' | Should -BeTrue
    }
    It 'flags a missing token-file message' {
        Test-DpAuthError -ErrorRecord 'Token file not found: C:\Users\me\.shellpilot-token. Run Initialize-Shp first.' | Should -BeTrue
    }
    It 'recognises an auth failure wrapped in an inner exception' {
        $inner = [System.Exception]::new('Response status code does not indicate success: 401 (Unauthorized).')
        $outer = [System.Exception]::new('Get-ShpModel failed', $inner)
        Test-DpAuthError -ErrorRecord $outer | Should -BeTrue
    }
    It 'recognises an auth failure carried on an ErrorRecord' {
        $ex = [System.Exception]::new('Session token exchange failed: 401 Unauthorized')
        $rec = [System.Management.Automation.ErrorRecord]::new($ex, 'AuthError', [System.Management.Automation.ErrorCategory]::AuthenticationError, $null)
        Test-DpAuthError -ErrorRecord $rec | Should -BeTrue
    }
    It 'does NOT flag a transient network failure' {
        Test-DpAuthError -ErrorRecord 'Unable to connect to the remote server' | Should -BeFalse
    }
    It 'does NOT flag an unrelated engine error' {
        Test-DpAuthError -ErrorRecord 'The model returned an empty response.' | Should -BeFalse
    }
    It 'returns false for a null error' {
        Test-DpAuthError -ErrorRecord $null | Should -BeFalse
    }
}

Describe 'Test-DpTransientEngineError' {
    It 'flags the reported 403 session-token-exchange failure' {
        Test-DpTransientEngineError -ErrorRecord 'Session token exchange failed: Response status code does not indicate success: 403 (Forbidden).' | Should -BeTrue
    }
    It 'flags a 429 / too many requests' {
        Test-DpTransientEngineError -ErrorRecord 'Response status code does not indicate success: 429 (Too Many Requests).' | Should -BeTrue
    }
    It 'flags a 503 / service unavailable' {
        Test-DpTransientEngineError -ErrorRecord 'Response status code does not indicate success: 503 (Service Unavailable).' | Should -BeTrue
    }
    It 'flags a request timeout' {
        Test-DpTransientEngineError -ErrorRecord 'The operation has timed out.' | Should -BeTrue
    }
    It 'flags a dropped connection' {
        Test-DpTransientEngineError -ErrorRecord 'Unable to read data from the transport connection: An existing connection was forcibly closed by the remote host.' | Should -BeTrue
    }
    It 'recognises a transient failure wrapped in an inner exception' {
        $inner = [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).')
        $outer = [System.Exception]::new('Session token exchange failed', $inner)
        Test-DpTransientEngineError -ErrorRecord $outer | Should -BeTrue
    }
    It 'does NOT flag a 401 / expired sign-in (must not retry that)' {
        Test-DpTransientEngineError -ErrorRecord 'Session token exchange failed: Response status code does not indicate success: 401 (Unauthorized).' | Should -BeFalse
    }
    It 'does NOT flag a missing token file' {
        Test-DpTransientEngineError -ErrorRecord 'Token file not found: C:\Users\me\.shellpilot-token. Run Initialize-Shp first.' | Should -BeFalse
    }
    It 'does NOT flag an unrelated engine error' {
        Test-DpTransientEngineError -ErrorRecord 'The model returned an empty response.' | Should -BeFalse
    }
    It 'returns false for a null error' {
        Test-DpTransientEngineError -ErrorRecord $null | Should -BeFalse
    }
}
