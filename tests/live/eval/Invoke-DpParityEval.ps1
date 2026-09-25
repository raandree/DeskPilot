#requires -Version 7.0
<#
.SYNOPSIS
    Runs the DeskPilot parity eval corpus, k independent trials per case.
.DESCRIPTION
    Every prompt in the parity series claims to close a gap; this is the thing
    that decides whether any of them did. It executes a corpus of cases drawn
    from tasks somebody actually ran, grades the prompt-08 transcript, the
    resulting repository state and the artifacts the work produced with
    deterministic graders, and records efficiency beside correctness without
    ever grading it - a cheaper run that is wrong is not better.

    An agent is not deterministic, so one trial is an anecdote. Each case is run
    -Repeat times, each trial in its own throwaway sandbox with its own data
    directory and therefore its own Conversation, and the result is reported
    three ways: the first trial, at least one of k (pass@k) and all of k
    (pass^k). Nothing is rounded into a single headline number.

    THE LIVE MODE SENDS REAL PROMPTS AND SPENDS REAL CREDITS. It is deliberately
    outside the Pester suite: build.yaml runs only tests/QA and tests/Unit, so
    nothing here is reached by ./build.ps1 -Tasks test, and a live run is
    refused outright when a CI environment variable is set. -Offline replays a
    committed scripted file through the same code with no Host Server, no
    network and no Model call; that is the mode a test may use, and the numbers
    it produces are about the harness, never about a Model.

    Fixture discipline, without which the numbers are noise:

    - The target repository is **cloned** to a throwaway folder and checked out
      at its pinned SHA before every trial. The source repository is never
      touched, never checked out and never cleaned - a harness that mutates a
      developer's working tree to make its numbers reproducible has traded one
      kind of wrong for a worse one.
    - Model, agent, permissions and iteration cap are fixed per case, and the
      fingerprint of all of it is recorded as the case identity, so trials of
      two different configurations can never be averaged together.
    - Each trial gets a fresh Host Server process and a fresh data directory,
      and therefore a fresh Engine Runspace and a fresh Conversation. No real
      Project and no real Conversation is ever opened. Prompt 07 established
      that the runspace inherits the launcher's environment, so that inheritance
      is recorded as a caveat on every result.
    - That child process is started from a committed launcher script with a
      structured argument list and a JSON configuration it reads as data. The
      harness generates no script, so a sandbox path, a repository root or an
      Engine path containing a space, an apostrophe or a character that looks
      like PowerShell stays a path.
    - The DeskPilot commit under test is recorded with every run.

    Output files carry no token, no absolute user path and no prompt text.
.PARAMETER RepositoryRoot
    The folder holding the fixture repositories named by the cases. Required for
    a live run, and never defaulted, so no machine-specific path is committed.
.PARAMETER CaseId
    Run only these case ids. Default: every case in the corpus.
.PARAMETER CasePath
    The corpus folder. Defaults to ./cases beside this script.
.PARAMETER OutputPath
    Where to write the run result and summary. Defaults to output/parity-eval.
.PARAMETER Repeat
    Independent trials per case, 1 to 25. Defaults to 1, because repetition is
    what spends the credits and must be asked for.
.PARAMETER Baseline
    A previous run result to compare against. A regression exits non-zero.
.PARAMETER CompareOnly
    Compare -BaselinePath against -CurrentPath and exit; run nothing.
.PARAMETER BaselinePath
    The baseline run result in -CompareOnly mode.
.PARAMETER CurrentPath
    The current run result in -CompareOnly mode.
.PARAMETER EngineModulePath
    Optional explicit ShellPilot path passed through to the Host Server.
.PARAMETER Offline
    Replay a scripted run instead of calling anything. No Host Server, no
    network, no Model, no credits.
.PARAMETER ScriptedRunPath
    The scripted trials to replay in -Offline mode.
.EXAMPLE
    pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git -Repeat 3

    Runs the whole corpus three times per case and writes
    output/parity-eval/run-<id>.{json,md}. Spends real credits.
.EXAMPLE
    pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -Offline -ScriptedRunPath ./tests/Unit/fixtures/eval/scripted-run.json -Repeat 2

    Exercises the whole repetition, grading, aggregation and gating path against
    committed scripted trials. Spends nothing and proves nothing about a Model.
.EXAMPLE
    pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -CompareOnly -BaselinePath a.json -CurrentPath b.json

    Diffs two runs and exits non-zero if anything regressed.
