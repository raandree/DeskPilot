BeforeAll {
    $script:childSource = Join-Path $PSScriptRoot '../../source/child'
    $script:providerEntry = Join-Path $script:childSource 'Start-DpChildProvider.ps1'
    $script:boundaryAssembly = Join-Path $TestDrive 'ChildRuntime.dll'
    Add-Type -Path @(Get-ChildItem -LiteralPath $script:childSource -Filter '*.cs' -File | Select-Object -ExpandProperty FullName) -OutputAssembly $script:boundaryAssembly -ErrorAction Stop
    $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($script:boundaryAssembly))
    $script:fixtureModule = Join-Path $TestDrive 'ShellPilot.psm1'
    @'
function New-ShpChildProviderContext {
    param($Model, $Tools, $Limits, $TokenPath, $MaxRequests, $MaxRequestBytes, $MaxResponseBytes, $MaxCountBytes, $MaxOutputTokens, $DurationSeconds, $BeforeGeneration)
    @{ Model = $Model; BeforeGeneration = $BeforeGeneration; Closed = $false; Reserved = 0; Generated = 0; Headers = @{ Authorization = 'fixture-provider-private-canary' }; Client = [Net.Http.HttpClient]::new(); Cancellation = [Threading.CancellationTokenSource]::new() }
}
function Get-ShpChildProviderUsage {
    param($Context)
    @{ Model = $Context.Model; UsageKnown = ($Context.Reserved -eq 0 -or $Context.Generated -gt 0); ReservedTokens = $Context.Reserved; ReservedCostUSD = 0.0004; GenerationAttempts = $Context.Generated; BudgetMode = 'provider-estimate'; PromptTokens = 10; CompletionTokens = 2; CostUSD = 0.000012 }
}
function Invoke-ShpChildProviderRequest {
    param($Context, $Request)
    $Context.Reserved = 42
    $admitted = & $Context.BeforeGeneration ([pscustomobject]@{ RequestId = $Request.RequestId; RequestDigest = ('d' * 64) }) (Get-ShpChildProviderUsage -Context $Context)
    if (-not $admitted) { throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('fixture-provider-private-canary'), 'ShpChildAdmissionRevoked', 'PermissionDenied', $null) }
    $Context.Generated++
    [pscustomobject]@{ Mode = 'chat'; ModelName = $Context.Model; Content = 'fixture response'; ToolCalls = @(); AssistantMessage = @{ role = 'assistant'; content = 'fixture response' }; PromptTokens = 10; CompletionTokens = 2 }
}
'@ | Set-Content -LiteralPath $script:fixtureModule -Encoding utf8
}

Describe 'Trusted provider process bridge' -Skip:(-not $IsWindows) {
    It 'requires host admission and protects provider state when Grant is <Grant>' -ForEach @(
        @{ Grant = $true }
        @{ Grant = $false }
    ) {
        Test-Path -LiteralPath $script:providerEntry | Should -BeTrue
        $environment = [System.Collections.Generic.Dictionary[string,string]]::new()
        $environment['SystemRoot'] = $env:SystemRoot
        $environment['TEMP'] = $TestDrive
        $environment['TMP'] = $TestDrive
        $environment['USERPROFILE'] = $TestDrive
        $environment['HOME'] = $TestDrive
        $environment['DOTNET_EnableDiagnostics'] = '0'
        $process = $null
        $channel = $null
        $cancellation = [Threading.CancellationTokenSource]::new(15000)
        try {
            $process = [DeskPilot.Child.OwnedProcess]::new((Join-Path $PSHOME 'pwsh.exe'), @('-NoProfile','-NonInteractive','-File',$script:providerEntry,'-EngineModulePath',$script:fixtureModule,'-RuntimeAssembly',$script:boundaryAssembly,'-LeaseSeconds','30'), $TestDrive, $environment, 268435456, 0.25, 8)
            $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            $channel = [DeskPilot.Child.MessageChannel]::new($process.Output, $process.Input, $key, $true, 4194304)
            $process.Resume()
            $process.Input.Write($key)
            $process.Input.Flush()
            $configuration = @{
                profile = 'single-child-v3'; budgetMode = 'provider-estimate'; model = 'claude-haiku-4.5'
                permissions = @{ file = $false; terminal = $false }; projectAccess = 'read-only'
                inputTokens = 16384; totalTokens = 32768; costUSD = 0.25; outputTokens = 64; iterations = 3
                requestBytes = 262144; outputBytes = 1048576; eventBytes = 16384; durationSeconds = 60
            }
            $channel.Send((@{ type = 'configure'; configuration = $configuration } | ConvertTo-Json -Depth 8 -Compress))
            ($channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult() | ConvertFrom-Json).type | Should -BeExactly 'ready'
            $ready = $channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $ready.payload.stage | Should -BeExactly 'ready'
            $channel.Send((@{ type = 'reply'; id = $ready.id; payload = @{ action = 'invoke'; request = @{ RequestId = ('a' * 32) } } } | ConvertTo-Json -Depth 8 -Compress))
            $reservationJson = $channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult()
            $reservationJson | Should -Not -Match 'canary|Authorization|Headers'
            $reserved = $reservationJson | ConvertFrom-Json -AsHashtable
            $reserved.payload.stage | Should -BeExactly 'reserved'
            $reserved.payload.usage.ReservedTokens | Should -Be 42
            $reserved.payload.usage.GenerationAttempts | Should -Be 0
            $channel.Send((@{ type = 'reply'; id = $reserved.id; payload = @{ admitted = $Grant } } | ConvertTo-Json -Depth 8 -Compress))
            $resultJson = $channel.ReceiveAsync($cancellation.Token).GetAwaiter().GetResult()
            $resultJson | Should -Not -Match 'canary|Authorization|Headers'
            $result = $resultJson | ConvertFrom-Json -AsHashtable
            if ($Grant) {
                $result.payload.stage | Should -BeExactly 'response'
                $result.payload.response.Content | Should -BeExactly 'fixture response'
                $result.payload.usage.GenerationAttempts | Should -Be 1
                $channel.Send('{"type":"stop"}')
            } else {
                $result.type | Should -BeExactly 'complete'
                $result.result.code | Should -BeExactly 'admission-revoked'
                $result.result.usage.ReservedTokens | Should -Be 42
                $result.result.usage.GenerationAttempts | Should -Be 0
            }
            $process.WaitForExit(5000) | Should -BeTrue
        } finally {
            $cancellation.Dispose()
            if ($channel) { $channel.Dispose() }
            if ($process) { $process.Dispose() }
        }
    }
}
