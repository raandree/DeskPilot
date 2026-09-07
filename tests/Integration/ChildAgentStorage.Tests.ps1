#requires -Version 7.4

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '../../source/Private'
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    $script:control = Join-Path $TestDrive 'control'
    $script:runtime = Install-DpChildRuntime -DataDirectory $script:control
}

AfterAll {
    if ($script:runtime) {
        foreach ($tag in @($script:runtime.tag, $script:runtime.baseTag)) {
            $null = Invoke-DpDockerControl -Argument @('image', 'rm', $tag)
        }
    }
}

Describe 'Child Agent private quota-backed storage' -Tag 'Integration' {
    BeforeEach {
        $script:container = $null
        $script:policy = ConvertTo-DpChildExecution -InputObject @{
            projectAccess = 'read-write'
            storageBytes = 33554432
            toolStorageBytes = 16777216
            baselineBytes = 1024
            baselineFiles = 10
            proposalBytes = 1048576
            proposalFiles = 10
            inodeLimit = 128
        }
    }

    AfterEach {
        if ($script:container) {
            $script:container.Dispose()
            $script:container.CleanupSucceeded | Should -BeTrue
        }
    }

    It 'seeds a private filesystem and supports confined File and Terminal work' {
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seed('input.txt', [Text.Encoding]::UTF8.GetBytes('baseline'))
        $script:container.Seal()

        ($script:container.Read('input.txt', 0, 100) | ConvertFrom-Json).text | Should -BeExactly 'baseline'
        ($script:container.Write('output.txt', [Text.Encoding]::UTF8.GetBytes('proposal')) | ConvertFrom-Json).ok |
            Should -BeTrue
        $result = $script:container.Execute('[IO.File]::ReadAllText("/work/project/output.txt")') | ConvertFrom-Json
        $result.exitCode | Should -Be 0
        $result.stdout.Trim() | Should -BeExactly 'proposal'
        $state = $script:container.Inspect() | ConvertFrom-Json
        $state.bytes | Should -Be 16777216
        $state.inodes | Should -Be 128
        $state.network | Should -BeExactly 'none'
        $state.hostMounts | Should -Be 0
        $state.memoryBytes | Should -Be ($script:policy.memoryBytes / 2)
        $state.cpuNano | Should -Be ([long]($script:policy.cpuCount * 500000000))
        $state.pids | Should -Be 40
        $state.readOnly | Should -BeTrue
        Test-Path -LiteralPath $script:container.ClaimPath | Should -BeTrue
    }

    It 'refuses stale loaded runtime types before creating another container' {
        $first = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $first.Dispose()
        $key = 'DeskPilot.Child.LoadedSourceHash'
        $previous = [AppDomain]::CurrentDomain.GetData($key)
        $attempt = @{ Container = $null }
        try {
            [AppDomain]::CurrentDomain.SetData($key, ('0' * 64))
            { $attempt.Container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy } |
                Should -Throw -ExpectedMessage '*restart*'
        } finally {
            [AppDomain]::CurrentDomain.SetData($key, $previous)
            if ($attempt.Container) { $attempt.Container.Dispose() }
        }
    }

    It 'requires exact loaded assembly bytes for complete-profile execution' {
        Import-DpChildRuntime -Runtime $script:runtime
        $key = 'DeskPilot.Child.LoadedAssemblyHash'
        $previous = [AppDomain]::CurrentDomain.GetData($key)
        try {
            [AppDomain]::CurrentDomain.SetData($key, ('0' * 64))
            { Import-DpChildRuntime -Runtime $script:runtime -ExactAssembly } | Should -Throw -ExpectedMessage '*restart*'
        } finally { [AppDomain]::CurrentDomain.SetData($key, $previous) }
    }

    It 'uses the V3 aggregate host job for Docker control and Tool clients' {
        Import-DpChildRuntime -Runtime $script:runtime
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $owner = $null
        try {
            $owner = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-Command','[Console]::ReadLine() | Out-Null'), $TestDrive, $environment, 268435456, 0.25, 8)
            $owner.Resume()
            $script:policy.profile = 'single-child-v3'
            $script:policy.budgetMode = 'provider-estimate'
            $script:policy.requestBytes = 65536
            $script:policy.outputBytes = 65536
            $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy -HostProcess $owner
            $script:container.Seal()
            ($script:container.Execute('Write-Output bounded') | ConvertFrom-Json).stdout.Trim() | Should -BeExactly 'bounded'
            $script:container.Stop()
            $script:container.CleanupSucceeded | Should -BeTrue
            $owner.HasExited | Should -BeFalse
        } finally { if ($script:container) { $script:container.Dispose() }; if ($owner) { $owner.Dispose() } }
    }

    It 'records trusted provider ownership before resuming any provider code' {
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $start.Environment.Clear()
        $start.Environment['SystemRoot'] = $env:SystemRoot
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '[Console]::WriteLine("provider-ready"); [Console]::ReadLine() | Out-Null')) {
            $start.ArgumentList.Add($argument)
        }
        $script:policy.profile = 'single-child-v3'
        $script:policy.budgetMode = 'provider-estimate'
        $script:policy.requestBytes = 65536
        $script:policy.outputBytes = 65536
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy -ProviderStart $start
        $script:container.HostProcess.Resumed | Should -BeFalse
        $script:container.HostProcess.IsInOwnedJob | Should -BeTrue
        $identity = Get-Content -LiteralPath (Join-Path $script:container.DirectoryPath 'provider.json') -Raw | ConvertFrom-Json
        $identity.processId | Should -Be $script:container.HostProcess.Id
        $identity.startTimeUtcTicks | Should -Be $script:container.HostProcess.StartTimeUtcTicks
        $identity.runId | Should -BeExactly $script:container.RunId
        $barrier = Get-Item -LiteralPath (Join-Path $script:container.DirectoryPath 'AppData')
        $barrier.PSIsContainer | Should -BeFalse
        $barrier.Length | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:container.DirectoryPath -Force | Sort-Object Name | Select-Object -ExpandProperty Name) |
            Should -Be @('AppData', 'claim.json', 'config.json', 'ownership.json', 'provider.json') -Because 'provider code has not been resumed'
        $script:container.HostProcess.Resume()
        $reader = [IO.StreamReader]::new($script:container.HostProcess.Output, [Text.Encoding]::UTF8, $false, 1024, $true)
        $deadline = [Threading.CancellationTokenSource]::new(10000)
        try { $reader.ReadLineAsync($deadline.Token).GetAwaiter().GetResult() | Should -BeExactly 'provider-ready' }
        finally { $reader.Dispose(); $deadline.Dispose() }
        $script:container.HostProcess.HasExited | Should -BeFalse
        $script:container.Stop()
        $script:container.HostProcess.HasExited | Should -BeTrue
        $script:container.CleanupSucceeded | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:container.DirectoryPath -Force | Sort-Object Name | Select-Object -ExpandProperty Name) |
            Should -Be @('AppData', 'claim.json', 'config.json', 'ownership.json', 'provider.json')
    }

    It 'exhausts the actual writable byte quota through the File path' {
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()
        $result = $script:container.Write('full.bin', [byte[]]::new(16777217)) | ConvertFrom-Json

        $result.ok | Should -BeFalse
        $result.code | Should -BeExactly 'quota_exceeded'
    }

    It 'exhausts the same byte quota through Terminal temporary writes' {
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()
        $result = $script:container.Execute('[IO.File]::WriteAllBytes("/work/tmp/full.bin", [byte[]]::new(16777217))') | ConvertFrom-Json

        $result.exitCode | Should -Not -Be 0
        $result.quotaExceeded | Should -BeTrue
    }

    It 'exhausts the inode quota with empty files rather than relying on a byte-size scan' {
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()
        $result = $script:container.Execute('foreach ($index in 1..256) { [IO.File]::WriteAllText("/work/project/file-$index", "") }') | ConvertFrom-Json

        $result.exitCode | Should -Not -Be 0
        $result.quotaExceeded | Should -BeTrue
    }

    It 'denies read-only writes through File and Terminal while retaining readable input' {
        $script:policy.projectAccess = 'read-only'
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seed('input.txt', [Text.Encoding]::UTF8.GetBytes('read only'))
        $script:container.Seal()

        ($script:container.Write('input.txt', [Text.Encoding]::UTF8.GetBytes('changed')) | ConvertFrom-Json).ok |
            Should -BeFalse
        ($script:container.Execute('[IO.File]::WriteAllText("/work/project/input.txt", "changed")') | ConvertFrom-Json).exitCode |
            Should -Not -Be 0
        ($script:container.Read('input.txt', 0, 100) | ConvertFrom-Json).text | Should -BeExactly 'read only'
    }

    It 'does not inherit a host credential canary or expose host paths and control sockets' {
        $previous = $env:DP_CHILD_HOST_CANARY
        try {
            $env:DP_CHILD_HOST_CANARY = 'host-only-credential-canary'
            $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
            $script:container.Seal()
            $command = '@{ canary = $env:DP_CHILD_HOST_CANARY; sockets = @(@("/var/run/docker.sock", "/run/docker.sock", "/mnt/host", "/host_mnt") | Where-Object { Test-Path -LiteralPath $_ }); interfaces = @([IO.Directory]::GetDirectories("/sys/class/net") | ForEach-Object { [IO.Path]::GetFileName($_) }) } | ConvertTo-Json -Compress'
            $result = $script:container.Execute($command) | ConvertFrom-Json
            $result.exitCode | Should -Be 0
            $observed = $result.stdout | ConvertFrom-Json
            $observed.canary | Should -BeNullOrEmpty
            @($observed.sockets).Count | Should -Be 0
            @($observed.interfaces) | Should -Be @('lo')
        }
        finally {
            if ($null -eq $previous) { Remove-Item Env:DP_CHILD_HOST_CANARY }
            else { $env:DP_CHILD_HOST_CANARY = $previous }
        }
    }

    It 'stops a busy command and its descendants through the independent control path' {
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()
        $command = '$null = Start-Process /bin/sleep -ArgumentList "600"; [Console]::Out.WriteLine("descendant-started"); [Threading.Thread]::Sleep(600000)'
        $execution = $script:container.ExecuteAsync($command)
        $script:container.WaitForToolOutput(15000) | Should -BeTrue

        $script:container.Stop()

        $script:container.CleanupSucceeded | Should -BeTrue
        { $execution.GetAwaiter().GetResult() } | Should -Throw
        { $script:container.Execute('Write-Output late') } | Should -Throw -ExpectedMessage '*not running*'
    }

    It 'expires its independent lease while the owner and control connection remain alive' {
        $script:policy.leaseSeconds = 2
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()

        $script:container.WithdrawLease()
        $exitCode = Invoke-DpDockerControl -Argument @('wait', $script:container.ContainerId) -TimeoutSeconds 10

        $exitCode.Trim() | Should -BeExactly '124'
    }

    It 'terminates on output overflow before the overall duration limit' {
        $script:policy.outputBytes = 1024
        $script:policy.durationSeconds = 15
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()
        $clock = [Diagnostics.Stopwatch]::StartNew()

        { $script:container.Execute('[Console]::Out.Write("x" * 32768); [Threading.Thread]::Sleep(600000)') } |
            Should -Throw -ExpectedMessage '*output limit*'

        $clock.Elapsed.TotalSeconds | Should -BeLessThan 8
        $script:container.CleanupSucceeded | Should -BeTrue
    }

    It 'counts stdout and stderr against one combined output limit' {
        $script:policy.outputBytes = 1024
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()

        { $script:container.Execute('[Console]::Out.Write("x" * 800); [Console]::Error.Write("y" * 800)') } |
            Should -Throw -ExpectedMessage '*output limit*'
    }

    It 'blocks another run when durable cleanup cannot be confirmed' {
        $failureDirectory = Join-Path $script:control 'cleanup-failure'
        $failed = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $failureDirectory -Policy $script:policy
        $claim = [IO.File]::Open($failed.ClaimPath, 'Open', 'Read', 'Read')
        try {
            $failed.Stop()
            $failed.CleanupSucceeded | Should -BeFalse
        }
        finally {
            $claim.Dispose()
            $failed.Dispose()
        }

        $attempt = @{ Container = $null }
        try {
            { $attempt.Container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $failureDirectory -Policy $script:policy } |
                Should -Throw -ExpectedMessage '*cleanup*'
        }
        finally { if ($attempt.Container) { $attempt.Container.Dispose() } }
    }

    It 'exports independently verified proposed changes without applying them to the Project' {
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seed('kept.txt', [Text.Encoding]::UTF8.GetBytes('unchanged'))
        $script:container.Seed('changed.txt', [Text.Encoding]::UTF8.GetBytes('before'))
        $script:container.Seed('deleted.txt', [Text.Encoding]::UTF8.GetBytes('delete'))
        $script:container.Seal()
        $null = $script:container.Write('changed.txt', [Text.Encoding]::UTF8.GetBytes('after'))
        $null = $script:container.Write('new.txt', [Text.Encoding]::UTF8.GetBytes('new'))
        $null = $script:container.Execute('Remove-Item -LiteralPath /work/project/deleted.txt')

        $proposal = $script:container.Export() | ConvertFrom-Json

        @($proposal.files) | Should -HaveCount 3
        $changed = $proposal.files | Where-Object path -eq 'changed.txt'
        $changed.operation | Should -BeExactly 'modify'
        $changed.baselineSha256 | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('before'))).ToLowerInvariant())
        $changed.resultSha256 | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('after'))).ToLowerInvariant())
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($changed.contentBase64)) | Should -BeExactly 'after'
        ($proposal.files | Where-Object path -eq 'deleted.txt').operation | Should -BeExactly 'delete'
        ($proposal.files | Where-Object path -eq 'new.txt').operation | Should -BeExactly 'add'
        $proposal.runId | Should -Not -BeNullOrEmpty
        @($proposal.realProjectFilesWritten).Count | Should -Be 0
        { $script:container.Execute('Write-Output late') } | Should -Throw -ExpectedMessage '*not running*'
    }

    It 'refuses symlinks and hard links at export even when Terminal created them' -ForEach @(
        @{ LinkCommand = 'New-Item -ItemType SymbolicLink -Path /work/project/export.txt -Target /etc/passwd' }
        @{ LinkCommand = 'New-Item -ItemType HardLink -Path /work/project/export.txt -Target /work/project/input.txt' }
    ) {
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seed('input.txt', [Text.Encoding]::UTF8.GetBytes('input'))
        $script:container.Seal()
        ($script:container.Execute($LinkCommand) | ConvertFrom-Json).exitCode | Should -Be 0

        { $script:container.Export() } | Should -Throw -ExpectedMessage '*Unsafe export*'
    }

    It 'refuses proposal byte and file-count overflow while constructing export' {
        $script:policy.proposalBytes = 4
        $script:policy.proposalFiles = 1
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $script:control -Policy $script:policy
        $script:container.Seal()
        $null = $script:container.Write('large.txt', [Text.Encoding]::UTF8.GetBytes('oversized'))

        { $script:container.Export() } | Should -Throw -ExpectedMessage '*proposal*limit*'
    }

    It 'reserves retained host storage before admitting another run' {
        $retentionDirectory = Join-Path $script:control 'retention'
        $script:policy.retentionBytes = 33554432
        $first = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $retentionDirectory -Policy $script:policy
        $first.Dispose()
        $first.CleanupSucceeded | Should -BeTrue
        $attempt = @{ Container = $null }
        try {
            { $attempt.Container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $retentionDirectory -Policy $script:policy } |
                Should -Throw -ExpectedMessage '*retention*limit*'
        }
        finally { if ($attempt.Container) { $attempt.Container.Dispose() } }
    }

    It 'rejects a control-directory junction before creating run records outside the installation' {
        $outside = Join-Path $TestDrive 'outside-control'
        $null = New-Item -Path $outside -ItemType Directory
        $linkedControl = Join-Path $TestDrive 'linked-control'
        $null = New-Item -ItemType Junction -Path $linkedControl -Target $outside

        { New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $linkedControl -Policy $script:policy } |
            Should -Throw -ExpectedMessage '*reparse*'

        @(Get-ChildItem -LiteralPath $outside -Force).Count | Should -Be 0
    }

    It 'releases retained capacity only through explicit completed-run cleanup' {
        $retentionDirectory = Join-Path $script:control 'retention-cleanup'
        $script:policy.retentionBytes = 33554432
        $first = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $retentionDirectory -Policy $script:policy
        $first.Dispose()

        $cleanup = Remove-DpChildRun -DataDirectory $retentionDirectory -DiscardCompleted -Confirm:$false

        $cleanup.removed | Should -Be 1
        $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $retentionDirectory -Policy $script:policy
        $script:container.Seal()
    }

    It 'stops after owner process death and reconciles only the recorded orphan before another run' {
        $ownerDirectory = Join-Path $script:control 'owner-death'
        $script:policy.leaseSeconds = 2
        $policyJson = $script:policy | ConvertTo-Json -Compress
        $runtimeJson = $script:runtime | ConvertTo-Json -Depth 6 -Compress
        $payload = @'
$ErrorActionPreference = 'Stop'
Get-ChildItem -LiteralPath '__PRIVATE__' -Filter '*.ps1' | ForEach-Object { . $_.FullName }
$runtime = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__RUNTIME__')) | ConvertFrom-Json -AsHashtable
$policy = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__POLICY__')) | ConvertFrom-Json -AsHashtable
$container = New-DpChildToolContainer -Runtime $runtime -DataDirectory '__DIRECTORY__' -Policy $policy
$container.Seal()
[Console]::Out.WriteLine($container.ContainerId)
[Console]::Out.Flush()
$null = [Threading.ManualResetEventSlim]::new($false).Wait(60000)
$container.Dispose()
'@
        $payload = $payload.Replace('__PRIVATE__', ([IO.Path]::GetFullPath($privateRoot)).Replace("'", "''"))
        $payload = $payload.Replace('__DIRECTORY__', $ownerDirectory.Replace("'", "''"))
        $payload = $payload.Replace('__RUNTIME__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($runtimeJson)))
        $payload = $payload.Replace('__POLICY__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($policyJson)))
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload)))) {
            $start.ArgumentList.Add($argument)
        }
        $owner = [Diagnostics.Process]::Start($start)
        try {
            $identity = $owner.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(20)).GetAwaiter().GetResult()
            $identity | Should -Match '^[a-f0-9]{64}$'
            $owner.Kill($true)
            $owner.WaitForExit(10000) | Should -BeTrue
            (Invoke-DpDockerControl -Argument @('wait', $identity) -TimeoutSeconds 10).Trim() | Should -BeExactly '125'

            $cleanup = Remove-DpChildRun -DataDirectory $ownerDirectory -Confirm:$false

            $cleanup.interrupted | Should -Be 1
            $cleanup.containersRemoved | Should -Be 1
            $script:container = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $ownerDirectory -Policy $script:policy
            $script:container.Seal()
        }
        finally {
            if (-not $owner.HasExited) { $owner.Kill($true); $null = $owner.WaitForExit(10000) }
            $owner.Dispose()
            if ($identity -cmatch '^[a-f0-9]{64}$') {
                $remaining = Invoke-DpDockerControl -Argument @('ps', '--all', '--no-trunc', '--filter', "id=$identity", '--format', '{{.ID}}')
                if ($remaining -ceq $identity) { $null = Invoke-DpDockerControl -Argument @('rm', '--force', $identity) }
            }
        }
    }
}
