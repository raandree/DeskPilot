#requires -Version 7.0
<#
    Unit tests for repeated-trial execution, honest aggregation and gating in
    the parity eval harness.

    These make no live call, start no Host Server and send no prompt to a Model.
    Every trial here comes from a scripted executor seam, which is the point:
    the harness plumbing can be proven without claiming anything about Model
    performance. A number produced from a fixture is a number about the harness.
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'The discovery-time capability probe is consumed by -Skip: expressions, which the analyzer does not follow.')]
param()

BeforeDiscovery {
    # -Skip: is evaluated during discovery, so a capability probe in BeforeAll
    # would always read as "cannot" and a test meant to run would silently be
    # skipped instead. Probe here, where discovery can see the answer.
    $canFileLink = $false
    $canDetectHardLink = $false
    $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-linkprobe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
        $probeTarget = Join-Path $probeRoot 'target.txt'
        Set-Content -LiteralPath $probeTarget -Value 'probe' -Encoding utf8NoBOM
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $probeRoot 'link.txt') -Value $probeTarget -ErrorAction Stop | Out-Null
            $canFileLink = $true
        }
        catch { $canFileLink = $false }
        try {
            $probeHardLink = Join-Path $probeRoot 'hard.txt'
            New-Item -ItemType HardLink -Path $probeHardLink -Value $probeTarget -ErrorAction Stop | Out-Null
            $canDetectHardLink = [bool](Get-Item -LiteralPath $probeHardLink -Force).LinkType
        }
        catch { $canDetectHardLink = $false }
    }
    catch { $null = $_ }
    finally { Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue }

    # Whether an exclusively-held file actually blocks a recursive delete. It
    # does on Windows and does not on Unix, and it is the one deterministic way
    # to make cleanup fail without adding a seam to production-shaped code.
    $canLockFile = $false
    $lockRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-lockprobe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $lockStream = $null
    try {
        New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
        $lockFile = Join-Path $lockRoot 'held.txt'
        Set-Content -LiteralPath $lockFile -Value 'held' -Encoding utf8NoBOM
        $lockStream = [System.IO.File]::Open($lockFile, 'Open', 'ReadWrite', 'None')
        try {
            Remove-Item -LiteralPath $lockRoot -Recurse -Force -ErrorAction Stop
            $canLockFile = $false
        }
        catch { $canLockFile = $true }
    }
    catch { $canLockFile = $false }
    finally {
        if ($lockStream) { $lockStream.Dispose() }
        Remove-Item -LiteralPath $lockRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'live' 'eval' 'DpEvalTrial.ps1')

    $script:evalRoot = Join-Path $PSScriptRoot '..' 'live' 'eval'
    $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures' 'eval'

    function script:New-Case {
        param([hashtable]$Override = @{})
        $case = @{
            id                = 'sample-case'
            set               = 'regression'
            note              = 'the real task this came from'
            repository        = 'DeskPilot'
            commit            = 'd354d53'
            model             = 'claude-opus-5'
            agent             = 'software-engineer'
            maxToolIterations = 25
            permissions       = @{ browsing = $false; file = $true; terminal = $true; askUser = $false; userTools = $true }
            timeoutSeconds    = 900
        }
        foreach ($key in $Override.Keys) { $case[$key] = $Override[$key] }
        [pscustomobject]$case
    }

    function script:New-Expect {
        param([object[]]$Grader)
        if (-not $Grader) {
            $Grader = @(
                [pscustomobject]@{ id = 'did-not-commit'; type = 'git_clean' }
                [pscustomobject]@{ id = 'answered'; type = 'answer_contains'; pattern = 'done' }
            )
        }
        [pscustomobject]@{ graders = @($Grader) }
    }

    # A trial record in the shape Measure-DpEvalCaseOutcome consumes. Written
    # by hand here so the aggregation rules are asserted without depending on
    # the grader layer.
    function script:New-Trial {
        param(
            [int]$Trial,
            [string]$Status = 'completed',
            [nullable[bool]]$Passed = $true,
            [string[]]$Failed = @(),
            [string[]]$SafetyFailed = @(),
            [hashtable]$Usage,
            [double]$Duration = 1.5
        )
        @{
            trial           = $Trial
            status          = $Status
            passed          = $Passed
            failed          = @($Failed)
            safetyFailed    = @($SafetyFailed)
            unavailable     = @()
            graders         = @()
            usage           = if ($PSBoundParameters.ContainsKey('Usage')) { $Usage } else { ConvertTo-DpEvalUsage }
            durationSeconds = $Duration
        }
    }

    # A junction on Windows and a symlink elsewhere: both are reparse points and
    # both are creatable without elevation, which a file symlink on Windows is
    # not.
    function script:New-DirectoryLink {
        param([string]$Path, [string]$Target)
        if ($IsWindows) { New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $Path -Value $Target -ErrorAction Stop | Out-Null }
    }

    function script:New-FileLink {
        param([string]$Path, [string]$Target)
        New-Item -ItemType SymbolicLink -Path $Path -Value $Target -ErrorAction Stop | Out-Null
    }

    # A stand-in for the child process. The failures that matter - a tree that
    # will not stop, an exit code that cannot be read, a capture that faults, a
    # log that will not close - cannot be provoked reliably against a real
    # process, and stopping a real one by a made-up id is exactly what this
    # harness must never do.
    function script:New-FakeProcess {
        param(
            [switch]$KillThrows,
            [switch]$ExitOnKill,
            [switch]$ExitCodeThrows,
            [string]$KillMessage = 'access is denied',
            [bool]$WaitResult = $true
        )
        $process = [pscustomobject]@{
            Id          = 4242424
            HasExited   = $false
            killThrows  = [bool]$KillThrows
            exitOnKill  = [bool]$ExitOnKill
            killMessage = $KillMessage
            waitResult  = $WaitResult
            killedTree  = @()
            disposed    = $false
        }
        if ($ExitCodeThrows) {
            $process | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { throw 'the exit code is not available' }
        }
        else {
            $process | Add-Member -MemberType NoteProperty -Name ExitCode -Value 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            param($EntireTree)
            $this.killedTree = @($this.killedTree + [bool]$EntireTree)
            if ($this.exitOnKill) { $this.HasExited = $true }
            if ($this.killThrows) { throw $this.killMessage }
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            # The bound is part of the shape being stood in for; this fake
            # answers immediately either way.
            $null = $Milliseconds
            [bool]$this.waitResult
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.disposed = $true }
        $process
    }

    function script:New-FakeSession {
        param(
            [Parameter(Mandatory)]
            [string]$Root,

            [object]$Process,
            [object[]]$Copies = @(),
            [object[]]$Streams = @()
        )
        @{
            process      = $Process
            logPath      = Join-Path $Root ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
            errorLogPath = Join-Path $Root ('err-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
            streams      = @($Streams)
            copies       = @($Copies)
        }
    }
}

Describe 'Test-DpEvalRepeat' {
    It 'accepts a bounded repeat count' {
        (Test-DpEvalRepeat -Repeat 1).valid | Should -BeTrue
        (Test-DpEvalRepeat -Repeat 5).valid | Should -BeTrue
    }

    It 'rejects a repeat count of zero or less' {
        $zero = Test-DpEvalRepeat -Repeat 0
        $zero.valid | Should -BeFalse
        $zero.error | Should -Match 'at least 1'
        (Test-DpEvalRepeat -Repeat -3).valid | Should -BeFalse
    }

    It 'rejects a repeat count above the bound so a typo cannot spend a fortune' {
        $huge = Test-DpEvalRepeat -Repeat 1000
        $huge.valid | Should -BeFalse
        $huge.error | Should -Match 'at most'
    }
}

Describe 'Test-DpEvalCaseId' {
    It 'accepts every id the committed corpus already uses' {
        # The allow-list is bounded, so the first thing it must not do is break
        # the corpus it exists to protect.
        $ids = @((Get-ChildItem -LiteralPath (Join-Path $script:evalRoot 'cases') -Directory).Name)
        @($ids).Count | Should -BeGreaterThan 0
        foreach ($id in $ids) {
            $decision = Test-DpEvalCaseId -CaseId $id
            $decision.ok | Should -BeTrue -Because "'$id' is a committed case: $($decision.reason)"
        }
    }

    It 'refuses an id carrying a quote, a subexpression or a separator' {
        # The finding: a crafted id reached the sandbox leaf and from there a
        # generated command line. The id is the first place to stop it.
        $crafted = @(
            "ok'; Write-Host pwned; '"
            'ok$(Write-Host pwned)'
            'ok`e'
            'ok"e'
            'ok|e'
            'ok;e'
            'ok&e'
            'ok e'
            'ok%e'
            'ok>e'
            '-ok'
        )
        foreach ($id in $crafted) {
            (Test-DpEvalCaseId -CaseId $id).ok | Should -BeFalse -Because "'$id' must never reach a path or an argument"
        }
    }

    It 'refuses a newline, which would forge a line in a log or a manifest' {
        # A trailing newline is the one a '$' anchor quietly accepts, so the
        # allow-list anchors on the whole string instead.
        foreach ($id in @("ok`nnext", "ok`r`nnext", "ok`tnext", "ok`0next", "ok`n", "ok`r")) {
            (Test-DpEvalCaseId -CaseId $id).ok | Should -BeFalse
        }
    }

    It 'refuses traversal and every path separator' {
        foreach ($id in @('..', '.', '../escape', '..\escape', 'a/b', 'a\b', '~', '~/x', 'C:\x', '/etc/passwd')) {
            (Test-DpEvalCaseId -CaseId $id).ok | Should -BeFalse -Because "'$id' must never become a sandbox leaf"
        }
    }

    It 'refuses an empty or overlong id rather than trimming it into a valid one' {
        (Test-DpEvalCaseId -CaseId '').ok | Should -BeFalse
        (Test-DpEvalCaseId -CaseId '   ').ok | Should -BeFalse
        (Test-DpEvalCaseId -CaseId ' ok').ok | Should -BeFalse -Because 'an id is never trimmed into a different id'
        (Test-DpEvalCaseId -CaseId ('a' * 64)).ok | Should -BeTrue -Because '64 characters is the bound itself'
        (Test-DpEvalCaseId -CaseId ('a' * 65)).ok | Should -BeFalse -Because 'an overlong id is refused, never truncated'
    }

    It 'refuses anything outside the ASCII allow-list' {
        # Written as code points so this file stays ASCII: a test that asserts
        # an encoding rule must not depend on its own file's encoding.
        $accented = 'caf' + [char]0x00E9
        $tick = 'ok' + [char]0x2713
        $rightToLeft = [string][char]0x202E + 'abc'
        foreach ($id in @($accented, $tick, $rightToLeft, 'Ok-Case')) {
            $decision = Test-DpEvalCaseId -CaseId $id
            $decision.ok | Should -BeFalse -Because "'$id' is outside the allow-list"
        }
    }

    It 'never normalises an id into a different one' {
        # Accepting 'Sample-Case' as 'sample-case' would let two manifests share
        # one sandbox leaf and one reported id.
        $decision = Test-DpEvalCaseId -CaseId 'Sample-Case'
        $decision.ok | Should -BeFalse
        $decision.reason | Should -Match 'a-z0-9'
    }

    It 'refuses an id that is not a string rather than stringifying it' {
        # A manifest is JSON: an id can arrive as a number, an array or an
        # object, and [string] would quietly turn any of them into a path.
        (Test-DpEvalCaseId -CaseId $null).ok | Should -BeFalse
        (Test-DpEvalCaseId -CaseId 42).ok | Should -BeFalse
        (Test-DpEvalCaseId -CaseId $true).ok | Should -BeFalse
        (Test-DpEvalCaseId -CaseId @('a', 'b')).ok | Should -BeFalse
        (Test-DpEvalCaseId -CaseId ([pscustomobject]@{ id = 'a' })).ok | Should -BeFalse
    }

    It 'names the id it refused without repeating a control character' {
        $decision = Test-DpEvalCaseId -CaseId "ok`nnext"
        $decision.ok | Should -BeFalse
        $decision.reason | Should -Not -Match "`n"
        $decision.reason | Should -Match 'case id'
    }
}

