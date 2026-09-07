BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
    $script:control = Join-Path $TestDrive 'control'
    $script:runtime = $null
    function Invoke-ChildHttpFixture {
        param([string]$Method, [string]$Path, [object]$Body, [switch]$NoToken)
        $requestMessage = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), ($script:httpBase + $Path))
        if (-not $NoToken) { $requestMessage.Headers.Add('X-DeskPilot-Token', $script:DeskPilot.Token) }
        $requestMessage.Headers.Add('Origin', $script:httpBase)
        if ($null -ne $Body) { $requestMessage.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 12 -Compress), [Text.Encoding]::UTF8, 'application/json') }
        $responseTask = $script:httpClient.SendAsync($requestMessage)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not $responseTask.IsCompleted -and $clock.Elapsed.TotalSeconds -lt 15) {
            Update-DpChildRunState
            if ($script:httpListener.Pending()) {
                Invoke-DpClient -Client $script:httpListener.AcceptTcpClient() -ReadTimeoutMs 5000
            } else { $null = [Threading.Tasks.Task]::WhenAny($responseTask, [Threading.Tasks.Task]::Delay(10)).GetAwaiter().GetResult() }
        }
        try {
            if (-not $responseTask.IsCompleted) { throw 'Fixture HTTP request timed out.' }
            $responseMessage = $responseTask.GetAwaiter().GetResult()
            try {
                @{ Status = [int]$responseMessage.StatusCode; Body = ($responseMessage.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -Depth 24) }
            } finally { $responseMessage.Dispose() }
        } finally { $requestMessage.Dispose() }
    }
    if ($IsWindows -and $env:DESKPILOT_CHILD_ENGINE_MODULE) {
        $script:runtime = Install-DpChildRuntime -DataDirectory $script:control -EngineModulePath $env:DESKPILOT_CHILD_ENGINE_MODULE
        $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($script:runtime.assembly))
        $fixtureRoot = Join-Path $TestDrive 'fixture-engine'
        Copy-Item -LiteralPath (Split-Path $script:runtime.engineManifest) -Destination $fixtureRoot -Recurse
        $fixture = @'
function New-ShpChildProviderContext {
    param($Model, $Tools, $Limits, $TokenPath, $MaxRequests, $MaxRequestBytes, $MaxResponseBytes, $MaxCountBytes, $MaxOutputTokens, $DurationSeconds, $BeforeGeneration)
    @{ Model = $Model; BeforeGeneration = $BeforeGeneration; Closed = $false; Reserved = 0; Generated = 0; Headers = @{ Authorization = 'private-provider-canary' }; Client = [Net.Http.HttpClient]::new(); Cancellation = [Threading.CancellationTokenSource]::new() }
}
function Get-ShpChildProviderUsage {
    param($Context)
    @{ Model = $Context.Model; UsageKnown = ($Context.Reserved -eq $Context.Generated * 132); ReservedTokens = $Context.Reserved; ReservedCostUSD = 0.0004; GenerationAttempts = $Context.Generated; CountAttempts = [int]($Context.Reserved / 132); ControlAttempts = 2; BudgetMode = 'provider-estimate'; PromptTokens = ($Context.Generated * 20); CompletionTokens = ($Context.Generated * 4); CostUSD = ($Context.Generated * 0.00004) }
}
function Invoke-ShpChildProviderRequest {
    param($Context, $Request)
    $Context.Reserved += 132
    $admitted = & $Context.BeforeGeneration ([pscustomobject]@{ RequestId = $Request.RequestId; RequestDigest = ('d' * 64) }) (Get-ShpChildProviderUsage -Context $Context)
    if (-not $admitted) { throw 'Private provider request refused.' }
    $Context.Generated++
    if ($Context.Generated -eq 2 -and ($Request.Conversation | ConvertTo-Json -Depth 16 -Compress) -notmatch 'selected baseline') { throw 'The selected file result was not returned.' }
    $toolName = switch ($Context.Generated) { 1 { 'child_read_file' }; 2 { 'child_write_file' }; 3 { 'child_terminal' }; default { '' } }
    $arguments = switch ($Context.Generated) { 1 { '{"Path":"input.txt"}' }; 2 { '{"Path":"result.txt","Content":"private proposal"}' }; 3 { '{"Command":"Write-Output contained-command"}' }; default { '{}' } }
    if ($Context.Generated -eq 3 -and ($Request.Conversation | ConvertTo-Json -Depth 16 -Compress) -match 'BUSY_TOOL_PROOF') {
        $arguments = @{ Command = '[Console]::Out.WriteLine("busy-tool-ready"); [Threading.ManualResetEventSlim]::new($false).Wait()' } | ConvertTo-Json -Compress
    }
    $message = @{ role = 'assistant'; content = '' }
    $calls = @()
    $finish = 'stop'
    if ($toolName) {
        $message.tool_calls = @(@{ id = ('fixture-' + $Context.Generated); type = 'function'; function = @{ name = $toolName; arguments = $arguments } })
        $calls = @(@{ Id = ('fixture-' + $Context.Generated); Name = $toolName; Arguments = $arguments })
        $finish = 'tool_calls'
    } else { $message.content = 'Completed private child work.' }
    [pscustomobject]@{ Mode = 'chat'; ModelName = $Context.Model; Content = $message.content; FinishReason = $finish; ToolCalls = $calls; AssistantMessage = $message; Reasoning = ''; PromptTokens = 20; CompletionTokens = 4; CachedTokens = 0; CacheWriteTokens = 0; CopilotUsage = $null; Raw = @{}; Response = @{ Headers = @{} } }
}
'@
        Add-Content -LiteralPath (Join-Path $fixtureRoot 'ShellPilot.psm1') -Value $fixture -Encoding utf8
        $script:fixtureRuntime = $script:runtime.Clone()
        $script:fixtureRuntime.engineManifest = Join-Path $fixtureRoot 'ShellPilot.psd1'
    }
}

