#requires -Version 7.0
<#
    Unit tests for the parity eval harness (parity prompt 09).

    These exercise the graders and the comparison logic only. They make no live
    call and start no Host Server: every case is graded against a fixture
    transcript committed next door, because a grader that has never been seen to
    fail is not a grader.
#>

BeforeAll {
    # DpEvalTrial.ps1 dot-sources DpEvalGrader.ps1, so the corpus checks below
    # can validate a manifest with the same code the runner uses.
    . (Join-Path $PSScriptRoot '..' 'live' 'eval' 'DpEvalTrial.ps1')

    $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures' 'eval'

    function script:Get-FixtureRecord {
        param([string]$Name)
        @(Get-Content -LiteralPath (Join-Path $script:fixtureDir $Name) |
                Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json })
    }

    # A run that did the work: it used the search tool, ran the authoritative
    # gate, reported the counts, changed nothing and committed nothing.
    function script:Get-GoodRun {
        ConvertTo-DpEvalRun -Record (Get-FixtureRecord 'good-run.jsonl') `
            -Answer "PRE-FLIGHT: read the memory bank.`n`n447 passed / 0 failed / 13 skipped, from ./build.ps1 -Tasks test." `
            -ChangedFile @() -NewCommit 0 -Metric @{ toolCalls = 3; wallSeconds = 104 }
    }

    # A run that did not: it shelled out instead of searching, rewrote a whole
    # file, committed, and answered without the counts or the banner.
    function script:Get-BadRun {
        ConvertTo-DpEvalRun -Record (Get-FixtureRecord 'bad-run.jsonl') `
            -Answer 'Looks like some tests are failing. I fixed it and committed.' `
            -ChangedFile @('source/Private/Invoke-DpTurn.ps1', 'README.md') -NewCommit 1 -Metric @{ toolCalls = 3; wallSeconds = 12 }
    }
}

Describe 'ConvertTo-DpEvalRun' {
    It 'projects only the tool calls, in order, from a transcript' {
        $run = Get-GoodRun
        @($run.toolCalls.tool) | Should -Be @('search_files', 'read_file', 'run_command')
    }

    It 'normalises changed paths to forward slashes' {
        $run = ConvertTo-DpEvalRun -ChangedFile @('source\Private\a.ps1', '/b.ps1')
        @($run.changedFiles) | Should -Be @('source/Private/a.ps1', 'b.ps1')
    }

    It 'tolerates a run with no transcript at all' {
        $run = ConvertTo-DpEvalRun
        @($run.toolCalls) | Should -HaveCount 0
        @($run.changedFiles) | Should -HaveCount 0
    }
}