Describe 'Test-DpEvalManifest' {
    It 'accepts a well-formed case' {
        $result = Test-DpEvalManifest -Case (New-Case) -Expect (New-Expect) -Prompt 'do the thing' -FolderName 'sample-case'
        $result.valid | Should -BeTrue -Because ($result.errors -join '; ')
        @($result.errors) | Should -HaveCount 0
    }

    It 'rejects a case whose id does not match its folder' {
        $result = Test-DpEvalManifest -Case (New-Case) -Expect (New-Expect) -Prompt 'x' -FolderName 'other-folder'
        $result.valid | Should -BeFalse
        ($result.errors -join '; ') | Should -Match 'folder'
    }

    It 'rejects an unknown grader type rather than silently skipping it' {
        $expect = New-Expect -Grader @([pscustomobject]@{ id = 'x'; type = 'vibes' })
        $result = Test-DpEvalManifest -Case (New-Case) -Expect $expect -Prompt 'x' -FolderName 'sample-case'
        $result.valid | Should -BeFalse
        ($result.errors -join '; ') | Should -Match "unknown grader type 'vibes'"
    }

    It 'refuses a grader that carries executable content' {
        # A manifest must never be able to run code: the corpus is data.
        foreach ($field in @('script', 'command', 'shell', 'run', 'exec')) {
            $grader = [pscustomobject]@{ id = 'x'; type = 'git_clean'; $field = 'rm -rf /' }
            $result = Test-DpEvalManifest -Case (New-Case) -Expect (New-Expect -Grader @($grader)) -Prompt 'x' -FolderName 'sample-case'
            $result.valid | Should -BeFalse -Because "$field must be rejected"
            ($result.errors -join '; ') | Should -Match 'executable'
        }
    }

    It 'refuses a grader that reads outside the fixture workspace' {
        foreach ($path in @('../secrets.txt', '/etc/passwd', 'C:\Users\someone\notes.md')) {
            $grader = [pscustomobject]@{ id = 'x'; type = 'file_contains'; path = $path; pattern = 'a' }
            $result = Test-DpEvalManifest -Case (New-Case) -Expect (New-Expect -Grader @($grader)) -Prompt 'x' -FolderName 'sample-case'
            $result.valid | Should -BeFalse -Because "$path escapes the workspace"
            ($result.errors -join '; ') | Should -Match 'workspace-relative'
        }
    }

    It 'refuses a grader that is both advisory and a safety invariant' {
        $grader = [pscustomobject]@{ id = 'x'; type = 'git_clean'; advisory = $true; safety = $true }
        $result = Test-DpEvalManifest -Case (New-Case) -Expect (New-Expect -Grader @($grader)) -Prompt 'x' -FolderName 'sample-case'
        $result.valid | Should -BeFalse
        ($result.errors -join '; ') | Should -Match 'advisory'
    }

    It 'refuses a case with no gating grader, because it asserts nothing' {
        $expect = New-Expect -Grader @([pscustomobject]@{ id = 'judge'; type = 'llm_judge' })
        $result = Test-DpEvalManifest -Case (New-Case) -Expect $expect -Prompt 'x' -FolderName 'sample-case'
        $result.valid | Should -BeFalse
        ($result.errors -join '; ') | Should -Match 'gating grader'
    }

    It 'refuses duplicate grader ids, which would make a failure unattributable' {
        $expect = New-Expect -Grader @(
            [pscustomobject]@{ id = 'same'; type = 'git_clean' }
            [pscustomobject]@{ id = 'same'; type = 'no_files_written' }
        )
        $result = Test-DpEvalManifest -Case (New-Case) -Expect $expect -Prompt 'x' -FolderName 'sample-case'
        $result.valid | Should -BeFalse
        ($result.errors -join '; ') | Should -Match 'duplicate grader id'
    }

    It 'refuses a machine-specific fixture, a missing note and a nonsensical iteration cap' {
        $noRepo = Test-DpEvalManifest -Case (New-Case @{ repository = 'V:\Git\DeskPilot' }) -Expect (New-Expect) -Prompt 'x' -FolderName 'sample-case'
        ($noRepo.errors -join '; ') | Should -Match 'repository'

        $noNote = Test-DpEvalManifest -Case (New-Case @{ note = '' }) -Expect (New-Expect) -Prompt 'x' -FolderName 'sample-case'
        ($noNote.errors -join '; ') | Should -Match 'note'

        $badCap = Test-DpEvalManifest -Case (New-Case @{ maxToolIterations = 0 }) -Expect (New-Expect) -Prompt 'x' -FolderName 'sample-case'
        ($badCap.errors -join '; ') | Should -Match 'maxToolIterations'

        $badSet = Test-DpEvalManifest -Case (New-Case @{ set = 'vibes' }) -Expect (New-Expect) -Prompt 'x' -FolderName 'sample-case'
        ($badSet.errors -join '; ') | Should -Match 'set'
    }

    It 'refuses an empty prompt' {
        $result = Test-DpEvalManifest -Case (New-Case) -Expect (New-Expect) -Prompt '   ' -FolderName 'sample-case'
        $result.valid | Should -BeFalse
        ($result.errors -join '; ') | Should -Match 'prompt'
    }

    It 'accepts a provenance block and rejects an invented origin' {
        $good = Test-DpEvalManifest -Case (New-Case @{ provenance = @{ origin = 'adapted'; source = 'commit 3d74541'; verbatimUserPrompt = $false } }) `
            -Expect (New-Expect) -Prompt 'x' -FolderName 'sample-case'
        $good.valid | Should -BeTrue -Because ($good.errors -join '; ')

        $bad = Test-DpEvalManifest -Case (New-Case @{ provenance = @{ origin = 'twenty-real-user-failures'; source = '' } }) `
            -Expect (New-Expect) -Prompt 'x' -FolderName 'sample-case'
        $bad.valid | Should -BeFalse
        ($bad.errors -join '; ') | Should -Match 'provenance'
    }

    It 'refuses a case id that carries a quote and a subexpression' {
        # The review finding: this id was accepted and became a sandbox leaf.
        $crafted = "sample-case'; `$(Write-Host pwned); '"
        $result = Test-DpEvalManifest -Case (New-Case @{ id = $crafted }) -Expect (New-Expect) -Prompt 'x' -FolderName $crafted
        $result.valid | Should -BeFalse
        ($result.errors -join '; ') | Should -Match 'case id'
    }

    It 'refuses a traversing case id even when its folder agrees with it' {
        foreach ($id in @('../escape', '..\escape', 'a/b', '..')) {
            $result = Test-DpEvalManifest -Case (New-Case @{ id = $id }) -Expect (New-Expect) -Prompt 'x' -FolderName $id
            $result.valid | Should -BeFalse -Because "'$id' must never become a path"
            ($result.errors -join '; ') | Should -Match 'case id'
        }
    }

    It 'refuses a case id that is not a string instead of stringifying it' {
        $number = Test-DpEvalManifest -Case (New-Case @{ id = 42 }) -Expect (New-Expect) -Prompt 'x' -FolderName '42'
        $number.valid | Should -BeFalse
        ($number.errors -join '; ') | Should -Match 'case id'

        $array = Test-DpEvalManifest -Case (New-Case @{ id = @('a', 'b') }) -Expect (New-Expect) -Prompt 'x' -FolderName 'a b'
        $array.valid | Should -BeFalse
        ($array.errors -join '; ') | Should -Match 'case id'
    }
}

Describe 'Get-DpEvalCaseIdentity' {
    It 'is stable for the same case and prompt' {
        $first = Get-DpEvalCaseIdentity -Case (New-Case) -Prompt 'do the thing'
        $second = Get-DpEvalCaseIdentity -Case (New-Case) -Prompt 'do the thing'
        $first | Should -Be $second
        $first | Should -Not -BeNullOrEmpty
    }

    It 'changes when anything that decides the outcome changes' {
        $baseline = Get-DpEvalCaseIdentity -Case (New-Case) -Prompt 'do the thing'
        Get-DpEvalCaseIdentity -Case (New-Case @{ model = 'claude-sonnet-5' }) -Prompt 'do the thing' | Should -Not -Be $baseline
        Get-DpEvalCaseIdentity -Case (New-Case @{ commit = 'aaaaaaa' }) -Prompt 'do the thing' | Should -Not -Be $baseline
        Get-DpEvalCaseIdentity -Case (New-Case @{ maxToolIterations = 26 }) -Prompt 'do the thing' | Should -Not -Be $baseline
        Get-DpEvalCaseIdentity -Case (New-Case) -Prompt 'do the other thing' | Should -Not -Be $baseline
    }

    It 'does not leak the prompt text into the identity' {
        $identity = Get-DpEvalCaseIdentity -Case (New-Case) -Prompt 'a secret internal prompt'
        $identity | Should -Not -Match 'secret'
    }

    It 'fingerprints the permissions whether they arrive as an object or a dictionary' {
        # A hashtable's PSObject.Properties are the adapter members, not the
        # keys, so reading them would fingerprint 'Count' and 'Keys' instead of
        # the permissions and make two different configurations look identical.
        $closed = New-Case @{ permissions = @{ browsing = $false; file = $true; terminal = $false; askUser = $false; userTools = $true } }
        $open = New-Case @{ permissions = @{ browsing = $true; file = $true; terminal = $true; askUser = $false; userTools = $true } }
        Get-DpEvalCaseIdentity -Case $closed -Prompt 'p' | Should -Not -Be (Get-DpEvalCaseIdentity -Case $open -Prompt 'p')

        $asObject = New-Case @{ permissions = [pscustomobject]@{ browsing = $false; file = $true; terminal = $false; askUser = $false; userTools = $true } }
        Get-DpEvalCaseIdentity -Case $asObject -Prompt 'p' | Should -Be (Get-DpEvalCaseIdentity -Case $closed -Prompt 'p')
    }
}

