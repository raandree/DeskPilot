BeforeAll {
    $script:childSource = Join-Path $PSScriptRoot '../../source/child'
    $script:engineEntry = Join-Path $script:childSource 'Start-DpChildEngine.ps1'
    $script:engineModule = $env:DESKPILOT_CHILD_ENGINE_MODULE
    $script:boundaryAssembly = Join-Path $TestDrive 'ChildRuntime.dll'
    Add-Type -Path @(Get-ChildItem -LiteralPath $script:childSource -Filter '*.cs' -File | Select-Object -ExpandProperty FullName) -OutputAssembly $script:boundaryAssembly -ErrorAction Stop
    $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($script:boundaryAssembly))
}

Describe 'Credentialless Engine process profile' -Skip:(-not $IsWindows -or -not $env:DESKPILOT_CHILD_ENGINE_MODULE) {
    It 'denies native dispatch and starts with only frozen owned Tools and empty history' {
        Test-Path -LiteralPath $script:engineEntry | Should -BeTrue
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $environment['USERPROFILE'] = $TestDrive
        $environment['HOME'] = $TestDrive
        $environment['DOTNET_EnableDiagnostics'] = '0'
        $process = $null
        $channel = $null
        $cancellation = [Threading.CancellationTokenSource]::new(20000)
        try {
            $process = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-File',$script:engineEntry,'-EngineModulePath',$script:engineModule,'-RuntimeAssembly',$script:boundaryAssembly,'-LeaseSeconds','30'), $TestDrive, $environment, 536870912, 0.5, 8)
            $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            $channel = [DeskPilot.Child.MessageChannel]::new($process.Output,$process.Input,$key,$true,4194304)
            $process.Resume()
            $process.Input.Write($key)
            $process.Input.Flush()
            $configuration = @{
                profile = 'single-child-v3'; budgetMode = 'provider-estimate'; model = 'claude-haiku-4.5'
                prompt = 'Inert dispatch test.'; agentBody = 'Only inspect selected files.'
                permissions = @{ file = $true; terminal = $true }; projectAccess = 'read-only'
                outputTokens = 64; iterations = 3; requestBytes = 262144; resultBytes = 262144
            }
            $channel.Send((@{ type = 'configure'; configuration = $configuration } | ConvertTo-Json -Depth 12 -Compress))
            ($channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult() | ConvertFrom-Json).type | Should -BeExactly 'ready'
            $first = $channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            if ($first.type -eq 'complete') { throw ('Child failed: phase={0}, category={1}, line={2}' -f $first.result.phase, $first.result.category, $first.result.line) }
            $first.type | Should -BeExactly 'provider'
            @($first.payload.Tools.function.name) | Should -Contain 'child_read_file'
            @($first.payload.Tools.function.name) | Should -Contain 'child_terminal'
            @($first.payload.Tools.function.name) | Should -Not -Contain 'run_command'
            @($first.payload.Tools.function.name) | Should -Not -Contain 'child_write_file'
            $response = @{
                Mode = 'chat'; ModelName = 'claude-haiku-4.5'; Content = ''; FinishReason = 'tool_calls'
                ToolCalls = @(@{ Id = 'denied-native'; Name = 'run_command'; Arguments = '{"command":"Write-Output not-permitted"}' })
                AssistantMessage = @{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'denied-native'; type = 'function'; function = @{ name = 'run_command'; arguments = '{"command":"Write-Output not-permitted"}' } }) }
                Reasoning = ''; PromptTokens = 30; CompletionTokens = 10; CachedTokens = 0; CacheWriteTokens = 0
                CopilotUsage = $null; Raw = @{}; Response = @{ Headers = @{} }
            }
            $channel.Send((@{ type = 'reply'; id = $first.id; payload = @{ ok = $true; response = $response } } | ConvertTo-Json -Depth 18 -Compress))
            $second = $channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $second.type | Should -BeExactly 'provider'
            ($second.payload.Conversation | ConvertTo-Json -Depth 12) | Should -Match 'denied'
            $response.Content = 'Native Tool was refused.'
            $response.FinishReason = 'stop'
            $response.ToolCalls = @()
            $response.AssistantMessage = @{ role = 'assistant'; content = 'Native Tool was refused.' }
            $channel.Send((@{ type = 'reply'; id = $second.id; payload = @{ ok = $true; response = $response } } | ConvertTo-Json -Depth 18 -Compress))
            $final = $channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $final.type | Should -BeExactly 'complete'
            $final.result.content | Should -BeExactly 'Native Tool was refused.'
            $final.result.commandsRun | Should -BeNullOrEmpty
            $process.WaitForExit(5000) | Should -BeTrue
        } finally {
            $cancellation.Dispose()
            if ($channel) { $channel.Dispose() }
            if ($process) { $process.Dispose() }
        }
    }
}