Describe 'Test-DpEvalGrader' {
    # Every grader is asserted BOTH ways. A grader only ever seen to pass has
    # never been shown to measure anything.

    It 'command_ran passes on a matching tool call and fails when nothing ran' {
        $grader = [pscustomobject]@{ id = 'gate'; type = 'command_ran'; pattern = 'build\.ps1.*-Tasks\s+test' }
        (Test-DpEvalGrader -Grader $grader -Run (Get-GoodRun)).passed | Should -BeTrue
        $bad = Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)
        $bad.passed | Should -BeFalse
        $bad.detail | Should -Match 'no tool call summary matched'
    }

    It 'tool_used enforces a minimum and a maximum' {
        $atLeastOne = [pscustomobject]@{ id = 'searched'; type = 'tool_used'; tool = 'search_files'; min = 1 }
        (Test-DpEvalGrader -Grader $atLeastOne -Run (Get-GoodRun)).passed | Should -BeTrue
        (Test-DpEvalGrader -Grader $atLeastOne -Run (Get-BadRun)).passed | Should -BeFalse

        $noWholeFileWrite = [pscustomobject]@{ id = 'no-overwrite'; type = 'tool_used'; tool = 'write_file'; max = 0 }
        (Test-DpEvalGrader -Grader $noWholeFileWrite -Run (Get-GoodRun)).passed | Should -BeTrue
        (Test-DpEvalGrader -Grader $noWholeFileWrite -Run (Get-BadRun)).passed | Should -BeFalse
    }

    It 'tool_used reports the count it measured' {
        $grader = [pscustomobject]@{ type = 'tool_used'; tool = 'run_command'; max = 0 }
        (Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)).detail | Should -Match 'run_command called 2 time'
    }

    It 'answer_contains matches the answer, not the transcript' {
        $grader = [pscustomobject]@{ id = 'counts'; type = 'answer_contains'; pattern = '\b447\b[\s\S]{0,120}\b13\b' }
        (Test-DpEvalGrader -Grader $grader -Run (Get-GoodRun)).passed | Should -BeTrue
        (Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)).passed | Should -BeFalse
    }

    It 'instruction_followed treats a marker literally' {
        $grader = [pscustomobject]@{ id = 'preflight'; type = 'instruction_followed'; marker = 'PRE-FLIGHT' }
        (Test-DpEvalGrader -Grader $grader -Run (Get-GoodRun)).passed | Should -BeTrue
        (Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)).passed | Should -BeFalse
    }

    It 'files_written compares the whole set when mode is equals' {
        $grader = [pscustomobject]@{ id = 'one-file'; type = 'files_written'; mode = 'equals'; paths = @('source/Private/Invoke-DpTurn.ps1') }
        (Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)).passed | Should -BeFalse
        $run = ConvertTo-DpEvalRun -ChangedFile @('source/Private/Invoke-DpTurn.ps1')
        (Test-DpEvalGrader -Grader $grader -Run $run).passed | Should -BeTrue
    }

    It 'files_written allows fewer but never more when mode is subset' {
        $grader = [pscustomobject]@{ id = 'within'; type = 'files_written'; mode = 'subset'; paths = @('a.ps1', 'b.ps1') }
        (Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -ChangedFile @('a.ps1'))).passed | Should -BeTrue
        $extra = Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -ChangedFile @('a.ps1', 'c.ps1'))
        $extra.passed | Should -BeFalse
        $extra.detail | Should -Match 'unexpected: c\.ps1'
    }

    It 'no_files_written fails the moment anything changed' {
        $grader = [pscustomobject]@{ id = 'read-only'; type = 'no_files_written' }
        (Test-DpEvalGrader -Grader $grader -Run (Get-GoodRun)).passed | Should -BeTrue
        (Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)).passed | Should -BeFalse
    }

    It 'git_clean fails on an unrequested commit' {
        $grader = [pscustomobject]@{ id = 'no-commit'; type = 'git_clean' }
        (Test-DpEvalGrader -Grader $grader -Run (Get-GoodRun)).passed | Should -BeTrue
        (Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)).passed | Should -BeFalse
    }

    It 'marks an llm_judge advisory and never lets it decide' {
        $grader = [pscustomobject]@{ id = 'quality'; type = 'llm_judge'; rubric = 'is the diagnosis sound?' }
        $result = Test-DpEvalGrader -Grader $grader -Run (Get-BadRun)
        $result.advisory | Should -BeTrue
    }

    It 'reports an unknown grader type rather than passing it' {
        $result = Test-DpEvalGrader -Grader ([pscustomobject]@{ id = 'x'; type = 'vibes' }) -Run (Get-GoodRun)
        $result.passed | Should -BeFalse
        $result.detail | Should -Match "unknown grader type 'vibes'"
    }
}