Describe 'New-DpEvalTrialContext' {
    BeforeAll {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-test-' + [guid]::NewGuid().ToString('N'))
    }

    AfterAll {
        if ($script:root -and (Test-Path -LiteralPath $script:root)) {
            Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'gives every trial its own sandbox, fixture clone and data directory' {
        $first = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 1 -Root $script:root
        $second = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 2 -Root $script:root
        $first.sandbox | Should -Not -Be $second.sandbox
        $first.dataDir | Should -Not -Be $second.dataDir
        $first.fixture | Should -Not -Be $second.fixture
        $first.trial | Should -Be 1
        $second.trial | Should -Be 2
    }

    It 'keeps the Conversation state inside the throwaway sandbox' {
        # A trial must never be able to reach a real Project or a real
        # Conversation: the data directory is a fresh folder under the run root.
        $context = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 1 -Root $script:root
        $context.dataDir | Should -BeLike (Join-Path $context.sandbox '*')
        $context.fixture | Should -BeLike (Join-Path $context.sandbox '*')
        $physicalRoot = Resolve-DpEvalPhysicalPath -Path $script:root
        $context.sandbox | Should -BeLike (Join-Path $physicalRoot '*')
        Test-Path -LiteralPath (Join-Path $script:root (Split-Path -Leaf $context.sandbox)) -PathType Container | Should -BeTrue
    }

    It 'allocates the sandbox fresh and records who owns it' {
        # Cleanup deletes recursively, so it must be able to prove the folder is
        # this run's and not something that was already there.
        $context = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 1 -Root $script:root -OwnerId 'owner-a'
        $context.ownerId | Should -Be 'owner-a'
        (Test-DpEvalOwnedDirectory -Path $context.sandbox -OwnerId 'owner-a').ok | Should -BeTrue
        Remove-DpEvalSandbox -Path $context.sandbox -OwnerId 'owner-a'
        Test-Path -LiteralPath $context.sandbox | Should -BeFalse
    }

    It 'gives a trial its own owner identity when the caller does not supply one' {
        $context = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 1 -Root $script:root
        $context.ownerId | Should -Not -BeNullOrEmpty
        (Test-DpEvalOwnedDirectory -Path $context.sandbox -OwnerId $context.ownerId).ok | Should -BeTrue
    }

    It 'refuses a run root that is the user profile or the repository itself' {
        { New-DpEvalTrialContext -CaseId 'x' -Trial 1 -Root $HOME } | Should -Throw -ExpectedMessage '*throwaway*'
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        { New-DpEvalTrialContext -CaseId 'x' -Trial 1 -Root $repoRoot } | Should -Throw -ExpectedMessage '*throwaway*'
    }

    It 'refuses a run root that only looks like it is under temp' {
        # Spelling is not confinement: a name under TEMP can be a link to        # anywhere, and everything the run writes - and deletes - would follow it.
        $outside = Join-Path $script:root 'pretend-not-temp'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $decoy = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-decoy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            # A link whose target is resolved, not assumed: point it at a folder
            # that is itself outside the temp tree.
            $realOutside = Join-Path ([System.IO.Path]::GetFullPath($env:USERPROFILE ?? $HOME)) ('dp-eval-outside-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $realOutside -Force | Out-Null
            try {
                New-DirectoryLink -Path $decoy -Target $realOutside
                { New-DpEvalTrialContext -CaseId 'x' -Trial 1 -Root $decoy } | Should -Throw -ExpectedMessage '*throwaway*'
            }
            finally {
                if (Test-Path -LiteralPath $decoy) {
                    if ($IsWindows) { [System.IO.Directory]::Delete($decoy, $false) }
                    else { [System.IO.File]::Delete($decoy) }
                }
                Remove-Item -LiteralPath $realOutside -Recurse -Force -ErrorAction Stop
            }
        }
        finally {
            Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a crafted case id before it allocates anything' {
        # The finding: this id was accepted and interpolated into the sandbox
        # leaf, which the live launcher then wrote into a generated script.
        $crafted = "case'; `$(New-Item -ItemType File -Path 'pwned.txt'); '"
        $before = @(Get-ChildItem -LiteralPath $script:root -Force -ErrorAction SilentlyContinue).Count
        { New-DpEvalTrialContext -CaseId $crafted -Trial 1 -Root $script:root } | Should -Throw -ExpectedMessage '*case id*'
        @(Get-ChildItem -LiteralPath $script:root -Force -ErrorAction SilentlyContinue).Count |
            Should -Be $before -Because 'an invalid id is refused before any directory is allocated'
    }

    It 'refuses a traversing case id rather than allocating outside the run root' {
        foreach ($id in @('..', '../escape', 'a/b', 'a\b', '-ok', ('a' * 65))) {
            { New-DpEvalTrialContext -CaseId $id -Trial 1 -Root $script:root } |
                Should -Throw -ExpectedMessage '*case id*' -Because "'$id' must never become a sandbox leaf"
        }
    }

    It 'gives the trial a log path for the child it will start' {
        $context = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 1 -Root $script:root
        $context.serverLog | Should -BeLike (Join-Path $context.sandbox '*')
        $context.serverErrorLog | Should -BeLike (Join-Path $context.sandbox '*')
        $context.serverErrorLog | Should -Not -Be $context.serverLog
        $context.launchConfig | Should -BeLike (Join-Path $context.sandbox '*') -Because 'the launch configuration is trial state, not shared state'
    }
}

Describe 'Get-DpEvalArtifactContent' {
    BeforeEach {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-art-' + [guid]::NewGuid().ToString('N'))
        $script:fixture = Join-Path $script:sandbox 'fixture'
        $script:outside = Join-Path $script:sandbox 'outside'
        New-Item -ItemType Directory -Path $script:fixture, $script:outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:outside 'secret.txt') -Value 'a private key' -Encoding utf8NoBOM
    }

    AfterEach {
        if ($script:sandbox -and (Test-Path -LiteralPath $script:sandbox)) {
            Get-ChildItem -LiteralPath $script:sandbox -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    if ($_.PSIsContainer) { [System.IO.Directory]::Delete($_.FullName, $false) }
                    else { [System.IO.File]::Delete($_.FullName) }
                }
            Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reads an ordinary artifact inside the fixture' {
        Set-Content -LiteralPath (Join-Path $script:fixture 'CHANGELOG.md') -Value "### Fixed`n- a thing" -Encoding utf8NoBOM
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'CHANGELOG.md'
        $result.captured | Should -BeTrue
        $result.content | Should -Match 'a thing'
        $result.reason | Should -BeNullOrEmpty
    }

    It 'reads an ordinary artifact in a real subfolder' {
        New-Item -ItemType Directory -Path (Join-Path $script:fixture 'out') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:fixture 'out/result.json') -Value '{ "status": "ok" }' -Encoding utf8NoBOM
        (Get-DpEvalArtifactContent -Root $script:fixture -Path 'out/result.json').captured | Should -BeTrue
    }

    It 'reports a missing artifact as not captured rather than failing the read' {
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'CHANGELOG.md'
        $result.captured | Should -BeFalse
        $result.reason | Should -Match 'does not exist'
    }

    It 'refuses an artifact reached through an ancestor link that leaves the fixture' {
        # The lexical check passes: 'escape/secret.txt' has no .. and is not
        # rooted. The ancestor is a junction, and only the filesystem knows.
        New-DirectoryLink -Path (Join-Path $script:fixture 'escape') -Target $script:outside
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'escape/secret.txt'
        $result.captured | Should -BeFalse
        $result.content | Should -BeNullOrEmpty
        $result.reason | Should -Match 'link'
    }

    It 'refuses an ancestor link even when it points back inside the fixture' {
        # Conservative on purpose: an artifact path that traverses any link is
        # refused, so the decision never depends on getting target analysis right.
        New-Item -ItemType Directory -Path (Join-Path $script:fixture 'real') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:fixture 'real/report.json') -Value '{ "status": "ok" }' -Encoding utf8NoBOM
        New-DirectoryLink -Path (Join-Path $script:fixture 'alias') -Target (Join-Path $script:fixture 'real')
        (Get-DpEvalArtifactContent -Root $script:fixture -Path 'alias/report.json').captured | Should -BeFalse
    }

    It 'refuses a leaf that is a link out of the fixture' -Skip:(-not $canFileLink) {
        New-FileLink -Path (Join-Path $script:fixture 'CHANGELOG.md') -Target (Join-Path $script:outside 'secret.txt')
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'CHANGELOG.md'
        $result.captured | Should -BeFalse
        $result.content | Should -Not -Match 'private key'
        # Either gate may catch it first - the leaf link target resolves outside
        # the fixture, and the chain contains a link. Both are refusals.
        $result.reason | Should -Match 'link|outside'
    }

    It 'refuses a leaf link even when its target is inside the fixture' -Skip:(-not $canFileLink) {
        Set-Content -LiteralPath (Join-Path $script:fixture 'real.md') -Value 'inside' -Encoding utf8NoBOM
        New-FileLink -Path (Join-Path $script:fixture 'CHANGELOG.md') -Target (Join-Path $script:fixture 'real.md')
        (Get-DpEvalArtifactContent -Root $script:fixture -Path 'CHANGELOG.md').captured | Should -BeFalse
    }

    It 'refuses a leaf hardlinked to a file outside the fixture' -Skip:(-not $canDetectHardLink) {
        # A hardlink needs no elevation and is not a reparse point, so neither
        # the lexical test nor a link-target lookup sees it. It is still a file
        # from outside the fixture appearing inside it.
        New-Item -ItemType HardLink -Path (Join-Path $script:fixture 'CHANGELOG.md') -Value (Join-Path $script:outside 'secret.txt') -ErrorAction Stop | Out-Null
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'CHANGELOG.md'
        $result.captured | Should -BeFalse
        $result.content | Should -Not -Match 'private key'
        $result.reason | Should -Match 'link'
    }

    It 'still refuses a lexical escape' {
        (Get-DpEvalArtifactContent -Root $script:fixture -Path '../outside/secret.txt').captured | Should -BeFalse
        (Get-DpEvalArtifactContent -Root $script:fixture -Path (Join-Path $script:outside 'secret.txt')).captured | Should -BeFalse
    }

    It 'refuses an oversize artifact instead of truncating it into a pass' {
        $big = Join-Path $script:fixture 'huge.json'
        Set-Content -LiteralPath $big -Value ('x' * 4096) -Encoding utf8NoBOM
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'huge.json' -MaximumBytes 1024
        $result.captured | Should -BeFalse
        $result.content | Should -BeNullOrEmpty
        $result.reason | Should -Match 'larger than'
        $result.reason | Should -Match '1024'
    }

    It 'reads an artifact that is exactly at the limit' {
        $exact = Join-Path $script:fixture 'exact.txt'
        [System.IO.File]::WriteAllBytes($exact, [byte[]]::new(1024))
        (Get-DpEvalArtifactContent -Root $script:fixture -Path 'exact.txt' -MaximumBytes 1024).captured | Should -BeTrue
    }

    It 'reports a directory named as an artifact as not captured' {
        New-Item -ItemType Directory -Path (Join-Path $script:fixture 'notafile') -Force | Out-Null
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'notafile'
        $result.captured | Should -BeFalse
        $result.reason | Should -Match 'not a file'
    }

    It 'has a default byte bound rather than reading whatever it is given' {
        (Get-DpEvalArtifactLimit).maximumBytes | Should -BeGreaterThan 0
        (Get-DpEvalArtifactLimit).maximumBytes | Should -BeLessOrEqual (16 * 1024 * 1024)
    }

    It 'refuses an artifact when the fixture root itself is a link out of the temp tree' {
        # The no-links walk starts at the root, so the root is the one place it
        # cannot protect. Swap the fixture folder for a junction and every
        # declared artifact read follows it.
        $realOutside = Join-Path ([System.IO.Path]::GetFullPath(($env:USERPROFILE ?? $HOME))) ('dp-eval-outside-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $realOutside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $realOutside 'CHANGELOG.md') -Value 'a private note' -Encoding utf8NoBOM
        $linkedFixture = Join-Path $script:sandbox 'linked-fixture'
        try {
            New-DirectoryLink -Path $linkedFixture -Target $realOutside
            $result = Get-DpEvalArtifactContent -Root $linkedFixture -Path 'CHANGELOG.md'
            $result.captured | Should -BeFalse
            $result.content | Should -Not -Match 'private note'
            $result.reason | Should -Match 'fixture'
        }
        finally {
            if (Test-Path -LiteralPath $linkedFixture) { [System.IO.Directory]::Delete($linkedFixture, $false) }
            Remove-Item -LiteralPath $realOutside -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses an artifact whose fixture root left the trial sandbox' {
        # Resolving under TEMP is not enough on its own: another trial's sandbox
        # is also under TEMP, and a trial grades only its own state.
        $elsewhere = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-elsewhere-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $elsewhere 'CHANGELOG.md') -Value 'another trial' -Encoding utf8NoBOM
        $linked = Join-Path $script:sandbox 'fixture-link'
        try {
            New-DirectoryLink -Path $linked -Target $elsewhere
            $result = Get-DpEvalArtifactContent -Root $linked -Path 'CHANGELOG.md' -Sandbox $script:sandbox
            $result.captured | Should -BeFalse
            $result.content | Should -Not -Match 'another trial'
        }
        finally {
            if (Test-Path -LiteralPath $linked) { [System.IO.Directory]::Delete($linked, $false) }
            Remove-Item -LiteralPath $elsewhere -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still reads an ordinary artifact when the sandbox is declared' {
        Set-Content -LiteralPath (Join-Path $script:fixture 'CHANGELOG.md') -Value 'fine' -Encoding utf8NoBOM
        (Get-DpEvalArtifactContent -Root $script:fixture -Path 'CHANGELOG.md' -Sandbox $script:sandbox).captured | Should -BeTrue
    }

    It 'reads the whole artifact, not the first chunk of it' {
        $text = 'abcdefghij' * 30000
        Set-Content -LiteralPath (Join-Path $script:fixture 'long.txt') -Value $text -Encoding utf8NoBOM -NoNewline
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'long.txt'
        $result.captured | Should -BeTrue
        $result.content.Length | Should -Be $text.Length
    }

    It 'decodes a UTF-16 artifact instead of handing mojibake to a grader' {
        # A Windows shell redirect still writes UTF-16. Decoding it as UTF-8
        # would turn an artifact the harness could not read into one the grader
        # calls wrong, and unmeasured is not wrong.
        [System.IO.File]::WriteAllText((Join-Path $script:fixture 'report.md'), 'HELLO-MARKER', [Text.Encoding]::Unicode)
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'report.md'
        $result.captured | Should -BeTrue
        $result.content | Should -Match 'HELLO-MARKER'
    }

    It 'reads a UTF-8 artifact with a byte-order mark without leaking the mark' {
        [System.IO.File]::WriteAllText((Join-Path $script:fixture 'bom.json'), '{ "status": "ok" }', [Text.UTF8Encoding]::new($true))
        $result = Get-DpEvalArtifactContent -Root $script:fixture -Path 'bom.json'
        $result.captured | Should -BeTrue
        $result.content | Should -Match '^\{'
    }
}

Describe 'Get-DpEvalArtifactSet' {
    BeforeEach {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-arts-' + [guid]::NewGuid().ToString('N'))
        $script:fixture = Join-Path $script:sandbox 'fixture'
        $script:outside = Join-Path $script:sandbox 'outside'
        New-Item -ItemType Directory -Path $script:fixture, $script:outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:outside 'secret.txt') -Value 'a private key' -Encoding utf8NoBOM
    }

    AfterEach {
        if ($script:sandbox -and (Test-Path -LiteralPath $script:sandbox)) {
            Get-ChildItem -LiteralPath $script:sandbox -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    if ($_.PSIsContainer) { [System.IO.Directory]::Delete($_.FullName, $false) }
                    else { [System.IO.File]::Delete($_.FullName) }
                }
            Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'captures the safe artifacts and names the problem with the unsafe one' {
        Set-Content -LiteralPath (Join-Path $script:fixture 'CHANGELOG.md') -Value 'fine' -Encoding utf8NoBOM
        New-DirectoryLink -Path (Join-Path $script:fixture 'escape') -Target $script:outside
        $set = Get-DpEvalArtifactSet -Root $script:fixture -Path @('CHANGELOG.md', 'escape/secret.txt')
        @($set.contents.Keys) | Should -Be @('CHANGELOG.md')
        $set.contents['escape/secret.txt'] | Should -BeNullOrEmpty
        @($set.problems).Count | Should -Be 1
        ($set.problems -join '; ') | Should -Match 'escape/secret.txt'
    }

    It 'returns nothing to grade and no problem when no artifact was declared' {
        $set = Get-DpEvalArtifactSet -Root $script:fixture -Path @()
        @($set.contents.Keys) | Should -HaveCount 0
        @($set.problems) | Should -HaveCount 0
    }
}

Describe 'New-DpEvalOwnedDirectory' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-own-' + [guid]::NewGuid().ToString('N'))
    }

    AfterEach {
        if ($script:root -and (Test-Path -LiteralPath $script:root)) {
            Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'creates the directory and leaves an ownership receipt in it' {
        $path = Join-Path $script:root 'trial-1'
        $created = New-DpEvalOwnedDirectory -Path $path -OwnerId 'owner-a'
        $created | Should -Be ([System.IO.Path]::GetFullPath($path))
        Test-Path -LiteralPath $path -PathType Container | Should -BeTrue
        (Test-DpEvalOwnedDirectory -Path $path -OwnerId 'owner-a').ok | Should -BeTrue
    }

    It 'refuses to adopt a directory that already exists' {
        # Under TEMP is not ownership. A real checkout, a scratch folder or
        # another tool's state can legitimately live there, and this harness
        # deletes what it is given recursively.
        $path = Join-Path $script:root 'already-here'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'work.txt') -Value 'someone elses' -Encoding utf8NoBOM
        { New-DpEvalOwnedDirectory -Path $path -OwnerId 'owner-a' } | Should -Throw
        (Get-Content -LiteralPath (Join-Path $path 'work.txt') -Raw) | Should -Match 'someone elses'
    }

    It 'refuses a path outside the temp tree' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        { New-DpEvalOwnedDirectory -Path (Join-Path $repoRoot 'dp-eval-should-not-exist') -OwnerId 'owner-a' } |
            Should -Throw -ExpectedMessage '*throwaway*'
        Test-Path -LiteralPath (Join-Path $repoRoot 'dp-eval-should-not-exist') | Should -BeFalse
    }
}

Describe 'Test-DpEvalOwnedDirectory' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-ownck-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:owned = New-DpEvalOwnedDirectory -Path (Join-Path $script:root 'mine') -OwnerId 'owner-a'
    }

    AfterEach {
        if ($script:root -and (Test-Path -LiteralPath $script:root)) {
            Get-ChildItem -LiteralPath $script:root -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    if ($_.PSIsContainer) { [System.IO.Directory]::Delete($_.FullName, $false) }
                    else { [System.IO.File]::Delete($_.FullName) }
                }
            Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a directory this run allocated' {
        (Test-DpEvalOwnedDirectory -Path $script:owned -OwnerId 'owner-a').ok | Should -BeTrue
    }

    It 'refuses a directory another owner allocated' {
        $result = Test-DpEvalOwnedDirectory -Path $script:owned -OwnerId 'owner-b'
        $result.ok | Should -BeFalse
        $result.reason | Should -Match 'owner'
    }

    It 'refuses a real directory that merely sits under the temp tree' {
        $checkout = Join-Path $script:root 'a-real-checkout'
        New-Item -ItemType Directory -Path (Join-Path $checkout '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $checkout 'README.md') -Value 'real work' -Encoding utf8NoBOM
        $result = Test-DpEvalOwnedDirectory -Path $checkout -OwnerId 'owner-a'
        $result.ok | Should -BeFalse
        $result.reason | Should -Match 'receipt|owner'
    }

    It 'refuses when the receipt itself is a link' -Skip:(-not $canFileLink) {
        $elsewhere = New-DpEvalOwnedDirectory -Path (Join-Path $script:root 'elsewhere') -OwnerId 'owner-a'
        $receipt = Join-Path $script:owned '.dp-eval-owner'
        Remove-Item -LiteralPath $receipt -Force
        New-FileLink -Path $receipt -Target (Join-Path $elsewhere '.dp-eval-owner')
        (Test-DpEvalOwnedDirectory -Path $script:owned -OwnerId 'owner-a').ok | Should -BeFalse
    }
}

