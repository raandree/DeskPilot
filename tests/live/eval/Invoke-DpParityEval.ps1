#requires -Version 7.0
<#
.SYNOPSIS
    Runs the DeskPilot parity eval corpus against a live Copilot model.
.DESCRIPTION
    Every prompt in the parity series claims to close a gap; this is the thing
    that decides whether any of them did. It executes a corpus of cases drawn
    from tasks somebody actually ran, grades the prompt-08 transcript and the
    resulting repository state with deterministic graders, and records efficiency
    beside correctness without ever grading it - a cheaper run that is wrong is
    not better.

    THIS SENDS REAL PROMPTS AND SPENDS REAL CREDITS. It is deliberately outside
    the Pester suite: build.yaml runs only tests/QA and tests/Unit, so nothing
    here is reached by ./build.ps1 -Tasks test.

    Fixture discipline, without which the numbers are noise:

    - The target repository is **cloned** to a throwaway folder and checked out
      at its pinned SHA before every case. The source repository is never
      touched, never checked out and never cleaned - a harness that mutates a
      developer's working tree to make its numbers reproducible has traded one
      kind of wrong for a worse one.
    - Model, agent, permissions and iteration cap are fixed per case.
    - Each case gets a fresh Host Server process, and therefore a fresh Engine
      Runspace. Prompt 07 established that the runspace inherits the launcher's
      environment, so that inheritance is recorded as a caveat on every result.
    - The DeskPilot commit under test is recorded with every run.

    Output files carry no token, no absolute user path and no prompt text.
.PARAMETER RepositoryRoot
    The folder holding the fixture repositories named by the cases. Required, and
    never defaulted, so no machine-specific path is committed.
.PARAMETER CaseId
    Run only these case ids. Default: every case in the corpus.
.PARAMETER CasePath
    The corpus folder. Defaults to ./cases beside this script.
.PARAMETER OutputPath
    Where to write the run result and summary. Defaults to output/parity-eval.
.PARAMETER Baseline
    A previous run result to compare against. A regression exits non-zero.
.PARAMETER CompareOnly
    Compare -Baseline against -Current and exit; run nothing.
.PARAMETER Current
    The run result to compare against -Baseline in -CompareOnly mode.
.PARAMETER EngineModulePath
    Optional explicit ShellPilot path passed through to the Host Server.
.EXAMPLE
    pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git

    Runs the whole corpus and writes output/parity-eval/run-<id>.{json,md}.
.EXAMPLE
    pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -CompareOnly -Baseline a.json -Current b.json

    Diffs two runs and exits non-zero if anything regressed.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'A standalone live runner; host output is the intended interface.')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [string]$RepositoryRoot,

    [Parameter(ParameterSetName = 'Run')]
    [string[]]$CaseId,

    [Parameter(ParameterSetName = 'Run')]
    [string]$CasePath,

    [Parameter(ParameterSetName = 'Run')]
    [string]$OutputPath,

    [Parameter(ParameterSetName = 'Run')]
    [string]$Baseline,

    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [switch]$CompareOnly,

    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string]$BaselinePath,

    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string]$CurrentPath,

    [Parameter(ParameterSetName = 'Run')]
    [string]$EngineModulePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'DpEvalGrader.ps1')

$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

if ($CompareOnly) {
    $baselineRun = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    $currentRun = Get-Content -LiteralPath $CurrentPath -Raw | ConvertFrom-Json
    $diff = Compare-DpEvalRun -Baseline $baselineRun -Current $currentRun
    Write-Host ''
    Write-Host "Baseline : $($baselineRun.runId) ($($baselineRun.deskPilotSha))"
    Write-Host "Current  : $($currentRun.runId) ($($currentRun.deskPilotSha))"
    Write-Host "Fixed    : $(@($diff.fixes).Count)  $((@($diff.fixes).id) -join ', ')"
    Write-Host "Unchanged: $(@($diff.unchanged).Count)"
    if (@($diff.added).Count) { Write-Host "Added    : $((@($diff.added)) -join ', ')" }
    if (@($diff.removed).Count) { Write-Host "Removed  : $((@($diff.removed)) -join ', ')" -ForegroundColor Yellow }
    if (@($diff.regressions).Count) {
        Write-Host ''
        Write-Host "REGRESSIONS: $(@($diff.regressions).Count)" -ForegroundColor Red
        foreach ($regression in @($diff.regressions)) {
            Write-Host "  $($regression.id) -> failed: $((@($regression.failed)) -join ', ')" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host ''
    Write-Host 'No regressions.' -ForegroundColor Green
    exit 0
}

if (-not $CasePath) { $CasePath = Join-Path $PSScriptRoot 'cases' }
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'output' 'parity-eval' }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$deskPilotSha = 'unknown'
try { $deskPilotSha = (git -C $repoRoot rev-parse --short HEAD 2>$null).Trim() } catch { $deskPilotSha = 'unknown' }

$caseFolders = @(Get-ChildItem -LiteralPath $CasePath -Directory | Sort-Object Name)
if ($CaseId) { $caseFolders = @($caseFolders | Where-Object { $CaseId -contains $_.Name }) }
if ($caseFolders.Count -eq 0) { throw "No cases found in '$CasePath'." }

$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$startedUtc = [DateTime]::UtcNow.ToString('o')
$results = [System.Collections.Generic.List[hashtable]]::new()

function Get-DpFreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $port
}