AfterAll {
    if ($script:runtime) {
        foreach ($tag in @($script:runtime.engineTag, $script:runtime.tag, $script:runtime.baseTag)) {
            $null = Invoke-DpDockerControl -Argument @('image', 'rm', $tag)
        }
    }
}

Describe 'Complete single-child controller' -Skip:(-not $IsWindows -or -not $env:DESKPILOT_CHILD_ENGINE_MODULE) {
    It 'serves authenticated child HTTP actions while the parent stays idle and Git stays unchanged' {
        $prior = $script:DeskPilot
        $project = Join-Path $TestDrive 'http-project'
        $directory = Join-Path $script:control 'http-host'
        $null = New-Item -Path $project -ItemType Directory
        $null = & git -C $project init -q
        [IO.File]::WriteAllText((Join-Path $project 'input.txt'), 'staged baseline')
        $null = & git -C $project add -- input.txt
        [IO.File]::WriteAllText((Join-Path $project 'input.txt'), 'selected baseline')
        $indexHash = (Get-FileHash -LiteralPath (Join-Path $project '.git/index')).Hash
        $settings = Get-DpDefaultSettings
        $settings.childExecution = ConvertTo-DpChildExecution -InputObject @{
            enabled = $true; profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-write'; durationSeconds = 90
        }
        $settings.permissions.file = $true
        $settings.permissions.terminal = $true
        $conversation = @{
            id = 'conversation'; title = 'Child HTTP proof'; titleLocked = $true; model = 'claude-haiku-4.5'
            pinned = $false; archived = $false; unread = $false; color = $null; compactedUtc = $null
            createdUtc = [datetime]::UtcNow.ToString('o'); updatedUtc = [datetime]::UtcNow.ToString('o')
            messages = [System.Collections.Generic.List[object]]::new(); history = @()
        }
        $parent = [runspacefactory]::CreateRunspace()
        $parent.Open()
        $script:DeskPilot = @{
            Token = [guid]::NewGuid().ToString('N'); TurnRunning = $true; CancelRequested = $false; DataDir = $directory
            Settings = $settings; Engine = @{ Runspace = $parent }; Conversations = @{ conversation = $conversation }
            Usage = @{ promptTokens = 0; completionTokens = 0; totalTokens = 0; costUSD = 0.0; credits = 0.0; turns = 0; unpricedTurns = 0; byModel = @{} }
            LifetimeUsage = New-DpLifetimeUsage
            Child = @{ Controller = $null; Last = $null; Recorded = $false; CleanupBlocked = $false; Prompt = 'Private HTTP work.'; Runtime = $script:runtime; Proof = $null; Health = $null; SetupJob = $null; Error = '' }
            Routes = @(
                @{ Method = 'GET'; Pattern = '/api/diagnostics/child'; Name = 'getChildReadiness' }
                @{ Method = 'GET'; Pattern = '/api/conversations/{id}/child-runs/{childId}'; Name = 'getChildRun' }
                @{ Method = 'GET'; Pattern = '/api/conversations/{id}/child-runs/{childId}/proposal'; Name = 'getChildProposal' }
                @{ Method = 'POST'; Pattern = '/api/conversations/{id}/child-runs/{childId}/approval'; Name = 'approveChildRun' }
                @{ Method = 'POST'; Pattern = '/api/conversations/{id}/messages'; Name = 'postMessage' }
            )
        }
        $request = @{
            launchId = $script:DeskPilot.Token; conversationId = 'conversation'; parentTurnId = 'parent'
            prompt = 'Private HTTP work.'; agentBody = 'Private Tool proof.'; projectPath = $project
            selectedPaths = @('input.txt'); permissions = @{ file = $true; terminal = $true }; policy = $settings.childExecution
        }
        $controller = $null
        $script:httpListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $script:httpListener.Start()
        $script:httpBase = 'http://127.0.0.1:' + $script:httpListener.LocalEndpoint.Port
        $script:httpClient = [Net.Http.HttpClient]::new()
        $script:httpClient.Timeout = [TimeSpan]::FromSeconds(15)
        try {
            (Invoke-ChildHttpFixture -Method GET -Path '/api/diagnostics/child' -NoToken).Status | Should -Be 401
            (Invoke-ChildHttpFixture -Method GET -Path '/api/diagnostics/child').Body.ready | Should -BeFalse
            $controller = [DeskPilot.Child.RunController]::new(($script:fixtureRuntime | ConvertTo-Json -Depth 12 -Compress), $directory, ($request | ConvertTo-Json -Depth 12 -Compress))
            $script:DeskPilot.Child.Controller = $controller
            $basePath = '/api/conversations/conversation/child-runs/' + $controller.Id
            (Invoke-ChildHttpFixture -Method POST -Path '/api/conversations/conversation/messages' -Body @{ prompt = 'Must not run.' }).Status | Should -Be 409
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not $controller.Completion.IsCompleted -and $clock.Elapsed.TotalSeconds -lt 100) {
                $status = Invoke-ChildHttpFixture -Method GET -Path $basePath
                $status.Status | Should -Be 200
                $parent.RunspaceAvailability | Should -BeExactly 'Available'
                if ($status.Body.approval -and $seen.Add($status.Body.approval.id)) {
                    $approval = $status.Body.approval
                    $answer = Invoke-ChildHttpFixture -Method POST -Path ($basePath + '/approval') -Body @{ approvalId = $approval.id; fingerprint = $approval.fingerprint; decision = 'approve' }
                    $answer.Status | Should -Be 202
                }
                $null = $controller.WaitForChange(200)
            }
            $controller.Completion.IsCompleted | Should -BeTrue
            Update-DpChildRunState
            $result = Invoke-ChildHttpFixture -Method GET -Path $basePath
            $result.Body.status | Should -BeExactly 'completed'
            $result.Body.cleanupSucceeded | Should -BeTrue
            $seen.Count | Should -Be 2
            $proposal = Invoke-ChildHttpFixture -Method GET -Path ($basePath + '/proposal')
            @($proposal.Body.files.path) | Should -Be @('result.txt')
            $script:DeskPilot.TurnRunning | Should -BeFalse
            $script:DeskPilot.Usage.turns | Should -Be 1
            @($conversation.history).Count | Should -Be 0
            $conversation.messages.Count | Should -Be 2
            (Get-FileHash -LiteralPath (Join-Path $project '.git/index')).Hash | Should -BeExactly $indexHash
            [IO.File]::ReadAllText((Join-Path $project 'input.txt')) | Should -BeExactly 'selected baseline'
            Test-Path -LiteralPath (Join-Path $project 'result.txt') | Should -BeFalse
            (Invoke-ChildHttpFixture -Method GET -Path '/api/diagnostics/child').Body.ready | Should -BeFalse
        } finally {
            if ($controller) { $controller.Dispose() }
            $script:httpClient.Dispose()
            $script:httpListener.Stop()
            $parent.Dispose()
            $script:DeskPilot = $prior
        }
    }

    It 'kills the provider through owner death and reconciles both expired containers without replay' {
        $project = Join-Path $TestDrive 'host-death-project'
        $null = New-Item -Path $project -ItemType Directory
        [IO.File]::WriteAllText((Join-Path $project 'input.txt'), 'selected baseline')
        $directory = Join-Path $script:control 'whole-host-death'
        $policy = ConvertTo-DpChildExecution -InputObject @{
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-write'; durationSeconds = 90; leaseSeconds = 2
        }
        $request = @{
            launchId = 'fixture'; conversationId = 'conversation'; parentTurnId = 'parent'
            prompt = 'Private work.'; agentBody = 'Private Tool proof.'; projectPath = $project
            selectedPaths = @('input.txt'); permissions = @{ file = $true; terminal = $true }; policy = $policy
        }
        $payload = @'
$ErrorActionPreference = 'Stop'
$runtime = '__RUNTIME__' | ConvertFrom-Json -AsHashtable -Depth 16
$request = '__REQUEST__'
$null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($runtime.assembly))
$controller = [DeskPilot.Child.RunController]::new(($runtime | ConvertTo-Json -Depth 16 -Compress), '__DIRECTORY__', $request)
while (-not $controller.Completion.IsCompleted) {
    $snapshot = $controller.Snapshot() | ConvertFrom-Json
    if ($snapshot.approval) {
        $root = Join-Path '__DIRECTORY__' ('child-runs/' + $controller.Id)
        $provider = Get-Content -LiteralPath (Join-Path $root 'provider.json') -Raw | ConvertFrom-Json
        $tool = Get-Content -LiteralPath (Join-Path $root 'claim.json') -Raw | ConvertFrom-Json
        $engine = Get-Content -LiteralPath (Join-Path $root 'engine.json') -Raw | ConvertFrom-Json
        [Console]::Out.WriteLine((@{ id = $controller.Id; provider = $provider.processId; providerStart = $provider.startTimeUtcTicks; tool = $tool.containerId; engine = $engine.containerId } | ConvertTo-Json -Compress))
        [Console]::Out.Flush()
        [Threading.ManualResetEventSlim]::new($false).Wait()
    }
    $null = $controller.WaitForChange(100)
}
throw 'Candidate did not reach its approval boundary.'
'@
        $payload = $payload.Replace('__RUNTIME__', ($script:fixtureRuntime | ConvertTo-Json -Depth 16 -Compress).Replace("'", "''"))
        $payload = $payload.Replace('__REQUEST__', ($request | ConvertTo-Json -Depth 16 -Compress).Replace("'", "''"))
        $payload = $payload.Replace('__DIRECTORY__', $directory.Replace("'", "''"))
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload)))) { $start.ArgumentList.Add($argument) }
        $hostProcess = [Diagnostics.Process]::Start($start)
        $providerProcess = $null
        $identity = $null
        try {
            $identity = $hostProcess.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(50)).GetAwaiter().GetResult() | ConvertFrom-Json
            $identity.id | Should -Match '^[a-f0-9]{32}$'
            $providerProcess = [Diagnostics.Process]::GetProcessById($identity.provider)
            $null = $providerProcess.Handle
            $providerProcess.StartTime.ToUniversalTime().Ticks | Should -Be $identity.providerStart
            $hostProcess.Kill()
            $hostProcess.WaitForExit(5000) | Should -BeTrue
            $providerProcess.WaitForExit(10000) | Should -BeTrue
            foreach ($containerId in @($identity.tool, $identity.engine)) {
                (Invoke-DpDockerControl -Argument @('wait', $containerId) -TimeoutSeconds 10).Trim() | Should -BeIn @('124', '125')
            }
            $cleanup = Remove-DpChildRun -DataDirectory $directory -Confirm:$false
            $cleanup.containersRemoved | Should -Be 2
            $cleanup.interrupted | Should -Be 1
            $record = Get-Content -LiteralPath (Join-Path $directory ('child-runs/' + $identity.id + '/run.json')) -Raw | ConvertFrom-Json
            $record.code | Should -BeExactly 'interrupted'
            $record.cleanupSucceeded | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $project 'result.txt') | Should -BeFalse
        } finally {
            if (-not $hostProcess.HasExited) { $hostProcess.Kill(); $null = $hostProcess.WaitForExit(5000) }
            $hostProcess.Dispose()
            if ($providerProcess) { $providerProcess.Dispose() }
            if ($identity) { $null = Remove-DpChildRun -DataDirectory $directory -Confirm:$false }
        }
    }

    It 'shows committed Tool execution and stops it without waiting for its command to return' {
        $project = Join-Path $TestDrive 'busy-tool'
        $null = New-Item -Path $project -ItemType Directory
        [IO.File]::WriteAllText((Join-Path $project 'input.txt'), 'selected baseline')
        $policy = ConvertTo-DpChildExecution -InputObject @{
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-write'; durationSeconds = 60
        }
        $request = @{
            launchId = 'fixture'; conversationId = 'conversation'; parentTurnId = 'parent'
            prompt = 'BUSY_TOOL_PROOF'; agentBody = 'Private Tool proof.'; projectPath = $project
            selectedPaths = @('input.txt'); permissions = @{ file = $true; terminal = $true }; policy = $policy
        }
        $controller = $null
        try {
            $controller = [DeskPilot.Child.RunController]::new(($script:fixtureRuntime | ConvertTo-Json -Depth 12 -Compress), (Join-Path $script:control 'busy-tool'), ($request | ConvertTo-Json -Depth 12 -Compress))
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $terminalApproved = $false
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            while (-not $terminalApproved -and -not $controller.Completion.IsCompleted -and $clock.Elapsed.TotalSeconds -lt 45) {
                $snapshot = $controller.Snapshot() | ConvertFrom-Json
                if ($snapshot.approval -and $seen.Add($snapshot.approval.id)) {
                    $controller.SubmitApproval('conversation', $controller.Id, $snapshot.approval.id, $snapshot.approval.fingerprint, $true) | Should -BeTrue
                    $terminalApproved = $snapshot.approval.operation -eq 'terminal'
                }
                $null = $controller.WaitForChange(100)
            }
            $terminalApproved | Should -BeTrue
            $owner = $controller.GetType().GetField('_owner', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($controller)
            $owner.WaitForToolOutput(10000) | Should -BeTrue
            $snapshot = $controller.Snapshot() | ConvertFrom-Json
            $snapshot.phase | Should -BeExactly 'tool-terminal'
            $snapshot.status | Should -BeExactly 'running'
            $stopClock = [Diagnostics.Stopwatch]::StartNew()
            $controller.Stop()
            $stopClock.Elapsed.TotalSeconds | Should -BeLessThan 1
            $controller.Completion.Wait(10000) | Should -BeTrue
            $final = $controller.Snapshot() | ConvertFrom-Json
            $final.status | Should -BeExactly 'stopped'
            $final.cleanupSucceeded | Should -BeTrue
        } finally { if ($controller) { $controller.Dispose() } }
    }

    It 'closes admission and verifies cleanup for <Action>' -ForEach @(
        @{ Action = 'startup-stop'; WaitForApproval = $false }
        @{ Action = 'approval-stop'; WaitForApproval = $true }
        @{ Action = 'approval-revocation'; WaitForApproval = $true }
    ) {
        ('DeskPilot.Child.RunController' -as [type]) | Should -Not -BeNullOrEmpty
        $project = Join-Path $TestDrive $Action
        $null = New-Item -Path $project -ItemType Directory
        [IO.File]::WriteAllText((Join-Path $project 'input.txt'), 'selected baseline')
        $policy = ConvertTo-DpChildExecution -InputObject @{
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-write'
            durationSeconds = 60; outputTokens = 128
        }
        $request = @{
            launchId = 'fixture-launch'; conversationId = 'fixture-conversation'; parentTurnId = 'fixture-parent'
            prompt = 'Perform the selected private work.'; agentBody = 'Use only the private Project.'
            projectPath = $project; selectedPaths = @('input.txt'); permissions = @{ file = $true; terminal = $true }
            policy = $policy
        }
        $controller = $null
        try {
            $controller = [DeskPilot.Child.RunController]::new(($script:fixtureRuntime | ConvertTo-Json -Depth 12 -Compress), (Join-Path $script:control $Action), ($request | ConvertTo-Json -Depth 12 -Compress))
            if ($WaitForApproval) {
                $deadline = [Diagnostics.Stopwatch]::StartNew()
                do {
                    $snapshot = $controller.Snapshot() | ConvertFrom-Json
                    if ($snapshot.approval) { break }
                    $null = $controller.WaitForChange(250)
                } while (-not $controller.Completion.IsCompleted -and $deadline.Elapsed.TotalSeconds -lt 45)
                $snapshot.approval | Should -Not -BeNullOrEmpty
            }
            if ($Action -eq 'approval-revocation') { $controller.UpdatePermissions($false, $true, $true) }
            else { $controller.Stop() }
            $controller.Completion.Wait(10000) | Should -BeTrue
            $final = $controller.Snapshot() | ConvertFrom-Json
            $final.cleanupSucceeded | Should -BeTrue
            if ($Action -eq 'approval-revocation') {
                $final.status | Should -BeExactly 'failed'
                $final.code | Should -BeExactly 'permission-revoked'
            } else { $final.status | Should -BeExactly 'stopped' }
            if ($WaitForApproval) {
                $controller.SubmitApproval('fixture-conversation', $controller.Id, $snapshot.approval.id, $snapshot.approval.fingerprint, $true) | Should -BeFalse
            }
            $remaining = Invoke-DpDockerControl -Argument @('ps', '--all', '--filter', ('label=io.deskpilot.child.run=' + $controller.Id), '--format', '{{.ID}}')
            $remaining | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $project 'result.txt') | Should -BeFalse
        } finally { if ($controller) { $controller.Dispose() } }
    }

    It 'keeps proposals private and obeys separate approvals with Grant=<Grant>' -ForEach @(
        @{ Grant = $true }
        @{ Grant = $false }
    ) {
        ('DeskPilot.Child.RunController' -as [type]) | Should -Not -BeNullOrEmpty
        $project = Join-Path $TestDrive ('project-' + $Grant)
        $null = New-Item -Path $project -ItemType Directory
        [IO.File]::WriteAllText((Join-Path $project 'input.txt'), 'selected baseline')
        [IO.File]::WriteAllText((Join-Path $project 'not-selected.txt'), 'host-only-project-canary')
        $policy = ConvertTo-DpChildExecution -InputObject @{
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-write'
            durationSeconds = 90; outputTokens = 128
        }
        $request = @{
            launchId = 'fixture-launch'; conversationId = 'fixture-conversation'; parentTurnId = 'fixture-parent'
            prompt = 'Perform the selected private work.'; agentBody = 'Use only the private Project.'
            projectPath = $project; selectedPaths = @('input.txt'); permissions = @{ file = $true; terminal = $true }
            policy = $policy
        }
        $controller = $null
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        try {
            $controller = [DeskPilot.Child.RunController]::new(($script:fixtureRuntime | ConvertTo-Json -Depth 12 -Compress), (Join-Path $script:control ('run-' + $Grant)), ($request | ConvertTo-Json -Depth 12 -Compress))
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            while (-not $controller.Completion.IsCompleted -and $deadline.Elapsed.TotalSeconds -lt 100) {
                $snapshot = $controller.Snapshot() | ConvertFrom-Json
                if ($snapshot.approval -and $seen.Add($snapshot.approval.id)) {
                    $snapshot.approval.operation | Should -BeIn @('write', 'terminal')
                    $controller.SubmitApproval('fixture-conversation', $controller.Id, $snapshot.approval.id, $snapshot.approval.fingerprint, $Grant) | Should -BeTrue
                }
                $null = $controller.WaitForChange(250)
            }
            $controller.Completion.IsCompleted | Should -BeTrue
            $controller.Completion.GetAwaiter().GetResult()
            $snapshotJson = $controller.Snapshot()
            $snapshotJson | Should -Not -Match 'private-provider-canary|host-only-project-canary|Authorization'
            $snapshot = $snapshotJson | ConvertFrom-Json
            $snapshot.status | Should -BeExactly 'completed' -Because ('failure code: ' + $snapshot.code + ', phase: ' + $snapshot.phase)
            $snapshot.cleanupSucceeded | Should -BeTrue
            $snapshot.content | Should -BeExactly 'Completed private child work.'
            $snapshot.usage.GenerationAttempts | Should -Be 4
            $snapshot.usage.UsageKnown | Should -BeTrue
            $snapshot.filesWritten | Should -BeNullOrEmpty
            $seen.Count | Should -Be 2
            if ($Grant) {
                @($snapshot.commandsRun).Count | Should -Be 1
                $proposal = $controller.GetProposal() | ConvertFrom-Json
                @($proposal.files.path) | Should -Be @('result.txt')
            } else {
                $snapshot.commandsRun | Should -BeNullOrEmpty
                @((($controller.GetProposal() | ConvertFrom-Json).files)).Count | Should -Be 0
            }
            [IO.File]::ReadAllText((Join-Path $project 'input.txt')) | Should -BeExactly 'selected baseline'
            [IO.File]::ReadAllText((Join-Path $project 'not-selected.txt')) | Should -BeExactly 'host-only-project-canary'
            Test-Path -LiteralPath (Join-Path $project 'result.txt') | Should -BeFalse
        } finally { if ($controller) { $controller.Dispose() } }
    }
}
