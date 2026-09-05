#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    $script:engineModule = Get-Module -ListAvailable ShellPilot |
        Where-Object { $_.Version -ge [version]'0.4.1' } |
        Sort-Object Version -Descending | Select-Object -First 1
    $script:project = Join-Path $TestDrive 'project'
    $null = New-Item -Path $script:project -ItemType Directory
    if ($IsWindows -and $script:engineModule) {
        $null = Install-DpTerminalRuntime -DataDirectory (Join-Path $TestDrive 'control')
    }

    function Invoke-DpIsolatedProof {
        param([string]$Command, [hashtable]$Policy = @{}, [switch]$Deny, [switch]$StopAfterDescendant, [switch]$CrashProxy)
        $Policy.mode = 'isolated'
        $context = @{
            conversationId = 'isolation-proof'; turnId = [guid]::NewGuid().ToString('N')
            project = $script:project; workingDirectory = $script:project
            dataDirectory = (Join-Path $TestDrive 'control')
            terminalExecution = (ConvertTo-DpTerminalExecution -InputObject $Policy)
        }
        $null = Initialize-DpTerminalTool -Runspace $script:runspace -Context $context -SafeCommand @() -Bridge $script:bridge
        $controller = $script:runspace.SessionStateProxy.GetVariable('DeskPilotIsolatedTerminal')
        $null = $script:shell.AddCommand('Invoke-DpTerminalApprovalTool').AddParameter('Command', $Command)
        $pending = $script:shell.BeginInvoke()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not $pending.IsCompleted -and $clock.Elapsed.TotalSeconds -lt 60) {
            $request = $script:bridge.GetPendingRequest()
            if ($request) {
                $answer = @{ decision = if ($Deny) { 'deny' } else { 'approve' } } | ConvertTo-Json -Compress
                $null = $script:bridge.SubmitAnswer('isolation-proof', $request.Id, $answer)
            }
            if (($StopAfterDescendant -or $CrashProxy) -and $controller.LastContainer) {
                $descendantReady = $false
                try {
                    $null = Invoke-DpDockerControl -Argument @('exec', '--user', '10001', $controller.LastContainer, '/usr/bin/test', '-f', '/tmp/descendant.ready') -TimeoutSeconds 2
                    $descendantReady = $true
                }
                catch { $descendantReady = $false }
                if ($descendantReady) {
                    if ($CrashProxy) {
                        $null = Invoke-DpDockerControl -Argument @('kill', ($controller.LastContainer + '-proxy'))
                        $CrashProxy = $false
                        continue
                    }
                    $previous = $script:DeskPilot
                    $stopStream = [IO.MemoryStream]::new()
                    try {
                        $script:DeskPilot = @{ Engine = @{ TerminalSession = $controller; ApprovalBridge = $script:bridge } }
                        Invoke-DpRouteHandler -Name 'stopTurn' -Stream $stopStream
                        [Text.Encoding]::UTF8.GetString($stopStream.ToArray()) | Should -Match '^HTTP/1.1 202'
                    }
                    finally { $stopStream.Dispose(); $script:DeskPilot = $previous }
                    $StopAfterDescendant = $false
                }
            }
            [Threading.Tasks.Task]::Delay(20).GetAwaiter().GetResult()
        }
        if (-not $pending.IsCompleted) {
            $controller.Cancel()
            $null = $pending.AsyncWaitHandle.WaitOne(15000)
            throw 'The isolated proof did not finish within its deadline.'
        }
        $result = @($script:shell.EndInvoke($pending))
        $script:shell.HadErrors | Should -BeFalse -Because ($script:shell.Streams.Error | Out-String)
        $result | Should -HaveCount 1
        $envelope = $result[0] | ConvertFrom-Json
        if ($Deny) { return $envelope }
        $envelope.approved | Should -BeTrue
        $envelope.result | ConvertFrom-Json
    }
}