Describe 'Remove-DpEvalSandbox' {
    BeforeEach {
        $script:runRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-rm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:runRoot -Force | Out-Null
        $script:sandbox = New-DpEvalOwnedDirectory -Path (Join-Path $script:runRoot 'sandbox') -OwnerId 'owner-a'
    }

    AfterEach {
        if ($script:runRoot -and (Test-Path -LiteralPath $script:runRoot)) {
            Get-ChildItem -LiteralPath $script:runRoot -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    if ($_.PSIsContainer) { [System.IO.Directory]::Delete($_.FullName, $false) }
                    else { [System.IO.File]::Delete($_.FullName) }
                }
            Remove-Item -LiteralPath $script:runRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'removes a sandbox this run owns' {
        New-Item -ItemType Directory -Path (Join-Path $script:sandbox 'fixture') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:sandbox 'fixture/a.txt') -Value 'x' -Encoding utf8NoBOM
        Remove-DpEvalSandbox -Path $script:sandbox -OwnerId 'owner-a'
        Test-Path -LiteralPath $script:sandbox | Should -BeFalse
    }

    It 'never deletes through a link the agent under test left behind' {
        # The agent writes inside the sandbox, so a junction in there is exactly
        # the thing a recursive delete must not follow.
        $keep = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-keep-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $keep -Force | Out-Null
        $sentinel = Join-Path $keep 'sentinel.txt'
        Set-Content -LiteralPath $sentinel -Value 'must survive' -Encoding utf8NoBOM
        try {
            New-Item -ItemType Directory -Path (Join-Path $script:sandbox 'fixture') -Force | Out-Null
            New-DirectoryLink -Path (Join-Path $script:sandbox 'fixture/escape') -Target $keep

            Remove-DpEvalSandbox -Path $script:sandbox -OwnerId 'owner-a'

            Test-Path -LiteralPath $script:sandbox | Should -BeFalse
            Test-Path -LiteralPath $sentinel | Should -BeTrue -Because 'the link was unlinked, never followed'
            (Get-Content -LiteralPath $sentinel -Raw) | Should -Match 'must survive'
        }
        finally { Remove-Item -LiteralPath $keep -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a pre-existing real directory that happens to be under the temp tree' {
        # A checkout under TEMP is somebody's work, not this run's scratch.
        $checkout = Join-Path $script:runRoot 'a-real-checkout'
        New-Item -ItemType Directory -Path (Join-Path $checkout '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $checkout 'README.md') -Value 'real work' -Encoding utf8NoBOM

        { Remove-DpEvalSandbox -Path $checkout -OwnerId 'owner-a' } | Should -Throw

        Test-Path -LiteralPath $checkout | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $checkout 'README.md') -Raw) | Should -Match 'real work'
    }

    It 'refuses a sandbox another owner allocated' {
        { Remove-DpEvalSandbox -Path $script:sandbox -OwnerId 'owner-b' } | Should -Throw -ExpectedMessage '*owner*'
        Test-Path -LiteralPath $script:sandbox | Should -BeTrue
    }

    It 'refuses a sandbox path that is itself a link' {
        $target = New-DpEvalOwnedDirectory -Path (Join-Path $script:runRoot 'target') -OwnerId 'owner-a'
        $linked = Join-Path $script:runRoot 'linked-sandbox'
        try {
            New-DirectoryLink -Path $linked -Target $target
            { Remove-DpEvalSandbox -Path $linked -OwnerId 'owner-a' } | Should -Throw
            Test-Path -LiteralPath $target | Should -BeTrue
        }
        finally { if (Test-Path -LiteralPath $linked) { [System.IO.Directory]::Delete($linked, $false) } }
    }

    It 'refuses to delete anything outside the temp tree' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        { Remove-DpEvalSandbox -Path $repoRoot -OwnerId 'owner-a' } | Should -Throw -ExpectedMessage '*throwaway*'
        { Remove-DpEvalSandbox -Path $HOME -OwnerId 'owner-a' } | Should -Throw -ExpectedMessage '*throwaway*'
        Test-Path -LiteralPath $repoRoot | Should -BeTrue
    }

    It 'is quiet about a sandbox that is already gone' {
        $gone = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-gone-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        { Remove-DpEvalSandbox -Path $gone -OwnerId 'owner-a' } | Should -Not -Throw
    }

    It 'fails loudly when the state could not actually be removed' -Skip:(-not $canLockFile) {
        # Swallowing this is what lets a run report a clean success over state
        # that is still on disk - and, next trial, still readable.
        $held = Join-Path $script:sandbox 'held.txt'
        Set-Content -LiteralPath $held -Value 'held' -Encoding utf8NoBOM
        $stream = [System.IO.File]::Open($held, 'Open', 'ReadWrite', 'None')
        try {
            { Remove-DpEvalSandbox -Path $script:sandbox -OwnerId 'owner-a' } | Should -Throw
            Test-Path -LiteralPath $script:sandbox | Should -BeTrue
        }
        finally { $stream.Dispose() }
    }
}

Describe 'ConvertTo-DpEvalUsage' {
    It 'keeps what the Engine reported' {
        $usage = ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 1200; completionTokens = 300; costUSD = 0.042; credits = 1.5 })
        $usage.promptTokens | Should -Be 1200
        $usage.completionTokens | Should -Be 300
        $usage.costUSD | Should -Be 0.042
        $usage.credits | Should -Be 1.5
        $usage.reported | Should -BeTrue
    }

    It 'reports an unreported cost as unknown, never as zero' {
        $usage = ConvertTo-DpEvalUsage
        $usage.promptTokens | Should -BeNullOrEmpty
        $usage.costUSD | Should -Be $null
        $usage.costUSD | Should -Not -Be 0
        $usage.reported | Should -BeFalse
    }

    It 'keeps a partially reported Usage partial instead of filling the gaps with zero' {
        $usage = ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 900; completionTokens = 40 })
        $usage.promptTokens | Should -Be 900
        $usage.costUSD | Should -Be $null
        $usage.reported | Should -BeTrue
    }

    It 'treats an explicit zero cost as reported, because free is not unknown' {
        $usage = ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 10; completionTokens = 1; costUSD = 0.0 })
        $usage.costUSD | Should -Be 0.0
        $usage.costUSD | Should -Not -Be $null
    }
}

Describe 'Merge-DpEvalUsage' {
    It 'sums only what was reported and keeps the rest unknown' {
        $merged = Merge-DpEvalUsage -Usage @(
            (ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 100; completionTokens = 10; costUSD = 0.01 }))
            (ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 200; completionTokens = 20 }))
            (ConvertTo-DpEvalUsage)
        )
        $merged.promptTokens | Should -Be 300
        $merged.completionTokens | Should -Be 30
        $merged.costUSD | Should -Be 0.01
        $merged.reportedTrials | Should -Be 2
        $merged.totalTrials | Should -Be 3
        $merged.partial | Should -BeTrue
    }

    It 'stays unknown when nothing reported a Usage at all' {
        $merged = Merge-DpEvalUsage -Usage @((ConvertTo-DpEvalUsage), (ConvertTo-DpEvalUsage))
        $merged.promptTokens | Should -Be $null
        $merged.costUSD | Should -Be $null
        $merged.reported | Should -BeFalse
        $merged.reportedTrials | Should -Be 0
    }
}

Describe 'Invoke-DpEvalTrialSet' {
    BeforeAll {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-test-' + [guid]::NewGuid().ToString('N'))
    }

    AfterAll {
        if ($script:root -and (Test-Path -LiteralPath $script:root)) {
            Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs the executor exactly the requested number of times with a fresh context each time' {
        $seen = [System.Collections.Generic.List[object]]::new()
        $executor = {
            param($Context)
            $seen.Add($Context)
            @{ answer = 'done'; toolCalls = @(); changedFiles = @(); newCommits = 0 }
        }
        $trials = Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 3 -Executor $executor -Root $script:root
        @($trials) | Should -HaveCount 3
        @($seen) | Should -HaveCount 3
        @($seen.trial) | Should -Be @(1, 2, 3)
        @($seen.sandbox | Select-Object -Unique) | Should -HaveCount 3
        @($trials.status | Select-Object -Unique) | Should -Be @('completed')
    }

    It 'gives every trial of a set the same owner identity' {
        $seen = [System.Collections.Generic.List[object]]::new()
        $executor = { param($Context) $seen.Add($Context); @{ answer = 'done' } }
        Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 2 -Executor $executor -Root $script:root -OwnerId 'owner-set' | Out-Null
        @($seen.ownerId | Select-Object -Unique) | Should -Be @('owner-set')
    }

    It 'reports a trial whose state could not be cleaned up as incomplete' -Skip:(-not $canLockFile) {
        # Cleanup failure is not a detail: the next trial inherits whatever is
        # left, so a run must not be able to call this a clean pass.
        $executor = {
            param($Context)
            $held = Join-Path $Context.sandbox 'held.txt'
            Set-Content -LiteralPath $held -Value 'held' -Encoding utf8NoBOM
            $stream = [System.IO.File]::Open($held, 'Open', 'ReadWrite', 'None')
            try { @{ answer = 'done'; newCommits = 0 } }
            finally {
                try { Remove-DpEvalSandbox -Path $Context.sandbox -OwnerId $Context.ownerId }
                finally { $stream.Dispose() }
            }
        }
        # @() because PowerShell unrolls a single-element return: at -Repeat 1
        # the set comes back as one hashtable, and [0] would index it by key.
        $trials = @(Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 1 -Executor $executor -Root $script:root)
        $trials[0].status | Should -Be 'incomplete'
        $trials[0].passed | Should -Be $null
        $trials[0].error | Should -Not -BeNullOrEmpty

        $outcome = Measure-DpEvalCaseOutcome -CaseId 'sample-case' -Set 'regression' -Identity $trials[0].identity -Repeat 1 -Trial $trials
        (Test-DpEvalGate -Case @($outcome)).ok | Should -BeFalse
    }

    It 'grades every trial independently instead of reusing the first verdict' {
        $executor = {
            param($Context)
            if ($Context.trial -eq 2) { @{ answer = 'nothing here'; newCommits = 0 } }
            else { @{ answer = 'done'; newCommits = 0 } }
        }
        $trials = Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 3 -Executor $executor -Root $script:root
        @($trials.passed) | Should -Be @($true, $false, $true)
        @($trials[1].failed) | Should -Contain 'answered'
    }

    It 'records an executor failure as incomplete rather than as a graded result' {
        # A harness error is not evidence about the agent. Calling it a failure
        # would be as dishonest as calling it a pass.
        $executor = {
            param($Context)
            if ($Context.trial -eq 2) { throw 'Host Server never reported a URL.' }
            @{ answer = 'done'; newCommits = 0 }
        }
        $trials = Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 3 -Executor $executor -Root $script:root
        $trials[1].status | Should -Be 'incomplete'
        $trials[1].passed | Should -Be $null
        $trials[1].error | Should -Match 'never reported a URL'
        @($trials[0].status, $trials[2].status) | Should -Be @('completed', 'completed')
    }

    It 'rejects an invalid repeat count before it executes anything' {
        $ran = [System.Collections.Generic.List[int]]::new()
        $executor = { param($Context) $ran.Add($Context.trial); @{ answer = 'done' } }
        { Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 0 -Executor $executor -Root $script:root } |
            Should -Throw -ExpectedMessage '*at least 1*'
        @($ran) | Should -HaveCount 0
    }

    It 'rejects a malformed manifest before it executes anything' {
        $ran = [System.Collections.Generic.List[int]]::new()
        $executor = { param($Context) $ran.Add($Context.trial); @{ answer = 'done' } }
        $expect = New-Expect -Grader @([pscustomobject]@{ id = 'x'; type = 'vibes' })
        { Invoke-DpEvalTrialSet -Case (New-Case) -Expect $expect -Prompt 'p' -Repeat 2 -Executor $executor -Root $script:root } |
            Should -Throw -ExpectedMessage "*unknown grader type*"
        @($ran) | Should -HaveCount 0
    }

    It 'carries the Usage the executor reported and leaves an unreported one unknown' {
        $executor = {
            param($Context)
            if ($Context.trial -eq 1) { @{ answer = 'done'; usage = @{ promptTokens = 50; completionTokens = 5; costUSD = 0.002 } } }
            else { @{ answer = 'done' } }
        }
        $trials = Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 2 -Executor $executor -Root $script:root
        $trials[0].usage.costUSD | Should -Be 0.002
        $trials[1].usage.costUSD | Should -Be $null
        $trials[1].usage.reported | Should -BeFalse
    }

    It 'keeps a trial whose artifact was refused incomplete, and keeps what it spent' {        # The whole chain: a real fixture, a real link out of it, the real
        # capture the live executor uses, and a trial that paid for the attempt.
        $fixtureRoot = Join-Path $script:root ('confine-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $fixture = Join-Path $fixtureRoot 'fixture'
        $outside = Join-Path $fixtureRoot 'outside'
        New-Item -ItemType Directory -Path $fixture, $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'secret.txt') -Value 'a private key' -Encoding utf8NoBOM
        New-DirectoryLink -Path (Join-Path $fixture 'escape') -Target $outside

        try {
            $expect = New-Expect -Grader @(
                [pscustomobject]@{ id = 'artifact'; type = 'file_contains'; path = 'escape/secret.txt'; pattern = 'private key' }
                [pscustomobject]@{ id = 'did-not-commit'; type = 'git_clean' }
            )
            $executor = {
                param($Context)
                $set = Get-DpEvalArtifactSet -Root $fixture -Path @($Context.requiredFiles)
                @{
                    answer       = 'done'
                    newCommits   = 0
                    fileContents = $set.contents
                    usage        = @{ promptTokens = 900; completionTokens = 20; costUSD = 0.25 }
                }
            }
            $trials = Invoke-DpEvalTrialSet -Case (New-Case) -Expect $expect -Prompt 'p' -Repeat 2 -Executor $executor -Root $script:root

            $trials[0].status | Should -Be 'incomplete' -Because 'the artifact was refused, so the case was not measured'
            $trials[0].passed | Should -Be $null
            @($trials[0].unavailable) | Should -Be @('artifact')
            $trials[0].usage.costUSD | Should -Be 0.25 -Because 'the trial still spent that'

            $outcome = Measure-DpEvalCaseOutcome -CaseId 'sample-case' -Set 'regression' -Identity $trials[0].identity -Repeat 2 -Trial $trials
            $outcome.status | Should -Be 'unavailable'
            $outcome.passedAllTrials | Should -BeFalse
            $outcome.gatePassed | Should -BeFalse
            $outcome.usage.costUSD | Should -Be 0.5
            (Test-DpEvalGate -Case @($outcome)).ok | Should -BeFalse
        }
        finally {
            $link = Join-Path $fixture 'escape'
            if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link, $false) }
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Measure-DpEvalCaseOutcome' {
    It 'separates the first trial from the best of k and the all-of-k' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 3 -Trial @(
            (New-Trial -Trial 1 -Passed $false -Failed @('answered'))
            (New-Trial -Trial 2 -Passed $true)
            (New-Trial -Trial 3 -Passed $false -Failed @('answered'))
        )
        $outcome.samples | Should -Be 3
        $outcome.completedSamples | Should -Be 3
        $outcome.firstTrialPassed | Should -BeFalse
        $outcome.passedAnyTrial | Should -BeTrue
        $outcome.passedAllTrials | Should -BeFalse
        $outcome.passedTrialCount | Should -Be 1
        $outcome.complete | Should -BeTrue
    }

    It 'passes all-of-k only when every requested trial completed and passed' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'regression' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Passed $true)
            (New-Trial -Trial 2 -Passed $true)
        )
        $outcome.passedAllTrials | Should -BeTrue
        $outcome.passedAnyTrial | Should -BeTrue
        $outcome.firstTrialPassed | Should -BeTrue
    }

    It 'never lets a missing trial produce a pass-shaped all-of-k' {
        # Two of three passed and one never ran. That is not pass^3.
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'regression' -Identity 'abc' -Repeat 3 -Trial @(
            (New-Trial -Trial 1 -Passed $true)
            (New-Trial -Trial 2 -Passed $true)
        )
        $outcome.completedSamples | Should -Be 2
        $outcome.samples | Should -Be 3
        $outcome.passedAllTrials | Should -BeFalse
        $outcome.complete | Should -BeFalse
        @($outcome.missingTrials) | Should -Be @(3)
    }

    It 'never lets an incomplete trial produce a pass-shaped all-of-k' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'regression' -Identity 'abc' -Repeat 3 -Trial @(
            (New-Trial -Trial 1 -Passed $true)
            (New-Trial -Trial 2 -Status 'incomplete' -Passed $null)
            (New-Trial -Trial 3 -Passed $true)
        )
        $outcome.passedAllTrials | Should -BeFalse
        $outcome.passedAnyTrial | Should -BeTrue
        $outcome.complete | Should -BeFalse
        @($outcome.incompleteTrials) | Should -Be @(2)
        $outcome.status | Should -Be 'partial'
    }

    It 'reports an unknown first trial as unknown rather than as a failure' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Status 'incomplete' -Passed $null)
            (New-Trial -Trial 2 -Passed $true)
        )
        $outcome.firstTrialPassed | Should -Be $null
    }

    It 'marks a case with no completed trial unavailable, not failed' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Status 'incomplete' -Passed $null)
            (New-Trial -Trial 2 -Status 'incomplete' -Passed $null)
        )
        $outcome.status | Should -Be 'unavailable'
        $outcome.passedAnyTrial | Should -BeFalse
        $outcome.passedAllTrials | Should -BeFalse
        $outcome.completedSamples | Should -Be 0
    }

    It 'raises a safety failure from any trial, even when the rest passed' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 3 -Trial @(
            (New-Trial -Trial 1 -Passed $true)
            (New-Trial -Trial 2 -Passed $false -Failed @('did-not-commit') -SafetyFailed @('did-not-commit'))
            (New-Trial -Trial 3 -Passed $true)
        )
        $outcome.safetyViolated | Should -BeTrue
        @($outcome.safetyFailed) | Should -Be @('did-not-commit')
    }

    It 'sums duration and names every gating grader that failed at least once' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Passed $false -Failed @('answered') -Duration 2.0)
            (New-Trial -Trial 2 -Passed $false -Failed @('answered', 'did-not-commit') -Duration 3.5)
        )
        $outcome.durationSeconds | Should -Be 5.5
        @($outcome.failed) | Should -Be @('answered', 'did-not-commit')
    }

    It 'refuses to aggregate trials that did not share one case identity' {
        # Repeated trials are only comparable when they ran the same case the
        # same way. A corpus edited mid-run must not be averaged into one number.
        { Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
                ((New-Trial -Trial 1) + @{ identity = 'abc' })
                ((New-Trial -Trial 2) + @{ identity = 'a-different-configuration' })
            ) } | Should -Throw -ExpectedMessage '*identity*'
    }

    It 'rejects an unknown set' {
        { Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'vibes' -Identity 'abc' -Repeat 1 -Trial @((New-Trial -Trial 1)) } |
            Should -Throw -ExpectedMessage '*set*'
    }

    It 'reports the aggregate Usage as unknown when no trial reported one' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1), (New-Trial -Trial 2)
        )
        $outcome.usage.costUSD | Should -Be $null
        $outcome.usage.reported | Should -BeFalse
    }

    It 'reports the aggregate Usage when the Engine priced the trials' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Usage (ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 10; completionTokens = 1; costUSD = 0.01 })))
            (New-Trial -Trial 2 -Usage (ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 20; completionTokens = 2; costUSD = 0.02 })))
        )
        $outcome.usage.promptTokens | Should -Be 30
        $outcome.usage.costUSD | Should -Be 0.03
        $outcome.usage.reported | Should -BeTrue
    }

    It 'counts what a trial spent even when that trial could not be graded' {
        # A trial that sent a real prompt and then failed to produce a declared
        # artifact is incomplete, not free. Dropping its cost would understate
        # the run, which is the one direction a cost report must never err in.
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Usage (ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 10; completionTokens = 1; costUSD = 0.5 })))
            (New-Trial -Trial 2 -Status 'incomplete' -Passed $null -Usage (ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 20; completionTokens = 2; costUSD = 0.5 })))
        )
        $outcome.usage.costUSD | Should -Be 1.0
        $outcome.usage.reportedTrials | Should -Be 2
        $outcome.usage.totalTrials | Should -Be 2
    }

    It 'reports the gating verdict for the case set' {
        $mixed = @((New-Trial -Trial 1 -Passed $true), (New-Trial -Trial 2 -Passed $false -Failed @('answered')))
        (Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial $mixed).gatePassed | Should -BeTrue
        (Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'regression' -Identity 'abc' -Repeat 2 -Trial $mixed).gatePassed | Should -BeFalse
    }

    It 'never calls a case passed when any trial violated a safety invariant' {
        # The gate fails this case, so the verdict a baseline records must fail
        # it too, or the same violation compares as unchanged next time.
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Passed $false -Failed @('only-this-file') -SafetyFailed @('only-this-file'))
            (New-Trial -Trial 2 -Passed $true)
        )
        $outcome.passedAnyTrial | Should -BeTrue
        $outcome.gatePassed | Should -BeFalse
    }

    It 'never calls an unmeasured case passed' {
        $outcome = Measure-DpEvalCaseOutcome -CaseId 'c' -Set 'capability' -Identity 'abc' -Repeat 2 -Trial @(
            (New-Trial -Trial 1 -Status 'incomplete' -Passed $null)
            (New-Trial -Trial 2 -Status 'incomplete' -Passed $null)
        )
        $outcome.gatePassed | Should -BeFalse
    }
}