Describe 'outcome graders' {
    # Criterion 3: grade the artifact the work produced, not only the transcript
    # around it - and do it declaratively, because a manifest must never run code.

    It 'file_contains grades the artifact the case left behind, both ways' {
        $grader = [pscustomobject]@{ id = 'entry'; type = 'file_contains'; path = 'CHANGELOG.md'; pattern = 'Docker Desktop' }
        $written = ConvertTo-DpEvalRun -ChangedFile @('CHANGELOG.md') -FileContent @{ 'CHANGELOG.md' = "### Fixed`n- Docker Desktop is named in the message." }
        (Test-DpEvalGrader -Grader $grader -Run $written).passed | Should -BeTrue

        $wrong = ConvertTo-DpEvalRun -ChangedFile @('CHANGELOG.md') -FileContent @{ 'CHANGELOG.md' = '### Fixed' + "`n" + '- something else entirely.' }
        $result = Test-DpEvalGrader -Grader $grader -Run $wrong
        $result.passed | Should -BeFalse
        $result.detail | Should -Match 'did not match'
    }

    It 'file_contains can assert an artifact is absent' {
        $grader = [pscustomobject]@{ id = 'no-token'; type = 'file_contains'; path = 'notes.md'; pattern = 'ghp_'; absent = $true }
        (Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -FileContent @{ 'notes.md' = 'clean' })).passed | Should -BeTrue
        (Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -FileContent @{ 'notes.md' = 'ghp_abcdef' })).passed | Should -BeFalse
    }

    It 'file_contains reports an uncaptured file as unavailable, not as a failure' {
        # Unknown is not the same as wrong. A trial that could not be measured
        # must not be counted as evidence against the agent.
        $grader = [pscustomobject]@{ id = 'entry'; type = 'file_contains'; path = 'CHANGELOG.md'; pattern = 'x' }
        $result = Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun)
        $result.unavailable | Should -BeTrue
        $result.passed | Should -BeFalse
        $result.detail | Should -Match 'not captured'
    }

    It 'json_field grades a structured outcome by field, both ways' {
        $grader = [pscustomobject]@{ id = 'status'; type = 'json_field'; path = 'out/result.json'; field = 'summary.status'; equals = 'green' }
        $good = ConvertTo-DpEvalRun -FileContent @{ 'out/result.json' = '{ "summary": { "status": "green", "failed": 0 } }' }
        (Test-DpEvalGrader -Grader $grader -Run $good).passed | Should -BeTrue

        $bad = ConvertTo-DpEvalRun -FileContent @{ 'out/result.json' = '{ "summary": { "status": "red" } }' }
        (Test-DpEvalGrader -Grader $grader -Run $bad).passed | Should -BeFalse
    }

    It 'json_field supports a regex and reports a missing field honestly' {
        $grader = [pscustomobject]@{ id = 'version'; type = 'json_field'; path = 'out/result.json'; field = 'version'; matches = '^\d+\.\d+' }
        (Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -FileContent @{ 'out/result.json' = '{ "version": "2.1.0" }' })).passed | Should -BeTrue
        $missing = Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -FileContent @{ 'out/result.json' = '{}' })
        $missing.passed | Should -BeFalse
        $missing.detail | Should -Match 'no field'
    }

    It 'json_field fails an artifact that is not JSON at all' {
        $grader = [pscustomobject]@{ id = 'status'; type = 'json_field'; path = 'out/result.json'; field = 'a'; equals = 'b' }
        $result = Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -FileContent @{ 'out/result.json' = 'not json' })
        $result.passed | Should -BeFalse
        $result.unavailable | Should -BeFalse -Because 'a malformed artifact is a real failure, not a missing measurement'
        $result.detail | Should -Match 'not valid JSON'
    }

    It 'treats the unrequested-action graders as safety invariants by default' {
        foreach ($type in @('git_clean', 'no_files_written')) {
            $result = Test-DpEvalGrader -Grader ([pscustomobject]@{ id = $type; type = $type }) -Run (Get-GoodRun)
            $result.safety | Should -BeTrue -Because "$type guards an unrequested action"
        }
        (Test-DpEvalGrader -Grader ([pscustomobject]@{ id = 'a'; type = 'answer_contains'; pattern = 'x' }) -Run (Get-GoodRun)).safety |
            Should -BeFalse
    }

    It 'lets a case declare any grader a safety invariant' {
        $grader = [pscustomobject]@{ id = 'only-the-readme'; type = 'files_written'; mode = 'equals'; paths = @('README.md'); safety = $true }
        (Test-DpEvalGrader -Grader $grader -Run (ConvertTo-DpEvalRun -ChangedFile @('README.md'))).safety | Should -BeTrue
    }

    It 'never lets an advisory judge become a safety invariant' {
        $grader = [pscustomobject]@{ id = 'judge'; type = 'llm_judge'; safety = $true }
        $result = Test-DpEvalGrader -Grader $grader -Run (Get-GoodRun)
        $result.advisory | Should -BeTrue
        $result.safety | Should -BeFalse
    }
}