Describe 'Registered Isolated Terminal execution' -Tag 'Integration' {
    BeforeEach {
        if (-not $IsWindows -or -not $script:engineModule) {
            Set-ItResult -Skipped -Because 'Windows Docker Desktop and a dispatch-enforcing ShellPilot are required.'
            return
        }
        $script:runspace = [runspacefactory]::CreateRunspace()
        $script:runspace.Open()
        $script:shell = [powershell]::Create()
        $script:shell.Runspace = $script:runspace
        $null = $script:shell.AddCommand('Import-Module').AddParameter('Name', $script:engineModule.Path)
        $null = $script:shell.Invoke()
        $script:shell.Commands.Clear()
        $null = Initialize-DpUserPromptBridge -Runspace $script:runspace
        $script:bridge = New-Object DeskPilot.UserPromptBridge
        $script:bridge.BeginTurn('isolation-proof')
    }

    AfterEach {
        if ($script:runspace) {
            $isolated = $script:runspace.SessionStateProxy.GetVariable('DeskPilotIsolatedTerminal')
            if ($isolated) { $isolated.Dispose() }
        }
        if ($script:shell) { $script:shell.Dispose() }
        if ($script:bridge) { $script:bridge.Dispose() }
        if ($script:runspace) { $script:runspace.Dispose() }
    }

    It 'executes the registered Tool inside Linux rather than the Windows Host Server' {
        $registration = @{
            Runspace = $script:runspace
            Bridge = $script:bridge
            SafeCommand = @(@{ command = '$IsLinux'; match = 'exact' })
            Context = @{
                conversationId = 'isolation-proof'
                turnId = 'runtime-proof'
                project = $script:project
                workingDirectory = $script:project
                dataDirectory = (Join-Path $TestDrive 'control')
                terminalExecution = (ConvertTo-DpTerminalExecution -InputObject @{ mode = 'isolated' })
            }
        }
        Initialize-DpTerminalTool @registration | Should -BeTrue
        $null = $script:shell.AddScript('Invoke-DpTerminalApprovalTool -Command ''$IsLinux''')
        $answer = @($script:shell.Invoke())

        $script:shell.HadErrors | Should -BeFalse -Because ($script:shell.Streams.Error | Out-String)
        $answer | Should -HaveCount 1
        $envelope = $answer[0] | ConvertFrom-Json
        $envelope.approved | Should -BeTrue
        $commandResult = $envelope.result | ConvertFrom-Json
        $commandResult.exitCode | Should -Be 0
        $commandResult.stdout.Trim() | Should -BeExactly 'True'
    }

    It 'permits an explicitly allowed HTTPS origin through the registered Tool' {
        $command = '(Invoke-WebRequest -Uri https://example.com -Proxy http://127.0.0.1:3128 -TimeoutSec 15 -MaximumRedirection 0).Content'
        $registration = @{
            Runspace = $script:runspace
            Bridge = $script:bridge
            SafeCommand = @(@{ command = $command; match = 'exact' })
            Context = @{
                conversationId = 'isolation-proof'
                turnId = 'allow-list-proof'
                project = $script:project
                workingDirectory = $script:project
                dataDirectory = (Join-Path $TestDrive 'control')
                terminalExecution = (ConvertTo-DpTerminalExecution -InputObject @{
                    mode = 'isolated'; network = 'allow-list'; allowedHosts = @('example.com')
                })
            }
        }
        Initialize-DpTerminalTool @registration | Should -BeTrue
        $null = $script:shell.AddCommand('Invoke-DpTerminalApprovalTool').AddParameter('Command', $command)
        $answer = @($script:shell.Invoke())

        $script:shell.HadErrors | Should -BeFalse -Because ($script:shell.Streams.Error | Out-String)
        $answer | Should -HaveCount 1
        $envelope = $answer[0] | ConvertFrom-Json
        $envelope.approved | Should -BeTrue
        $commandResult = $envelope.result | ConvertFrom-Json
        $commandResult.exitCode | Should -Be 0 -Because ($commandResult.error + ' ' + $commandResult.stderr)
        $commandResult.stdout | Should -Match 'Example Domain'
        $commandResult.cleanupSucceeded | Should -BeTrue
    }

    It 'denies a command without creating its file' {
        $result = Invoke-DpIsolatedProof -Command 'Set-Content /project/denied.txt denied' -Policy @{ projectAccess = 'read-write' } -Deny
        $result.approved | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:project 'denied.txt') | Should -BeFalse
    }

    It 'reads the Project but refuses writes on its default read-only mount' {
        Set-Content -LiteralPath (Join-Path $script:project 'input.txt') -Value 'project-input'
        $result = Invoke-DpIsolatedProof -Command 'Get-Content /project/input.txt; Set-Content /project/readonly.txt forbidden'
        $result.stdout | Should -Match 'project-input'
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $script:project 'readonly.txt') | Should -BeFalse
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'records read-write Project changes using Project-relative paths' {
        $result = Invoke-DpIsolatedProof -Command 'Set-Content /project/changed.txt written' -Policy @{ projectAccess = 'read-write' }
        $result.exitCode | Should -Be 0 -Because ($result.error + $result.stderr)
        (Get-Content -LiteralPath (Join-Path $script:project 'changed.txt') -Raw).Trim() | Should -BeExactly 'written'
        @($result.filesWritten) | Should -Contain 'changed.txt'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'does not inherit an ambient environment marker' {
        $prior = $env:DP_ISOLATION_AMBIENT
        try {
            $env:DP_ISOLATION_AMBIENT = 'host-only-fixture'
            $result = Invoke-DpIsolatedProof -Command '[string]::IsNullOrEmpty($env:DP_ISOLATION_AMBIENT)'
            $result.stdout.Trim() | Should -BeExactly 'True'
        }
        finally { $env:DP_ISOLATION_AMBIENT = $prior }
    }

    It 'passes only an explicitly selected variable and redacts its secret value' {
        $prior = $env:DP_ISOLATION_SECRET
        try {
            $env:DP_ISOLATION_SECRET = 'test-only-secret-' + [guid]::NewGuid().ToString('N')
            $result = Invoke-DpIsolatedProof -Command 'Write-Output $env:DP_ISOLATION_SECRET' -Policy @{ environment = @(@{ name = 'DP_ISOLATION_SECRET'; secret = $true }) }
            $result.stdout.Trim() | Should -BeExactly '[secret]'
            ($result | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($env:DP_ISOLATION_SECRET))
        }
        finally { $env:DP_ISOLATION_SECRET = $prior }
    }

    It 'reports a combined output limit instead of silently returning partial output' {
        $result = Invoke-DpIsolatedProof -Command 'Write-Output ("X" * 20000)' -Policy @{ outputBytes = 1024 }
        $result.outputLimitExceeded | Should -BeTrue
        $result.exitCode | Should -Not -Be 0
        $result.stdout | Should -BeNullOrEmpty
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'terminates a timed-out command and removes the container' {
        $result = Invoke-DpIsolatedProof -Command 'Start-Sleep -Seconds 20' -Policy @{ timeoutSeconds = 1 }
        $result.timedOut | Should -BeTrue
        $result.exitCode | Should -Be 124
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'enforces the temporary disk bound' {
        $result = Invoke-DpIsolatedProof -Command '[IO.File]::WriteAllBytes("/tmp/fill", [byte[]]::new(40MB))' -Policy @{ tempMB = 16 }
        $result.exitCode | Should -Not -Be 0
        $result.stderr | Should -Match 'space|disk|I/O'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'exposes the declared CPU memory and process cgroup limits' {
        $result = Invoke-DpIsolatedProof -Command 'Get-Content /sys/fs/cgroup/cpu.max; Get-Content /sys/fs/cgroup/memory.max; Get-Content /sys/fs/cgroup/pids.max'
        $result.exitCode | Should -Be 0
        $result.stdout | Should -Match '100000 100000'
        $result.stdout | Should -Match '1073741824'
        $result.stdout | Should -Match '(?m)^64\r?$'
    }

    It 'denies direct network access by default' {
        $result = Invoke-DpIsolatedProof -Command '& /usr/bin/curl --connect-timeout 2 --max-time 3 https://example.com; exit $LASTEXITCODE'
        $result.exitCode | Should -Not -Be 0
        $result.stdout | Should -Not -Match 'Example Domain'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'denies an unapproved HTTPS origin through the proxy' {
        $result = Invoke-DpIsolatedProof -Command 'Invoke-WebRequest https://example.org -TimeoutSec 8' -Policy @{ network = 'allow-list'; allowedHosts = @('example.com') }
        $result.exitCode | Should -Not -Be 0
        $result.stderr | Should -Match '403|Forbidden|denied'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'denies direct TCP and DNS even with an HTTPS allow-list' {
        $command = '$client = [Net.Sockets.TcpClient]::new(); $connected = $client.ConnectAsync("1.1.1.1",443).Wait(1500); $client.Dispose(); if ($connected) { throw "Direct TCP escaped" }; & /usr/bin/curl --noproxy "*" --connect-timeout 2 --max-time 3 https://example.com; exit $LASTEXITCODE'
        $result = Invoke-DpIsolatedProof -Command $command -Policy @{ network = 'allow-list'; allowedHosts = @('example.com') }
        $result.exitCode | Should -Not -Be 0
        $result.stderr | Should -Not -Match 'Direct TCP escaped'
        $result.stdout | Should -Not -Match 'Example Domain'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'Stop terminates a command after its descendant is running' {
        $command = '$child = Start-Process /bin/sleep -ArgumentList 60 -PassThru; Set-Content /tmp/descendant.ready $child.Id; Start-Sleep -Seconds 60'
        $result = Invoke-DpIsolatedProof -Command $command -StopAfterDescendant
        $result.cancelled | Should -BeTrue
        $result.exitCode | Should -Be 125
        $result.cleanupSucceeded | Should -BeTrue
        $remaining = Invoke-DpDockerControl -Argument @('ps', '--all', '--filter', 'label=io.deskpilot.terminal=1', '--format', '{{.ID}}')
        $remaining | Should -BeNullOrEmpty
    }

    It 'cannot reach a sibling secret through a Project junction' {
        $outside = Join-Path $TestDrive 'outside'
        $null = New-Item -Path $outside -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $outside 'private.txt') -Value 'outside-fixture-only'
        $link = Join-Path $script:project 'escape'
        $null = New-Item -Path $link -ItemType Junction -Target $outside
        try {
            $result = Invoke-DpIsolatedProof -Command '[IO.File]::Exists("/project/escape/private.txt"); Test-Path /mnt/host; Test-Path /var/run/docker.sock'
            $result.exitCode | Should -Be 0
            @($result.stdout.Trim() -split '\r?\n') | Should -Be @('False', 'False', 'False')
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }

    It 'refuses read-write Project hard links before running a command' {
        $outside = Join-Path $TestDrive 'hard-link-secret.txt'
        Set-Content -LiteralPath $outside -Value 'outside-original'
        $link = Join-Path $script:project 'hard-link.txt'
        $null = New-Item -Path $link -ItemType HardLink -Target $outside
        try {
            $result = Invoke-DpIsolatedProof -Command 'Set-Content /project/hard-link.txt forbidden' -Policy @{ projectAccess = 'read-write' }
            $result.exitCode | Should -Not -Be 0
            $result.error | Should -Match 'hard-linked'
            (Get-Content -LiteralPath $outside -Raw).Trim() | Should -BeExactly 'outside-original'
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }

    It 'refuses archive traversal outside the Project' {
        $archivePath = Join-Path $script:project 'crafted.zip'
        $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('../../escaped.txt')
            $writer = [IO.StreamWriter]::new($entry.Open())
            $writer.Write('archive-fixture')
            $writer.Dispose()
        }
        finally { $archive.Dispose() }
        $result = Invoke-DpIsolatedProof -Command '[IO.Compression.ZipFile]::ExtractToDirectory("/project/crafted.zip", "/project/extracted")' -Policy @{ projectAccess = 'read-write' }
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $TestDrive 'escaped.txt') | Should -BeFalse
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'reports memory exhaustion inside the declared cgroup bound' {
        $result = Invoke-DpIsolatedProof -Command '$bytes = [byte[]]::new(512MB); for ($offset = 0; $offset -lt $bytes.Length; $offset += 4096) { $bytes[$offset] = 1 }' -Policy @{ memoryMB = 256 }
        $result.exitCode | Should -Not -Be 0
        ($result.outOfMemory -or $result.stderr -match 'memory|OutOfMemory') | Should -BeTrue
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'refuses process creation above the declared process bound' {
        $command = '& /bin/sh -c ''for number in $(seq 1 100); do /bin/sleep 30 & done; wait''; exit $LASTEXITCODE'
        $result = Invoke-DpIsolatedProof -Command $command
        $result.exitCode | Should -Not -Be 0
        $result.stderr | Should -Match 'fork|resource'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'throttles CPU work under a fractional quota' {
        $command = '$until = [datetime]::UtcNow.AddSeconds(2); while ([datetime]::UtcNow -lt $until) { [math]::Sqrt(12345) | Out-Null }; Get-Content /sys/fs/cgroup/cpu.stat'
        $result = Invoke-DpIsolatedProof -Command $command -Policy @{ cpuCount = 0.1 }
        $result.exitCode | Should -Be 0
        $result.stdout | Should -Match 'nr_throttled [1-9][0-9]*'
    }

    It 'denies an unapproved HTTP Host behind an approved TLS origin' {
        $command = '& /usr/bin/curl --silent --show-error --fail-with-body --max-time 8 --header "Host: example.org" https://example.com; exit $LASTEXITCODE'
        $result = Invoke-DpIsolatedProof -Command $command -Policy @{ network = 'allow-list'; allowedHosts = @('example.com') }
        $result.exitCode | Should -Not -Be 0
        $result.stderr | Should -Match '403|409|certificate' -Because $result.stdout
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'denies cloud metadata through the HTTPS proxy' {
        $result = Invoke-DpIsolatedProof -Command 'Invoke-WebRequest https://169.254.169.254/latest/meta-data/ -TimeoutSec 5' -Policy @{ network = 'allow-list'; allowedHosts = @('example.com') }
        $result.exitCode | Should -Not -Be 0
        $result.stderr | Should -Match '403|Forbidden|denied'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'denies plain HTTP to an approved host on port 443' {
        $command = '& /usr/bin/curl --silent --show-error --fail-with-body --max-time 8 --proxy http://127.0.0.1:3128 http://example.com:443/; exit $LASTEXITCODE'
        $result = Invoke-DpIsolatedProof -Command $command -Policy @{ network = 'allow-list'; allowedHosts = @('example.com') }
        $result.exitCode | Should -Not -Be 0
        $result.stderr | Should -Match '403' -Because $result.stdout
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'denies a direct HTTPS proxy request without a CONNECT handshake' {
        $command = '$client=[Net.Sockets.TcpClient]::new("127.0.0.1",3128); $client.ReceiveTimeout=8000; $stream=$client.GetStream(); $bytes=[Text.Encoding]::ASCII.GetBytes("GET https://example.com:443/ HTTP/1.1`r`nHost: example.com:443`r`nConnection: close`r`n`r`n"); $stream.Write($bytes,0,$bytes.Length); $reader=[IO.StreamReader]::new($stream); $reader.ReadToEnd(); $reader.Dispose(); $client.Dispose()'
        $result = Invoke-DpIsolatedProof -Command $command -Policy @{ network = 'allow-list'; allowedHosts = @('example.com') }
        $result.exitCode | Should -Be 0 -Because ($result.error + $result.stderr)
        $result.stdout | Should -Match '^HTTP/1\.[01] 403'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'terminates a command when its HTTPS proxy crashes' {
        $result = Invoke-DpIsolatedProof -Command 'Set-Content /tmp/descendant.ready ready; Start-Sleep -Seconds 10; "survived"' -Policy @{ network = 'allow-list'; allowedHosts = @('example.com') } -CrashProxy
        $result.exitCode | Should -Not -Be 0
        $result.error | Should -Match 'HTTPS boundary'
        $result.stdout | Should -Not -Match 'survived'
        $result.cleanupSucceeded | Should -BeTrue
    }

    It 'reports a missing prepared image without running on the host' {
        $recordPath = Join-Path $TestDrive 'control' 'isolation' 'runtime.json'
        $original = Get-Content -LiteralPath $recordPath -Raw
        try {
            $record = $original | ConvertFrom-Json -AsHashtable
            $record.image = 'sha256:' + ('0' * 64)
            $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recordPath -Encoding utf8
            $result = Invoke-DpIsolatedProof -Command 'Set-Content /project/must-not-run.txt forbidden'
            $result.exitCode | Should -Not -Be 0
            $result.error | Should -Match 'creation failed'
            Test-Path -LiteralPath (Join-Path $script:project 'must-not-run.txt') | Should -BeFalse
            $result.cleanupSucceeded | Should -BeTrue
        }
        finally { Set-Content -LiteralPath $recordPath -Value $original -Encoding utf8 -NoNewline }
    }

    It 'keeps cleanup failure visible and refuses subsequent commands' {
        $record = Get-Content -LiteralPath (Join-Path $TestDrive 'control' 'isolation' 'runtime.json') -Raw | ConvertFrom-Json
        $policy = ConvertTo-DpTerminalExecution -InputObject @{ mode = 'isolated' }
        $arguments = @((Join-Path $TestDrive 'missing-docker.exe'), $script:project, (Join-Path $TestDrive 'failed-control'), $record.image, $record.powerShellVersion, ($policy | ConvertTo-Json -Depth 5 -Compress))
        $controller = New-Object -TypeName 'DeskPilot.Isolation.TerminalSession' -ArgumentList $arguments
        try {
            $result = $controller.Run('Write-Output test', '/project', 1) | ConvertFrom-Json
            $result.cleanupSucceeded | Should -BeFalse
            $result.error | Should -Match 'cleanup failed'
            { $controller.Run('Write-Output test', '/project', 1) } | Should -Throw '*requires cleanup*'
        }
        finally { $controller.Dispose() }
    }

    It 'prepares the runtime asynchronously and reports its verified state' {
        $previous = $script:DeskPilot
        $script:DeskPilot = @{ DataDir = (Join-Path $TestDrive 'async-control') }
        try {
            Start-DpTerminalPreparation | Should -BeTrue
            $job = $script:DeskPilot.TerminalSetupJob
            $job | Should -Not -BeNullOrEmpty
            $null = $job | Wait-Job -Timeout 120
            Update-DpTerminalPreparation
            $script:DeskPilot.TerminalSetupJob | Should -BeNullOrEmpty
            $script:DeskPilot.TerminalRuntime.ready | Should -BeTrue -Because ($script:DeskPilot.TerminalRuntime.issues -join ' ')
        }
        finally {
            if ($script:DeskPilot.TerminalSetupJob) { $script:DeskPilot.TerminalSetupJob | Remove-Job -Force }
            $script:DeskPilot = $previous
        }
    }
}