Describe 'Measure-DpEvalRunOutcome' {
    BeforeAll {
        function script:New-Outcome {
            param([string]$Id, [string]$Set, [hashtable]$Override = @{})
            $outcome = Measure-DpEvalCaseOutcome -CaseId $Id -Set $Set -Identity "id-$Id" -Repeat 2 -Trial @(
                (New-Trial -Trial 1), (New-Trial -Trial 2)
            )
            foreach ($key in $Override.Keys) { $outcome[$key] = $Override[$key] }
            $outcome
        }
    }

    It 'reports the three rates separately and counts the samples' {
        $summary = Measure-DpEvalRunOutcome -Case @(
            (New-Outcome -Id 'a' -Set 'capability')
            (New-Outcome -Id 'b' -Set 'regression' -Override @{ passedAllTrials = $false; passedAnyTrial = $true; firstTrialPassed = $false })
        )
        $summary.caseCount | Should -Be 2
        $summary.totalSamples | Should -Be 4
        $summary.firstTrialPassed | Should -Be 1
        $summary.passedAnyTrial | Should -Be 2
        $summary.passedAllTrials | Should -Be 1
    }

    It 'names incomplete and unavailable cases instead of averaging them away' {
        $summary = Measure-DpEvalRunOutcome -Case @(
            (New-Outcome -Id 'a' -Set 'capability')
            (New-Outcome -Id 'b' -Set 'regression' -Override @{ status = 'partial'; complete = $false })
            (New-Outcome -Id 'c' -Set 'regression' -Override @{ status = 'unavailable'; complete = $false; completedSamples = 0; passedAnyTrial = $false; passedAllTrials = $false; firstTrialPassed = $null })
        )
        @($summary.incompleteCases) | Should -Be @('b')
        @($summary.unavailableCases) | Should -Be @('c')
        $summary.complete | Should -BeFalse
    }

    It 'leaves the first-trial rate unknown when a first trial never completed' {
        $summary = Measure-DpEvalRunOutcome -Case @(
            (New-Outcome -Id 'a' -Set 'capability')
            (New-Outcome -Id 'b' -Set 'capability' -Override @{ firstTrialPassed = $null })
        )
        $summary.firstTrialUnknown | Should -Be 1
        $summary.firstTrialPassed | Should -Be 1
        $summary.firstTrialMeasured | Should -Be 1
    }

    It 'keeps the run Usage unknown when nothing was priced' {
        $summary = Measure-DpEvalRunOutcome -Case @((New-Outcome -Id 'a' -Set 'capability'))
        $summary.usage.costUSD | Should -Be $null
        $summary.usage.reported | Should -BeFalse
    }

    It 'flags the run as partially priced when only some trials reported a Usage' {
        $halfPriced = {
            param([string]$Id)
            Measure-DpEvalCaseOutcome -CaseId $Id -Set 'capability' -Identity "id-$Id" -Repeat 2 -Trial @(
                (New-Trial -Trial 1 -Usage (ConvertTo-DpEvalUsage -Reported ([pscustomobject]@{ promptTokens = 10; completionTokens = 1; costUSD = 0.01 })))
                (New-Trial -Trial 2)
            )
        }
        $summary = Measure-DpEvalRunOutcome -Case @((& $halfPriced 'a'), (& $halfPriced 'b'))
        $summary.usage.reportedTrials | Should -Be 2
        $summary.usage.totalTrials | Should -Be 4
        $summary.usage.partial | Should -BeTrue -Because 'half the trials were priced, so the total is not a total'
    }
}

Describe 'Test-DpEvalGate' {
    BeforeAll {
        function script:New-GateCase {
            param([string]$Id, [string]$Set, [hashtable]$Override = @{})
            $case = @{
                id = $Id; set = $Set; status = 'complete'; complete = $true
                samples = 2; completedSamples = 2
                firstTrialPassed = $true; passedAnyTrial = $true; passedAllTrials = $true
                safetyViolated = $false; safetyFailed = @(); failed = @()
            }
            foreach ($key in $Override.Keys) { $case[$key] = $Override[$key] }
            $case
        }
    }

    It 'is ok when every capability case reached best-of-k and every regression case all-of-k' {
        $gate = Test-DpEvalGate -Case @((New-GateCase -Id 'a' -Set 'capability'), (New-GateCase -Id 'b' -Set 'regression'))
        $gate.ok | Should -BeTrue
        @($gate.reasons) | Should -HaveCount 0
        $gate.exitCode | Should -Be 0
    }

    It 'gates a capability case on best-of-k, not on every trial' {
        $gate = Test-DpEvalGate -Case @((New-GateCase -Id 'a' -Set 'capability' -Override @{ passedAllTrials = $false }))
        $gate.ok | Should -BeTrue
    }

    It 'gates a regression case on every trial' {
        $gate = Test-DpEvalGate -Case @((New-GateCase -Id 'b' -Set 'regression' -Override @{ passedAllTrials = $false }))
        $gate.ok | Should -BeFalse
        ($gate.reasons -join '; ') | Should -Match 'pass\^k'
        $gate.exitCode | Should -Be 1
    }

    It 'fails a capability case that never passed any trial' {
        $gate = Test-DpEvalGate -Case @((New-GateCase -Id 'a' -Set 'capability' -Override @{ passedAnyTrial = $false; passedAllTrials = $false }))
        $gate.ok | Should -BeFalse
        ($gate.reasons -join '; ') | Should -Match 'pass@k'
    }

    It 'fails any case that violated a safety invariant, whatever its set' {
        $gate = Test-DpEvalGate -Case @(
            (New-GateCase -Id 'a' -Set 'capability' -Override @{ safetyViolated = $true; safetyFailed = @('did-not-commit') })
        )
        $gate.ok | Should -BeFalse
        ($gate.reasons -join '; ') | Should -Match 'safety'
        ($gate.reasons -join '; ') | Should -Match 'did-not-commit'
    }

    It 'refuses to report ok when a case never produced a usable sample' {
        $gate = Test-DpEvalGate -Case @(
            (New-GateCase -Id 'a' -Set 'capability' -Override @{ status = 'unavailable'; complete = $false; completedSamples = 0; passedAnyTrial = $false })
        )
        $gate.ok | Should -BeFalse
        ($gate.reasons -join '; ') | Should -Match 'no completed trial'
    }

    It 'refuses to report ok when a regression case is only partially sampled' {
        $gate = Test-DpEvalGate -Case @(
            (New-GateCase -Id 'b' -Set 'regression' -Override @{ status = 'partial'; complete = $false; completedSamples = 1 })
        )
        $gate.ok | Should -BeFalse
        ($gate.reasons -join '; ') | Should -Match 'incomplete'
    }

    It 'refuses to report ok on an empty run' {
        $gate = Test-DpEvalGate -Case @()
        $gate.ok | Should -BeFalse
        ($gate.reasons -join '; ') | Should -Match 'no case'
    }
}

Describe 'Test-DpEvalLiveRunAllowed' {
    It 'allows an explicit local run' {
        $decision = Test-DpEvalLiveRunAllowed -Environment @{}
        $decision.allowed | Should -BeTrue
    }

    It 'refuses to spend credits from CI' {
        foreach ($name in @('CI', 'GITHUB_ACTIONS', 'TF_BUILD')) {
            $decision = Test-DpEvalLiveRunAllowed -Environment @{ $name = 'true' }
            $decision.allowed | Should -BeFalse -Because "$name means automation"
            $decision.reason | Should -Match 'CI'
        }
    }

    It 'ignores a CI variable that is explicitly false' {
        (Test-DpEvalLiveRunAllowed -Environment @{ CI = 'false' }).allowed | Should -BeTrue
    }
}

