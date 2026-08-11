#requires -Version 7.0
<#
.SYNOPSIS
    Deterministic graders and run comparison for the DeskPilot parity eval harness.
.DESCRIPTION
    Dot-source this file. It defines the grading and comparison logic and nothing
    else: no live calls, no network, no Host Server, no state. That is what makes
    it unit-testable against fixture transcripts committed to the repository,
    which is the only way a grader can be shown to fail on a known-bad run - and
    a grader that has never been seen to fail is not a grader.

    It deliberately grades the *transcript* and the *repository*, never prose
    volume. Prose volume is the metric that made DeskPilot look weak while being
    irrelevant to whether it was right.
#>

function ConvertTo-DpEvalRun {
    <#
    .SYNOPSIS
        Normalises one executed case into the shape the graders read.
    .DESCRIPTION
        The graders never see a transcript file, an API response or a git
        command; they see this. Keeping the projection in one place means a
        fixture used by a unit test is the same shape a live run produces, so a
        grader that passes in a test passes for the same reason live.
    .PARAMETER Record
        The prompt-08 transcript records, in order.
    .PARAMETER Answer
        The assistant Message text. Read from the Message, not the transcript:
        the transcript deliberately stores a length for model prose, never a copy.
    .PARAMETER ChangedFile
        Repository-relative paths the case left modified, added or deleted.
    .PARAMETER NewCommit
        How many commits the case created in the fixture.
    .PARAMETER Metric
        Efficiency measurements. Recorded, never graded.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Record = @(),

        [AllowEmptyString()]
        [string]$Answer = '',

        [AllowEmptyCollection()]
        [string[]]$ChangedFile = @(),

        [int]$NewCommit = 0,

        [hashtable]$Metric = @{}
    )

    $toolCalls = @(
        foreach ($entry in @($Record)) {
            if ([string]$entry.kind -ne 'tool_call') { continue }
            @{ tool = [string]$entry.tool; summary = [string]$entry.summary; iteration = [int]$entry.iteration }
        }
    )

    @{
        toolCalls    = $toolCalls
        answer       = $Answer
        changedFiles = @($ChangedFile | ForEach-Object { ([string]$_ -replace '\\', '/').Trim('/') } | Where-Object { $_ })
        newCommits   = $NewCommit
        metrics      = $Metric
    }
}

