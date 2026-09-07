BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
    $script:runtime = $null
    $script:control = Join-Path $TestDrive 'control'
    if ($IsWindows -and $env:DESKPILOT_CHILD_ENGINE_MODULE) {
        $script:runtime = Install-DpChildRuntime -DataDirectory $script:control -EngineModulePath $env:DESKPILOT_CHILD_ENGINE_MODULE
    }
}

AfterAll {
    if ($script:runtime) {
        foreach ($tag in @($script:runtime.engineTag, $script:runtime.tag, $script:runtime.baseTag)) {
            if ($tag) { $null = Invoke-DpDockerControl -Argument @('image', 'rm', $tag) }
        }
    }
}

Describe 'Prepared credentialless child Engine image' -Skip:(-not $IsWindows -or -not $env:DESKPILOT_CHILD_ENGINE_MODULE) {
    BeforeEach {
        $script:owner = $null
        $script:engine = $null
    }

    AfterEach {
        if ($script:engine) {
            $script:engine.Dispose()
            $script:engine.CleanupSucceeded | Should -BeTrue
        }
        if ($script:owner) {
            $script:owner.Dispose()
            $script:owner.CleanupSucceeded | Should -BeTrue
        }
    }

    It 'prepares separate immutable Engine bytes without enabling child execution' {
        $script:runtime.engineImage | Should -Match '^sha256:[a-f0-9]{64}$'
        $script:runtime.engineImage | Should -Not -Be $script:runtime.image
        $script:runtime.ready | Should -BeFalse
        Test-Path -LiteralPath $script:runtime.engineManifest -PathType Leaf | Should -BeTrue
        $script:runtime.engineHashes.Keys | Should -Contain 'ShellPilot.psm1'
        $script:runtime.engineHashes.Keys | Should -Contain 'data/PriceTable.psd1'
        foreach ($relative in $script:runtime.engineHashes.Keys) {
            (Get-FileHash -LiteralPath (Join-Path (Split-Path $script:runtime.engineManifest) $relative)).Hash |
                Should -BeExactly $script:runtime.engineHashes[$relative]
        }
        $inspection = @(Invoke-DpDockerControl -Argument @('image', 'inspect', $script:runtime.engineImage) | ConvertFrom-Json)[0]
        $inspection.Config.User | Should -BeExactly '65534:65534'
        $inspection.Config.Volumes | Should -BeNullOrEmpty
    }

    It 'shares one cleanup grace and refuses to claim cleanup after it expires' {
        $policy = ConvertTo-DpChildExecution -InputObject @{ profile = 'single-child-v3'; budgetMode = 'provider-estimate'; cleanupSeconds = 1 }
        $directory = Join-Path $script:control 'cleanup-deadline'
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '[Console]::ReadLine() | Out-Null')) { $start.ArgumentList.Add($argument) }
        $script:owner = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory $directory -Policy $policy -ProviderStart $start
        $script:engine = [DeskPilot.Child.EngineContainer]::new($script:owner, $script:runtime.engineImage)
        $clockField = $script:owner.GetType().GetField('_cleanupClock', [Reflection.BindingFlags]'Instance,NonPublic')
        $clockField | Should -Not -BeNullOrEmpty
        $clock = $clockField.GetValue($script:owner)
        $clock.Start()
        [Threading.Tasks.Task]::Delay(1100).GetAwaiter().GetResult()
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $script:owner.Stop()
        $script:owner.CleanupSucceeded | Should -BeFalse
        $elapsed.Elapsed.TotalSeconds | Should -BeLessThan 2
        $script:engine.Dispose()
        $script:owner.Dispose()
        $script:engine = $null
        $script:owner = $null
        $recovered = Remove-DpChildRun -DataDirectory $directory -Confirm:$false
        $recovered.containersRemoved | Should -Be 2
    }

    It 'runs the real Engine with no writable filesystem, host mounts, or network' {
        $policy = ConvertTo-DpChildExecution -InputObject @{ profile = 'single-child-v3'; budgetMode = 'provider-estimate' }
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '[Console]::ReadLine() | Out-Null')) { $start.ArgumentList.Add($argument) }
        $script:owner = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory (Join-Path $script:control 'engine-positive') -Policy $policy -ProviderStart $start
        $script:engine = [DeskPilot.Child.EngineContainer]::new($script:owner, $script:runtime.engineImage)
        $configuration = @{
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; model = 'claude-haiku-4.5'
            prompt = 'Inert contained request.'; agentBody = 'Inspect only selected input.'
            permissions = @{ file = $true; terminal = $false }; projectAccess = 'read-only'
            outputTokens = 64; iterations = 2; requestBytes = 262144; resultBytes = 262144
        }
        $script:engine.Configure(($configuration | ConvertTo-Json -Depth 8 -Compress))
        $deadline = [Threading.CancellationTokenSource]::new(30000)
        try {
            try {
                $request = $script:engine.ReceiveAsync($deadline.Token).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            } catch {
                $inspection = @(Invoke-DpDockerControl -Argument @('inspect', $script:engine.ContainerId) | ConvertFrom-Json)[0]
                $errorTask = $script:engine.GetType().GetField('_errors', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($script:engine)
                $inertError = if ($errorTask.IsCompletedSuccessfully) { [Text.Encoding]::UTF8.GetString($errorTask.Result) } else { 'stderr pending' }
                throw ('Inert Engine startup: exit={0}, oom={1}, stderr={2}' -f $inspection.State.ExitCode, $inspection.State.OOMKilled, $inertError)
            }
            $request.type | Should -BeExactly 'provider'
            @($request.payload.Tools.function.name) | Should -Be @('child_read_file')
            $inspection = $script:engine.Inspect() | ConvertFrom-Json
            $inspection.network | Should -BeExactly 'none'
            $inspection.hostMounts | Should -Be 0
            $inspection.readOnly | Should -BeTrue
            $inspection.memoryBytes | Should -Be ($policy.memoryBytes / 4)
            $inspection.pids | Should -Be 16
            $response = @{
                Mode = 'chat'; ModelName = 'claude-haiku-4.5'; Content = 'contained-result'; FinishReason = 'stop'
                ToolCalls = @(); AssistantMessage = @{ role = 'assistant'; content = 'contained-result' }
                Reasoning = ''; PromptTokens = 10; CompletionTokens = 2; CachedTokens = 0; CacheWriteTokens = 0
                CopilotUsage = $null; Raw = @{}; Response = @{ Headers = @{} }
            }
            $script:engine.Reply($request.id, (@{ ok = $true; response = $response } | ConvertTo-Json -Depth 16 -Compress))
            $result = $script:engine.ReceiveAsync($deadline.Token).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $result.type | Should -BeExactly 'complete'
            $result.result.content | Should -BeExactly 'contained-result'
            $result.result.filesWritten | Should -BeNullOrEmpty
        } finally { $deadline.Dispose() }
    }

    It 'expires the Engine lease independently of its waiting Runspace' {
        $policy = ConvertTo-DpChildExecution -InputObject @{ profile = 'single-child-v3'; budgetMode = 'provider-estimate'; leaseSeconds = 2 }
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '[Console]::ReadLine() | Out-Null')) { $start.ArgumentList.Add($argument) }
        $script:owner = New-DpChildToolContainer -Runtime $script:runtime -DataDirectory (Join-Path $script:control 'engine-lease') -Policy $policy -ProviderStart $start
        $script:engine = [DeskPilot.Child.EngineContainer]::new($script:owner, $script:runtime.engineImage)
        $script:engine.WithdrawLease()
        $exitCode = Invoke-DpDockerControl -Argument @('wait', $script:engine.ContainerId) -TimeoutSeconds 15
        if ($exitCode.Trim() -ne '125') {
            $deadline = [Threading.CancellationTokenSource]::new(5000)
            try { $frame = $script:engine.ReceiveAsync($deadline.Token).GetAwaiter().GetResult() }
            catch { $frame = 'no final frame' }
            finally { $deadline.Dispose() }
            $errorTask = $script:engine.GetType().GetField('_errors', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($script:engine)
            $inertError = if ($errorTask.IsCompletedSuccessfully) { [Text.Encoding]::UTF8.GetString($errorTask.Result) } else { 'stderr pending' }
            throw ('Inert Engine lease: exit={0}; frame={1}; stderr={2}' -f $exitCode.Trim(), $frame, $inertError)
        }
        $exitCode.Trim() | Should -BeExactly '125'
    }
}