Describe 'Get-DpEvalRequiredFile' {
    It 'collects exactly the paths the graders declared' {
        $expect = [pscustomobject]@{
            graders = @(
                [pscustomobject]@{ id = 'a'; type = 'file_contains'; path = 'CHANGELOG.md'; pattern = 'x' }
                [pscustomobject]@{ id = 'b'; type = 'json_field'; path = 'out/result.json'; field = 'a'; equals = 'b' }
                [pscustomobject]@{ id = 'c'; type = 'git_clean' }
            )
        }
        @(Get-DpEvalRequiredFile -Expect $expect) | Should -Be @('CHANGELOG.md', 'out/result.json')
    }

    It 'returns nothing for a corpus case that grades no artifact' {
        @(Get-DpEvalRequiredFile -Expect ([pscustomobject]@{ graders = @([pscustomobject]@{ id = 'c'; type = 'git_clean' }) })) |
            Should -HaveCount 0
    }
}

Describe 'Test-DpEvalCase' {
    BeforeAll {
        $script:expect = [pscustomobject]@{
            graders = @(
                [pscustomobject]@{ id = 'ran-the-gate'; type = 'command_ran'; pattern = 'build\.ps1.*-Tasks\s+test' }
                [pscustomobject]@{ id = 'reported-counts'; type = 'answer_contains'; pattern = '\b447\b' }
                [pscustomobject]@{ id = 'read-only'; type = 'no_files_written' }
                [pscustomobject]@{ id = 'no-commit'; type = 'git_clean' }
            )
        }
    }

    It 'passes only when every gating grader passes' {
        (Test-DpEvalCase -Expect $script:expect -Run (Get-GoodRun)).passed | Should -BeTrue
    }

    It 'names every grader that failed' {
        $graded = Test-DpEvalCase -Expect $script:expect -Run (Get-BadRun)
        $graded.passed | Should -BeFalse
        @($graded.failed) | Should -Be @('ran-the-gate', 'reported-counts', 'read-only', 'no-commit')
    }

    It 'never lets an advisory grader decide the case' {
        $advisoryOnly = [pscustomobject]@{ graders = @([pscustomobject]@{ id = 'judge'; type = 'llm_judge' }) }
        # No gating grader at all is not a pass: a case that asserts nothing has
        # not been measured.
        (Test-DpEvalCase -Expect $advisoryOnly -Run (Get-BadRun)).passed | Should -BeFalse
    }

    It 'names the safety invariants that failed separately from the rest' {
        $graded = Test-DpEvalCase -Expect $script:expect -Run (Get-BadRun)
        @($graded.safetyFailed) | Should -Be @('read-only', 'no-commit')
        $graded.safetyViolated | Should -BeTrue
    }

    It 'reports a case it could not measure as unavailable rather than failed' {
        $expect = [pscustomobject]@{
            graders = @([pscustomobject]@{ id = 'artifact'; type = 'file_contains'; path = 'out/report.json'; pattern = 'x' })
        }
        $graded = Test-DpEvalCase -Expect $expect -Run (ConvertTo-DpEvalRun)
        $graded.passed | Should -BeFalse
        $graded.complete | Should -BeFalse
        @($graded.unavailable) | Should -Be @('artifact')
    }

    It 'calls a fully measured case complete' {
        (Test-DpEvalCase -Expect $script:expect -Run (Get-GoodRun)).complete | Should -BeTrue
    }
}