.LINK
    https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'A standalone live runner; host output is the intended interface.')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'RepositoryRoot and EngineModulePath are consumed inside the live executor scriptblock, which the analyzer does not follow.')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [string]$RepositoryRoot,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Offline')]
    [string[]]$CaseId,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Offline')]
    [string]$CasePath,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Offline')]
    [string]$OutputPath,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Offline')]
    [object]$Repeat = 1,

    [Parameter(ParameterSetName = 'Run')]
    [string]$Baseline,

    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [switch]$CompareOnly,

    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string]$BaselinePath,

    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string]$CurrentPath,

    [Parameter(ParameterSetName = 'Run')]
    [string]$EngineModulePath,

    [Parameter(Mandatory, ParameterSetName = 'Offline')]
    [switch]$Offline,

    [Parameter(Mandatory, ParameterSetName = 'Offline')]
    [string]$ScriptedRunPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'DpEvalTrial.ps1')

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

# Validate before anything is created, cloned or spent.
$repeatCheck = Test-DpEvalRepeat -Repeat $Repeat
if (-not $repeatCheck.valid) { throw $repeatCheck.error }
$repeatCount = $repeatCheck.repeat

if (-not $Offline) {
    $liveDecision = Test-DpEvalLiveRunAllowed
    if (-not $liveDecision.allowed) { throw $liveDecision.reason }
}

if (-not $CasePath) { $CasePath = Join-Path $PSScriptRoot 'cases' }
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'output' 'parity-eval' }

$scripted = $null
if ($Offline) {
    $scripted = Get-Content -LiteralPath $ScriptedRunPath -Raw | ConvertFrom-Json
    if (-not $scripted.cases) { throw "'$ScriptedRunPath' declares no cases." }
}

$caseFolders = @(Get-ChildItem -LiteralPath $CasePath -Directory | Sort-Object Name)
if ($Offline) {
    $scriptedIds = @($scripted.cases.PSObject.Properties.Name)
    $missingFolders = @($scriptedIds | Where-Object { $_ -notin @($caseFolders.Name) })
    if ($missingFolders.Count) { throw "The scripted run names cases that are not in the corpus: $($missingFolders -join ', ')." }
    $caseFolders = @($caseFolders | Where-Object { $scriptedIds -contains $_.Name })
}
if ($CaseId) { $caseFolders = @($caseFolders | Where-Object { $CaseId -contains $_.Name }) }
if ($caseFolders.Count -eq 0) { throw "No cases found in '$CasePath'." }

$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$startedUtc = [DateTime]::UtcNow.ToString('o')
$mode = if ($Offline) { 'offline-scripted' } else { 'live' }

$deskPilotSha = 'unknown'
try { $deskPilotSha = (git -C $repoRoot rev-parse --short HEAD 2>$null).Trim() } catch { $deskPilotSha = 'unknown' }