function Test-DpEvalGrader {
    <#
    .SYNOPSIS
        Applies one grader to one normalised run.
    .DESCRIPTION
        Deterministic first, and deterministic only: every type here is a set
        comparison, a count or a regex over data the harness measured. An
        llm_judge grader is accepted so a case can carry one, but it is always
        advisory - a judge score never gates a decision on its own.
    .PARAMETER Grader
        One grader definition from a case's expect.json.
    .PARAMETER Run
        The normalised run from ConvertTo-DpEvalRun.
    .OUTPUTS
        System.Collections.Hashtable with id, type, passed, advisory and detail.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Grader,

        [Parameter(Mandatory)]
        [hashtable]$Run
    )

    $type = [string]$Grader.type
    $id = if ($Grader.PSObject.Properties['id'] -and $Grader.id) { [string]$Grader.id } else { $type }
    $advisory = [bool]($Grader.PSObject.Properties['advisory'] -and $Grader.advisory)
    $result = @{ id = $id; type = $type; passed = $false; advisory = $advisory; detail = '' }

    $value = {
        param([string]$Name, $Default)
        if ($Grader.PSObject.Properties[$Name]) { $Grader.$Name } else { $Default }
    }

    switch ($type) {
        'command_ran' {
            $pattern = [string](& $value 'pattern' '')
            $tool = [string](& $value 'tool' '')
            $candidates = @($Run.toolCalls | Where-Object { -not $tool -or $_.tool -eq $tool })
            $hit = @($candidates | Where-Object { $_.summary -match $pattern })
            $result.passed = $hit.Count -gt 0
            $result.detail = if ($hit.Count -gt 0) { "matched: $($hit[0].summary)" } else { "no tool call summary matched /$pattern/ (checked $($candidates.Count))" }
        }
        'tool_used' {
            $tool = [string](& $value 'tool' '')
            $count = @($Run.toolCalls | Where-Object { $_.tool -eq $tool }).Count
            $min = & $value 'min' $null
            $max = & $value 'max' $null
            $okMin = ($null -eq $min) -or ($count -ge [int]$min)
            $okMax = ($null -eq $max) -or ($count -le [int]$max)
            $result.passed = $okMin -and $okMax
            $result.detail = "$tool called $count time(s); min=$(if ($null -eq $min) { '-' } else { $min }) max=$(if ($null -eq $max) { '-' } else { $max })"
        }
        'answer_contains' {
            $pattern = [string](& $value 'pattern' '')
            $result.passed = [string]$Run.answer -match $pattern
            $result.detail = if ($result.passed) { "answer matched /$pattern/" } else { "answer did not match /$pattern/" }
        }
        'instruction_followed' {
            $marker = [string](& $value 'marker' '')
            $pattern = if ($marker) { [regex]::Escape($marker) } else { [string](& $value 'pattern' '') }
            $result.passed = [string]$Run.answer -match $pattern
            $result.detail = if ($result.passed) { "found $(if ($marker) { $marker } else { $pattern })" } else { "missing $(if ($marker) { $marker } else { $pattern })" }
        }
        'files_written' {
            $expected = @(@(& $value 'paths' @()) | ForEach-Object { ([string]$_ -replace '\\', '/').Trim('/') } | Where-Object { $_ })
            $actual = @($Run.changedFiles)
            $mode = [string](& $value 'mode' 'equals')
            if ($mode -eq 'subset') {
                $extra = @($actual | Where-Object { $expected -notcontains $_ })
                $result.passed = $extra.Count -eq 0
                $result.detail = if ($result.passed) { "changed: $($actual -join ', ')" } else { "unexpected: $($extra -join ', ')" }
            }
            else {
                $missing = @($expected | Where-Object { $actual -notcontains $_ })
                $extra = @($actual | Where-Object { $expected -notcontains $_ })
                $result.passed = ($missing.Count -eq 0) -and ($extra.Count -eq 0)
                $result.detail = if ($result.passed) { "changed exactly: $($actual -join ', ')" } else { "missing: $($missing -join ', '); unexpected: $($extra -join ', ')" }
            }
        }
        'no_files_written' {
            $result.passed = @($Run.changedFiles).Count -eq 0
            $result.detail = if ($result.passed) { 'working tree unchanged' } else { "changed: $(@($Run.changedFiles) -join ', ')" }
        }
        'git_clean' {
            $result.passed = [int]$Run.newCommits -eq 0
            $result.detail = "$([int]$Run.newCommits) new commit(s)"
        }
        'llm_judge' {
            # Accepted so a case can carry one, and always advisory: a judge score
            # never gates a decision on its own.
            $result.advisory = $true
            $result.passed = $true
            $result.detail = 'advisory - judge not run by this harness'
        }
        default {
            $result.detail = "unknown grader type '$type'"
        }
    }

    $result
}

function Test-DpEvalCase {
    <#
    .SYNOPSIS
        Grades one executed case against its expect.json.
    .DESCRIPTION
        A case passes when every non-advisory grader passes. An advisory grader is
        recorded and reported but never gates, so an LLM judge cannot decide a
        case on its own.
    .PARAMETER Expect
        The parsed expect.json (an object with a graders array).
    .PARAMETER Run
        The normalised run from ConvertTo-DpEvalRun.
    .OUTPUTS
        System.Collections.Hashtable with passed, graders and failed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Expect,

        [Parameter(Mandatory)]
        [hashtable]$Run
    )

    $graders = @(
        foreach ($grader in @($Expect.graders)) {
            if ($null -eq $grader) { continue }
            Test-DpEvalGrader -Grader $grader -Run $Run
        }
    )

    $gating = @($graders | Where-Object { -not $_.advisory })
    $failed = @($gating | Where-Object { -not $_.passed })

    @{
        passed  = ($gating.Count -gt 0) -and ($failed.Count -eq 0)
        graders = $graders
        failed  = @($failed | ForEach-Object { $_.id })
    }
}

