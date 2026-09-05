#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Diagnostic Log' -Tag 'Unit' {
    It 'keeps the newest entries in sequence order when the entry capacity is exceeded' {
        $log = New-DpDiagnosticLog -MaxEntries 3 -MaxBytes 4096

        1..4 | ForEach-Object {
            Add-DpDiagnosticLog -Log $log -Severity 'information' -Component 'host' `
                -EventId "test.$_" -Summary "entry $_"
        }

        $entries = @(Get-DpDiagnosticLog -Log $log)
        $entries | Should -HaveCount 3
        $entries.summary | Should -Be @('entry 2', 'entry 3', 'entry 4')
        $entries.sequence | Should -Be @(2, 3, 4)
    }

    It 'evicts oldest entries until the UTF-8 byte ceiling holds' {
        $log = New-DpDiagnosticLog -MaxEntries 20 -MaxBytes 420

        1..4 | ForEach-Object {
            Add-DpDiagnosticLog -Log $log -Severity 'information' -Component 'host' `
                -EventId "byte.$_" -Summary ("$_" * 100)
        }

        $entries = @(Get-DpDiagnosticLog -Log $log)
        $entries.Count | Should -BeGreaterThan 0
        $entries.Count | Should -BeLessThan 4
        $entries[-1].eventId | Should -Be 'byte.4'
        $log.CurrentBytes | Should -BeLessOrEqual $log.MaxBytes
        ($entries.bytes | Measure-Object -Sum).Sum | Should -Be $log.CurrentBytes
    }

    It 'clears retained entries without reusing sequence numbers' {
        $log = New-DpDiagnosticLog -MaxEntries 10 -MaxBytes 4096
        Add-DpDiagnosticLog -Log $log -Severity 'information' -Component 'host' -EventId 'before' -Summary 'before'

        Clear-DpDiagnosticLog -Log $log | Should -Be 1
        @(Get-DpDiagnosticLog -Log $log) | Should -HaveCount 0

        Add-DpDiagnosticLog -Log $log -Severity 'information' -Component 'host' -EventId 'after' -Summary 'after'
        $entries = @(Get-DpDiagnosticLog -Log $log)
        $entries[0].sequence | Should -Be 2
    }

    It 'returns only entries after a polling cursor' {
        $log = New-DpDiagnosticLog -MaxEntries 10 -MaxBytes 4096
        1..4 | ForEach-Object {
            Add-DpDiagnosticLog -Log $log -Severity 'information' -Component 'host' -EventId "poll.$_" -Summary "entry $_"
        }

        $entries = @(Get-DpDiagnosticLog -Log $log -AfterSequence 2)
        $entries.sequence | Should -Be @(3, 4)
    }

    It 'redacts configured tokens, authorization values, and credentialed URLs' {
        $script:DeskPilot = @{
            Token    = 'session-secret-123'
            Intercom = @{ Token = '123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi' }
        }
        $log = New-DpDiagnosticLog -MaxEntries 10 -MaxBytes 4096
        $summary = 'Bearer abc.def.ghi session-secret-123 123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi https://user:pass@example.test/path?access_token=visible'

        Add-DpDiagnosticLog -Log $log -Severity 'error' -Component 'host' -EventId 'secret' -Summary $summary

        $json = Get-DpDiagnosticLog -Log $log | ConvertTo-Json -Compress
        $json | Should -Not -Match 'abc\.def\.ghi|session-secret-123|ABCDEFGHIJKLMNOPQRSTUVWXYZ|user:pass|visible'
        $json | Should -Match '<redacted>'
    }

    It 'redacts safely before the full Host Server state is initialized under StrictMode' {
        $script:DeskPilot = @{ Token = 'early-session-secret' }

        $safe = & {
            Set-StrictMode -Version Latest
            Protect-DpDiagnosticText -Text 'Bearer auth-value early-session-secret'
        }

        $safe | Should -Not -Match 'auth-value|early-session-secret'
    }

    It 'serializes concurrent appends without duplicate or missing sequences' {
        $log = New-DpDiagnosticLog -MaxEntries 500 -MaxBytes 1048576
        $addPath = Join-Path $privateRoot 'Add-DpDiagnosticLog.ps1'
        $hidePath = Join-Path $privateRoot 'Hide-DpIntercomSecret.ps1'
        $protectPath = Join-Path $privateRoot 'Protect-DpDiagnosticText.ps1'

        1..8 | ForEach-Object -Parallel {
            . $using:hidePath
            . $using:protectPath
            . $using:addPath
            $producer = $_
            1..25 | ForEach-Object {
                Add-DpDiagnosticLog -Log $using:log -Severity 'information' -Component 'test' `
                    -EventId "producer.$producer" -Summary "entry $_"
            }
        } -ThrottleLimit 8

        $entries = @(Get-DpDiagnosticLog -Log $log)
        $entries | Should -HaveCount 200
        @($entries.sequence | Sort-Object -Unique) | Should -HaveCount 200
        $entries.sequence | Should -Be (1..200)
    }
}

Describe 'Diagnostic state mapping' -Tag 'Unit' {
    It 'maps dependency facts to the required state' -ForEach @(
        @{ Configured = $true; Available = $true; Healthy = $true; Expected = 'healthy' }
        @{ Configured = $true; Available = $true; Healthy = $false; Expected = 'degraded' }
        @{ Configured = $true; Available = $false; Healthy = $false; Expected = 'unavailable' }
        @{ Configured = $false; Available = $false; Healthy = $false; Expected = 'not configured' }
    ) {
        Resolve-DpDiagnosticState -Configured:$Configured -Available:$Available -Healthy:$Healthy |
            Should -Be $Expected
    }

    It 'bounds every explanation and safe next action' {
        $check = New-DpDiagnosticCheck -Id 'bounded' -Label 'Bounded' -State 'degraded' `
            -Explanation ('x' * 1000) -Action ('y' * 1000)

        $check.explanation.Length | Should -BeLessOrEqual 300
        $check.action.Length | Should -BeLessOrEqual 200
    }
}

Describe 'Invoke-DpDiagnosticProbe' -Tag 'Unit' {
    It 'times out a slow probe and reports degraded without waiting for it to finish' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-DpDiagnosticProbe -Id 'slow' -Label 'Slow dependency' `
            -Probe { Start-Sleep -Seconds 5 } -TimeoutMilliseconds 100 `
            -TimeoutAction 'Check the dependency directly.'
        $stopwatch.Stop()

        $result.state | Should -Be 'degraded'
        $result.explanation | Should -Match 'did not finish'
        $result.action | Should -Be 'Check the dependency directly.'
        $stopwatch.ElapsedMilliseconds | Should -BeLessThan 1500
    }

    It 'reports a failing probe honestly instead of marking it healthy' {
        $result = Invoke-DpDiagnosticProbe -Id 'broken' -Label 'Broken dependency' `
            -Probe { throw 'inspection failed' } -TimeoutMilliseconds 500 `
            -FailureAction 'Inspect the dependency manually.'

        $result.state | Should -Be 'degraded'
        $result.explanation | Should -Match 'inspection failed'
        $result.action | Should -Be 'Inspect the dependency manually.'
    }
}