Describe 'the offline runner seam' {
    BeforeAll {
        $script:runner = (Resolve-Path (Join-Path $script:evalRoot 'Invoke-DpParityEval.ps1')).Path
        $script:scripted = (Resolve-Path (Join-Path $script:fixtureDir 'scripted-run.json')).Path
        $script:scriptedFailure = (Resolve-Path (Join-Path $script:fixtureDir 'scripted-run-unsafe.json')).Path
        $script:outDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-offline-' + [guid]::NewGuid().ToString('N'))
    }

    AfterAll {
        if ($script:outDir -and (Test-Path -LiteralPath $script:outDir)) {
            Remove-Item -LiteralPath $script:outDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs the whole harness with a scripted executor and no live call' {
        $output = Join-Path $script:outDir 'pass'
        & pwsh -NoProfile -File $script:runner -Offline -ScriptedRunPath $script:scripted -OutputPath $output -Repeat 2 2>&1 | Out-String |
            Set-Variable -Name log -Scope Script
        $LASTEXITCODE | Should -Be 0 -Because $script:log
        $resultFile = @(Get-ChildItem -LiteralPath $output -Filter 'run-*.json')[0]
        $result = Get-Content -LiteralPath $resultFile.FullName -Raw | ConvertFrom-Json
        $result.mode | Should -Be 'offline-scripted'
        $result.repeat | Should -Be 2
        $result.gate.ok | Should -BeTrue
        @($result.cases).Count | Should -BeGreaterThan 0
        $result.aggregate.totalSamples | Should -Be (@($result.cases).Count * 2)
        $result.aggregate.usage.reported | Should -BeFalse -Because 'a scripted trial prices nothing, and unknown is not zero'
        $script:log | Should -Not -Match 'spends real credits'
    }

    It 'gives every trial a fresh Conversation and leaves no sandbox behind' {
        $output = Join-Path $script:outDir 'isolation'
        & pwsh -NoProfile -File $script:runner -Offline -ScriptedRunPath $script:scripted -OutputPath $output -Repeat 2 2>&1 | Out-Null
        $resultFile = @(Get-ChildItem -LiteralPath $output -Filter 'run-*.json')[0].FullName
        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        foreach ($case in @($result.cases)) {
            @($case.trials).Count | Should -Be 2
            @($case.trials.trial) | Should -Be @(1, 2)
            @($case.identity) | Should -Not -BeNullOrEmpty
        }
        $result.sandboxRootName | Should -Match '^dp-eval-run-'
        Test-Path -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) $result.sandboxRootName) |
            Should -BeFalse -Because 'the run root is removed when the run ends'
    }

    It 'publishes no absolute user path in the run result' {
        # The runner's own header promises this. A run file may be committed as
        # a baseline, and a temp path on Windows carries the operator's username.
        $output = Join-Path $script:outDir 'privacy'
        & pwsh -NoProfile -File $script:runner -Offline -ScriptedRunPath $script:scripted -OutputPath $output -Repeat 2 2>&1 | Out-Null
        $raw = Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $output -Filter 'run-*.json')[0].FullName) -Raw
        $raw | Should -Not -Match '[A-Za-z]:\\{1,2}Users\\{1,2}'
        $raw | Should -Not -Match '/(home|Users)/[A-Za-z0-9._-]+/'
    }

    It 'exits non-zero when a scripted trial breaks a safety invariant' {
        $output = Join-Path $script:outDir 'fail'
        & pwsh -NoProfile -File $script:runner -Offline -ScriptedRunPath $script:scriptedFailure -OutputPath $output -Repeat 2 2>&1 | Out-String |
            Set-Variable -Name failLog -Scope Script
        $LASTEXITCODE | Should -Be 1 -Because $script:failLog
        $resultFile = @(Get-ChildItem -LiteralPath $output -Filter 'run-*.json')[0]
        $result = Get-Content -LiteralPath $resultFile.FullName -Raw | ConvertFrom-Json
        $result.gate.ok | Should -BeFalse
        ($result.gate.reasons -join '; ') | Should -Match 'safety|pass\^k'
        $result.cases[0].passedAllTrials | Should -BeFalse
        $result.cases[0].passed | Should -BeFalse -Because 'the verdict a baseline records must agree with the gate'
    }

    It 'rejects an invalid repeat count instead of running' {
        $output = Join-Path $script:outDir 'bad-repeat'
        & pwsh -NoProfile -File $script:runner -Offline -ScriptedRunPath $script:scripted -OutputPath $output -Repeat 0 2>&1 | Out-String |
            Set-Variable -Name repeatLog -Scope Script
        $LASTEXITCODE | Should -Not -Be 0
        $script:repeatLog | Should -Match 'at least 1'
    }

    It 'writes a Markdown summary that separates the three rates' {
        $output = Join-Path $script:outDir 'md'
        & pwsh -NoProfile -File $script:runner -Offline -ScriptedRunPath $script:scripted -OutputPath $output -Repeat 2 2>&1 | Out-Null
        $markdown = Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $output -Filter 'run-*.md')[0].FullName) -Raw
        $markdown | Should -Match 'pass@k'
        $markdown | Should -Match 'pass\^k'
        $markdown | Should -Match 'first trial'
        $markdown | Should -Match 'offline-scripted'
    }

    It 'still refuses a live run from CI, whatever the launcher does' {
        # The live mode spends real credits and now starts a child process from
        # a committed launcher. Neither is a reason for CI to be able to reach a
        # Model: the refusal comes before anything is created or started.
        $output = Join-Path $script:outDir 'ci-refusal'
        $previous = $env:CI
        try {
            $env:CI = 'true'
            & pwsh -NoProfile -File $script:runner -RepositoryRoot $script:outDir -OutputPath $output 2>&1 | Out-String |
                Set-Variable -Name ciLog -Scope Script
        }
        finally {
            if ($null -eq $previous) { Remove-Item Env:\CI -ErrorAction SilentlyContinue } else { $env:CI = $previous }
        }
        $LASTEXITCODE | Should -Not -Be 0
        $script:ciLog | Should -Match 'CI'
        Test-Path -LiteralPath $output | Should -BeFalse -Because 'a refused run creates nothing'
    }
}

Describe 'Format-DpEvalTrialSummary' {
    It 'reports unknown cost as unknown and never as a zero' {
        $result = [pscustomobject]@{
            runId = 'r'; startedUtc = '2026-09-24T00:00:00Z'; deskPilotSha = 'abc1234'; mode = 'offline-scripted'; repeat = 2
            caveats = @('the Engine Runspace inherits the launcher environment')
            cases = @(
                [pscustomobject]@{
                    id = 'a'; set = 'capability'; samples = 2; completedSamples = 2; status = 'complete'
                    firstTrialPassed = $true; passedAnyTrial = $true; passedAllTrials = $false; passedTrialCount = 1
                    failed = @('answered'); safetyViolated = $false; durationSeconds = 4.0
                    usage = [pscustomobject]@{ promptTokens = $null; completionTokens = $null; costUSD = $null; reported = $false }
                }
            )
            aggregate = [pscustomobject]@{
                caseCount = 1; totalSamples = 2; firstTrialPassed = 1; firstTrialMeasured = 1; firstTrialUnknown = 0
                passedAnyTrial = 1; passedAllTrials = 0; complete = $true; incompleteCases = @(); unavailableCases = @()
                durationSeconds = 4.0
                usage = [pscustomobject]@{ promptTokens = $null; completionTokens = $null; costUSD = $null; reported = $false; reportedTrials = 0; totalTrials = 2 }
            }
            gate = [pscustomobject]@{ ok = $true; reasons = @(); exitCode = 0 }
        }
        $markdown = Format-DpEvalTrialSummary -Result $result
        $markdown | Should -Match 'unknown'
        $markdown | Should -Not -Match '\| 0\.0 \|'
        $markdown | Should -Match 'abc1234'
        $markdown | Should -Match 'Caveat: the Engine Runspace'
    }

    It 'says plainly that a run with an unavailable case is not a pass rate' {
        $result = [pscustomobject]@{
            runId = 'r'; startedUtc = 'x'; deskPilotSha = 'abc1234'; mode = 'live'; repeat = 3
            caveats = @()
            cases = @(
                [pscustomobject]@{
                    id = 'a'; set = 'regression'; samples = 3; completedSamples = 0; status = 'unavailable'
                    firstTrialPassed = $null; passedAnyTrial = $false; passedAllTrials = $false; passedTrialCount = 0
                    failed = @(); safetyViolated = $false; durationSeconds = 0
                    usage = [pscustomobject]@{ reported = $false; costUSD = $null }
                }
            )
            aggregate = [pscustomobject]@{
                caseCount = 1; totalSamples = 3; firstTrialPassed = 0; firstTrialMeasured = 0; firstTrialUnknown = 1
                passedAnyTrial = 0; passedAllTrials = 0; complete = $false; incompleteCases = @(); unavailableCases = @('a')
                durationSeconds = 0
                usage = [pscustomobject]@{ reported = $false; costUSD = $null; reportedTrials = 0; totalTrials = 0 }
            }
            gate = [pscustomobject]@{ ok = $false; reasons = @('a: no completed trial'); exitCode = 1 }
        }
        $markdown = Format-DpEvalTrialSummary -Result $result
        $markdown | Should -Match 'incomplete'
        $markdown | Should -Match 'unavailable'
        $markdown | Should -Match 'a: no completed trial'
    }

    It 'renders the run timestamp as UTC, not as a local-format date' {
        # Observed in an offline run: the JSON round-trip turns the ISO string
        # into a DateTime and the summary printed '09/24/2026 18:39:39' under a
        # heading that says UTC.
        $result = [pscustomobject]@{
            runId = 'r'; startedUtc = ([datetime]::new(2026, 9, 24, 18, 39, 39, [DateTimeKind]::Utc)); deskPilotSha = 'abc1234'; mode = 'live'; repeat = 1
            caveats = @()
            cases = @()
            aggregate = [pscustomobject]@{
                caseCount = 0; totalSamples = 0; completedSamples = 0; firstTrialPassed = 0; firstTrialMeasured = 0; firstTrialUnknown = 0
                passedAnyTrial = 0; passedAllTrials = 0; complete = $false; incompleteCases = @(); unavailableCases = @()
                durationSeconds = 0
                usage = [pscustomobject]@{ reported = $false; costUSD = $null; reportedTrials = 0; totalTrials = 0 }
            }
            gate = [pscustomobject]@{ ok = $false; reasons = @('no case was executed'); exitCode = 1 }
        }
        $markdown = Format-DpEvalTrialSummary -Result $result
        $markdown | Should -Match '2026-09-24T18:39:39'
        $markdown | Should -Not -Match '09/24/2026'
    }
}

Describe 'the Host Server launch plan' {
    BeforeAll {
        $script:planRoot = (Get-Item -LiteralPath (New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-plan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))).FullName
        $script:planSentinel = Join-Path $script:planRoot 'pwned-plan.txt'
        # A benign sentinel in the shape that escapes a quoted, interpolated
        # command line: an apostrophe, a subexpression and a statement
        # separator. It is only ever a path, and nothing may ever run it.
        $script:hostilePath = "it's a dir `$(New-Item -ItemType File -Path '$script:planSentinel' -Force); Set-Content -LiteralPath '$script:planSentinel' -Value pwned; #"
    }

    AfterAll {
        if ($script:planRoot -and (Test-Path -LiteralPath $script:planRoot)) {
            Remove-Item -LiteralPath $script:planRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'invokes a fixed launcher script that is committed beside the harness' {
        $launcher = Get-DpEvalHostLauncherPath
        Test-Path -LiteralPath $launcher -PathType Leaf | Should -BeTrue
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$parseErrors)
        @($parseErrors) | Should -HaveCount 0 -Because 'the launcher is committed code, not generated text'
    }

    It 'passes every path as data and never as generated code' {
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:planRoot -Port 51234 `
            -DataDirectory $script:hostilePath -EngineModulePath $script:hostilePath `
            -ConfigPath (Join-Path $script:planRoot 'launch.json')

        @($plan.argumentList) | Should -Not -Contain '-EncodedCommand'
        @($plan.argumentList) | Should -Not -Contain '-Command'
        @($plan.argumentList) | Should -Contain '-File'
        @($plan.argumentList) | Should -Contain '-NoProfile'
        $index = [Array]::IndexOf([string[]]@($plan.argumentList), '-File')
        $plan.argumentList[$index + 1] | Should -Be (Get-DpEvalHostLauncherPath)

        foreach ($argument in @($plan.argumentList)) {
            $argument | Should -Not -Match 'Start-DeskPilot|Import-Module|New-Item' -Because 'an argument carries data, never a command'
            $argument | Should -Not -Be $script:hostilePath -Because 'an untrusted path travels in the configuration, not on the command line'
        }

        $plan.configuration.dataDirectory | Should -BeExactly $script:hostilePath
        $plan.configuration.engineModulePath | Should -BeExactly $script:hostilePath
        $plan.configuration.port | Should -Be 51234
        $plan.workingDirectory | Should -Be $script:planRoot
    }

    It 'omits the Engine path entirely when the operator supplied none' {
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:planRoot -Port 51234 `
            -DataDirectory $script:planRoot -ConfigPath (Join-Path $script:planRoot 'launch-default.json')
        $plan.configuration.Contains('engineModulePath') | Should -BeFalse -Because 'the default Engine path is the Host Server default, not an empty string'
    }

    It 'carries a configuration that is data and nothing else' {
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:planRoot -Port 51234 `
            -DataDirectory $script:planRoot -ConfigPath (Join-Path $script:planRoot 'launch-data.json')
        foreach ($key in @($plan.configuration.Keys)) {
            $key | Should -Not -BeIn @('script', 'command', 'shell', 'run', 'exec', 'preRun', 'postRun')
        }
        $plan.configuration.schemaVersion | Should -Be 1
    }
}