function Compare-DpEvalRun {
    <#
    .SYNOPSIS
        Diffs two eval runs and names what changed.
    .DESCRIPTION
        A regression must be impossible to miss, so it is reported separately from
        everything else and is the only thing that decides the exit code. Cases
        that appear or disappear between runs are reported too rather than
        silently ignored - a corpus that shrank is not an improvement.
    .PARAMETER Baseline
        The parsed baseline run result.
    .PARAMETER Current
        The parsed current run result.
    .OUTPUTS
        System.Collections.Hashtable with regressions, fixes, unchanged, added,
        removed and ok.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Baseline,

        [Parameter(Mandatory)]
        [object]$Current
    )

    $baseMap = @{}
    foreach ($case in @($Baseline.cases)) { if ($case) { $baseMap[[string]$case.id] = $case } }
    $currentMap = @{}
    foreach ($case in @($Current.cases)) { if ($case) { $currentMap[[string]$case.id] = $case } }

    $regressions = [System.Collections.Generic.List[hashtable]]::new()
    $fixes = [System.Collections.Generic.List[hashtable]]::new()
    $unchanged = [System.Collections.Generic.List[string]]::new()

    foreach ($id in @($currentMap.Keys | Sort-Object)) {
        if (-not $baseMap.ContainsKey($id)) { continue }
        $was = [bool]$baseMap[$id].passed
        $now = [bool]$currentMap[$id].passed
        if ($was -and -not $now) {
            $regressions.Add(@{ id = $id; failed = @($currentMap[$id].failed) })
        }
        elseif (-not $was -and $now) {
            $fixes.Add(@{ id = $id; fixed = @($baseMap[$id].failed) })
        }
        else {
            $unchanged.Add($id)
        }
    }

    @{
        regressions = @($regressions)
        fixes       = @($fixes)
        unchanged   = @($unchanged)
        added       = @($currentMap.Keys | Where-Object { -not $baseMap.ContainsKey($_) } | Sort-Object)
        removed     = @($baseMap.Keys | Where-Object { -not $currentMap.ContainsKey($_) } | Sort-Object)
        ok          = ($regressions.Count -eq 0)
    }
}

function Format-DpEvalSummary {
    <#
    .SYNOPSIS
        Renders a run result as the Markdown summary a human reads.
    .DESCRIPTION
        Correctness first and efficiency beside it, never mixed: a cheaper run
        that is wrong is not better, so the metric table is reported and never
        graded.
    .PARAMETER Result
        The run result object.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $cases = @($Result.cases)
    $passed = @($cases | Where-Object { $_.passed }).Count
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# DeskPilot parity eval run')
    $lines.Add('')
    $lines.Add("- Run: ``$($Result.runId)`` at $($Result.startedUtc)")
    $lines.Add("- DeskPilot commit: ``$($Result.deskPilotSha)``")
    $lines.Add("- Pass rate: **$passed / $($cases.Count)**")
    if ($Result.caveats) {
        foreach ($caveat in @($Result.caveats)) { $lines.Add("- Caveat: $caveat") }
    }
    $lines.Add('')
    $lines.Add('## Cases')
    $lines.Add('')
    $lines.Add('| Case | Result | Failed graders |')
    $lines.Add('|---|---|---|')
    foreach ($case in $cases) {
        $status = if ($case.passed) { 'pass' } else { 'FAIL' }
        $lines.Add("| $($case.id) | $status | $((@($case.failed) -join ', ')) |")
    }
    $lines.Add('')
    $lines.Add('## Efficiency (recorded, never graded)')
    $lines.Add('')
    $lines.Add('| Case | Tool calls | Iterations | Prompt tok | Completion tok | Cost USD | Wall s |')
    $lines.Add('|---|---|---|---|---|---|---|')
    foreach ($case in $cases) {
        $m = $case.metrics
        $lines.Add("| $($case.id) | $($m.toolCalls) | $($m.iterations) | $($m.promptTokens) | $($m.completionTokens) | $($m.costUSD) | $([Math]::Round([double]$m.wallSeconds, 1)) |")
    }
    ($lines -join "`n") + "`n"
}