Describe 'Invoke-DpDiagnosticCheck' -Tag 'Unit' {
    BeforeEach {
        $dataPath = Join-Path $TestDrive 'data'
        $projectPath = Join-Path $TestDrive 'project'
        $modulePath = Join-Path $TestDrive 'ShellPilot.psd1'
        $null = New-Item -ItemType Directory -Path $dataPath, $projectPath -Force
        Set-Content -LiteralPath $modulePath -Value '@{}' -NoNewline

        $script:snapshot = @{
            versions      = @{
                deskPilot      = '0.6.0'
                powerShell     = $PSVersionTable.PSVersion.ToString()
                engine         = '0.4.0'
                git            = ''
                operatingSystem = 'Test OS'
            }
            paths         = @{ data = $dataPath; module = $modulePath }
            configuration = @{ valid = $true; settingCount = 12; permissionCount = 6 }
            project       = @{ configured = $true; name = 'Demo'; path = $projectPath }
            engine        = @{ imported = $true; authenticated = $true; importError = '' }
            mcp           = @{
                supported = $true; configuredCount = 1; enabledCount = 1
                observed = $true; healthyCount = 1; degradedCount = 0
            }
            intercom      = @{ enabled = $false; available = $false; healthy = $false; error = '' }
            update        = @{ checked = $true; checking = $false; updateAvailable = $false; targetVersion = '' }
        }
    }

    It 'reports every dependency with a bounded state and safe next action' {
        $result = Invoke-DpDiagnosticCheck -Snapshot $script:snapshot -TimeoutMilliseconds 1000

        @($result.checks.id) | Should -Be @(
            'configuration', 'data-path', 'engine-module', 'project', 'engine',
            'engine-auth', 'git', 'mcp', 'browser-automation', 'intercom', 'update'
        )
        ($result.checks | Where-Object id -EQ 'project').state | Should -Be 'healthy'
        ($result.checks | Where-Object id -EQ 'mcp').state | Should -Be 'healthy'
        ($result.checks | Where-Object id -EQ 'intercom').state | Should -Be 'not configured'
        # Off by default, so the honest report is that it is not configured
        # rather than that something is wrong with it.
        ($result.checks | Where-Object id -EQ 'browser-automation').state | Should -Be 'not configured'
        @($result.checks | Where-Object { $_.state -notin @('healthy', 'degraded', 'unavailable', 'not configured') }) |
            Should -HaveCount 0
        @($result.checks | Where-Object { $_.explanation.Length -gt 300 -or $_.action.Length -gt 200 }) |
            Should -HaveCount 0
    }

    It 'maps missing and unhealthy dependencies to honest actions' {
        $script:snapshot.project = @{ configured = $false; name = ''; path = '' }
        $script:snapshot.engine = @{ imported = $false; authenticated = $false; importError = 'module missing' }
        $script:snapshot.mcp = @{
            supported = $false; configuredCount = 1; enabledCount = 1
            observed = $false; healthyCount = 0; degradedCount = 0
        }
        $script:snapshot.intercom = @{ enabled = $true; available = $true; healthy = $false; error = 'poll failed' }
        $script:snapshot.update = @{ checked = $false; checking = $false; updateAvailable = $false; targetVersion = '' }

        $result = Invoke-DpDiagnosticCheck -Snapshot $script:snapshot -TimeoutMilliseconds 1000

        ($result.checks | Where-Object id -EQ 'project').state | Should -Be 'not configured'
        ($result.checks | Where-Object id -EQ 'project').action | Should -Match 'Select a Project'
        ($result.checks | Where-Object id -EQ 'engine').state | Should -Be 'unavailable'
        ($result.checks | Where-Object id -EQ 'mcp').state | Should -Be 'unavailable'
        ($result.checks | Where-Object id -EQ 'intercom').state | Should -Be 'degraded'
        ($result.checks | Where-Object id -EQ 'update').state | Should -Be 'unavailable'
    }

    It 'surfaces a bounded redacted MCP inspection failure' {
        $script:snapshot.mcp = @{
            supported = $true; configuredCount = 1; enabledCount = 1
            observed = $true; healthyCount = 0; degradedCount = 1
            issue = 'The server executable could not be found. Bearer secret-value'
        }

        $result = Invoke-DpDiagnosticCheck -Snapshot $script:snapshot -TimeoutMilliseconds 1000
        $mcp = $result.checks | Where-Object id -EQ 'mcp'

        $mcp.state | Should -Be 'degraded'
        $mcp.explanation | Should -Match 'executable could not be found'
        $mcp.explanation | Should -Not -Match 'secret-value'
    }

    It 'reports an unavailable MCP inspection with its redacted reason' {
        $script:snapshot.mcp = @{
            supported = $true; configuredCount = 1; enabledCount = 1
            observed = $false; healthyCount = 0; degradedCount = 0
            issue = 'The Engine inspection failed. Bearer secret-value'
        }

        $result = Invoke-DpDiagnosticCheck -Snapshot $script:snapshot -TimeoutMilliseconds 1000
        $mcp = $result.checks | Where-Object id -EQ 'mcp'

        $mcp.state | Should -Be 'unavailable'
        $mcp.explanation | Should -Match 'Engine inspection failed'
        $mcp.explanation | Should -Not -Match 'secret-value'
    }

    It 'performs no Model call, network request, or file mutation' {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | Select-Object FullName, Length)
        $result = Invoke-DpDiagnosticCheck -Snapshot $script:snapshot -TimeoutMilliseconds 1000
        $after = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | Select-Object FullName, Length)
        $source = Get-Content -LiteralPath (Join-Path $privateRoot 'Invoke-DpDiagnosticCheck.ps1') -Raw

        $result.checks | Should -Not -BeNullOrEmpty
        ($before | ConvertTo-Json -Compress) | Should -Be ($after | ConvertTo-Json -Compress)
        $source | Should -Not -Match 'Invoke-Shp|Invoke-DpEngineCommand|Invoke-WebRequest|Invoke-RestMethod|Find-Module'
    }
}

