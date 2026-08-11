#requires -Version 7.0
<#
    Unit tests for the parity eval harness (parity prompt 09).

    These exercise the graders and the comparison logic only. They make no live
    call and start no Host Server: every case is graded against a fixture
    transcript committed next door, because a grader that has never been seen to
    fail is not a grader.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'live' 'eval' 'DpEvalGrader.ps1')

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
        $known = @('command_ran', 'tool_used', 'answer_contains', 'files_written', 'no_files_written', 'git_clean', 'instruction_followed', 'llm_judge')
        foreach ($folder in $script:caseFolders) {
            $expect = Get-Content -LiteralPath (Join-Path $folder.FullName 'expect.json') -Raw | ConvertFrom-Json
            foreach ($grader in @($expect.graders)) {
                [string]$grader.type | Should -BeIn $known -Because "$($folder.Name) uses $($grader.type)"
            }
        }
    }

    It 'keeps the harness out of the Pester suite that build.ps1 runs' {
        # Acceptance criterion 5: this costs real money and needs real credentials.
        $buildYaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'build.yaml') -Raw
        $buildYaml | Should -Not -Match 'tests/live'
    }
}