Describe 'the Host Server child process' {
    BeforeAll {
        $script:procRoot = (Get-Item -LiteralPath (New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-proc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))).FullName
        # macOS child processes report the physical /private/var spelling.
        $script:procRoot = Resolve-DpEvalPhysicalPath -Path $script:procRoot
        $script:procSentinel = Join-Path $script:procRoot 'pwned-child.txt'
        $script:hostileValue = "it's a dir `$(New-Item -ItemType File -Path '$script:procSentinel' -Force); Set-Content -LiteralPath '$script:procSentinel' -Value pwned; #"

        # A synthetic launcher: it records exactly what the child received and
        # prints a Host-Server-shaped URL. No Host Server, no Engine, no Model.
        $script:recorder = Join-Path $script:procRoot 'Record-DpEvalLaunch.ps1'
        $recorderText = @(
            'param('
            '    [Parameter(Mandatory)]'
            '    [string]$ConfigPath,'
            ''
            '    [Parameter(ValueFromRemainingArguments)]'
            '    [string[]]$Rest'
            ')'
            '$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json'
            '$received = [ordered]@{'
            '    configPath       = $ConfigPath'
            '    rest             = @(@($Rest) | Where-Object { $null -ne $_ })'
            '    workingDirectory = (Get-Location).Path'
            '    configuration    = $config'
            '}'
            '$received | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($ConfigPath + ''.received.json'') -Encoding utf8NoBOM'
            'Write-Host "  Open: http://127.0.0.1:$($config.port)/?t=00112233445566778899aabbccddeeff"'
            'Start-Sleep -Seconds 120'
        ) -join [Environment]::NewLine
        Set-Content -LiteralPath $script:recorder -Value $recorderText -Encoding utf8NoBOM
    }

    AfterAll {
        if ($script:procRoot -and (Test-Path -LiteralPath $script:procRoot)) {
            Remove-Item -LiteralPath $script:procRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'hands the child its configuration as data, byte for byte' {
        $dataDir = Join-Path $script:procRoot "it's a data dir"
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:procRoot -Port 51234 `
            -DataDirectory $dataDir -EngineModulePath $script:hostileValue `
            -ConfigPath (Join-Path $script:procRoot 'launch-1.json') -LauncherPath $script:recorder
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath (Join-Path $script:procRoot 'server-1.log')
        try {
            $url = Wait-DpEvalHostUrl -Server $server -Port 51234 -TimeoutSeconds 60
            $url.ok | Should -BeTrue -Because $url.reason
            $url.token | Should -Be '00112233445566778899aabbccddeeff'

            $received = Get-Content -LiteralPath ($plan.configPath + '.received.json') -Raw | ConvertFrom-Json
            $received.configuration.dataDirectory | Should -BeExactly $dataDir -Because 'a path with an apostrophe and spaces must arrive literally'
            $received.configuration.engineModulePath | Should -BeExactly $script:hostileValue
            $received.configPath | Should -BeExactly $plan.configPath
            @($received.rest).Count | Should -Be 0 -Because 'every value is one argument, never a parsed command line'
            $received.workingDirectory | Should -Be $script:procRoot
        }
        finally {
            Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 20 | Out-Null
        }
        Test-Path -LiteralPath $script:procSentinel | Should -BeFalse -Because 'nothing in the configuration is ever executed'
    }

    It 'runs the committed launcher against a hostile path without executing any of it' {
        # The real launcher, the real argument transport, no Host Server: the
        # dry run proves what it would pass to the Host Server and nothing else.
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:procRoot -Port 51234 `
            -DataDirectory $script:hostileValue -EngineModulePath $script:hostileValue `
            -ConfigPath (Join-Path $script:procRoot 'launch-2.json') -ValidateOnly
        $log = Join-Path $script:procRoot 'server-2.log'
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath $log
        $stop = Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 60 -GraceSeconds 60
        $stop.ok | Should -BeTrue -Because $stop.reason
        $stop.exitCode | Should -Be 0 -Because (Read-DpEvalHostLog -Path $log).text

        $text = (Read-DpEvalHostLog -Path $log).text
        $text | Should -Match 'configuration valid'
        $text | Should -Match ([regex]::Escape("DataDir = $script:hostileValue"))
        $text | Should -Match ([regex]::Escape("EngineModulePath = $script:hostileValue"))
        Test-Path -LiteralPath $script:procSentinel | Should -BeFalse -Because 'a path is data, even when it is shaped like code'
    }

    It 'passes no Engine path when the operator supplied none' {
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:procRoot -Port 51235 `
            -DataDirectory (Join-Path $script:procRoot 'data-default') `
            -ConfigPath (Join-Path $script:procRoot 'launch-3.json') -ValidateOnly
        $log = Join-Path $script:procRoot 'server-3.log'
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath $log
        $stop = Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 60 -GraceSeconds 60
        $stop.ok | Should -BeTrue -Because $stop.reason
        $stop.exitCode | Should -Be 0 -Because (Read-DpEvalHostLog -Path $log).text
        $text = (Read-DpEvalHostLog -Path $log).text
        $text | Should -Match 'DataDir ='
        $text | Should -Not -Match 'EngineModulePath ='
    }

    It 'refuses a configuration that carries anything but the known launch data' {
        # A manifest, a case or an operator must never be able to name a script
        # for the child to run.
        $configPath = Join-Path $script:procRoot 'launch-unknown.json'
        [ordered]@{
            schemaVersion  = 1
            repositoryRoot = $script:procRoot
            modulePath     = Join-Path $script:procRoot 'module'
            port           = 51236
            dataDirectory  = Join-Path $script:procRoot 'data'
            preRun         = "New-Item -ItemType File -Path '$script:procSentinel'"
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

        $output = & pwsh -NoProfile -NonInteractive -File (Get-DpEvalHostLauncherPath) -ConfigPath $configPath -ValidateOnly 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'preRun'
        Test-Path -LiteralPath $script:procSentinel | Should -BeFalse
    }

    It 'refuses a configuration that is incomplete or malformed' {
        $missing = Join-Path $script:procRoot 'launch-missing.json'
        [ordered]@{ schemaVersion = 1; repositoryRoot = $script:procRoot; modulePath = $script:procRoot } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $missing -Encoding utf8NoBOM
        & pwsh -NoProfile -NonInteractive -File (Get-DpEvalHostLauncherPath) -ConfigPath $missing -ValidateOnly 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0

        $badPort = Join-Path $script:procRoot 'launch-port.json'
        [ordered]@{ schemaVersion = 1; repositoryRoot = $script:procRoot; modulePath = $script:procRoot; port = 'ninety'; dataDirectory = $script:procRoot } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $badPort -Encoding utf8NoBOM
        & pwsh -NoProfile -NonInteractive -File (Get-DpEvalHostLauncherPath) -ConfigPath $badPort -ValidateOnly 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'stops the child it owns and says so, twice if asked' {
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:procRoot -Port 51237 `
            -DataDirectory $script:procRoot -ConfigPath (Join-Path $script:procRoot 'launch-4.json') `
            -LauncherPath $script:recorder
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath (Join-Path $script:procRoot 'server-4.log')
        $processId = $server.process.Id
        $stop = Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 30
        $stop.stopped | Should -BeTrue -Because $stop.reason
        $stop.ok | Should -BeTrue -Because $stop.reason
        @(Get-Process -Id $processId -ErrorAction SilentlyContinue) | Should -HaveCount 0
        $server.process | Should -BeNullOrEmpty -Because 'the handle is released once the stop is verified'

        # Cleanup runs in a finally block, so stopping a stopped child is normal
        # and must not turn a completed trial into an error.
        (Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 5).ok | Should -BeTrue
    }

    It 'gives up on a URL within its deadline rather than waiting forever' {
        $silent = Join-Path $script:procRoot 'Silent-DpEvalLaunch.ps1'
        Set-Content -LiteralPath $silent -Encoding utf8NoBOM -Value @(
            'param([string]$ConfigPath)'
            'Start-Sleep -Seconds 120'
        )
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:procRoot -Port 51238 `
            -DataDirectory $script:procRoot -ConfigPath (Join-Path $script:procRoot 'launch-5.json') `
            -LauncherPath $silent
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath (Join-Path $script:procRoot 'server-5.log')
        try {
            $url = Wait-DpEvalHostUrl -Server $server -Port 51238 -TimeoutSeconds 3
            $url.ok | Should -BeFalse
            $url.reason | Should -Match 'never reported'
        }
        finally {
            Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 20 | Out-Null
        }
    }

    It 'reports a child that died instead of waiting out the whole deadline' {
        $dying = Join-Path $script:procRoot 'Dying-DpEvalLaunch.ps1'
        Set-Content -LiteralPath $dying -Encoding utf8NoBOM -Value @(
            'param([string]$ConfigPath)'
            'Write-Host "the module could not be imported"'
            'exit 3'
        )
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:procRoot -Port 51239 `
            -DataDirectory $script:procRoot -ConfigPath (Join-Path $script:procRoot 'launch-6.json') `
            -LauncherPath $dying
        $log = Join-Path $script:procRoot 'server-6.log'
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath $log
        try {
            $url = @(Wait-DpEvalHostUrl -Server $server -Port 51239 -TimeoutSeconds 60)
            @($url).Count | Should -Be 1 -Because 'the wait returns one readiness result, never a stray boolean beside it'
            $url[0] | Should -BeOfType [hashtable]
            $url[0].ok | Should -BeFalse
            $url[0].reason | Should -Match 'exited'
            $url[0].reason | Should -Match 'could not be imported' -Because 'a preparation failure is reported with its detail, not as a timeout'
        }
        finally {
            Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 20 | Out-Null
        }
    }

    It 'launches an ordinary path that happens to contain an apostrophe' {
        # Nothing exotic: a real operator's folder. This is the case a quoting
        # patch breaks and a data transport does not notice.
        $ordinary = Join-Path $script:procRoot "o'brien's trials"
        New-Item -ItemType Directory -Path $ordinary -Force | Out-Null
        $dataDir = Join-Path $ordinary 'data dir'
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $ordinary -Port 51241 `
            -DataDirectory $dataDir -ConfigPath (Join-Path $ordinary 'host-launch.json') -ValidateOnly
        $log = Join-Path $ordinary 'server.log'
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath $log
        $stop = Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 60 -GraceSeconds 60
        $stop.ok | Should -BeTrue -Because $stop.reason
        $stop.exitCode | Should -Be 0 -Because (Read-DpEvalHostLog -Path $log).text

        $text = (Read-DpEvalHostLog -Path $log).text
        $text | Should -Match 'configuration valid'
        $text | Should -Match ([regex]::Escape("DataDir = $dataDir"))
    }

    It 'makes the startup line readable while the child is still running' {
        # The capture must not sit in a buffer: the harness reads this log to
        # find the URL of a server that has not finished starting.
        $plan = New-DpEvalHostLaunchPlan -RepositoryRoot $script:procRoot -Port 51242 `
            -DataDirectory $script:procRoot -ConfigPath (Join-Path $script:procRoot 'launch-7.json') `
            -LauncherPath $script:recorder
        $log = Join-Path $script:procRoot 'server-7.log'
        $server = Start-DpEvalHostProcess -Plan $plan -LogPath $log
        try {
            $url = Wait-DpEvalHostUrl -Server $server -Port 51242 -TimeoutSeconds 20
            $url.ok | Should -BeTrue -Because $url.reason
            $server.process.HasExited | Should -BeFalse -Because 'the line was readable while the child was still running'
            (Read-DpEvalHostLog -Path $log).text | Should -Not -BeNullOrEmpty
        }
        finally {
            Stop-DpEvalHostProcess -Server $server -TimeoutSeconds 20 | Out-Null
        }
    }
}

Describe 'the live launch path generates no PowerShell' {
    BeforeAll {
        $script:launchFiles = @(
            (Join-Path $script:evalRoot 'Invoke-DpParityEval.ps1')
            (Join-Path $script:evalRoot 'DpEvalTrial.ps1')
            (Get-DpEvalHostLauncherPath)
        )
    }

    It 'interpolates no value into anything that will be executed' {
        # The primitive behind the finding: a value inside an expandable string
        # that is then run. The fix is structural, so the test is structural.
        foreach ($file in $script:launchFiles) {
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
            @($parseErrors) | Should -HaveCount 0 -Because "$file must parse"
            $interpolated = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                        @($node.NestedExpressions).Count -gt 0
                    }, $true))
            foreach ($node in $interpolated) {
                $node.Value | Should -Not -Match 'Start-DeskPilot|Import-Module|Set-Location|New-Item|Remove-Item' `
                    -Because "$(Split-Path $file -Leaf) must not build a command out of a value"
            }
        }
    }

    It 'encodes no generated script and evaluates no string' {
        foreach ($file in $script:launchFiles) {
            $text = Get-Content -LiteralPath $file -Raw
            $text | Should -Not -Match 'EncodedCommand' -Because "$(Split-Path $file -Leaf) must pass arguments, not an encoded script"
            $text | Should -Not -Match 'ToBase64String'
            $text | Should -Not -Match 'Invoke-Expression'
            $text | Should -Not -Match 'ScriptBlock\]::Create'
        }
    }

    It 'starts the child through the launch plan and never through a shell' {
        $runner = Get-Content -LiteralPath (Join-Path $script:evalRoot 'Invoke-DpParityEval.ps1') -Raw
        $runner | Should -Match 'New-DpEvalHostLaunchPlan'
        $runner | Should -Match 'Start-DpEvalHostProcess'
        $runner | Should -Match 'Complete-DpEvalTrialCleanup'
        $runner | Should -Not -Match "Start-Process -FilePath 'pwsh'"
    }

    It 'never deletes trial state directly, so the stop is always decided first' {
        # The defect this guards: a finally block that removed the sandbox
        # before it knew whether the child was gone, and a run root that was
        # deleted unconditionally underneath it.
        $runnerPath = Join-Path $script:evalRoot 'Invoke-DpParityEval.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
        $assignment = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$liveExecutor'
            }, $true)
        $assignment | Should -Not -BeNullOrEmpty -Because 'the live executor is where a child process is owned'

        $liveText = $assignment.Right.Extent.Text
        $liveText | Should -Not -Match 'Remove-DpEvalSandbox' -Because 'the live trial asks the cleanup helper, which decides the stop before it deletes anything'
        $liveText | Should -Match 'Complete-DpEvalTrialCleanup'
        $liveText | Should -Match 'Test-DpEvalLiveTrialAllowed'

        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $runner | Should -Match 'Complete-DpEvalRunCleanup' -Because 'the run root is kept when a trial cleanup was blocked'
    }

    It 'stops nothing by name and depends on no newer runtime API' {
        # The child is stopped through the handle this run owns. Nothing here
        # may reach for a process by name, and nothing may depend on an API
        # added after the PowerShell 7.0 floor this harness declares.
        foreach ($file in $script:launchFiles) {
            $text = Get-Content -LiteralPath $file -Raw
            $text | Should -Not -Match 'Stop-Process' -Because "$(Split-Path $file -Leaf) owns a handle, not a name"
            $text | Should -Not -Match 'ProcessPath' -Because "$(Split-Path $file -Leaf) must run on the PowerShell 7.0 floor it declares"
        }
    }
}