Describe 'Diagnostic Host Server state' -Tag 'Unit' {
    BeforeEach {
        $dataPath = Join-Path $TestDrive 'host-data'
        $projectPath = Join-Path $TestDrive 'host-project'
        $modulePath = Join-Path $TestDrive 'ShellPilot' '0.4.0' 'ShellPilot.psd1'
        $tokenPath = Join-Path $TestDrive '.shellpilot-token'
        $null = New-Item -ItemType Directory -Path $dataPath, $projectPath, (Split-Path $modulePath -Parent) -Force
        Set-Content -LiteralPath $modulePath -Value '@{}' -NoNewline
        Set-Content -LiteralPath $tokenPath -Value 'engine-token-value' -NoNewline

        $settings = Get-DpDefaultSettings
        $settings.projects = @(@{ id = 'p1'; name = 'Demo'; path = $projectPath; intercom = $false; intercomGroup = $false })
        $settings.selectedProjectId = 'p1'
        $settings.workspaceFolder = $projectPath
        $settings.mcpServers = @(
            ConvertTo-DpMcpServer -InputObject @{ id = 'mcp1'; name = 'files'; command = 'npx'; envKeys = @('DP_TEST_SECRET') }
        )

        $script:DeskPilot = @{
            Version       = '0.6.0'
            Token         = 'host-session-secret'
            DataDir       = $dataPath
            Settings      = $settings
            Engine        = @{
                Imported = $true; ImportError = ''; ModulePath = $modulePath
                TokenPath = $tokenPath; Version = '0.4.0'; McpSupported = $true
            }
            Mcp           = @{
                Rows = @{ mcp1 = @{ names = @('files'); fingerprint = 'fingerprint-secret' } }
                LastObserved = @{
                    checkedUtc = [datetime]::UtcNow.ToString('o')
                    rows = @(@{ id = 'mcp1'; ok = $true; servers = @(@{ name = 'files'; state = 'Ready'; running = $true }) })
                }
            }
            Intercom      = @{
                TokenConfigured = $false; Token = 'telegram-secret'; Running = $false
                LastError = ''; Log = @(); Counters = @{}
            }
            Update        = @{
                checkedUtc = [datetime]::UtcNow.ToString('o'); checking = $false
                updateAvailable = $false; targetVersion = $null
            }
            Conversations = @{
                c1 = @{ messages = @(@{ role = 'user'; text = 'MESSAGE-CONTENT-MUST-NOT-LEAK' }) }
            }
            Attachments   = @{ 'C:\private\document.txt' = 'text/plain' }
            Diagnostics   = @{
                Log = New-DpDiagnosticLog -MaxEntries 50 -MaxBytes 65536
                CheckJob = $null; Checking = $false; LastCheck = $null; LastCheckUtc = $null
                Exporting = $false; LastExport = $null
            }
            UnknownSecret = 'UNKNOWN-STATE-MUST-NOT-LEAK'
        }
        $env:DP_TEST_SECRET = 'ENVIRONMENT-VALUE-MUST-NOT-LEAK'
    }

    AfterEach {
        Remove-Item Env:\DP_TEST_SECRET -ErrorAction SilentlyContinue
        if ($script:DeskPilot.Diagnostics.CheckJob) {
            $script:DeskPilot.Diagnostics.CheckJob | Remove-Job -Force -ErrorAction SilentlyContinue
            $script:DeskPilot.Diagnostics.CheckJob = $null
        }
    }

    It 'constructs a self-check snapshot from an allow-list only' {
        $snapshot = New-DpDiagnosticSnapshot
        $json = $snapshot | ConvertTo-Json -Depth 10 -Compress

        $snapshot.versions.deskPilot | Should -Be '0.6.0'
        $snapshot.paths.data | Should -Be $dataPath
        $snapshot.paths.module | Should -Be $modulePath
        $snapshot.project.name | Should -Be 'Demo'
        $snapshot.engine.authenticated | Should -BeTrue
        $snapshot.mcp.healthyCount | Should -Be 1
        $json | Should -Not -Match 'MESSAGE-CONTENT|UNKNOWN-STATE|ENVIRONMENT-VALUE|telegram-secret|host-session-secret|engine-token-value|fingerprint-secret'
        $snapshot.Keys | Should -Be @('versions', 'paths', 'configuration', 'project', 'engine', 'mcp', 'intercom', 'browser', 'update')
    }

    It 'starts the self-check off-thread and reaps its result' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $started = Start-DpDiagnosticCheck -Snapshot (New-DpDiagnosticSnapshot) -TimeoutMilliseconds 1000
        $stopwatch.Stop()

        $started.started | Should -BeTrue
        $script:DeskPilot.Diagnostics.Checking | Should -BeTrue
        $stopwatch.ElapsedMilliseconds | Should -BeLessThan 1000
        $script:DeskPilot.Diagnostics.CheckJob | Wait-Job -Timeout 15 | Should -Not -BeNullOrEmpty

        Update-DpDiagnosticCheckState

        $script:DeskPilot.Diagnostics.Checking | Should -BeFalse
        $script:DeskPilot.Diagnostics.CheckJob | Should -BeNullOrEmpty
        $script:DeskPilot.Diagnostics.LastCheck.checks | Should -Not -BeNullOrEmpty
        @($script:DeskPilot.Diagnostics.LastCheck.checks.id) | Should -Contain 'configuration'
        @($script:DeskPilot.Diagnostics.LastCheck.checks.id) | Should -Contain 'mcp'
        @($script:DeskPilot.Diagnostics.LastCheck.checks.id) | Should -Not -Contain 'self-check'
        $script:DeskPilot.Diagnostics.LastCheckUtc | Should -Not -BeNullOrEmpty
    }

    It 'refuses a concurrent self-check without replacing the running job' {
        $job = [pscustomobject]@{ State = 'Running' }
        $script:DeskPilot.Diagnostics.CheckJob = $job
        $script:DeskPilot.Diagnostics.Checking = $true

        $result = Start-DpDiagnosticCheck -Snapshot (New-DpDiagnosticSnapshot)

        $result.started | Should -BeFalse
        $result.alreadyRunning | Should -BeTrue
        [object]::ReferenceEquals($script:DeskPilot.Diagnostics.CheckJob, $job) | Should -BeTrue
    }

    It 'injects every helper the isolated self-check worker calls' {
        $source = Get-Content -LiteralPath (Join-Path $privateRoot 'Start-DpDiagnosticCheck.ps1') -Raw

        $source | Should -Match ([regex]::Escape("'Get-DpPropertyValue'"))
        $source | Should -Match ([regex]::Escape("'Invoke-DpDiagnosticCheck'"))
    }

    It 'returns bounded live status and log data without serializing live state' {
        Add-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log -Severity 'information' `
            -Component 'host' -EventId 'test.ready' -Summary 'Ready'
        $script:DeskPilot.Diagnostics.LastCheck = Invoke-DpDiagnosticCheck `
            -Snapshot (New-DpDiagnosticSnapshot) -TimeoutMilliseconds 1000
        $script:DeskPilot.Diagnostics.LastCheckUtc = $script:DeskPilot.Diagnostics.LastCheck.completedUtc

        $payload = Get-DpDiagnosticPayload -AfterSequence 0
        $json = $payload | ConvertTo-Json -Depth 12 -Compress

        $payload.logs.entries | Should -HaveCount 1
        $payload.logs.retention.maxEntries | Should -Be 50
        $payload.logs.retention.maxBytes | Should -Be 65536
        $payload.logs.retention.persistent | Should -BeFalse
        $payload.logs.retention.clearedOnRestart | Should -BeTrue
        $payload.paths.data.absolute | Should -BeTrue
        $payload.paths.module.absolute | Should -BeTrue
        $json | Should -Not -Match 'MESSAGE-CONTENT|UNKNOWN-STATE|ENVIRONMENT-VALUE|telegram-secret|host-session-secret|engine-token-value|fingerprint-secret'
    }
}

