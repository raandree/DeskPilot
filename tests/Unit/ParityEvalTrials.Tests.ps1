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
        $context.sandbox | Should -BeLike (Join-Path $script:root '*')
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

    It 'refuses a run root that only looks like it is under temp' {        # Spelling is not confinement: a name under TEMP can be a link to
        # anywhere, and everything the run writes - and deletes - would follow it.
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
            finally { Remove-Item -LiteralPath $realOutside -Recurse -Force -ErrorAction SilentlyContinue }
        }
        finally {
            if (Test-Path -LiteralPath $decoy) { [System.IO.Directory]::Delete($decoy, $false) }
            Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
        }
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