Describe 'trial and run cleanup after a stop that did not work' {
    BeforeAll {
        $script:cleanupRoot = (Get-Item -LiteralPath (New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-clean-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))).FullName
    }

    AfterAll {
        if ($script:cleanupRoot -and (Test-Path -LiteralPath $script:cleanupRoot)) {
            Remove-Item -LiteralPath $script:cleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not delete a trial sandbox underneath a child it could not stop' {
        # The defect: the sandbox was removed in a finally block before anyone
        # asked whether the child was actually gone. A still-running Host
        # Server would have had its data directory deleted under it.
        $context = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 1 -Root $script:cleanupRoot -OwnerId 'owner-blocked'
        $session = New-FakeSession -Root $script:cleanupRoot -Process (New-FakeProcess -KillThrows)
        $state = @{ blocked = ''; sandbox = '' }

        { Complete-DpEvalTrialCleanup -Server $session -Context $context -State $state -TimeoutSeconds 1 -SettleMilliseconds 0 } |
            Should -Throw -ExpectedMessage '*could not clean up*'

        Test-Path -LiteralPath $context.sandbox -PathType Container |
            Should -BeTrue -Because 'nothing is deleted while the child may still be running'
        $state.blocked | Should -Not -BeNullOrEmpty
        $state.blocked | Should -Match 'tree'
        $state.sandbox | Should -Be $context.sandbox
    }

    It 'removes a trial sandbox once the stop and the capture are verified' {
        $context = New-DpEvalTrialContext -CaseId 'sample-case' -Trial 2 -Root $script:cleanupRoot -OwnerId 'owner-clean'
        $session = New-FakeSession -Root $script:cleanupRoot -Process (New-FakeProcess)
        $state = @{ blocked = ''; sandbox = '' }

        Complete-DpEvalTrialCleanup -Server $session -Context $context -State $state -TimeoutSeconds 1 -SettleMilliseconds 0

        Test-Path -LiteralPath $context.sandbox | Should -BeFalse
        $state.blocked | Should -BeNullOrEmpty
    }

    It 'starts no further live trial once a cleanup is blocked' {
        $blocked = @{ blocked = "trial 1 of 'sample-case' could not clean up its Host Server: the process tree of 42 could not be stopped."; sandbox = 'x' }
        $decision = Test-DpEvalLiveTrialAllowed -State $blocked
        $decision.allowed | Should -BeFalse
        $decision.reason | Should -Match 'could not clean up'
        (Test-DpEvalLiveTrialAllowed -State @{ blocked = ''; sandbox = '' }).allowed | Should -BeTrue
    }

    It 'keeps the owned run root when a trial cleanup was blocked' {
        $root = Join-Path $script:cleanupRoot ('run-kept-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-DpEvalOwnedDirectory -Path $root -OwnerId 'owner-run-kept' | Out-Null
        $state = @{ blocked = "trial 1 of 'sample-case' could not clean up its Host Server: the process tree of 42 could not be stopped."; sandbox = 'x' }

        $result = Complete-DpEvalRunCleanup -Path $root -OwnerId 'owner-run-kept' -State $state
        $result.ok | Should -BeFalse
        $result.retained | Should -BeTrue
        Test-Path -LiteralPath $root -PathType Container | Should -BeTrue -Because 'the run root is kept for explicit recovery'
        $result.reason | Should -Match ([regex]::Escape((Split-Path $root -Leaf)))
        $result.reason | Should -Not -Match '[A-Za-z]:\\{1,2}Users\\{1,2}' -Because 'a gate reason is published and must carry no user path'

        Remove-DpEvalSandbox -Path $root -OwnerId 'owner-run-kept'
    }

    It 'removes the owned run root when nothing was blocked' {
        $root = Join-Path $script:cleanupRoot ('run-gone-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-DpEvalOwnedDirectory -Path $root -OwnerId 'owner-run-gone' | Out-Null

        $result = Complete-DpEvalRunCleanup -Path $root -OwnerId 'owner-run-gone' -State @{ blocked = ''; sandbox = '' }
        $result.ok | Should -BeTrue -Because $result.reason
        $result.retained | Should -BeFalse
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'cannot reach a clean gate, or a second trial, after a blocked cleanup' {
        # The whole caller-side chain, with the executor shaped exactly like the
        # live one: guard, work, cleanup that decides before it deletes.
        $state = @{ blocked = ''; sandbox = '' }
        $root = $script:cleanupRoot
        $executor = {
            param($Context)
            $allowed = Test-DpEvalLiveTrialAllowed -State $state
            if (-not $allowed.allowed) { throw $allowed.reason }
            $session = New-FakeSession -Root $root -Process (New-FakeProcess -KillThrows)
            try { @{ answer = 'done'; newCommits = 0 } }
            finally { Complete-DpEvalTrialCleanup -Server $session -Context $Context -State $state -TimeoutSeconds 1 -SettleMilliseconds 0 }
        }

        $trials = @(Invoke-DpEvalTrialSet -Case (New-Case) -Expect (New-Expect) -Prompt 'p' -Repeat 2 -Executor $executor -Root $script:cleanupRoot -OwnerId 'owner-chain')
        $trials[0].status | Should -Be 'incomplete' -Because 'a trial that could not clean up is not evidence'
        $trials[0].error | Should -Match 'could not clean up'
        $trials[1].status | Should -Be 'incomplete'
        $trials[1].error | Should -Match 'Refusing to start'
        Test-Path -LiteralPath $state.sandbox -PathType Container | Should -BeTrue -Because 'the blocked trial state is kept for recovery'

        $outcome = Measure-DpEvalCaseOutcome -CaseId 'sample-case' -Set 'regression' -Identity $trials[0].identity -Repeat 2 -Trial $trials
        $gate = Test-DpEvalGate -Case @($outcome)
        $gate.ok | Should -BeFalse -Because 'a run that could not clean up never reports a clean gate'
        $gate.exitCode | Should -Not -Be 0
    }
}

Describe 'Get-DpEvalPowerShellPath' {
    It 'resolves the PowerShell it is running under' {
        $path = Get-DpEvalPowerShellPath
        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because 'a launch plan names an executable that exists'
    }

    It 'takes the executable beside PSHOME rather than a newer runtime API' {
        $expected = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')
        if (Test-Path -LiteralPath $expected -PathType Leaf) {
            Get-DpEvalPowerShellPath | Should -Be $expected
        }
        else {
            Set-ItResult -Skipped -Because 'this host has no pwsh beside $PSHOME'
        }
    }
}

Describe 'Read-DpEvalHostLog' {
    BeforeAll {
        $script:logRoot = (Get-Item -LiteralPath (New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-log-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))).FullName
    }

    AfterAll {
        if ($script:logRoot -and (Test-Path -LiteralPath $script:logRoot)) {
            Remove-Item -LiteralPath $script:logRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports an empty log only when it was never created' {
        $result = Read-DpEvalHostLog -Path (Join-Path $script:logRoot 'never-written.log')
        $result.ok | Should -BeTrue
        $result.exists | Should -BeFalse
        $result.text | Should -Be ''
        $result.reason | Should -Be ''
    }

    It 'reads what a log actually says' {
        $path = Join-Path $script:logRoot 'said.log'
        Set-Content -LiteralPath $path -Value 'the Host Server is running' -Encoding utf8NoBOM
        $result = Read-DpEvalHostLog -Path $path
        $result.ok | Should -BeTrue
        $result.exists | Should -BeTrue
        $result.truncated | Should -BeFalse
        $result.text | Should -Match 'Host Server is running'
    }

    It 'bounds a diagnostic tail instead of materialising the whole log' {
        $path = Join-Path $script:logRoot 'large.log'
        [System.IO.File]::WriteAllText($path, ('a' * 300000) + 'THE-LAST-LINE')
        $tail = Read-DpEvalHostLog -Path $path -Tail 64
        $tail.ok | Should -BeTrue
        $tail.text.Length | Should -BeLessOrEqual 64 -Because 'a tail is bounded before it is read, not after'
        $tail.text | Should -Match 'THE-LAST-LINE'
        $tail.truncated | Should -BeTrue
    }

    It 'bounds a whole-log read as well, and says when it truncated' {
        $path = Join-Path $script:logRoot 'runaway.log'
        [System.IO.File]::WriteAllText($path, 'START-OF-LOG' + ('b' * 3000000))
        $result = Read-DpEvalHostLog -Path $path -MaximumBytes 4096
        $result.ok | Should -BeTrue
        $result.text.Length | Should -BeLessOrEqual 4096
        $result.text | Should -Match 'START-OF-LOG'
        $result.truncated | Should -BeTrue
    }

    It 'reports a log it could not read rather than calling it empty' -Skip:(-not $canLockFile) {
        # An unreadable log is not an empty log. Reporting it as empty would
        # turn a broken capture into "the server never printed a URL".
        $path = Join-Path $script:logRoot 'locked.log'
        Set-Content -LiteralPath $path -Value 'held' -Encoding utf8NoBOM
        $held = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        try {
            $result = Read-DpEvalHostLog -Path $path
            $result.ok | Should -BeFalse
            $result.exists | Should -BeTrue
            $result.text | Should -Be ''
            $result.reason | Should -Not -BeNullOrEmpty
        }
        finally { $held.Dispose() }
    }
}

Describe 'the child process lifecycle reports its own failures' {
    BeforeAll {
        $script:lifeRoot = (Get-Item -LiteralPath (New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('dp-eval-life-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))).FullName
    }

    AfterAll {
        if ($script:lifeRoot -and (Test-Path -LiteralPath $script:lifeRoot)) {
            Remove-Item -LiteralPath $script:lifeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not call a failed tree stop a stopped process' {
        # Falling back to stopping the parent alone would leave the tree running
        # and report success. A bounded, explicit failure is the honest answer.
        $process = New-FakeProcess -KillThrows
        $session = New-FakeSession -Root $script:lifeRoot -Process $process
        $stop = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1
        $stop.stopped | Should -BeFalse
        $stop.ok | Should -BeFalse
        $stop.reason | Should -Match 'tree'
        $stop.reason | Should -Match 'access is denied'
        @($process.killedTree) | Should -Be @($true) -Because 'the tree is what a trial owns'
        $session.process | Should -Not -BeNullOrEmpty -Because 'a handle is released only after a verified stop'
        $process.disposed | Should -BeFalse
    }

    It 'treats a process that exited while it was being stopped as stopped' {
        $process = New-FakeProcess -KillThrows -ExitOnKill
        $session = New-FakeSession -Root $script:lifeRoot -Process $process
        $stop = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1
        $stop.ok | Should -BeTrue -Because $stop.reason
        $stop.stopped | Should -BeTrue
    }

    It 'does not call a process that never exits stopped' {
        $process = New-FakeProcess -WaitResult $false
        $session = New-FakeSession -Root $script:lifeRoot -Process $process
        $stop = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1
        $stop.stopped | Should -BeFalse
        $stop.ok | Should -BeFalse
        $stop.reason | Should -Match 'did not exit'
    }

    It 'reports a capture that faulted instead of reporting a clean stop' {
        $faulted = [System.Threading.Tasks.Task]::FromException([System.IO.IOException]::new('the capture pipe broke'))
        $session = New-FakeSession -Root $script:lifeRoot -Process (New-FakeProcess) -Copies @($faulted)
        $stop = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1 -CaptureTimeoutMilliseconds 500
        $stop.captured | Should -BeFalse
        $stop.ok | Should -BeFalse
        $stop.stopped | Should -BeTrue -Because 'the process did stop; it is the capture that failed'
        $stop.reason | Should -Match 'capture'
        $stop.reason | Should -Match 'the capture pipe broke'
    }

    It 'reports a capture that did not finish within its bound' {
        $pending = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
        try {
            $session = New-FakeSession -Root $script:lifeRoot -Process (New-FakeProcess) -Copies @($pending.Task)
            $stop = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1 -CaptureTimeoutMilliseconds 200
            $stop.captured | Should -BeFalse
            $stop.ok | Should -BeFalse
            $stop.reason | Should -Match 'capture'
        }
        finally { $pending.SetResult($null) }
    }

    It 'reports a trial log that could not be closed' {
        $stream = [pscustomobject]@{ name = 'out' }
        $stream | Add-Member -MemberType ScriptMethod -Name Dispose -Value { throw 'the log could not be flushed' }
        $session = New-FakeSession -Root $script:lifeRoot -Process (New-FakeProcess) -Streams @($stream)
        $stop = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1
        $stop.captured | Should -BeFalse
        $stop.ok | Should -BeFalse
        $stop.reason | Should -Match 'the log could not be flushed'
    }

    It 'returns one result, and releases the handle, after a verified stop' {
        $process = New-FakeProcess
        $session = New-FakeSession -Root $script:lifeRoot -Process $process
        $result = @(Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1)
        @($result).Count | Should -Be 1 -Because 'a caller reads one result, not a pipeline of them'
        $result[0].ok | Should -BeTrue -Because $result[0].reason
        $process.disposed | Should -BeTrue -Because 'the handle is released after the stop is verified'
        $session.process | Should -BeNullOrEmpty

        # Cleanup runs in a finally block, so a second stop is normal.
        $again = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1
        $again.ok | Should -BeTrue -Because $again.reason
        $again.exitCode | Should -Be 0 -Because 'the verified exit code is remembered after the handle is gone'
    }

    It 'reports an exit code it could not read rather than calling the stop clean' {
        # Every problem this reports has to fail the result. A reason beside an
        # ok of true is a trial that looks clean and is not.
        $process = New-FakeProcess -ExitCodeThrows
        $session = New-FakeSession -Root $script:lifeRoot -Process $process
        $stop = Stop-DpEvalHostProcess -Server $session -TimeoutSeconds 1
        $stop.stopped | Should -BeTrue
        $stop.captured | Should -BeTrue
        $stop.ok | Should -BeFalse -Because 'a reported problem always fails the result'
        $stop.exitCode | Should -BeNullOrEmpty
        $stop.reason | Should -Match 'exit code'
        $process.disposed | Should -BeFalse -Because 'a handle is released only after a clean stop'
    }

    It 'surfaces a log it cannot read instead of polling to its deadline' -Skip:(-not $canLockFile) {
        $session = New-FakeSession -Root $script:lifeRoot -Process (New-FakeProcess)
        Set-Content -LiteralPath $session.logPath -Value 'held' -Encoding utf8NoBOM
        $held = [System.IO.File]::Open($session.logPath, 'Open', 'ReadWrite', 'None')
        try {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $ready = @(Wait-DpEvalHostUrl -Server $session -Port 51240 -TimeoutSeconds 30 -PollMilliseconds 100)
            $clock.Stop()
            @($ready).Count | Should -Be 1
            $ready[0].ok | Should -BeFalse
            $ready[0].reason | Should -Match 'could not be read'
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 10 -Because 'an unreadable log is a failure, not a reason to wait'
        }
        finally { $held.Dispose() }
    }
}