# Read and validate every manifest up front. A malformed manifest stops the run
# rather than quietly shrinking the corpus a pass rate is quoted over.
$corpus = [System.Collections.Generic.List[hashtable]]::new()
$manifestErrors = [System.Collections.Generic.List[string]]::new()
foreach ($folder in $caseFolders) {
    $case = Get-Content -LiteralPath (Join-Path $folder.FullName 'case.json') -Raw | ConvertFrom-Json
    $expect = Get-Content -LiteralPath (Join-Path $folder.FullName 'expect.json') -Raw | ConvertFrom-Json
    $prompt = Get-Content -LiteralPath (Join-Path $folder.FullName 'prompt.md') -Raw
    $manifest = Test-DpEvalManifest -Case $case -Expect $expect -Prompt $prompt -FolderName $folder.Name
    if (-not $manifest.valid) {
        foreach ($problem in @($manifest.errors)) { $manifestErrors.Add("$($folder.Name): $problem") }
        continue
    }
    $corpus.Add(@{ folder = $folder; case = $case; expect = $expect; prompt = $prompt })
}
if ($manifestErrors.Count) {
    throw "The corpus is malformed and nothing was executed:`n  $($manifestErrors -join "`n  ")"
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$runOwnerId = [guid]::NewGuid().ToString('N')
$sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-run-' + $runId + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
# Freshly allocated and receipted. Cleanup deletes recursively, so it must be
# able to prove this folder is this run's and not something already there.
New-DpEvalOwnedDirectory -Path $sandboxRoot -OwnerId $runOwnerId | Out-Null

function Get-DpFreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $port
}

# The execution seam. A live trial drives a Host Server; a scripted trial reads
# a committed file. Everything above this line is identical either way, which is
# what makes the harness testable without spending anything.

# Latched once a trial could not clean up after itself. A child that would not
# stop still holds its sandbox, so from that point nothing further is started
# and nothing is deleted - including the run root, which is kept for recovery.
$liveCleanup = @{ blocked = ''; sandbox = '' }

$liveExecutor = {
    param($Context)

    $allowed = Test-DpEvalLiveTrialAllowed -State $liveCleanup
    if (-not $allowed.allowed) { throw $allowed.reason }

    $case = $Context.case
    $source = Join-Path $RepositoryRoot ([string]$case.repository)
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Fixture repository '$($case.repository)' not found under '$RepositoryRoot'." }

    # Cloned, never checked out in place: restoring the developer's own working
    # tree to a pinned SHA would make the numbers reproducible by destroying
    # whatever they were working on.
    $fixture = $Context.fixture
    git clone --quiet --no-hardlinks --local "$source" "$fixture" 2>&1 | Out-Null
    git -C $fixture checkout --quiet --force ([string]$case.commit) 2>&1 | Out-Null
    git -C $fixture clean -qfdx 2>&1 | Out-Null
    $pinned = (git -C $fixture rev-parse HEAD).Trim()
    $expectedSha = (git -C $fixture rev-parse ([string]$case.commit)).Trim()
    if ($pinned -ne $expectedSha) { throw "Fixture for '$($case.id)' is at $pinned, not the pinned $expectedSha." }

    $port = Get-DpFreePort

    # The child process is described as data and started natively: a fixed
    # launcher script, one argument per value, and a JSON configuration it
    # reads. Nothing here builds PowerShell out of a path, so a sandbox path,
    # a repository root or an Engine path stays a path.
    $launch = @{
        RepositoryRoot = $repoRoot
        Port           = $port
        DataDirectory  = $Context.dataDir
        ConfigPath     = $Context.launchConfig
    }
    if ($EngineModulePath) { $launch['EngineModulePath'] = $EngineModulePath }
    $plan = New-DpEvalHostLaunchPlan @launch
    $server = Start-DpEvalHostProcess -Plan $plan -LogPath $Context.serverLog -ErrorLogPath $Context.serverErrorLog

    try {
        $ready = Wait-DpEvalHostUrl -Server $server -Port $port -TimeoutSeconds 120
        if (-not $ready.ok) { throw "Host Server for '$($case.id)' trial $($Context.trial) $($ready.reason)" }
        $token = $ready.token

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

        # A fresh Conversation in a fresh data directory: trial two can inherit
        # nothing from trial one, and no Conversation of the user's is touched.
        $conversation = Invoke-RestMethod -Uri "$base/api/conversations" -Method Post -Headers $headers -Body '{}' -ContentType 'application/json'
        $timeout = if ($case.PSObject.Properties['timeoutSeconds'] -and $case.timeoutSeconds) { [int]$case.timeoutSeconds } else { 900 }

        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $stream = Invoke-WebRequest -Uri "$base/api/conversations/$($conversation.id)/messages" -Method Post -Headers $headers -Body (@{ prompt = $Context.prompt } | ConvertTo-Json -Depth 3) -ContentType 'application/json' -TimeoutSec $timeout
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

        # Only the paths the case's graders declared, read through the one
        # confined path: no link anywhere in the chain, and a byte bound. A
        # refused artifact is reported, never truncated into a pass.
        $artifacts = Get-DpEvalArtifactSet -Root $fixture -Path @($Context.requiredFiles) -Sandbox $Context.sandbox

        $usage = @($records | Where-Object { $_.kind -eq 'meta' -and $_.event -eq 'usage' } | Select-Object -First 1)[0]

        @{
            answer           = $answer
            records          = $records
            changedFiles     = $changed
            newCommits       = $newCommits
            fileContents     = $artifacts.contents
            artifactProblems = @($artifacts.problems)
            usage            = $usage
            durationSeconds  = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        }
    }
    finally {
        # The stop is decided before anything is deleted. A child that is still
        # running owns the data directory below, so a stop, a capture or a log
        # that did not close keeps every byte of this trial on disk, latches the
        # run and makes this trial incomplete.
        Complete-DpEvalTrialCleanup -Server $server -Context $Context -State $liveCleanup -TimeoutSeconds 30
    }
}

$offlineExecutor = {
    param($Context)

    $entry = $scripted.cases.($Context.caseId)
    if (-not $entry) { throw "The scripted run has no entry for '$($Context.caseId)'." }
    $trials = @($entry.trials)
    if ($Context.trial -gt $trials.Count) {
        # A sample that was never scripted is a missing sample, and the
        # aggregate must see it as incomplete rather than invent one.
        throw "The scripted run provides $($trials.Count) trial(s) for '$($Context.caseId)'; trial $($Context.trial) was requested."
    }
    $trial = $trials[$Context.trial - 1]

    try {
        @{
            answer          = [string]$trial.answer
            toolCalls       = @($trial.toolCalls)
            changedFiles    = @($trial.changedFiles)
            newCommits      = [int]$trial.newCommits
            fileContents    = $trial.fileContents
            usage           = $trial.usage
            durationSeconds = [double]$trial.durationSeconds
        }
    }
    finally {
        Remove-DpEvalSandbox -Path $Context.sandbox -OwnerId $Context.ownerId
    }
}

$executor = if ($Offline) { $offlineExecutor } else { $liveExecutor }

Write-Host ''
Write-Host "DeskPilot parity eval - run $runId (DeskPilot $deskPilotSha, mode $mode)" -ForegroundColor Cyan
Write-Host "Cases: $(@($corpus).Count), trials per case (k): $repeatCount" -ForegroundColor DarkGray
if ($Offline) {
    Write-Host 'Offline: scripted trials replayed through the same graders. No Model call, no credits, and no claim about model performance.' -ForegroundColor DarkGray
}
else {
    Write-Host 'This sends real prompts and spends real credits.' -ForegroundColor Yellow
}
Write-Host ''

$outcomes = [System.Collections.Generic.List[hashtable]]::new()
$cleanupFailure = ''
try {
    foreach ($entry in $corpus) {
        $case = $entry.case
        Write-Host "-> $($entry.folder.Name)" -ForegroundColor White
        $identity = Get-DpEvalCaseIdentity -Case $case -Prompt $entry.prompt

        $trials = Invoke-DpEvalTrialSet -Case $case -Expect $entry.expect -Prompt $entry.prompt `
            -Repeat $repeatCount -Executor $executor -Root $sandboxRoot -OwnerId $runOwnerId -FolderName $entry.folder.Name

        $outcome = Measure-DpEvalCaseOutcome -CaseId ([string]$case.id) -Set ([string]$case.set) `
            -Identity $identity -Repeat $repeatCount -Trial $trials

        # Kept for Compare-DpEvalRun and for a baseline written before repeated
        # trials existed: the same verdict the gate reaches for this case.
        $outcome.passed = [bool]$outcome.gatePassed
        $outcome.repository = [string]$case.repository
        $outcome.commit = [string]$case.commit
        $outcome.model = [string]$case.model
        $outcome.agent = [string]$case.agent
        $outcomes.Add($outcome)

        $colour = if ($outcome.passed) { 'Green' } elseif ($outcome.status -ne 'complete') { 'Yellow' } else { 'Red' }
        $status = "$($outcome.status): $($outcome.passedTrialCount)/$($outcome.completedSamples) of $($outcome.samples) trials passed"
        if (@($outcome.failed).Count) { $status += " [failed: $((@($outcome.failed)) -join ', ')]" }
        if ([bool]$outcome.safetyViolated) { $status += " [SAFETY: $((@($outcome.safetyFailed)) -join ', ')]" }
        Write-Host "   $status" -ForegroundColor $colour
        foreach ($problem in @($outcome.errors)) { Write-Host "   trial error: $problem" -ForegroundColor DarkYellow }
        foreach ($problem in @($outcome.artifactProblems)) { Write-Host "   artifact refused: $problem" -ForegroundColor DarkYellow }
    }
}
finally {
    # Recorded, never swallowed, and never deleted underneath a child that may
    # still be running: a blocked trial cleanup keeps the owned run root for
    # explicit recovery, and the gate below says so.
    $runCleanup = Complete-DpEvalRunCleanup -Path $sandboxRoot -OwnerId $runOwnerId -State $liveCleanup
    if (-not $runCleanup.ok) { $cleanupFailure = $runCleanup.reason }
    if ($runCleanup.retained -and (Test-Path -LiteralPath $sandboxRoot)) {
        Write-Host ''
        Write-Host "Run state kept for recovery: $sandboxRoot" -ForegroundColor Yellow
    }
}

$aggregate = Measure-DpEvalRunOutcome -Case @($outcomes)
$gate = Test-DpEvalGate -Case @($outcomes)

if ($cleanupFailure) {
    $gate.reasons = @(@($gate.reasons) + "run state could not be cleaned up: $cleanupFailure")
    $gate.ok = $false
    $gate.exitCode = 1
}

$result = [ordered]@{
    runId        = $runId
    startedUtc   = $startedUtc
    finishedUtc  = [DateTime]::UtcNow.ToString('o')
    deskPilotSha = $deskPilotSha
    mode         = $mode
    repeat       = $repeatCount
    # The leaf name only. A temp path on Windows carries the operator's
    # username, and a run file may be committed as a baseline.
    sandboxRootName = Split-Path $sandboxRoot -Leaf
    caveats      = @(@(
            'The Engine Runspace inherits the launcher process environment (parity prompt 07 is diagnosed and unfixed), so PSModulePath differences between machines can change a case outcome.'
            'pass@k is best-of-k and pass^k is all-of-k; neither is a benchmark score, and an incomplete case is reported, never averaged away.'
            if ($Offline) { 'This run replayed committed scripted trials. It exercises the harness and says nothing about how any Model performs.' }
        ) | Where-Object { $_ })
    aggregate    = $aggregate
    gate         = $gate
    cases        = @($outcomes)
}

$jsonPath = Join-Path $OutputPath "run-$runId.json"
$mdPath = Join-Path $OutputPath "run-$runId.md"
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
Format-DpEvalTrialSummary -Result ($result | ConvertTo-Json -Depth 12 | ConvertFrom-Json) | Set-Content -LiteralPath $mdPath -Encoding utf8NoBOM

Write-Host ''
Write-Host "First trial : $($aggregate.firstTrialPassed) / $($aggregate.firstTrialMeasured) measured ($($aggregate.firstTrialUnknown) unknown)" -ForegroundColor Cyan
Write-Host "pass@k      : $($aggregate.passedAnyTrial) / $($aggregate.caseCount)" -ForegroundColor Cyan
Write-Host "pass^k      : $($aggregate.passedAllTrials) / $($aggregate.caseCount)" -ForegroundColor Cyan
if (@($aggregate.incompleteCases).Count -or @($aggregate.unavailableCases).Count) {
    Write-Host "Incomplete  : $((@($aggregate.incompleteCases)) -join ', ')  Unavailable: $((@($aggregate.unavailableCases)) -join ', ')" -ForegroundColor Yellow
    Write-Host 'This run is incomplete; the rates above are not a corpus pass rate.' -ForegroundColor Yellow
}
if (-not [bool]$aggregate.usage.reported) {
    Write-Host 'Usage       : unknown - no trial reported a priced Usage. Unknown is not zero.' -ForegroundColor DarkGray
}
else {
    Write-Host "Usage       : $($aggregate.usage.promptTokens) prompt + $($aggregate.usage.completionTokens) completion tokens over $($aggregate.usage.reportedTrials)/$($aggregate.usage.totalTrials) trials" -ForegroundColor DarkGray
}
Write-Host "Result:  $jsonPath" -ForegroundColor DarkGray
Write-Host "Summary: $mdPath" -ForegroundColor DarkGray

if ($Baseline) {
    $baselineRun = Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json
    $diff = Compare-DpEvalRun -Baseline $baselineRun -Current ($result | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    Write-Host ''
    Write-Host "vs baseline $($baselineRun.runId) ($($baselineRun.deskPilotSha)): fixed $(@($diff.fixes).Count), regressed $(@($diff.regressions).Count)"
    foreach ($regression in @($diff.regressions)) {
        Write-Host "  REGRESSION $($regression.id) -> $((@($regression.failed)) -join ', ')" -ForegroundColor Red
    }
    if (-not $diff.ok) { exit 1 }
}

Write-Host ''
if ($gate.ok) {
    Write-Host 'Gate: pass.' -ForegroundColor Green
}
else {
    Write-Host 'Gate: FAIL' -ForegroundColor Red
    foreach ($reason in @($gate.reasons)) { Write-Host "  $reason" -ForegroundColor Red }
}

exit $gate.exitCode