Describe 'Support bundle' -Tag 'Unit' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:bundleData = Join-Path $caseRoot 'bundle-data'
        $script:bundleProject = Join-Path $caseRoot 'private-project'
        $script:bundleModule = Join-Path $caseRoot 'modules' 'ShellPilot' '0.4.0' 'ShellPilot.psd1'
        $script:bundleTokenPath = Join-Path $caseRoot '.shellpilot-token'
        $null = New-Item -ItemType Directory -Path $script:bundleData, $script:bundleProject, (Split-Path $script:bundleModule -Parent) -Force
        Set-Content -LiteralPath $script:bundleModule -Value '@{}' -NoNewline
        Set-Content -LiteralPath $script:bundleTokenPath -Value 'ENGINE-TOKEN-MUST-NOT-LEAK' -NoNewline

        $settings = Get-DpDefaultSettings
        $settings.permissions.terminal = $false
        $settings.projects = @(@{ id = 'p1'; name = 'Private Project'; path = $script:bundleProject; intercom = $false; intercomGroup = $false })
        $settings.selectedProjectId = 'p1'
        $settings.workspaceFolder = $script:bundleProject
        $settings.mcpServers = @(
            ConvertTo-DpMcpServer -InputObject @{
                id = 'mcp1'; name = 'files'; command = 'npx'; args = @('--token', 'RAW-TOOL-SECRET')
                envKeys = @('GITHUB_TOKEN'); enabled = $true; unknown = 'UNKNOWN-MCP-FIELD'
            }
        )

        $script:DeskPilot = @{
            Version       = '0.6.0'
            Token         = 'HOST-TOKEN-MUST-NOT-LEAK'
            DataDir       = $script:bundleData
            Settings      = $settings
            Engine        = @{
                Imported = $true; ImportError = ''; ModulePath = $script:bundleModule
                TokenPath = $script:bundleTokenPath; Version = '0.4.0'; McpSupported = $true
            }
            Mcp           = @{
                Rows = @{}
                LastObserved = @{
                    checkedUtc = [datetime]::UtcNow.ToString('o')
                    rows = @(@{ id = 'mcp1'; ok = $false; error = 'Bearer RAW-MCP-BEARER'; servers = @() })
                }
            }
            Intercom      = @{
                TokenConfigured = $true; Token = '123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi'
                Running = $false; LastError = 'poll failed'; Log = @(); Counters = @{}
            }
            Update        = @{
                checkedUtc = [datetime]::UtcNow.ToString('o'); checking = $false
                updateAvailable = $true; targetVersion = '0.7.0'
            }
            Conversations = @{
                c1 = @{ messages = @(@{ role = 'user'; text = 'MESSAGE-CONTENT-MUST-NOT-LEAK' }) }
            }
            TurnState     = @{ rawToolArguments = '{"token":"RAW-TOOL-SECRET"}'; reasoning = 'REASONING-MUST-NOT-LEAK' }
            Diagnostics   = @{
                Log = New-DpDiagnosticLog -MaxEntries 50 -MaxBytes 65536
                CheckJob = $null; Checking = $false; LastCheck = $null; LastCheckUtc = $null
                Exporting = $false; LastExport = $null
            }
            UnknownSecret = 'UNKNOWN-STATE-MUST-NOT-LEAK'
        }
        Add-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log -Severity 'error' `
            -Component 'engine' -EventId 'engine.failed' `
            -Summary "Bearer RAW-BEARER HOST-TOKEN-MUST-NOT-LEAK 123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi $script:bundleProject\private\plan.txt C:\unrelated\secret.txt /home/person/private.txt"
        $script:DeskPilot.Diagnostics.LastCheck = Invoke-DpDiagnosticCheck `
            -Snapshot (New-DpDiagnosticSnapshot) -TimeoutMilliseconds 1000
        $script:DeskPilot.Diagnostics.LastCheckUtc = $script:DeskPilot.Diagnostics.LastCheck.completedUtc
    }

    It 'constructs structured export data from field allow-lists' {
        $record = New-DpSupportBundleRecord
        $json = $record | ConvertTo-Json -Depth 12 -Compress

        $record.Keys | Should -Be @(
            'schemaVersion', 'createdUtc', 'versions', 'paths', 'project',
            'configuration', 'checks', 'logs'
        )
        $record.paths.data.Keys | Should -Be @('purpose', 'leaf')
        $record.paths.module.Keys | Should -Be @('purpose', 'leaf')
        $record.configuration.permissions.terminal | Should -BeFalse
        $record.configuration.mcpServers[0].Keys | Should -Be @(
            'name', 'source', 'enabled', 'environmentKeyCount', 'toolRestrictionCount'
        )
        $json | Should -Not -Match 'MESSAGE-CONTENT|REASONING-MUST|RAW-TOOL-SECRET|RAW-MCP-BEARER|UNKNOWN-MCP|UNKNOWN-STATE|HOST-TOKEN|ENGINE-TOKEN|ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $json | Should -Not -Match ([regex]::Escape($script:bundleData))
        $json | Should -Not -Match ([regex]::Escape($script:bundleModule))
        $json | Should -Not -Match ([regex]::Escape($script:bundleProject))
        $json | Should -Match '<Project:private-project>'
        $json | Should -Not -Match 'C:\\unrelated|/home/person'
        $json | Should -Match '<path:secret\.txt>|<path:private\.txt>'
    }

    It 'constructs a bundle record before any self-check under StrictMode' {
        $script:DeskPilot.Diagnostics.LastCheck = $null
        $script:DeskPilot.Diagnostics.LastCheckUtc = $null

        $record = & {
            Set-StrictMode -Version Latest
            New-DpSupportBundleRecord
        }

        $record.checks | Should -HaveCount 0
        $record.versions.git | Should -BeNullOrEmpty
    }

    It 'creates one valid bounded archive with human-readable and structured entries' {
        $result = New-DpSupportBundle -Directory $script:bundleData -Record (New-DpSupportBundleRecord) -Confirm:$false

        $result.ok | Should -BeTrue
        Test-Path -LiteralPath $result.path -PathType Leaf | Should -BeTrue
        $result.bytes | Should -BeGreaterThan 0
        $result.bytes | Should -BeLessOrEqual 3145728

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($result.path)
        try {
            @($archive.Entries.FullName) | Should -Be @('summary.md', 'diagnostics.json', 'host-log.jsonl')
            $allText = foreach ($entry in $archive.Entries) {
                $reader = [System.IO.StreamReader]::new($entry.Open())
                try { $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        }
        finally {
            $archive.Dispose()
        }
        $joined = $allText -join "`n"
        $joined | Should -Match '# DeskPilot support bundle'
        $joined | Should -Not -Match 'MESSAGE-CONTENT|REASONING-MUST|RAW-TOOL-SECRET|RAW-MCP-BEARER|UNKNOWN-STATE|HOST-TOKEN|ENGINE-TOKEN|ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    }

    It 'uses collision-safe names for consecutive exports' {
        $record = New-DpSupportBundleRecord
        $first = New-DpSupportBundle -Directory $script:bundleData -Record $record -Confirm:$false
        $second = New-DpSupportBundle -Directory $script:bundleData -Record $record -Confirm:$false

        $first.ok | Should -BeTrue
        $second.ok | Should -BeTrue
        $first.path | Should -Not -Be $second.path
    }

    It 'writes only the supplied allow-listed record, not later global state' {
        $record = New-DpSupportBundleRecord
        $script:DeskPilot.Diagnostics.LastCheck.overallState = 'GLOBAL-STATE-MUST-NOT-LEAK'

        $result = New-DpSupportBundle -Directory $script:bundleData -Record $record -Confirm:$false
        $archive = [System.IO.Compression.ZipFile]::OpenRead($result.path)
        try {
            $text = foreach ($entry in $archive.Entries) {
                $reader = [System.IO.StreamReader]::new($entry.Open())
                try { $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        }
        finally {
            $archive.Dispose()
        }

        ($text -join "`n") | Should -Not -Match 'GLOBAL-STATE-MUST-NOT-LEAK'
    }

    It 'refuses a destination outside the support-bundles directory' {
        $outside = Join-Path $TestDrive 'escaped.zip'

        $result = New-DpSupportBundle -Directory $script:bundleData -Destination $outside `
            -Record (New-DpSupportBundleRecord) -Confirm:$false

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'outside_destination'
        Test-Path -LiteralPath $outside | Should -BeFalse
    }

    It 'refuses a reparse-point destination directory' {
        $result = New-DpSupportBundle -Directory $script:bundleData `
            -Record (New-DpSupportBundleRecord) -ReparsePointTester { param($Path) $true } -Confirm:$false

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'redirected_destination'
    }

    It 'never overwrites an existing archive' {
        $bundleDirectory = Join-Path $script:bundleData 'support-bundles'
        $null = New-Item -ItemType Directory -Path $bundleDirectory -Force
        $destination = Join-Path $bundleDirectory 'existing.zip'
        Set-Content -LiteralPath $destination -Value 'keep-me' -NoNewline

        $result = New-DpSupportBundle -Directory $script:bundleData -Destination $destination `
            -Record (New-DpSupportBundleRecord) -Confirm:$false

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'already_exists'
        Get-Content -LiteralPath $destination -Raw | Should -Be 'keep-me'
    }

    It 'refuses unbounded input before creating an archive' {
        $result = New-DpSupportBundle -Directory $script:bundleData `
            -Record (New-DpSupportBundleRecord) -MaxUncompressedBytes 128 -Confirm:$false

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'too_large'
        @(Get-ChildItem -LiteralPath (Join-Path $script:bundleData 'support-bundles') -Filter '*.zip' -ErrorAction SilentlyContinue) |
            Should -HaveCount 0
    }
}

Describe 'Diagnostics routes' -Tag 'Unit' {
    BeforeEach {
        $dataPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $modulePath = Join-Path $dataPath 'ShellPilot.psd1'
        $null = New-Item -ItemType Directory -Path $dataPath
        Set-Content -LiteralPath $modulePath -Value '@{}' -NoNewline
        $settings = Get-DpDefaultSettings
        $script:DeskPilot = @{
            Version = '0.6.0'; Token = 'test-token'; DataDir = $dataPath; Settings = $settings
            Engine = @{
                Imported = $true; ImportError = ''; ModulePath = $modulePath; TokenPath = ''
                Version = '0.4.0'; McpSupported = $true
            }
            Mcp = @{ Rows = @{}; LastObserved = $null }
            Intercom = @{ TokenConfigured = $false; Running = $false; LastError = ''; Token = '' }
            Update = @{ checkedUtc = $null; checking = $false; updateAvailable = $false; targetVersion = $null }
            Diagnostics = @{
                Log = New-DpDiagnosticLog -MaxEntries 50 -MaxBytes 65536
                CheckJob = $null; Checking = $false; CheckStartedUtc = $null
                LastCheck = $null; LastCheckUtc = $null; Exporting = $false; LastExport = $null
            }
        }
        $script:responseStream = [System.IO.MemoryStream]::new()
    }

    AfterEach {
        $script:responseStream.Dispose()
        if ($script:DeskPilot.Diagnostics.CheckJob) {
            $script:DeskPilot.Diagnostics.CheckJob | Remove-Job -Force -ErrorAction SilentlyContinue
        }
        $script:DeskPilot = $null
    }

    It 'polls status and only log entries newer than the cursor' {
        1..3 | ForEach-Object {
            Add-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log -Severity 'information' `
                -Component 'host' -EventId "route.$_" -Summary "entry $_"
        }

        Invoke-DpRouteHandler -Name 'getDiagnostics' -Stream $script:responseStream `
            -Request @{ Query = @{ after = '1' } }

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 200 OK'
        $payload = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        @($payload.logs.entries.sequence) | Should -Be @(2, 3)
    }

    It 'starts a self-check and returns 202 without waiting for it' {
        Mock Start-DpDiagnosticCheck { @{ started = $true; alreadyRunning = $false } }

        Invoke-DpRouteHandler -Name 'runDiagnosticCheck' -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 202 Accepted'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).selfCheck.checking | Should -BeFalse
        Should -Invoke Start-DpDiagnosticCheck -Times 1 -Exactly
    }

    It 'clears the log and leaves it empty' {
        Add-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log -Severity 'warning' `
            -Component 'host' -EventId 'clear.me' -Summary 'clear me'

        Invoke-DpRouteHandler -Name 'clearDiagnosticLog' -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $payload = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $payload.cleared | Should -Be 1
        @(Get-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log) | Should -HaveCount 0
    }

    It 'exports a support bundle only on the explicit route and returns its destination' {
        $expected = Join-Path $script:DeskPilot.DataDir 'support-bundles' 'support.zip'
        Mock New-DpSupportBundle {
            @{ ok = $true; code = 'created'; error = ''; path = $expected; name = 'support.zip'; createdUtc = '2026-09-02T20:00:00Z'; bytes = 123; uncompressedBytes = 456; entries = 3 }
        }

        Invoke-DpRouteHandler -Name 'exportSupportBundle' -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 201 Created'
        $payload = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $payload.path | Should -Be $expected
        $script:DeskPilot.Diagnostics.LastExport.path | Should -Be $expected
        $script:DeskPilot.Diagnostics.Exporting | Should -BeFalse
        Should -Invoke New-DpSupportBundle -Times 1 -Exactly
    }

    It 'refuses a concurrent support-bundle export' {
        $script:DeskPilot.Diagnostics.Exporting = $true
        Mock New-DpSupportBundle { throw 'must not run' }

        Invoke-DpRouteHandler -Name 'exportSupportBundle' -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 409 Conflict'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'export_running'
        Should -Invoke New-DpSupportBundle -Times 0 -Exactly
    }

    It 'keeps bounded live-log polling off the Engine and accept-loop blockers' {
        1..50 | ForEach-Object {
            Add-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log -Severity 'information' `
                -Component 'host' -EventId "poll.$_" -Summary ('x' * 100)
        }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Get-DpDiagnosticPayload -AfterSequence 0
        $stopwatch.Stop()
        $source = Get-Content -LiteralPath (Join-Path $privateRoot 'Get-DpDiagnosticPayload.ps1') -Raw

        $stopwatch.ElapsedMilliseconds | Should -BeLessThan 500
        $source | Should -Not -Match 'Start-Sleep|WaitOne|Invoke-DpEngineCommand|Invoke-Shp'
    }

    It 'registers every diagnostics route and reaps checks on idle ticks' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Public' 'Start-DeskPilot.ps1') -Raw

        $source | Should -Match ([regex]::Escape("Pattern = '/api/diagnostics'; Name = 'getDiagnostics'"))
        $source | Should -Match ([regex]::Escape("Pattern = '/api/diagnostics/check'; Name = 'runDiagnosticCheck'"))
        $source | Should -Match ([regex]::Escape("Pattern = '/api/diagnostics/log/clear'; Name = 'clearDiagnosticLog'"))
        $source | Should -Match ([regex]::Escape("Pattern = '/api/diagnostics/support-bundle'; Name = 'exportSupportBundle'"))
        $source | Should -Match 'Diagnostics\s*=\s*@\{'
        $source | Should -Match 'Update-DpDiagnosticCheckState'
    }

    It 'inherits the shared Origin and session-token gate before dispatch' {
        $script:DeskPilot.Routes = @(@{ Method = 'GET'; Pattern = '/api/diagnostics'; Name = 'getDiagnostics' })
        $script:DeskPilot.WebRoot = $script:DeskPilot.DataDir
        Mock Get-DpDiagnosticPayload { throw 'must not dispatch' }

        $hostileStream = [System.IO.MemoryStream]::new()
        try {
            Invoke-DpRequest -Request @{
                Method = 'GET'; Path = '/api/diagnostics'; Query = @{ after = '0' }; Body = ''; BodyBytes = [byte[]]@()
                Headers = @{ Host = '127.0.0.1:52100'; Origin = 'https://evil.example'; 'X-DeskPilot-Token' = 'test-token' }
            } -Stream $hostileStream
            $hostile = [System.Text.Encoding]::UTF8.GetString($hostileStream.ToArray())
            $hostile | Should -Match '^HTTP/1\.1 403 Forbidden'
            (($hostile -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'forbidden_origin'
        }
        finally {
            $hostileStream.Dispose()
        }

        $missingTokenStream = [System.IO.MemoryStream]::new()
        try {
            Invoke-DpRequest -Request @{
                Method = 'GET'; Path = '/api/diagnostics'; Query = @{ after = '0' }; Body = ''; BodyBytes = [byte[]]@()
                Headers = @{ Host = '127.0.0.1:52100'; Origin = 'http://127.0.0.1:52100' }
            } -Stream $missingTokenStream
            $missing = [System.Text.Encoding]::UTF8.GetString($missingTokenStream.ToArray())
            $missing | Should -Match '^HTTP/1\.1 401 Unauthorized'
        }
        finally {
            $missingTokenStream.Dispose()
        }

        Should -Invoke Get-DpDiagnosticPayload -Times 0 -Exactly
    }

    It 'does not mask a request failure when diagnostics state is not initialized' {
        $script:DeskPilot.Remove('Diagnostics')
        $script:DeskPilot.Routes = @(@{ Method = 'GET'; Pattern = '/api/fail'; Name = 'fail' })
        $script:DeskPilot.WebRoot = $script:DeskPilot.DataDir
        Mock Invoke-DpRouteHandler { throw 'primary request failure' }

        $stream = [System.IO.MemoryStream]::new()
        try {
            & {
                Set-StrictMode -Version Latest
                Invoke-DpRequest -Request @{
                    Method = 'GET'; Path = '/api/fail'; Query = @{}; Body = ''; BodyBytes = [byte[]]@()
                    Headers = @{ Host = '127.0.0.1:52100'; Origin = 'http://127.0.0.1:52100'; 'X-DeskPilot-Token' = 'test-token' }
                } -Stream $stream
            }
            $response = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
            $response | Should -Match '^HTTP/1\.1 500 Internal Server Error'
            (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.message | Should -Match 'primary request failure'
        }
        finally {
            $stream.Dispose()
        }
    }
}

Describe 'API origin control' -Tag 'Unit' {
    It 'accepts a same-origin loopback request' {
        Test-DpRequestOrigin -Headers @{
            Host = '127.0.0.1:52100'
            Origin = 'http://127.0.0.1:52100'
        } | Should -BeTrue
    }

    It 'accepts a loopback request with no Origin header' {
        Test-DpRequestOrigin -Headers @{ Host = 'localhost:52100' } | Should -BeTrue
    }

    It 'refuses a non-loopback Host or a mismatched Origin' -ForEach @(
        @{ HostHeader = 'evil.example'; OriginHeader = 'http://evil.example' }
        @{ HostHeader = '127.0.0.1:52100'; OriginHeader = 'https://evil.example' }
        @{ HostHeader = '127.0.0.1:52100'; OriginHeader = 'http://127.0.0.1:52101' }
        @{ HostHeader = '127.0.0.1:52100'; OriginHeader = 'null' }
    ) {
        Test-DpRequestOrigin -Headers @{ Host = $HostHeader; Origin = $OriginHeader } | Should -BeFalse
    }
}