function Invoke-DpEvalCase {
    param(
        [System.IO.DirectoryInfo]$Folder,
        [string]$FixtureRoot,
        [string]$EnginePath
    )

    $case = Get-Content -LiteralPath (Join-Path $Folder.FullName 'case.json') -Raw | ConvertFrom-Json
    $expect = Get-Content -LiteralPath (Join-Path $Folder.FullName 'expect.json') -Raw | ConvertFrom-Json
    $prompt = Get-Content -LiteralPath (Join-Path $Folder.FullName 'prompt.md') -Raw

    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-' + [guid]::NewGuid().ToString('N'))
    $fixture = Join-Path $sandbox 'fixture'
    $dataDir = Join-Path $sandbox 'data'
    New-Item -ItemType Directory -Path $sandbox, $dataDir -Force | Out-Null

    $source = Join-Path $FixtureRoot ([string]$case.repository)
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Fixture repository '$($case.repository)' not found under '$FixtureRoot'." }

    # Cloned, never checked out in place: restoring the developer's own working
    # tree to a pinned SHA would make the numbers reproducible by destroying
    # whatever they were working on.
    git clone --quiet --no-hardlinks --local "$source" "$fixture" 2>&1 | Out-Null
    git -C $fixture checkout --quiet --force ([string]$case.commit) 2>&1 | Out-Null
    git -C $fixture clean -qfdx 2>&1 | Out-Null
    $pinned = (git -C $fixture rev-parse HEAD).Trim()
    $expectedSha = (git -C $fixture rev-parse ([string]$case.commit)).Trim()
    if ($pinned -ne $expectedSha) { throw "Fixture for '$($case.id)' is at $pinned, not the pinned $expectedSha." }

    $port = Get-DpFreePort
    $serverLog = Join-Path $sandbox 'server.log'
    $engineArgument = if ($EnginePath) { " -EngineModulePath '$EnginePath'" } else { '' }
    $serverScript = @"
Set-Location -LiteralPath '$repoRoot'
Import-Module '$repoRoot\output\module\DeskPilot' -Force
Start-DeskPilot -NoBrowser -Port $port -DataDir '$dataDir'$engineArgument
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($serverScript))
    $server = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -RedirectStandardOutput $serverLog -WindowStyle Hidden

    $token = $null
    try {
        for ($i = 0; $i -lt 240; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not (Test-Path -LiteralPath $serverLog)) { continue }
            $log = Get-Content -LiteralPath $serverLog -Raw
            if ($log -match "http://127\.0\.0\.1:$port/\?t=([0-9a-f]{32})") { $token = $Matches[1]; break }
        }
        if (-not $token) { throw "Host Server for '$($case.id)' never reported a URL." }

        $base = "http://127.0.0.1:$port"
        $headers = @{ 'X-DeskPilot-Token' = $token }

        $settings = @{
            workspaceFolder   = $fixture
            turnTranscript    = $true
            showThinking      = $false
            maxToolIterations = [int]$case.maxToolIterations
            permissions       = @{
                browsing  = [bool]$case.permissions.browsing
                file      = [bool]$case.permissions.file
                terminal  = [bool]$case.permissions.terminal
                askUser   = $false
                userTools = $true
            }
        }
        if ($case.model) { $settings.model = [string]$case.model }
        if ($case.PSObject.Properties['agent'] -and $case.agent) { $settings.selectedAgent = [string]$case.agent }
        Invoke-RestMethod -Uri "$base/api/settings" -Method Put -Headers $headers -Body ($settings | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null

        $conversation = Invoke-RestMethod -Uri "$base/api/conversations" -Method Post -Headers $headers -Body '{}' -ContentType 'application/json'
        $timeout = if ($case.PSObject.Properties['timeoutSeconds'] -and $case.timeoutSeconds) { [int]$case.timeoutSeconds } else { 900 }

        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $stream = Invoke-WebRequest -Uri "$base/api/conversations/$($conversation.id)/messages" -Method Post -Headers $headers -Body (@{ prompt = $prompt } | ConvertTo-Json -Depth 3) -ContentType 'application/json' -TimeoutSec $timeout
        $clock.Stop()
        $messageId = if ($stream.Content -match '"messageId"\s*:\s*"([^"]+)"') { $Matches[1] } else { '' }

        $records = @()
        try {
            $transcript = Invoke-RestMethod -Uri "$base/api/transcript?conversationId=$($conversation.id)&messageId=$messageId" -Method Get -Headers $headers
            $records = @($transcript.records)
        }
        catch { $records = @() }

        $answer = ''
        try {
            $after = Invoke-RestMethod -Uri "$base/api/conversations/$($conversation.id)" -Method Get -Headers $headers
            $answer = [string](@($after.messages) | Where-Object { $_.id -eq $messageId } | Select-Object -First 1).text
        }
        catch { $answer = '' }

        $changed = @((git -C $fixture status --porcelain --untracked-files=all) | ForEach-Object { ($_ -replace '^..\s+', '').Trim() } | Where-Object { $_ })
        $newCommits = [int]((git -C $fixture rev-list --count "$expectedSha..HEAD") | Select-Object -First 1)

        $usage = @($records | Where-Object { $_.kind -eq 'meta' -and $_.event -eq 'usage' } | Select-Object -First 1)
        $metrics = @{
            toolCalls        = @($records | Where-Object { $_.kind -eq 'tool_call' }).Count
            iterations       = [int](@($records | Measure-Object -Property iteration -Maximum).Maximum)
            promptTokens     = [int]($usage.promptTokens | Select-Object -First 1)
            completionTokens = [int]($usage.completionTokens | Select-Object -First 1)
            costUSD          = [double]($usage.costUSD | Select-Object -First 1)
            credits          = [double]($usage.credits | Select-Object -First 1)
            wallSeconds      = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
            transcriptRecords = @($records).Count
        }

        $run = ConvertTo-DpEvalRun -Record $records -Answer $answer -ChangedFile $changed -NewCommit $newCommits -Metric $metrics
        $graded = Test-DpEvalCase -Expect $expect -Run $run

        return @{
            id      = [string]$case.id
            set     = [string]$case.set
            repository = [string]$case.repository
            commit  = [string]$case.commit
            model   = [string]$case.model
            agent   = [string]$case.agent
            passed  = $graded.passed
            failed  = @($graded.failed)
            graders = @($graded.graders)
            metrics = $metrics
            changedFiles = @($run.changedFiles)
            newCommits = $newCommits
        }
    }
    finally {
        try { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        Start-Sleep -Milliseconds 300
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
}

Write-Host ''
Write-Host "DeskPilot parity eval - run $runId (DeskPilot $deskPilotSha)" -ForegroundColor Cyan
Write-Host "Cases: $(@($caseFolders).Count)" -ForegroundColor DarkGray
Write-Host 'This sends real prompts and spends real credits.' -ForegroundColor Yellow
Write-Host ''

foreach ($folder in $caseFolders) {
    Write-Host "-> $($folder.Name)" -ForegroundColor White
    try {
        $result = Invoke-DpEvalCase -Folder $folder -FixtureRoot $RepositoryRoot -EnginePath $EngineModulePath
        $status = if ($result.passed) { 'pass' } else { "FAIL ($((@($result.failed)) -join ', '))" }
        $colour = if ($result.passed) { 'Green' } else { 'Red' }
        Write-Host "   $status  [$($result.metrics.toolCalls) tools, $($result.metrics.wallSeconds)s, `$$($result.metrics.costUSD)]" -ForegroundColor $colour
        $results.Add($result)
    }
    catch {
        $caseError = $_
        Write-Host "   ERROR $caseError" -ForegroundColor Red
        $results.Add(@{
                id      = $folder.Name
                passed  = $false
                failed  = @('harness-error')
                graders = @()
                metrics = @{ toolCalls = 0; iterations = 0; promptTokens = 0; completionTokens = 0; costUSD = 0.0; credits = 0.0; wallSeconds = 0; transcriptRecords = 0 }
                error   = "$caseError"
            })
    }
}

$result = [ordered]@{
    runId        = $runId
    startedUtc   = $startedUtc
    finishedUtc  = [DateTime]::UtcNow.ToString('o')
    deskPilotSha = $deskPilotSha
    caveats      = @(
        'The Engine Runspace inherits the launcher process environment (parity prompt 07 is diagnosed and unfixed), so PSModulePath differences between machines can change a case outcome.'
    )
    cases        = @($results)
}

$jsonPath = Join-Path $OutputPath "run-$runId.json"
$mdPath = Join-Path $OutputPath "run-$runId.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
Format-DpEvalSummary -Result ($result | ConvertTo-Json -Depth 8 | ConvertFrom-Json) | Set-Content -LiteralPath $mdPath -Encoding utf8NoBOM

$passedCount = @($results | Where-Object { $_.passed }).Count
Write-Host ''
Write-Host "Pass rate: $passedCount / $(@($results).Count)" -ForegroundColor Cyan
Write-Host "Result:  $jsonPath" -ForegroundColor DarkGray
Write-Host "Summary: $mdPath" -ForegroundColor DarkGray

if ($Baseline) {
    $baselineRun = Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json
    $diff = Compare-DpEvalRun -Baseline $baselineRun -Current ($result | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    Write-Host ''
    Write-Host "vs baseline $($baselineRun.runId) ($($baselineRun.deskPilotSha)): fixed $(@($diff.fixes).Count), regressed $(@($diff.regressions).Count)"
    foreach ($regression in @($diff.regressions)) {
        Write-Host "  REGRESSION $($regression.id) -> $((@($regression.failed)) -join ', ')" -ForegroundColor Red
    }
    if (-not $diff.ok) { exit 1 }
}

exit 0