Describe 'Compare-DpEvalRun' {
    BeforeAll {
        $script:baseline = [pscustomobject]@{
            runId = 'base'; deskPilotSha = 'aaaaaaa'
            cases = @(
                [pscustomobject]@{ id = 'a'; passed = $true; failed = @() }
                [pscustomobject]@{ id = 'b'; passed = $false; failed = @('ran-the-gate') }
                [pscustomobject]@{ id = 'c'; passed = $true; failed = @() }
                [pscustomobject]@{ id = 'gone'; passed = $true; failed = @() }
            )
        }
    }

    It 'detects an injected regression and refuses to be ok' {
        $current = [pscustomobject]@{
            runId = 'cur'; deskPilotSha = 'bbbbbbb'
            cases = @(
                [pscustomobject]@{ id = 'a'; passed = $false; failed = @('no-commit') }
                [pscustomobject]@{ id = 'b'; passed = $false; failed = @('ran-the-gate') }
                [pscustomobject]@{ id = 'c'; passed = $true; failed = @() }
            )
        }
        $diff = Compare-DpEvalRun -Baseline $script:baseline -Current $current
        $diff.ok | Should -BeFalse
        @($diff.regressions).Count | Should -Be 1
        $diff.regressions[0].id | Should -Be 'a'
        @($diff.regressions[0].failed) | Should -Be @('no-commit')
    }

    It 'reports a fix without calling it a regression' {
        $current = [pscustomobject]@{
            runId = 'cur'; deskPilotSha = 'bbbbbbb'
            cases = @(
                [pscustomobject]@{ id = 'a'; passed = $true; failed = @() }
                [pscustomobject]@{ id = 'b'; passed = $true; failed = @() }
                [pscustomobject]@{ id = 'c'; passed = $true; failed = @() }
            )
        }
        $diff = Compare-DpEvalRun -Baseline $script:baseline -Current $current
        $diff.ok | Should -BeTrue
        @($diff.fixes).id | Should -Be @('b')
        @($diff.unchanged) | Should -Be @('a', 'c')
    }

    It 'names a case that appeared or disappeared instead of ignoring it' {
        # A corpus that shrank is not an improvement.
        $current = [pscustomobject]@{
            runId = 'cur'; deskPilotSha = 'bbbbbbb'
            cases = @(
                [pscustomobject]@{ id = 'a'; passed = $true; failed = @() }
                [pscustomobject]@{ id = 'b'; passed = $false; failed = @('x') }
                [pscustomobject]@{ id = 'c'; passed = $true; failed = @() }
                [pscustomobject]@{ id = 'new'; passed = $true; failed = @() }
            )
        }
        $diff = Compare-DpEvalRun -Baseline $script:baseline -Current $current
        @($diff.added) | Should -Be @('new')
        @($diff.removed) | Should -Be @('gone')
    }
}

Describe 'Format-DpEvalSummary' {
    It 'reports the pass rate, the DeskPilot commit and the caveats' {
        $result = [pscustomobject]@{
            runId = '20260811-1200'; startedUtc = '2026-08-11T12:00:00Z'; deskPilotSha = 'abc1234'
            caveats = @('engine runspace inherits the launcher environment')
            cases = @(
                [pscustomobject]@{ id = 'a'; passed = $true; failed = @(); metrics = [pscustomobject]@{ toolCalls = 3; iterations = 2; promptTokens = 100; completionTokens = 20; costUSD = 0.01; wallSeconds = 12.3 } }
                [pscustomobject]@{ id = 'b'; passed = $false; failed = @('no-commit'); metrics = [pscustomobject]@{ toolCalls = 9; iterations = 5; promptTokens = 900; completionTokens = 80; costUSD = 0.09; wallSeconds = 40.0 } }
            )
        }
        $markdown = Format-DpEvalSummary -Result $result
        $markdown | Should -Match 'Pass rate: \*\*1 / 2\*\*'
        $markdown | Should -Match 'abc1234'
        $markdown | Should -Match 'Caveat: engine runspace'
        $markdown | Should -Match '\| b \| FAIL \| no-commit \|'
        $markdown | Should -Match 'Efficiency \(recorded, never graded\)'
    }
}

Describe 'the parity eval corpus' {
    BeforeAll {
        $script:caseRoot = Join-Path $PSScriptRoot '..' 'live' 'eval' 'cases'
        $script:caseFolders = @(Get-ChildItem -LiteralPath $script:caseRoot -Directory)
    }

    It 'has enough cases to expose a pattern' {
        @($script:caseFolders).Count | Should -BeGreaterOrEqual 10
    }

    It 'gives every case a prompt, a pinned fixture and graders' {
        foreach ($folder in $script:caseFolders) {
            Test-Path -LiteralPath (Join-Path $folder.FullName 'prompt.md') | Should -BeTrue -Because "$($folder.Name) needs a prompt"
            $case = Get-Content -LiteralPath (Join-Path $folder.FullName 'case.json') -Raw | ConvertFrom-Json
            $case.id | Should -Be $folder.Name
            $case.set | Should -BeIn @('capability', 'regression')
            $case.repository | Should -Not -BeNullOrEmpty
            $case.commit | Should -Not -BeNullOrEmpty
            $case.note | Should -Not -BeNullOrEmpty -Because "$($folder.Name) must record the real task it came from"
            $expect = Get-Content -LiteralPath (Join-Path $folder.FullName 'expect.json') -Raw | ConvertFrom-Json
            @($expect.graders).Count | Should -BeGreaterThan 0
        }
    }

    It 'names its fixture repository rather than an absolute path' {
        # A committed absolute path is a machine-specific fixture and a user path
        # in the repository.
        foreach ($folder in $script:caseFolders) {
            $case = Get-Content -LiteralPath (Join-Path $folder.FullName 'case.json') -Raw | ConvertFrom-Json
            [string]$case.repository | Should -Not -Match '[:\\/]'
        }
    }

    It 'uses only grader types the harness implements' {
        $known = @(Get-DpEvalGraderType)
        foreach ($folder in $script:caseFolders) {
            $expect = Get-Content -LiteralPath (Join-Path $folder.FullName 'expect.json') -Raw | ConvertFrom-Json
            foreach ($grader in @($expect.graders)) {
                [string]$grader.type | Should -BeIn $known -Because "$($folder.Name) uses $($grader.type)"
            }
        }
    }

    It 'accepts every committed case as a well-formed manifest' {
        foreach ($folder in $script:caseFolders) {
            $case = Get-Content -LiteralPath (Join-Path $folder.FullName 'case.json') -Raw | ConvertFrom-Json
            $expect = Get-Content -LiteralPath (Join-Path $folder.FullName 'expect.json') -Raw | ConvertFrom-Json
            $prompt = Get-Content -LiteralPath (Join-Path $folder.FullName 'prompt.md') -Raw
            $result = Test-DpEvalManifest -Case $case -Expect $expect -Prompt $prompt -FolderName $folder.Name
            $result.valid | Should -BeTrue -Because "$($folder.Name): $($result.errors -join '; ')"
        }
    }

    It 'guards an unrequested action in every case that lets the agent write' {
        # Criterion 3: a safety invariant is not optional just because the case
        # is about capability.
        foreach ($folder in $script:caseFolders) {
            $case = Get-Content -LiteralPath (Join-Path $folder.FullName 'case.json') -Raw | ConvertFrom-Json
            if (-not [bool]$case.permissions.file) { continue }
            $expect = Get-Content -LiteralPath (Join-Path $folder.FullName 'expect.json') -Raw | ConvertFrom-Json
            $safety = @(@($expect.graders) | Where-Object { Get-DpEvalGraderSafety -Grader $_ })
            @($safety).Count | Should -BeGreaterThan 0 -Because "$($folder.Name) can write and must assert what it may not do"
        }
    }

    It 'labels the provenance of every case that declares one, and invents none' {
        $allowed = @('parity-series', 'adapted', 'synthetic')
        foreach ($folder in $script:caseFolders) {
            $case = Get-Content -LiteralPath (Join-Path $folder.FullName 'case.json') -Raw | ConvertFrom-Json
            if (-not $case.PSObject.Properties['provenance']) { continue }
            [string]$case.provenance.origin | Should -BeIn $allowed -Because "$($folder.Name) must not invent an origin"
            [string]$case.provenance.source | Should -Not -BeNullOrEmpty -Because "$($folder.Name) must name where it came from"
            $case.provenance.PSObject.Properties['verbatimUserPrompt'] | Should -Not -BeNullOrEmpty -Because "$($folder.Name) must say whether a user typed this"
        }
    }

    It 'publishes no private history, user path or credential in a prompt' {
        # The corpus is committed. Anything in it is published.
        foreach ($folder in $script:caseFolders) {
            $prompt = Get-Content -LiteralPath (Join-Path $folder.FullName 'prompt.md') -Raw
            $prompt | Should -Not -Match '[A-Za-z]:\\Users\\' -Because "$($folder.Name) must carry no user path"
            $prompt | Should -Not -Match '/(home|Users)/[A-Za-z0-9._-]+/' -Because "$($folder.Name) must carry no user path"
            $prompt | Should -Not -Match 'promptHistory' -Because "$($folder.Name) must not quote private history"
            $prompt | Should -Not -Match '(ghp_|github_pat_|gho_)[A-Za-z0-9]' -Because "$($folder.Name) must carry no credential"
        }
    }

    It 'keeps the harness out of the Pester suite that build.ps1 runs' {
        # Acceptance criterion 5: this costs real money and needs real credentials.
        $buildYaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'build.yaml') -Raw
        $buildYaml | Should -Not -Match 'tests/live'
    }
}
