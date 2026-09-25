#requires -Version 7.0
<#
.SYNOPSIS
    Repeated-trial execution, honest aggregation and gating for the DeskPilot
    parity eval harness.
.DESCRIPTION
    Dot-source this file. It dot-sources DpEvalGrader.ps1 and adds everything
    above a single graded run: validating a case manifest, giving each trial a
    fresh throwaway sandbox, running the executor k times, and turning k graded
    trials into numbers a reader can trust.

    It contains no live call, no network, no Host Server and no Model call. The
    execution seam is a scriptblock the caller supplies, which is what lets the
    whole repetition and aggregation path be tested against scripted trials
    without claiming anything about a Model.

    Three rules run through all of it:

    - An agent is not deterministic, so one trial is an anecdote. Every case is
      sampled k times and scored three ways: the first trial (what a user
      actually gets on the first attempt), at least one of k (pass@k, best
      case), and all of k (pass^k, worst case).
    - A trial that could not be measured is neither a pass nor a failure. It is
      incomplete, it is named, and it can never be rounded into a rate. A
      missing sample must never produce a pass-shaped aggregate.
    - A cost nobody reported is unknown, not zero. Zero is a measurement.
    - An artifact is read through one confined path and never otherwise. The
      folder a trial grades is one an agent under test just had write access to,
      so a link in it is expected rather than exotic, and a refused read is
      reported unavailable rather than truncated into a pass.
.LINK
    https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
#>

. (Join-Path $PSScriptRoot 'DpEvalGrader.ps1')

# Reuse the repository's single workspace confinement test rather than growing a
# second one beside it that can drift. It is the lexical check plus the leaf
# link target; the ancestor walk and the byte bound below are what this harness
# adds, because the thing being confined here is a folder an agent under test
# just had write access to.
$dpEvalRepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$dpEvalConfinement = Join-Path $dpEvalRepoRoot 'source' 'Private' 'Resolve-DpWorkspacePath.ps1'
if (-not (Test-Path -LiteralPath $dpEvalConfinement -PathType Leaf)) {
    throw "The eval harness needs the repository's path confinement helper at '$dpEvalConfinement'."
}
. $dpEvalConfinement

function Get-DpEvalArtifactLimit {
    <#
    .SYNOPSIS
        The byte bound on one graded artifact.
    .DESCRIPTION
        An artifact is read to be matched by a regex or parsed as JSON, so it is
        small by definition. The bound exists because the file is written by the
        agent under test: without it, one runaway write turns a grader into an
        out-of-memory failure, and a silently truncated read turns a wrong
        artifact into a passing one.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{ maximumBytes = 1048576 }
}

function Resolve-DpEvalPhysicalPath {
    <#
    .SYNOPSIS
        Resolves a path segment by segment through every link in its chain.
    .DESCRIPTION
        GetFullPath normalises spelling and nothing else, so a path that reads as
        if it is under the temp directory can land anywhere. This walks the chain
        and follows each link it meets, so the answer is where the filesystem
        would actually go. A segment that does not exist yet is kept as written -
        it links nowhere until something creates it.
    .PARAMETER Path
        The path to resolve.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not $root) { return $full }

    $segments = @($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })
    $current = $root
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            $target = $item.ResolveLinkTarget($true)
            if ($target) { $current = [System.IO.Path]::GetFullPath($target.FullName) }
        }
        catch { $null = $_ }
    }
    $current
}

function Test-DpEvalPathTraversesLink {
    <#
    .SYNOPSIS
        Says whether any segment between a root and a path is a link.
    .DESCRIPTION
        Deliberately conservative: *any* link in the chain refuses the path, even
        one whose target is inside the root. The alternative is to decide each
        target correctly every time, and a confinement test that has to be clever
        is one that eventually is not. Nothing a grader legitimately reads needs
        to be reached through a link.
    .PARAMETER Root
        The already-resolved root the path must stay inside.
    .PARAMETER Path
        The full path to check.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('/', '\')
    $full = [System.IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $full.StartsWith($rootFull + $separator, $comparison)) { return $true }

    $segments = @($full.Substring($rootFull.Length) -split '[\\/]' | Where-Object { $_ })
    $current = $rootFull
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { return $true }
            if ($item.LinkType) { return $true }
        }
        catch {
            # A segment that cannot be classified is not a segment that can be
            # shown to be safe.
            return $true
        }
    }
    $false
}

function Get-DpEvalArtifactContent {
    <#
    .SYNOPSIS
        Reads one graded artifact out of a trial fixture, or refuses to.
    .DESCRIPTION
        This is the only place the harness reads a file the agent under test may
        have written, so it is where confinement has to actually hold. Four
        gates, in order:

        - The repository's workspace confinement test: lexical, plus the leaf's
          link target.
        - No link anywhere between the fixture root and the artifact. The lexical
          test sees spelling; only the filesystem knows that 'docs' is a junction
          to somewhere else entirely.
        - It must be a file that exists.
        - It must be within the byte bound, checked again against the open handle.

        A refusal returns no content and a reason. It is never a truncated read
        and never a silent empty string: the grader that wanted it reports
        *unavailable*, the trial is incomplete, and the case is named rather than
        scored. Wrong and unmeasured are different answers.
    .PARAMETER Root
        The trial fixture folder.
    .PARAMETER Path
        The workspace-relative path the manifest declared.
    .PARAMETER Sandbox
        The trial sandbox the fixture must stay inside, when the caller owns one.
    .PARAMETER MaximumBytes
        The byte bound. Defaults to Get-DpEvalArtifactLimit.
    .OUTPUTS
        System.Collections.Hashtable with captured, content and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [string]$Sandbox,

        [long]$MaximumBytes = (Get-DpEvalArtifactLimit).maximumBytes
    )

    $refuse = { param([string]$Reason) @{ captured = $false; content = $null; reason = $Reason } }

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return & $refuse "the fixture folder '$Root' does not exist"
    }

    # The root is the one place the no-links walk below cannot protect, because
    # it is where that walk starts. Swap the fixture folder itself for a
    # junction and every declared read follows it, so the root is confined
    # first, by where it actually resolves to.
    $rootDecision = Test-DpEvalThrowawayPath -Path $Root
    if (-not $rootDecision.ok) {
        return & $refuse 'the trial fixture folder resolves outside the throwaway temp tree'
    }
    $rootPhysical = $rootDecision.physical

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    if ($Sandbox) {
        # Under TEMP is not enough on its own: another trial's sandbox is also
        # under TEMP, and a trial grades only its own state.
        $sandboxDecision = Test-DpEvalThrowawayPath -Path $Sandbox
        if (-not $sandboxDecision.ok) {
            return & $refuse 'the trial sandbox resolves outside the throwaway temp tree'
        }
        $sandboxPhysical = $sandboxDecision.physical.TrimEnd('/', '\')
        if (-not ($rootPhysical.TrimEnd('/', '\') + $separator).StartsWith($sandboxPhysical + $separator, $comparison)) {
            return & $refuse 'the trial fixture folder resolves outside the trial sandbox'
        }
    }

    $full = Resolve-DpWorkspacePath -Root $rootPhysical -Path $Path
    if (-not $full) { return & $refuse 'it resolves outside the trial fixture' }

    if (Test-DpEvalPathTraversesLink -Root $rootPhysical -Path $full) {
        return & $refuse 'it is reached through a link, which a graded artifact never needs to be'
    }

    if (-not (Test-Path -LiteralPath $full)) { return & $refuse 'it does not exist' }

    try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop }
    catch { return & $refuse 'it could not be read' }

    if ($item.PSIsContainer) { return & $refuse 'it is not a file' }
    if ([long]$item.Length -gt $MaximumBytes) {
        return & $refuse "it is $($item.Length) bytes, larger than the $MaximumBytes byte bound, and a graded artifact is never truncated"
    }

    try {
        $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch { return & $refuse 'it could not be opened' }

    try {
        if ([long]$stream.Length -gt $MaximumBytes) {
            return & $refuse "it is $($stream.Length) bytes, larger than the $MaximumBytes byte bound, and a graded artifact is never truncated"
        }
        $buffer = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
    }
    catch { return & $refuse 'it could not be read' }
    finally { $stream.Dispose() }

    if ($offset -ne $buffer.Length) {
        # The agent under test may still be running, and the handle is shared
        # for writing. A short read is not a small artifact, it is half of one.
        return & $refuse 'it changed while it was being read, so what was read is not the artifact'
    }

    # The link check and the read are two moments. Ask again, so a path swapped
    # in between is refused rather than graded.
    if (Test-DpEvalPathTraversesLink -Root $rootPhysical -Path $full) {
        return & $refuse 'it became a link while it was being read'
    }

    # Decode the way Get-Content would: honour a byte-order mark. Forcing UTF-8
    # on a UTF-16 artifact would hand a grader mojibake, and the grader would
    # call it wrong when the truth is that it was never read.
    try {
        $memory = [System.IO.MemoryStream]::new($buffer, 0, $offset)
        try {
            $reader = [System.IO.StreamReader]::new($memory, [Text.Encoding]::UTF8, $true)
            try { $content = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $memory.Dispose() }
    }
    catch { return & $refuse 'it could not be decoded as text' }

    @{ captured = $true; content = $content; reason = '' }
}

function Get-DpEvalArtifactSet {
    <#
    .SYNOPSIS
        Reads every artifact a case declared, and names the ones it refused.
    .PARAMETER Root
        The trial fixture folder.
    .PARAMETER Path
        The declared workspace-relative paths.
    .PARAMETER Sandbox
        The trial sandbox the fixture must stay inside, when the caller owns one.
    .PARAMETER MaximumBytes
        The per-artifact byte bound.
    .OUTPUTS
        System.Collections.Hashtable with contents and problems.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [AllowEmptyCollection()]
        [string[]]$Path = @(),

        [string]$Sandbox,

        [long]$MaximumBytes = (Get-DpEvalArtifactLimit).maximumBytes
    )

    $contents = @{}
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $normalised = ([string]$relative -replace '\\', '/').Trim('/')
        $result = Get-DpEvalArtifactContent -Root $Root -Path $relative -Sandbox $Sandbox -MaximumBytes $MaximumBytes
        if ($result.captured) { $contents[$normalised] = $result.content }
        else { $problems.Add("$($normalised): $($result.reason)") }
    }
    @{ contents = $contents; problems = @($problems) }
}

function Test-DpEvalThrowawayPath {
    <#
    .SYNOPSIS
        Says whether a path really is throwaway state under the temp directory.
    .DESCRIPTION
        Resolved, not spelled. A folder named under TEMP can be a link to a home
        directory or a repository, and this harness both writes and recursively
        deletes under that folder.
    .PARAMETER Path
        The candidate run root or sandbox.
    .OUTPUTS
        System.Collections.Hashtable with ok, physical and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $temp = Resolve-DpEvalPhysicalPath -Path ([System.IO.Path]::GetTempPath())
    $temp = $temp.TrimEnd('/', '\')
    $physical = (Resolve-DpEvalPhysicalPath -Path $Path).TrimEnd('/', '\')
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    if (-not $physical.StartsWith($temp + $separator, $comparison)) {
        return @{
            ok       = $false
            physical = $physical
            reason   = "'$Path' resolves to '$physical', which is not a throwaway folder under the system temp directory. A trial must never be able to reach a real Project, a real Conversation or the repository."
        }
    }
    @{ ok = $true; physical = $physical; reason = '' }
}

function New-DpEvalOwnedDirectory {
    <#
    .SYNOPSIS
        Allocates a new directory for this run and records that it owns it.
    .DESCRIPTION
        Being under the temp directory is not ownership. A real checkout, a
        scratch folder or another tool's state can legitimately live there, and
        this harness deletes what it is given recursively. So trial state is
        always *newly allocated*: a path that already exists is refused rather
        than adopted, and a small receipt is written naming the run that created
        it. Cleanup will not touch a directory that cannot show that receipt.
    .PARAMETER Path
        The directory to allocate. Must not already exist.
    .PARAMETER OwnerId
        The identity of the run allocating it.
    .OUTPUTS
        System.String

        The full path of the allocated directory.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OwnerId
    )

    $decision = Test-DpEvalThrowawayPath -Path $Path
    if (-not $decision.ok) { throw $decision.reason }

    $full = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) {
        throw "Refusing to reuse '$full': this run allocates its own trial state and never adopts a directory that already exists."
    }
    if (-not $PSCmdlet.ShouldProcess($full, 'Allocate eval trial state')) { return }

    New-Item -ItemType Directory -Path $full -ErrorAction Stop | Out-Null
    $receipt = [ordered]@{
        harness    = 'dp-eval'
        ownerId    = $OwnerId
        createdUtc = [DateTime]::UtcNow.ToString('o')
        processId  = $PID
    }
    Set-Content -LiteralPath (Join-Path $full (Get-DpEvalOwnerReceiptName)) -Value ($receipt | ConvertTo-Json -Depth 3) -Encoding utf8NoBOM -ErrorAction Stop
    $full
}

function Get-DpEvalOwnerReceiptName {
    <#
    .SYNOPSIS
        The file name of the ownership receipt.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    '.dp-eval-owner'
}

function Test-DpEvalOwnedDirectory {
    <#
    .SYNOPSIS
        Says whether a directory is trial state this run allocated.
    .DESCRIPTION
        The receipt must be a real file - a link where the receipt should be
        proves nothing, because its target can be anywhere - and it must name
        this run. Anything else is somebody's directory, not this run's scratch.
    .PARAMETER Path
        The directory to check.
    .PARAMETER OwnerId
        The identity the receipt must name.
    .OUTPUTS
        System.Collections.Hashtable with ok and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OwnerId
    )

    $decision = Test-DpEvalThrowawayPath -Path $Path
    if (-not $decision.ok) { return @{ ok = $false; reason = $decision.reason } }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @{ ok = $false; reason = "'$Path' is not a directory." }
    }

    $receiptPath = Join-Path $Path (Get-DpEvalOwnerReceiptName)
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        return @{ ok = $false; reason = "'$Path' carries no eval ownership receipt, so this run did not allocate it." }
    }

    try {
        $item = Get-Item -LiteralPath $receiptPath -Force -ErrorAction Stop
        if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or $item.LinkType) {
            return @{ ok = $false; reason = "the ownership receipt in '$Path' is a link, so it proves nothing about this directory." }
        }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        return @{ ok = $false; reason = "the ownership receipt in '$Path' could not be read." }
    }

    if ([string]$receipt.harness -ne 'dp-eval') {
        return @{ ok = $false; reason = "the receipt in '$Path' is not an eval ownership receipt." }
    }
    if ([string]$receipt.ownerId -ne $OwnerId) {
        return @{ ok = $false; reason = "'$Path' is owned by '$($receipt.ownerId)', not by this run." }
    }
    @{ ok = $true; reason = '' }
}

function Remove-DpEvalSandbox {
    <#
    .SYNOPSIS
        Deletes trial state this run owns, or refuses and says why.
    .DESCRIPTION
        Two rules, and both fail closed.

        Ownership: the directory must carry this run's receipt. Under the temp
        directory is not ownership, and a recursive delete is not something to
        point at a folder on the strength of where it happens to live.

        Links: every link inside is unlinked before anything is deleted, so a
        recursive delete can never reach a link's target. If a link cannot be
        unlinked, or is still there afterwards, the recursion does not happen at
        all - continuing would be the exact hazard the unlinking exists to
        prevent.

        Nothing here is swallowed. A cleanup that failed is reported to the
        caller, because state that is still on disk is state the next trial can
        still read, and a run that could not clean up has not cleanly finished.
    .PARAMETER Path
        The sandbox or run root to remove.
    .PARAMETER OwnerId
        The identity that must own it.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OwnerId
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $decision = Test-DpEvalThrowawayPath -Path $Path
    if (-not $decision.ok) { throw $decision.reason }
    if (-not (Test-Path -LiteralPath $Path)) { return }

    # A path that cannot be classified is not a path that can be shown safe to
    # delete recursively.
    try { $self = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch { throw "Refusing to remove '$Path': it could not be inspected. $($_.Exception.Message)" }

    if ($self.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or $self.LinkType) {
        throw "Refusing to remove '$Path': it is a link. This harness never allocates trial state as a link, so a link here is not this run's state."
    }

    $ownership = Test-DpEvalOwnedDirectory -Path $Path -OwnerId $OwnerId
    if (-not $ownership.ok) { throw "Refusing to remove '$Path': $($ownership.reason)" }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove eval trial state')) { return }

    # Get-ChildItem does not descend into a reparse point, so this enumerates the
    # links without ever entering one.
    try { $children = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop) }
    catch { throw "Refusing to remove '$Path' recursively: its contents could not be enumerated. $($_.Exception.Message)" }

    $links = @($children | Where-Object { $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or $_.LinkType })
    foreach ($link in @($links | Sort-Object { $_.FullName.Length } -Descending)) {
        try {
            if ($link.PSIsContainer) { [System.IO.Directory]::Delete($link.FullName, $false) }
            else { [System.IO.File]::Delete($link.FullName) }
        }
        catch {
            throw "Refusing to remove '$Path' recursively: the link '$($link.FullName)' could not be unlinked, and recursing now would follow it. $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $link.FullName) {
            throw "Refusing to remove '$Path' recursively: the link '$($link.FullName)' is still present after unlinking."
        }
    }

    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    catch { throw "Trial state at '$Path' could not be removed. $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $Path) { throw "Trial state at '$Path' is still present after removal." }
}

function Get-DpEvalRepeatBound {
    <#
    .SYNOPSIS
        The inclusive bounds on the trial repeat count.
    .DESCRIPTION
        Bounded on purpose. Repetition is what makes the numbers mean anything
        and it is also what spends the credits, so a mistyped repeat count is
        refused rather than obeyed.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{ minimum = 1; maximum = 25 }
}

function Test-DpEvalRepeat {
    <#
    .SYNOPSIS
        Validates a trial repeat count.
    .PARAMETER Repeat
        The requested number of independent trials per case.
    .OUTPUTS
        System.Collections.Hashtable with valid, repeat and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Repeat
    )

    $bound = Get-DpEvalRepeatBound
    $value = 0
    if (-not [int]::TryParse([string]$Repeat, [ref]$value)) {
        return @{ valid = $false; repeat = 0; error = "Repeat must be a whole number; got '$Repeat'." }
    }
    if ($value -lt $bound.minimum) {
        return @{ valid = $false; repeat = $value; error = "Repeat must be at least $($bound.minimum); got $value." }
    }
    if ($value -gt $bound.maximum) {
        return @{ valid = $false; repeat = $value; error = "Repeat must be at most $($bound.maximum); got $value. Repetition costs real credits." }
    }
    @{ valid = $true; repeat = $value; error = '' }
}

function Test-DpEvalWorkspacePath {
    <#
    .SYNOPSIS
        Says whether a manifest path stays inside the fixture workspace.
    .DESCRIPTION
        A committed manifest may name a file to read after a trial. It may not
        name a file outside the throwaway workspace, which is the difference
        between grading an artifact and reading the developer's disk.
    .PARAMETER Path
        The path as written in the manifest.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalised = $Path -replace '\\', '/'
    if ($normalised -match '^[A-Za-z]:') { return $false }
    if ($normalised.StartsWith('/')) { return $false }
    if ($normalised.StartsWith('~')) { return $false }
    if (@($normalised -split '/') -contains '..') { return $false }
    $true
}

function Test-DpEvalCaseId {
    <#
    .SYNOPSIS
        Says whether a case id may become a path, an argument or a log line.
    .DESCRIPTION
        A case id is not a label. It is the leaf of the throwaway sandbox a
        trial writes to, it appears in the launch configuration handed to a
        child process, and it is printed into the run report. So it is checked
        against a bounded ASCII allow-list *before* any of that happens: lower
        case letters, digits and hyphens, starting with a letter or a digit, up
        to 64 characters.

        Everything else is refused and nothing is repaired. An id is never
        trimmed, never lower-cased and never truncated into a valid one: two
        manifests that differ only in case or in trailing whitespace would
        otherwise share one sandbox and one reported id, and the run would be
        about a corpus that does not exist.

        The anchors are \A and \z rather than ^ and $ deliberately. In .NET, $
        also matches before a trailing newline, so an id ending in one would
        pass a check that looks strict and then forge a line in a log.
    .PARAMETER CaseId
        The candidate id, as it arrived. A manifest is JSON, so this may be a
        number, an array or an object rather than a string; each is refused
        rather than stringified into a path.
    .OUTPUTS
        System.Collections.Hashtable with ok and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$CaseId
    )

    $pattern = '\A[a-z0-9][a-z0-9-]{0,63}\z'

    if ($null -eq $CaseId) {
        return @{ ok = $false; reason = 'a case id is required: case.json has no id.' }
    }
    if ($CaseId -isnot [string]) {
        return @{ ok = $false; reason = "a case id must be a string; got $($CaseId.GetType().Name). A manifest id is never converted into a path." }
    }

    # Control characters are shown as '?' so a refusal cannot forge a line in
    # the console or the run report it is written to.
    $display = ($CaseId -replace '[^\x20-\x7E]', '?')
    if ($display.Length -gt 80) { $display = $display.Substring(0, 80) + '...' }

    # -cmatch, not -match: the default comparison is case-insensitive, and an
    # allow-list of a-z that quietly accepts A-Z is not an allow-list.
    if ($CaseId -cnotmatch $pattern) {
        return @{
            ok     = $false
            reason = "case id '$display' is not allowed: a case id is 1 to 64 characters of a-z0-9 and '-', starting with a-z0-9. It is refused, never repaired."
        }
    }

    @{ ok = $true; reason = '' }
}

function Test-DpEvalManifest {
    <#
    .SYNOPSIS
        Validates one case manifest before anything is executed.
    .DESCRIPTION
        A malformed manifest is rejected, never tolerated: a case that names a
        grader nobody implements, asserts nothing, or carries two graders with
        the same id has not been measured, and a run that silently skipped it
        would report a pass rate over a corpus that is not the corpus.

        It also enforces the two things a committed corpus must never do: run
        code, and read outside the fixture workspace.
    .PARAMETER Case
        The parsed case.json.
    .PARAMETER Expect
        The parsed expect.json.
    .PARAMETER Prompt
        The prompt.md text.
    .PARAMETER FolderName
        The corpus folder the case came from, when there is one.
    .OUTPUTS
        System.Collections.Hashtable with valid and errors.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Case,

        [Parameter(Mandatory)]
        [object]$Expect,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Prompt,

        [string]$FolderName
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # The id first, and against an allow-list: it becomes a sandbox path and a
    # launch argument long before anybody reads this manifest again.
    $idCheck = Test-DpEvalCaseId -CaseId $Case.id
    $id = if ($Case.id -is [string]) { [string]$Case.id } else { '' }
    if (-not $idCheck.ok) { $errors.Add($idCheck.reason) }
    elseif ($FolderName -and $id -ne $FolderName) { $errors.Add("case id '$id' does not match its folder '$FolderName'.") }

    $set = [string]$Case.set
    if ($set -notin @('capability', 'regression')) { $errors.Add("set must be 'capability' or 'regression'; got '$set'.") }

    if ([string]::IsNullOrWhiteSpace([string]$Case.note)) {
        $errors.Add('note is required: a case must record the real task it came from.')
    }

    $repository = [string]$Case.repository
    if (-not $repository) { $errors.Add('repository is required.') }
    elseif ($repository -match '[:\\/]') { $errors.Add("repository must be a name resolved under -RepositoryRoot, not a path: '$repository'.") }

    if ([string]::IsNullOrWhiteSpace([string]$Case.commit)) { $errors.Add('commit is required: a fixture that is not pinned is not a fixture.') }

    $cap = 0
    if (-not [int]::TryParse([string]$Case.maxToolIterations, [ref]$cap) -or $cap -lt 1) {
        $errors.Add("maxToolIterations must be a whole number of at least 1; got '$($Case.maxToolIterations)'.")
    }

    if ([string]::IsNullOrWhiteSpace($Prompt)) { $errors.Add('prompt.md is empty: there is nothing to send.') }

    if ($Case.PSObject.Properties['provenance'] -and $Case.provenance) {
        $origin = [string]$Case.provenance.origin
        if ($origin -notin @('parity-series', 'adapted', 'synthetic')) {
            $errors.Add("provenance.origin must be 'parity-series', 'adapted' or 'synthetic'; got '$origin'.")
        }
        if ([string]::IsNullOrWhiteSpace([string]$Case.provenance.source)) {
            $errors.Add('provenance.source is required: a case must name the commit, fixture or document it came from.')
        }
    }

    $known = @(Get-DpEvalGraderType)
    $seen = @{}
    $gating = 0
    foreach ($grader in @($Expect.graders)) {
        if ($null -eq $grader) { $errors.Add('expect.json contains a null grader.'); continue }
        $type = [string]$grader.type
        $graderId = if ($grader.PSObject.Properties['id'] -and $grader.id) { [string]$grader.id } else { $type }

        if ($type -notin $known) { $errors.Add("unknown grader type '$type' on grader '$graderId'."); continue }

        if ($seen.ContainsKey($graderId)) { $errors.Add("duplicate grader id '$graderId'.") }
        else { $seen[$graderId] = $true }

        foreach ($field in @('script', 'command', 'shell', 'run', 'exec')) {
            if ($grader.PSObject.Properties[$field]) {
                $errors.Add("grader '$graderId' carries executable content in '$field'; a manifest is data and never runs code.")
            }
        }

        $advisory = [bool]($grader.PSObject.Properties['advisory'] -and $grader.advisory)
        $declaredSafety = [bool]($grader.PSObject.Properties['safety'] -and $grader.safety)
        if ($advisory -and $declaredSafety) {
            $errors.Add("grader '$graderId' is advisory and a safety invariant; an advisory grader gates nothing.")
        }
        if ($type -eq 'llm_judge' -and $declaredSafety) {
            $errors.Add("grader '$graderId' is an llm_judge and cannot be a safety invariant; a judge is always advisory.")
        }
        if (-not $advisory -and $type -ne 'llm_judge') { $gating++ }

        switch ($type) {
            'command_ran' {
                if (-not [string]$grader.pattern) { $errors.Add("grader '$graderId' needs a pattern.") }
            }
            'tool_used' {
                if (-not [string]$grader.tool) { $errors.Add("grader '$graderId' needs a tool.") }
                if (-not $grader.PSObject.Properties['min'] -and -not $grader.PSObject.Properties['max']) {
                    $errors.Add("grader '$graderId' needs a min or a max.")
                }
            }
            'answer_contains' {
                if (-not [string]$grader.pattern) { $errors.Add("grader '$graderId' needs a pattern.") }
            }
            'instruction_followed' {
                if (-not [string]$grader.marker -and -not [string]$grader.pattern) {
                    $errors.Add("grader '$graderId' needs a marker or a pattern.")
                }
            }
            'files_written' {
                $paths = @($grader.paths)
                if ($paths.Count -eq 0) { $errors.Add("grader '$graderId' needs at least one path.") }
                if ($grader.PSObject.Properties['mode'] -and [string]$grader.mode -notin @('equals', 'subset')) {
                    $errors.Add("grader '$graderId' has mode '$($grader.mode)'; expected 'equals' or 'subset'.")
                }
                foreach ($path in $paths) {
                    if (-not (Test-DpEvalWorkspacePath -Path ([string]$path))) {
                        $errors.Add("grader '$graderId' names '$path', which is not workspace-relative.")
                    }
                }
            }
            'file_contains' {
                if (-not (Test-DpEvalWorkspacePath -Path ([string]$grader.path))) {
                    $errors.Add("grader '$graderId' names '$($grader.path)', which is not workspace-relative.")
                }
                if (-not [string]$grader.pattern) { $errors.Add("grader '$graderId' needs a pattern.") }
            }
            'json_field' {
                if (-not (Test-DpEvalWorkspacePath -Path ([string]$grader.path))) {
                    $errors.Add("grader '$graderId' names '$($grader.path)', which is not workspace-relative.")
                }
                if (-not [string]$grader.field) { $errors.Add("grader '$graderId' needs a field.") }
                if (-not $grader.PSObject.Properties['equals'] -and -not [string]$grader.matches) {
                    $errors.Add("grader '$graderId' needs an equals or a matches.")
                }
            }
        }
    }

    if ($gating -eq 0) {
        $errors.Add('expect.json declares no gating grader; a case that asserts nothing has not been measured.')
    }

    @{ valid = ($errors.Count -eq 0); errors = @($errors) }
}

function Get-DpEvalCaseIdentity {
    <#
    .SYNOPSIS
        A stable fingerprint of everything that decides a case's outcome.
    .DESCRIPTION
        Repeated trials are only comparable when they ran the same case the same
        way. The identity covers the fixture, the Model, the Agent, the
        permissions, the iteration cap and the prompt, so a corpus edited
        between a baseline and a current run cannot be silently compared.

        It is a hash, not a copy: the prompt decides the identity without being
        published in the report.
    .PARAMETER Case
        The parsed case.json.
    .PARAMETER Prompt
        The prompt.md text.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Case,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Prompt
    )

    $permissions = ''
    if ($Case.PSObject.Properties['permissions'] -and $Case.permissions) {
        # A hashtable's PSObject.Properties are the adapter members (Count,
        # Keys, ...), never the keys, so the dictionary case is asked first.
        $names = if ($Case.permissions -is [System.Collections.IDictionary]) {
            @($Case.permissions.Keys | Sort-Object)
        }
        else {
            @($Case.permissions.PSObject.Properties.Name | Sort-Object)
        }
        $permissions = ($names | ForEach-Object { "$_=$([bool]$Case.permissions.$_)" }) -join ','
    }

    $material = @(
        [string]$Case.id
        [string]$Case.set
        [string]$Case.repository
        [string]$Case.commit
        [string]$Case.model
        [string]$Case.agent
        [string]$Case.maxToolIterations
        $permissions
        $Prompt
    ) -join "`u{001F}"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material)) }
    finally { $sha.Dispose() }
    (-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
}

function New-DpEvalTrialContext {
    <#
    .SYNOPSIS
        Creates the throwaway state one trial runs in.
    .DESCRIPTION
        Every trial gets its own sandbox, its own fixture clone and its own data
        directory, so a Conversation, a Project registry and any file the agent
        wrote in trial one cannot reach trial two. The run root must *resolve*
        under the system temp directory - spelling is not confinement, and a
        folder named under TEMP can be a link to a home directory - because a
        harness must never be able to point a trial, or its own recursive
        cleanup, at a real Project or a real DeskPilot data directory.
    .PARAMETER CaseId
        The case being run.
    .PARAMETER Trial
        The 1-based trial number.
    .PARAMETER Root
        The throwaway run root, under the system temp directory.
    .PARAMETER OwnerId
        The identity of the run allocating the sandbox. Defaults to a fresh one,
        so a standalone caller still owns what it creates.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a throwaway sandbox folder under the system temp directory; there is no user state to confirm.')]
    param(
        [Parameter(Mandatory)]
        [string]$CaseId,

        [Parameter(Mandatory)]
        [int]$Trial,

        [Parameter(Mandatory)]
        [string]$Root,

        [string]$OwnerId
    )

    if (-not $OwnerId) { $OwnerId = [guid]::NewGuid().ToString('N') }

    # Before anything is allocated: the id is about to become a directory leaf
    # and a value in the launch configuration of a child process.
    $idCheck = Test-DpEvalCaseId -CaseId $CaseId
    if (-not $idCheck.ok) { throw $idCheck.reason }

    $decision = Test-DpEvalThrowawayPath -Path $Root
    if (-not $decision.ok) { throw $decision.reason }
    $normalised = $decision.physical

    $sandbox = Join-Path $normalised ('{0}-trial{1}-{2}' -f $CaseId, $Trial, [guid]::NewGuid().ToString('N').Substring(0, 8))
    $context = @{
        caseId         = $CaseId
        trial          = $Trial
        ownerId        = $OwnerId
        sandbox        = $sandbox
        fixture        = Join-Path $sandbox 'fixture'
        dataDir        = Join-Path $sandbox 'data'
        serverLog      = Join-Path $sandbox 'server.log'
        serverErrorLog = Join-Path $sandbox 'server.err.log'
        launchConfig   = Join-Path $sandbox 'host-launch.json'
    }
    # Freshly allocated and receipted, so cleanup can prove it is this run's.
    New-DpEvalOwnedDirectory -Path $context.sandbox -OwnerId $OwnerId | Out-Null
    New-Item -ItemType Directory -Path $context.dataDir -ErrorAction Stop | Out-Null
    $context
}

function Get-DpEvalHostLauncherPath {
    <#
    .SYNOPSIS
        The fixed launcher script a trial's Host Server is started from.
    .DESCRIPTION
        One committed file, always the same one. The harness never generates a
        script for the child process, so there is exactly one place where the
        code a trial runs can be read and reviewed.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path $PSScriptRoot 'Start-DpEvalHost.ps1'
}

function Get-DpEvalPowerShellPath {
    <#
    .SYNOPSIS
        The PowerShell executable a trial's child process is started with.
    .DESCRIPTION
        The one running this harness, so a trial cannot silently land on a
        different PowerShell than the operator is using. It is resolved from
        $PSHOME, which every PowerShell has, rather than from an API added
        after the 7.0 floor this harness declares; the running process is asked
        only if $PSHOME holds no executable. A path that cannot be resolved is
        an error, never a name for the operating system to search for.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $name = $IsWindows ? 'pwsh.exe' : 'pwsh'
    $candidate = Join-Path $PSHOME $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }

    $running = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if ($running -and (Test-Path -LiteralPath $running -PathType Leaf)) { return $running }

    throw "The eval harness could not resolve the PowerShell executable it is running under; '$candidate' does not exist."
}

function New-DpEvalHostLaunchPlan {
    <#
    .SYNOPSIS
        Describes the child process one trial's Host Server runs in, as data.
    .DESCRIPTION
        The plan is the whole fix for a harness that used to build a script out
        of paths and hand it to PowerShell to parse. Here nothing is parsed
        twice:

        - The executable and the fixed launcher are named, never composed.
        - Each argument is one element of an argument list, handed to the
          operating system as its own argument. Nothing is quoted, so nothing
          can be unquoted.
        - Everything else - the repository root, the port, the sandbox data
          directory, an optional Engine path - is configuration written as
          JSON and read by the launcher as data.

        A path with a space, an apostrophe or a character that looks like
        PowerShell therefore stays a path. This is a transport property, not a
        filter: nothing here inspects a value for hostile content, because a
        value is never in a position to be executed.
    .PARAMETER RepositoryRoot
        The DeskPilot checkout the child runs from.
    .PARAMETER Port
        The loopback port the Host Server binds.
    .PARAMETER DataDirectory
        The trial's throwaway data directory.
    .PARAMETER EngineModulePath
        An explicit Engine (ShellPilot) path. Omitted entirely when the operator
        supplied none, so the Host Server keeps its own default.
    .PARAMETER ConfigPath
        Where the launch configuration is written.
    .PARAMETER LauncherPath
        The launcher script. Defaults to the committed one; a test supplies its
        own to prove what a child actually received.
    .PARAMETER ValidateOnly
        Ask the launcher to validate its configuration and exit without
        starting anything.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Describes a child process as data and changes nothing; the plan is only executed by Start-DpEvalHostProcess.')]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter(Mandatory)]
        [string]$DataDirectory,

        [string]$EngineModulePath,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [string]$LauncherPath,

        [switch]$ValidateOnly
    )

    if (-not $LauncherPath) { $LauncherPath = Get-DpEvalHostLauncherPath }
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        throw "The eval launcher '$LauncherPath' does not exist; a trial starts a committed script and nothing else."
    }

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $fullConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

    $configuration = [ordered]@{
        schemaVersion  = 1
        repositoryRoot = $root
        modulePath     = Join-Path $root 'output' 'module' 'DeskPilot'
        port           = $Port
        dataDirectory  = $DataDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($EngineModulePath)) {
        $configuration['engineModulePath'] = $EngineModulePath
    }

    $argumentList = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $LauncherPath, '-ConfigPath', $fullConfigPath)) {
        $argumentList.Add([string]$argument)
    }
    if ($ValidateOnly) { $argumentList.Add('-ValidateOnly') }

    @{
        filePath         = Get-DpEvalPowerShellPath
        argumentList     = @($argumentList)
        workingDirectory = $root
        configPath       = $fullConfigPath
        configuration    = $configuration
    }
}

function New-DpEvalLogStream {
    <#
    .SYNOPSIS
        Opens a trial log the harness can read while the child writes it.
    .DESCRIPTION
        Shared for reading, because the harness polls this file for the URL the
        Host Server prints. It is also opened write-through: a FileStream
        buffer of one byte disables the stream's own buffering, so a startup
        line reaches the disk when it is written rather than when a buffer
        happens to fill. That is a property of the *file*; the copy that feeds
        it reads in ordinary sized blocks.
    .PARAMETER Path
        The log file to create.
    .OUTPUTS
        System.IO.FileStream
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a log file inside the trial sandbox; there is no user state to confirm.')]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    [System.IO.FileStream]::new($full, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 1, $false)
}

function Read-DpEvalHostLog {
    <#
    .SYNOPSIS
        Reads a bounded part of a trial log while the child is still writing it.
    .DESCRIPTION
        Three rules, and the first one is why this exists at all:

        - An unreadable log is not an empty log. A read that failed is reported
          as a failure, because reporting it as empty would turn a broken
          capture into "the server never printed a URL". Only a log that has
          not been created yet is legitimately empty.
        - The read tolerates the writer. An ordinary read takes no write
          sharing and fails against a file that is being written.
        - The bytes are bounded before they are read, not after. A tail seeks
          to the end and reads only the tail; a whole read stops at the
          maximum. A runaway child must not be able to turn a diagnostic line
          into an out-of-memory failure.
    .PARAMETER Path
        The log file.
    .PARAMETER Tail
        Read at most this many trailing bytes. 0 reads from the start.
    .PARAMETER MaximumBytes
        The bound on a whole-log read.
    .OUTPUTS
        System.Collections.Hashtable with ok, exists, text, truncated and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Tail = 0,

        [int]$MaximumBytes = 1048576
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ ok = $true; exists = $false; text = ''; truncated = $false; reason = '' }
    }

    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = $stream.Length
        $truncated = $false

        if ($Tail -gt 0) {
            $count = [int][Math]::Min([long]$Tail, $length)
            $offset = $length - $count
            if ($offset -gt 0) {
                $null = $stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
                $truncated = $true
            }
        }
        else {
            $count = [int][Math]::Min([long]$MaximumBytes, $length)
            if ($count -lt $length) { $truncated = $true }
        }

        $buffer = [byte[]]::new($count)
        $read = 0
        while ($read -lt $count) {
            $chunk = $stream.Read($buffer, $read, $count - $read)
            if ($chunk -le 0) { break }
            $read += $chunk
        }

        # A byte offset can land inside a character. Drop the continuation
        # bytes at the front rather than decoding a broken one.
        $start = 0
        if ($truncated -and $Tail -gt 0) {
            while ($start -lt $read -and ($buffer[$start] -band 0xC0) -eq 0x80) { $start++ }
        }

        @{
            ok        = $true
            exists    = $true
            text      = [System.Text.Encoding]::UTF8.GetString($buffer, $start, $read - $start)
            truncated = $truncated
            reason    = ''
        }
    }
    catch {
        @{
            ok        = $false
            exists    = $true
            text      = ''
            truncated = $false
            reason    = "the trial log '$Path' could not be read: $($_.Exception.Message)"
        }
    }
    finally { if ($stream) { $stream.Dispose() } }
}

function Start-DpEvalHostProcess {
    <#
    .SYNOPSIS
        Starts one trial's Host Server child process from a launch plan.
    .DESCRIPTION
        Native transport throughout: the argument list goes to the process
        start information one element at a time, the working directory is a
        property of the process rather than a command in a script, and the
        configuration is written as JSON for the launcher to read.

        Both output streams are captured to files the harness can read while
        the child runs, so a child that fails to start is reported with what it
        said instead of as a silent timeout.
    .PARAMETER Plan
        The launch plan from New-DpEvalHostLaunchPlan.
    .PARAMETER LogPath
        Where the child's standard output is captured.
    .PARAMETER ErrorLogPath
        Where the child's standard error is captured. Defaults beside the log.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a throwaway child process for one trial; there is no user state to confirm.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Plan,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [string]$ErrorLogPath
    )

    if (-not $ErrorLogPath) { $ErrorLogPath = "$LogPath.err" }

    $json = $Plan.configuration | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $Plan.configPath -Value $json -Encoding utf8NoBOM -ErrorAction Stop

    $start = [System.Diagnostics.ProcessStartInfo]::new([string]$Plan.filePath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [string]$Plan.workingDirectory
    foreach ($argument in @($Plan.argumentList)) { $start.ArgumentList.Add([string]$argument) }

    $outStream = New-DpEvalLogStream -Path $LogPath
    $errorStream = $null
    $process = $null
    try {
        $errorStream = New-DpEvalLogStream -Path $ErrorLogPath
        $process = [System.Diagnostics.Process]::Start($start)
        try { $process.StandardInput.Close() } catch { $null = $_ }
        $copies = @(
            $process.StandardOutput.BaseStream.CopyToAsync($outStream, 4096)
            $process.StandardError.BaseStream.CopyToAsync($errorStream, 4096)
        )
    }
    catch {
        # A child that started but could not be captured is still a child. It is
        # stopped here rather than left behind holding the trial's sandbox.
        if ($process -and -not $process.HasExited) {
            try { $process.Kill($true) } catch { $null = $_ }
        }
        if ($outStream) { $outStream.Dispose() }
        if ($errorStream) { $errorStream.Dispose() }
        throw
    }

    @{
        process      = $process
        logPath      = [System.IO.Path]::GetFullPath($LogPath)
        errorLogPath = [System.IO.Path]::GetFullPath($ErrorLogPath)
        configPath   = $Plan.configPath
        streams      = @($outStream, $errorStream)
        copies       = @($copies)
    }
}

function Wait-DpEvalHostUrl {
    <#
    .SYNOPSIS
        Waits for the Host Server to print its loopback URL, or says why it did not.
    .DESCRIPTION
        Bounded on both sides: it gives up at the deadline, and it stops as soon
        as the child exits rather than waiting out the whole deadline for a
        process that is already gone. A child that died during preparation is
        reported with the tail of what it wrote, because "never reported a URL"
        is not a diagnosis.
    .PARAMETER Server
        The session from Start-DpEvalHostProcess.
    .PARAMETER Port
        The port the Host Server was told to bind.
    .PARAMETER TimeoutSeconds
        How long to wait in total.
    .PARAMETER PollMilliseconds
        How often to read the log.
    .OUTPUTS
        System.Collections.Hashtable with ok, url, token and reason.

        Exactly one of them. Everything this function calls is consumed, so no
        stray value is ever emitted beside the result a caller reads.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server,

        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutSeconds = 120,

        [int]$PollMilliseconds = 250
    )

    $pattern = "http://127\.0\.0\.1:$Port/\?t=([0-9a-f]{32})"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    if (-not $Server.process) {
        return @{ ok = $false; url = ''; token = ''; reason = 'the child process handle has already been released, so there is nothing to wait for.' }
    }

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds $PollMilliseconds

        $log = Read-DpEvalHostLog -Path $Server.logPath
        if (-not $log.ok) {
            # An unreadable log is a failure now, not a reason to keep polling
            # until the deadline and then blame the server for saying nothing.
            return @{ ok = $false; url = ''; token = ''; reason = $log.reason }
        }
        if ($log.text -match $pattern) {
            $token = $Matches[1]
            return @{ ok = $true; url = "http://127.0.0.1:$Port/?t=$token"; token = $token; reason = '' }
        }

        if ($Server.process.HasExited) {
            # The pipes close when the child exits, so the capture finishes
            # quickly; the wait is bounded anyway and its answer is kept.
            $capture = Complete-DpEvalHostOutput -Server $Server -TimeoutMilliseconds 2000
            $log = Read-DpEvalHostLog -Path $Server.logPath
            if ($log.ok -and $log.text -match $pattern) {
                $token = $Matches[1]
                return @{ ok = $true; url = "http://127.0.0.1:$Port/?t=$token"; token = $token; reason = '' }
            }

            $detail = [System.Collections.Generic.List[string]]::new()
            if (-not $capture.ok) { $detail.Add($capture.reason) }
            foreach ($candidate in @($Server.errorLogPath, $Server.logPath)) {
                $tail = Read-DpEvalHostLog -Path $candidate -Tail 2000
                if (-not $tail.ok) { $detail.Add($tail.reason) }
                elseif ($tail.text.Trim()) { $detail.Add($tail.text.Trim()) }
            }
            if (-not $detail.Count) { $detail.Add('it wrote nothing.') }

            return @{
                ok     = $false
                url    = ''
                token  = ''
                reason = "exited with code $($Server.process.ExitCode) before reporting a URL: $($detail -join ' ')"
            }
        }
    }

    $tail = Read-DpEvalHostLog -Path $Server.errorLogPath -Tail 1000
    $wrote = if (-not $tail.ok) { $tail.reason } else { $tail.text.Trim() }
    @{
        ok     = $false
        url    = ''
        token  = ''
        reason = "never reported a URL within $TimeoutSeconds seconds.$(if ($wrote) { " It wrote: $wrote" })"
    }
}

function Complete-DpEvalHostOutput {
    <#
    .SYNOPSIS
        Waits, briefly, for the child's captured output to finish arriving.
    .DESCRIPTION
        The answer is a result, not a side effect. A capture that faulted or
        that did not finish within its bound means the trial log is incomplete,
        and an incomplete log is something the caller has to know about rather
        than something to discover later in a missing line.
    .PARAMETER Server
        The session from Start-DpEvalHostProcess.
    .PARAMETER TimeoutMilliseconds
        The bound on the wait.
    .OUTPUTS
        System.Collections.Hashtable with ok and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server,

        [int]$TimeoutMilliseconds = 2000
    )

    $copies = @($Server.copies | Where-Object { $_ })
    if (-not $copies.Count) { return @{ ok = $true; reason = '' } }

    try {
        $completed = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$copies, $TimeoutMilliseconds)
    }
    catch {
        $faults = @($copies |
                Where-Object { $_.IsFaulted -and $_.Exception } |
                ForEach-Object { $_.Exception.GetBaseException().Message })
        if (-not $faults.Count) { $faults = @($_.Exception.GetBaseException().Message) }
        return @{ ok = $false; reason = "the child output capture failed: $($faults -join '; ')" }
    }

    if (-not $completed) {
        return @{ ok = $false; reason = "the child output capture did not finish within $TimeoutMilliseconds ms, so the trial log is incomplete." }
    }
    @{ ok = $true; reason = '' }
}

function Stop-DpEvalHostProcess {
    <#
    .SYNOPSIS
        Stops the child process this trial started, and says whether it worked.
    .DESCRIPTION
        Only the process this run started, through the handle it was given,
        with the tree it started: a Host Server that spawned anything must not
        outlive the trial that owns it, and nothing here is ever stopped by
        name.

        Nothing is downgraded into success. A tree that could not be stopped is
        reported as a failed stop rather than retried as a parent-only kill
        that would leave the tree running and read as clean. A capture that
        faulted or timed out, and a log that could not be closed, are failures
        of their own: the trial log is then incomplete, and the caller is told.

        The process handle is released only once the stop *and* the capture are
        verified, and the exit code is remembered on the session so a second
        stop - the normal case, from a finally block - still answers.
    .PARAMETER Server
        The session from Start-DpEvalHostProcess.
    .PARAMETER TimeoutSeconds
        How long to wait for the process to exit after it is stopped.
    .PARAMETER GraceSeconds
        How long to let the process finish on its own first. 0 stops it now.
    .PARAMETER CaptureTimeoutMilliseconds
        The bound on waiting for the captured output to finish arriving.
    .OUTPUTS
        System.Collections.Hashtable with ok, stopped, captured, exitCode and
        reason. One object, always.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops the throwaway child process this trial started; confirming it would strand a Host Server the cleanup must outlive.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server,

        [int]$TimeoutSeconds = 15,

        [int]$GraceSeconds = 0,

        [int]$CaptureTimeoutMilliseconds = 2000
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $stopped = $true
    $captured = $true
    $released = $true
    $exitCode = $Server['exitCode']
    $process = $Server.process

    if ($process) {
        try {
            if ($GraceSeconds -gt 0 -and -not $process.HasExited) {
                $null = $process.WaitForExit($GraceSeconds * 1000)
            }
            if (-not $process.HasExited) {
                try { $process.Kill($true) }
                catch {
                    # A process that exited between the check and the kill is
                    # not a failure. Anything else is, and it stays one: a
                    # parent-only stop would leave the tree running and report
                    # a clean trial.
                    if (-not $process.HasExited) {
                        $stopped = $false
                        $problems.Add("the process tree of $($process.Id) could not be stopped: $($_.Exception.Message)")
                    }
                }
            }
            if ($stopped -and -not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $stopped = $false
                $problems.Add("process $($process.Id) did not exit within $TimeoutSeconds seconds.")
            }
        }
        catch {
            $stopped = $false
            $problems.Add("process $($process.Id) could not be stopped: $($_.Exception.Message)")
        }

        if ($stopped) {
            # Property access swallows a getter failure under the caller's
            # error preference, and [int]$null is 0 - an exit code nobody could
            # read would have been reported as a clean zero. The read is
            # contained so the failure is a value this can report.
            $raw = & { $ErrorActionPreference = 'Stop'; try { $process.ExitCode } catch { $null } }
            if ($null -eq $raw) {
                $exitCode = $null
                $problems.Add("the exit code of process $($process.Id) could not be read.")
            }
            else {
                $exitCode = [int]$raw
            }
        }
    }

    $capture = Complete-DpEvalHostOutput -Server $Server -TimeoutMilliseconds $CaptureTimeoutMilliseconds
    if (-not $capture.ok) {
        $captured = $false
        $problems.Add($capture.reason)
    }

    foreach ($stream in @($Server.streams | Where-Object { $_ })) {
        try { $stream.Dispose() }
        catch {
            $captured = $false
            $problems.Add("a trial log could not be closed: $($_.Exception.Message)")
        }
    }

    # Released only after the stop and the capture are both verified, and only
    # when nothing else was reported: a handle is what a caller still has to
    # inspect a child that would not go away.
    if ($process -and $stopped -and $captured -and $problems.Count -eq 0) {
        try {
            $process.Dispose()
            $Server['process'] = $null
            $Server['streams'] = @()
            $Server['copies'] = @()
            $Server['exitCode'] = $exitCode
        }
        catch {
            $released = $false
            $problems.Add("the process handle could not be released: $($_.Exception.Message)")
        }
    }

    @{
        # Every problem fails the result. A reason beside an ok of true is a
        # trial that reads clean and is not.
        ok       = ($stopped -and $captured -and $released -and $problems.Count -eq 0)
        stopped  = $stopped
        captured = $captured
        exitCode = $exitCode
        reason   = ($problems -join ' ')
    }
}

function Test-DpEvalLiveTrialAllowed {
    <#
    .SYNOPSIS
        Says whether another live trial may start.
    .DESCRIPTION
        Once a trial could not clean up after itself, the run is over. A child
        that would not stop still holds its sandbox, and the next trial would
        allocate its own state beside it, start another Host Server and
        eventually ask a run root that must not be deleted to be deleted. The
        latch is set once and never cleared: the honest end of that run is an
        incomplete report and state kept for recovery.
    .PARAMETER State
        The run's cleanup state, carrying 'blocked' once a cleanup failed.
    .OUTPUTS
        System.Collections.Hashtable with allowed and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    if ($State['blocked']) {
        return @{
            allowed = $false
            reason  = "Refusing to start another live trial: $($State['blocked']) The state it could not clean up is kept for recovery."
        }
    }
    @{ allowed = $true; reason = '' }
}

function Complete-DpEvalTrialCleanup {
    <#
    .SYNOPSIS
        Stops a trial's child process and removes its sandbox, in that order.
    .DESCRIPTION
        The order is the whole point. The sandbox is the data directory the
        Host Server is writing to, so it is removed only once the stop and the
        capture are verified. A stop that did not work leaves everything on
        disk, latches the run so nothing further starts, and throws - which
        makes the trial incomplete, because a trial whose state could not be
        cleaned up is not evidence about anything.
    .PARAMETER Server
        The session from Start-DpEvalHostProcess.
    .PARAMETER Context
        The trial context that owns the sandbox.
    .PARAMETER State
        The run's cleanup state, latched when this cleanup is blocked.
    .PARAMETER TimeoutSeconds
        The bound on stopping the child.
    .PARAMETER SettleMilliseconds
        A short pause after a verified stop, so the operating system can
        release the handles the removal below needs.
    .OUTPUTS
        None. It throws when the trial could not be cleaned up.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes the throwaway sandbox this trial allocated, after the child that owns it is verified stopped.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server,

        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [int]$TimeoutSeconds = 30,

        [int]$SettleMilliseconds = 300
    )

    $stop = Stop-DpEvalHostProcess -Server $Server -TimeoutSeconds $TimeoutSeconds
    if (-not $stop.ok) {
        $problem = "trial $($Context.trial) of '$($Context.caseId)' could not clean up its Host Server: $($stop.reason)"
        if (-not $State['blocked']) {
            $State['blocked'] = $problem
            $State['sandbox'] = [string]$Context.sandbox
        }
        throw "$problem Nothing was deleted: the trial state is kept for recovery and no further live trial is started."
    }

    if ($SettleMilliseconds -gt 0) { Start-Sleep -Milliseconds $SettleMilliseconds }
    # Not swallowed: state still on disk is state the next trial can read, so a
    # removal failure makes this trial incomplete rather than clean.
    Remove-DpEvalSandbox -Path $Context.sandbox -OwnerId $Context.ownerId
}

function Complete-DpEvalRunCleanup {
    <#
    .SYNOPSIS
        Removes the run root, or keeps it and says why.
    .DESCRIPTION
        The run root holds every trial sandbox, so deleting it unconditionally
        would do at run level exactly what a trial must never do: remove state
        underneath a child process that is still running. When a trial cleanup
        was blocked, the owned run root is kept for explicit recovery and the
        reason is handed back for the gate.

        The reason names the run root by its leaf only. A temp path carries the
        operator's username and a run result may be committed as a baseline.
    .PARAMETER Path
        The run root this run allocated.
    .PARAMETER OwnerId
        The identity that must own it.
    .PARAMETER State
        The run's cleanup state.
    .OUTPUTS
        System.Collections.Hashtable with ok, retained and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes the run root this run allocated and receipted; keeping it is the failure path, not the confirmable one.')]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OwnerId,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $name = Split-Path $Path -Leaf

    if ($State['blocked']) {
        return @{
            ok       = $false
            retained = $true
            reason   = "$($State['blocked']) The run root '$name' under the system temp directory was kept for recovery; nothing was deleted underneath a child process that may still be running. Remove it by hand once that process is gone."
        }
    }

    try { Remove-DpEvalSandbox -Path $Path -OwnerId $OwnerId }
    catch { return @{ ok = $false; retained = $true; reason = "$_" } }

    @{ ok = $true; retained = $false; reason = '' }
}

function ConvertTo-DpEvalUsage {
    <#
    .SYNOPSIS
        Normalises a reported Usage, keeping what was not reported unknown.
    .DESCRIPTION
        The one rule that matters here: a cost nobody reported is null, never
        zero. Zero is a measurement, and a report that prints 0.00 USD for a
        Turn whose Usage never arrived is not a cheap run, it is a wrong one.
    .PARAMETER Reported
        The Usage the Engine reported, when it reported one.
    .OUTPUTS
        System.Collections.IDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowNull()]
        [object]$Reported
    )

    $usage = [ordered]@{
        promptTokens     = $null
        completionTokens = $null
        costUSD          = $null
        credits          = $null
        reported         = $false
    }
    if ($null -eq $Reported) { return $usage }

    $any = $false
    foreach ($field in @('promptTokens', 'completionTokens', 'costUSD', 'credits')) {
        $property = $null
        if ($Reported -is [System.Collections.IDictionary]) {
            if ($Reported.Contains($field)) { $property = $Reported[$field] }
        }
        elseif ($Reported.PSObject.Properties[$field]) {
            $property = $Reported.$field
        }
        if ($null -eq $property) { continue }
        $usage[$field] = if ($field -in @('promptTokens', 'completionTokens')) { [int]$property } else { [double]$property }
        $any = $true
    }
    $usage.reported = $any
    $usage
}

function Merge-DpEvalUsage {
    <#
    .SYNOPSIS
        Sums the Usage across trials without inventing the parts nobody reported.
    .DESCRIPTION
        A field is summed over the trials that reported it and stays null when
        no trial did. When some trials reported and others did not, the total is
        flagged partial, because a sum over an unknown number of samples is not
        a total.
    .PARAMETER Usage
        The per-trial Usage records.
    .OUTPUTS
        System.Collections.IDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Usage = @()
    )

    $all = @($Usage | Where-Object { $null -ne $_ })
    $reported = @($all | Where-Object { [bool]$_.reported })

    $merged = [ordered]@{
        promptTokens     = $null
        completionTokens = $null
        costUSD          = $null
        credits          = $null
        reported         = ($reported.Count -gt 0)
        partial          = (($reported.Count -gt 0) -and ($reported.Count -lt $all.Count))
        reportedTrials   = $reported.Count
        totalTrials      = $all.Count
    }

    foreach ($field in @('promptTokens', 'completionTokens', 'costUSD', 'credits')) {
        $values = @($reported | ForEach-Object { $_.$field } | Where-Object { $null -ne $_ })
        if ($values.Count -eq 0) { continue }
        $sum = ($values | Measure-Object -Sum).Sum
        $merged[$field] = if ($field -in @('promptTokens', 'completionTokens')) { [int]$sum } else { [Math]::Round([double]$sum, 6) }
    }

    $merged
}

function Invoke-DpEvalTrialSet {
    <#
    .SYNOPSIS
        Runs one case k times through an execution seam and grades every trial.
    .DESCRIPTION
        The executor is a scriptblock that takes the trial context and returns
        what happened. That is the whole live surface: supply an executor that
        drives a Host Server and it is a live run, supply one that replays a
        scripted result and it is an offline self-check that spends nothing.

        The manifest and the repeat count are validated before anything runs, so
        a typo costs nothing. An executor that throws produces an *incomplete*
        trial, never a failed one: a harness error is not evidence about the
        agent, and calling it a failure would be as dishonest as calling it a pass.
    .PARAMETER Case
        The parsed case.json.
    .PARAMETER Expect
        The parsed expect.json.
    .PARAMETER Prompt
        The prompt.md text.
    .PARAMETER Repeat
        How many independent trials to run.
    .PARAMETER Executor
        The execution seam. Receives the trial context, returns a hashtable with
        answer, toolCalls or records, changedFiles, newCommits, fileContents and
        usage.
    .PARAMETER Root
        The throwaway run root.
    .PARAMETER OwnerId
        The identity that owns every sandbox this set allocates.
    .PARAMETER FolderName
        The corpus folder, when the case came from one.
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Case,

        [Parameter(Mandatory)]
        [object]$Expect,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [object]$Repeat,

        [Parameter(Mandatory)]
        [scriptblock]$Executor,

        [Parameter(Mandatory)]
        [string]$Root,

        [string]$OwnerId,

        [string]$FolderName
    )

    $repeatCheck = Test-DpEvalRepeat -Repeat $Repeat
    if (-not $repeatCheck.valid) { throw $repeatCheck.error }
    if (-not $OwnerId) { $OwnerId = [guid]::NewGuid().ToString('N') }

    $manifest = Test-DpEvalManifest -Case $Case -Expect $Expect -Prompt $Prompt -FolderName $FolderName
    if (-not $manifest.valid) {
        throw "Case '$($Case.id)' has a malformed manifest: $($manifest.errors -join ' ')"
    }

    $identity = Get-DpEvalCaseIdentity -Case $Case -Prompt $Prompt
    $requiredFiles = @(Get-DpEvalRequiredFile -Expect $Expect)
    $trials = [System.Collections.Generic.List[hashtable]]::new()

    for ($index = 1; $index -le $repeatCheck.repeat; $index++) {
        $context = New-DpEvalTrialContext -CaseId ([string]$Case.id) -Trial $index -Root $Root -OwnerId $OwnerId
        $context.identity = $identity
        $context.requiredFiles = $requiredFiles
        $context.prompt = $Prompt
        $context.case = $Case

        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $outcome = & $Executor $context
            $clock.Stop()

            $records = @()
            if ($null -ne $outcome -and $outcome.records) { $records = @($outcome.records) }
            elseif ($null -ne $outcome -and $outcome.toolCalls) {
                $records = @($outcome.toolCalls | ForEach-Object {
                        @{ kind = 'tool_call'; tool = [string]$_.tool; summary = [string]$_.summary; iteration = [int]$_.iteration }
                    })
            }

            $fileContents = @{}
            if ($null -ne $outcome -and $outcome.fileContents) {
                if ($outcome.fileContents -is [System.Collections.IDictionary]) {
                    foreach ($key in @($outcome.fileContents.Keys)) { $fileContents[[string]$key] = [string]$outcome.fileContents[$key] }
                }
                else {
                    foreach ($property in @($outcome.fileContents.PSObject.Properties)) { $fileContents[$property.Name] = [string]$property.Value }
                }
            }

            $duration = if ($null -ne $outcome -and $outcome.durationSeconds) { [double]$outcome.durationSeconds } else { [Math]::Round($clock.Elapsed.TotalSeconds, 3) }
            $reportedUsage = if ($null -ne $outcome) { $outcome.usage } else { $null }
            $usage = ConvertTo-DpEvalUsage -Reported $reportedUsage
            $artifactProblems = if ($null -ne $outcome -and $outcome.artifactProblems) { @($outcome.artifactProblems) } else { @() }

            $metric = @{
                toolCalls         = @($records | Where-Object { $_.kind -eq 'tool_call' }).Count
                iterations        = [int](@($records | Measure-Object -Property iteration -Maximum).Maximum)
                wallSeconds       = $duration
                transcriptRecords = @($records).Count
            }

            $run = ConvertTo-DpEvalRun -Record $records -Answer ([string]$outcome.answer) `
                -ChangedFile @($outcome.changedFiles) -NewCommit ([int]$outcome.newCommits) `
                -FileContent $fileContents -Metric $metric
            $graded = Test-DpEvalCase -Expect $Expect -Run $run

            $trials.Add(@{
                    trial           = $index
                    identity        = $identity
                    status          = if ($graded.complete) { 'completed' } else { 'incomplete' }
                    passed          = if ($graded.complete) { [bool]$graded.passed } else { $null }
                    failed          = @($graded.failed)
                    unavailable     = @($graded.unavailable)
                    safetyFailed    = @($graded.safetyFailed)
                    graders         = @($graded.graders)
                    changedFiles    = @($run.changedFiles)
                    newCommits      = [int]$run.newCommits
                    usage           = $usage
                    metrics         = $metric
                    durationSeconds = $duration
                    artifactProblems = $artifactProblems
                    error           = ''
                })
        }
        catch {
            $clock.Stop()
            $trials.Add(@{
                    trial           = $index
                    identity        = $identity
                    status          = 'incomplete'
                    passed          = $null
                    failed          = @()
                    unavailable     = @()
                    safetyFailed    = @()
                    graders         = @()
                    changedFiles    = @()
                    newCommits      = 0
                    usage           = (ConvertTo-DpEvalUsage)
                    metrics         = @{}
                    durationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
                    artifactProblems = @()
                    error           = "$_"
                })
        }
    }

    @($trials)
}

function Measure-DpEvalCaseOutcome {
    <#
    .SYNOPSIS
        Turns k graded trials into one honest case result.
    .DESCRIPTION
        Three numbers, never one: the first trial is what a user gets on the
        first attempt, pass@k is the best of k, and pass^k is all of k. A case
        with a missing or incomplete trial is reported partial and can never
        reach pass^k, because a sample that never ran is not a sample that passed.
    .PARAMETER CaseId
        The case id.
    .PARAMETER Set
        'capability' or 'regression'.
    .PARAMETER Identity
        The case identity every trial must share.
    .PARAMETER Repeat
        The number of trials that were requested.
    .PARAMETER Trial
        The graded trials.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$CaseId,

        [Parameter(Mandatory)]
        [string]$Set,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Identity,

        [Parameter(Mandatory)]
        [object]$Repeat,

        [AllowEmptyCollection()]
        [object[]]$Trial = @()
    )

    if ($Set -notin @('capability', 'regression')) {
        throw "Case '$CaseId' declares set '$Set'; expected 'capability' or 'regression'."
    }
    $repeatCheck = Test-DpEvalRepeat -Repeat $Repeat
    if (-not $repeatCheck.valid) { throw $repeatCheck.error }
    $samples = $repeatCheck.repeat

    $byIndex = @{}
    foreach ($entry in @($Trial)) {
        if ($null -eq $entry) { continue }
        if ($entry.identity -and [string]$entry.identity -ne $Identity) {
            throw "Case '$CaseId' trial $($entry.trial) ran under identity '$($entry.identity)', not '$Identity'; trials of different configurations cannot be aggregated."
        }
        $byIndex[[int]$entry.trial] = $entry
    }

    $completed = @($Trial | Where-Object { $null -ne $_ -and [string]$_.status -eq 'completed' })
    $incompleteTrials = @($Trial | Where-Object { $null -ne $_ -and [string]$_.status -ne 'completed' } | ForEach-Object { [int]$_.trial } | Sort-Object)
    $missingTrials = @(1..$samples | Where-Object { -not $byIndex.ContainsKey($_) })
    $passedTrials = @($completed | Where-Object { [bool]$_.passed })

    $firstTrialPassed = $null
    if ($byIndex.ContainsKey(1) -and [string]$byIndex[1].status -eq 'completed') { $firstTrialPassed = [bool]$byIndex[1].passed }

    $complete = ($missingTrials.Count -eq 0) -and ($incompleteTrials.Count -eq 0) -and ($completed.Count -eq $samples)
    $status = if ($completed.Count -eq 0) { 'unavailable' } elseif (-not $complete) { 'partial' } else { 'complete' }

    $safetyFailed = @($Trial | Where-Object { $null -ne $_ } | ForEach-Object { @($_.safetyFailed) } | Where-Object { $_ } | Select-Object -Unique)
    $failed = @($Trial | Where-Object { $null -ne $_ } | ForEach-Object { @($_.failed) } | Where-Object { $_ } | Select-Object -Unique)
    $unavailable = @($Trial | Where-Object { $null -ne $_ } | ForEach-Object { @($_.unavailable) } | Where-Object { $_ } | Select-Object -Unique)
    $errors = @($Trial | Where-Object { $null -ne $_ -and $_.error } | ForEach-Object { [string]$_.error } | Select-Object -Unique)
    $artifactProblems = @($Trial | Where-Object { $null -ne $_ } | ForEach-Object { @($_.artifactProblems) } | Where-Object { $_ } | Select-Object -Unique)
    $duration = [Math]::Round([double](@($Trial | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_.durationSeconds }) | Measure-Object -Sum).Sum, 1)

    $anyPassed = ($passedTrials.Count -gt 0)
    # pass^k is a claim about k trials, so it needs k of them. A missing or
    # incomplete sample can never satisfy it, however well the rest went.
    $allPassed = ($complete -and ($passedTrials.Count -eq $samples))
    $setVerdict = if ($Set -eq 'capability') { $anyPassed } else { $allPassed }

    @{
        id               = $CaseId
        set              = $Set
        identity         = $Identity
        samples          = $samples
        completedSamples = $completed.Count
        passedTrialCount = $passedTrials.Count
        firstTrialPassed = $firstTrialPassed
        passedAnyTrial   = $anyPassed
        passedAllTrials  = $allPassed
        # The verdict the gate reaches, and therefore the one a baseline records:
        # the set's rule, no safety violation, and something actually measured.
        gatePassed       = ($setVerdict -and ($safetyFailed.Count -eq 0) -and ($completed.Count -gt 0))
        complete         = $complete
        status           = $status
        incompleteTrials = @($incompleteTrials)
        missingTrials    = @($missingTrials)
        failed           = @($failed)
        unavailable      = @($unavailable)
        safetyFailed     = @($safetyFailed)
        safetyViolated   = ($safetyFailed.Count -gt 0)
        errors           = @($errors)
        artifactProblems = @($artifactProblems)
        durationSeconds  = $duration
        # Every trial that produced a Usage, not only the gradeable ones: a trial
        # that spent credits and then failed to produce a declared artifact is
        # incomplete, never free.
        usage            = (Merge-DpEvalUsage -Usage @($Trial | Where-Object { $null -ne $_ } | ForEach-Object { $_.usage }))
        trials           = @($Trial)
    }
}

function Measure-DpEvalRunOutcome {
    <#
    .SYNOPSIS
        Rolls case outcomes into a run aggregate that hides nothing.
    .DESCRIPTION
        Counts, never bare percentages of an unknown denominator: how many cases
        passed on the first trial, how many reached pass@k, how many reached
        pass^k, how many samples that was over, and which cases were incomplete
        or unavailable. A run with an unavailable case is not complete, and the
        aggregate says so instead of quietly averaging it away.
    .PARAMETER Case
        The case outcomes from Measure-DpEvalCaseOutcome.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Case = @()
    )

    $cases = @($Case | Where-Object { $null -ne $_ })
    $usage = Merge-DpEvalUsage -Usage @($cases | ForEach-Object { $_.usage })
    # The merge counted cases; the honest denominator is trials, so the counts
    # and the partial flag are restated over the trials the cases summed.
    $usage.reportedTrials = [int](@($cases | ForEach-Object { [int]$_.usage.reportedTrials }) | Measure-Object -Sum).Sum
    $usage.totalTrials = [int](@($cases | ForEach-Object { [int]$_.usage.totalTrials }) | Measure-Object -Sum).Sum
    $usage.partial = (($usage.reportedTrials -gt 0) -and ($usage.reportedTrials -lt $usage.totalTrials))

    $firstPassed = @($cases | Where-Object { $_.firstTrialPassed -eq $true }).Count
    $firstFailed = @($cases | Where-Object { $_.firstTrialPassed -eq $false }).Count
    $incomplete = @($cases | Where-Object { [string]$_.status -eq 'partial' } | ForEach-Object { [string]$_.id })
    $unavailable = @($cases | Where-Object { [string]$_.status -eq 'unavailable' } | ForEach-Object { [string]$_.id })

    @{
        caseCount          = $cases.Count
        totalSamples       = [int](@($cases | ForEach-Object { [int]$_.samples }) | Measure-Object -Sum).Sum
        completedSamples   = [int](@($cases | ForEach-Object { [int]$_.completedSamples }) | Measure-Object -Sum).Sum
        firstTrialPassed   = $firstPassed
        firstTrialFailed   = $firstFailed
        firstTrialUnknown  = ($cases.Count - $firstPassed - $firstFailed)
        firstTrialMeasured = ($firstPassed + $firstFailed)
        passedAnyTrial     = @($cases | Where-Object { [bool]$_.passedAnyTrial }).Count
        passedAllTrials    = @($cases | Where-Object { [bool]$_.passedAllTrials }).Count
        safetyViolations   = @($cases | Where-Object { [bool]$_.safetyViolated } | ForEach-Object { [string]$_.id })
        incompleteCases    = @($incomplete)
        unavailableCases   = @($unavailable)
        complete           = (($incomplete.Count -eq 0) -and ($unavailable.Count -eq 0) -and ($cases.Count -gt 0))
        durationSeconds    = [Math]::Round([double](@($cases | ForEach-Object { [double]$_.durationSeconds }) | Measure-Object -Sum).Sum, 1)
        usage              = $usage
        sets               = @{
            capability = @($cases | Where-Object { [string]$_.set -eq 'capability' } | ForEach-Object { [string]$_.id })
            regression = @($cases | Where-Object { [string]$_.set -eq 'regression' } | ForEach-Object { [string]$_.id })
        }
    }
}

function Test-DpEvalGate {
    <#
    .SYNOPSIS
        Decides the run's exit status from the declared sets and the safety
        invariants.
    .DESCRIPTION
        A capability case is gated on pass@k - can it do this at all - and a
        regression case on pass^k - does it still do it every time. A safety
        invariant fails the case whatever its set: an unrequested commit is not
        excused by two clean trials. A case that produced no usable sample fails
        the gate instead of being scored, because an unmeasured case is not a
        passing one.
    .PARAMETER Case
        The case outcomes.
    .OUTPUTS
        System.Collections.Hashtable with ok, reasons and exitCode.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Case = @()
    )

    $cases = @($Case | Where-Object { $null -ne $_ })
    $reasons = [System.Collections.Generic.List[string]]::new()

    if ($cases.Count -eq 0) {
        $reasons.Add('no case was executed, so there is nothing to gate on.')
    }

    foreach ($outcome in $cases) {
        $id = [string]$outcome.id
        if ([bool]$outcome.safetyViolated) {
            $reasons.Add("$($id): violated a safety invariant ($((@($outcome.safetyFailed)) -join ', ')).")
        }
        if ([int]$outcome.completedSamples -le 0) {
            $reasons.Add("$($id): no completed trial, so it cannot be scored.")
            continue
        }
        switch ([string]$outcome.set) {
            'capability' {
                if (-not [bool]$outcome.passedAnyTrial) {
                    $suffix = if (-not [bool]$outcome.complete) { ' and the sample is incomplete' } else { '' }
                    $reasons.Add("$($id): failed pass@k - no trial passed$suffix.")
                }
            }
            'regression' {
                if (-not [bool]$outcome.complete) {
                    $reasons.Add("$($id): incomplete sample ($($outcome.completedSamples)/$($outcome.samples)), so pass^k cannot be claimed.")
                }
                elseif (-not [bool]$outcome.passedAllTrials) {
                    $reasons.Add("$($id): failed pass^k - $($outcome.passedTrialCount)/$($outcome.samples) trials passed ($((@($outcome.failed)) -join ', ')).")
                }
            }
            default {
                $reasons.Add("$($id): declares an unknown set '$($outcome.set)'.")
            }
        }
    }

    $ok = ($reasons.Count -eq 0)
    @{ ok = $ok; reasons = @($reasons); exitCode = $(if ($ok) { 0 } else { 1 }) }
}

function Test-DpEvalLiveRunAllowed {
    <#
    .SYNOPSIS
        Says whether a live, paid run may start here.
    .DESCRIPTION
        A live run sends real prompts and spends real credits, so it stays an
        explicit local act. Automation is refused: the offline self-check is what
        CI runs, and nothing in CI should be able to reach a Model.
    .PARAMETER Environment
        The environment variables to inspect. Defaults to the process environment.
    .OUTPUTS
        System.Collections.Hashtable with allowed and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Environment
    )

    if (-not $PSBoundParameters.ContainsKey('Environment')) {
        $Environment = @{}
        foreach ($name in @('CI', 'GITHUB_ACTIONS', 'TF_BUILD', 'GITLAB_CI', 'JENKINS_URL')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ($null -ne $value) { $Environment[$name] = $value }
        }
    }

    foreach ($name in @('CI', 'GITHUB_ACTIONS', 'TF_BUILD', 'GITLAB_CI', 'JENKINS_URL')) {
        if (-not $Environment.ContainsKey($name)) { continue }
        $value = [string]$Environment[$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value -in @('0', 'false', 'False', 'FALSE', 'no')) { continue }
        return @{
            allowed = $false
            reason  = "Refusing a live run: '$name' is set, so this is CI. A live run spends real credits and must be started explicitly by a person. Use -Offline for the self-check."
        }
    }

    @{ allowed = $true; reason = '' }
}

function Format-DpEvalTrialSummary {
    <#
    .SYNOPSIS
        Renders a repeated-trial run as the Markdown summary a human reads.
    .DESCRIPTION
        The three rates are printed side by side and never collapsed into one
        headline, incomplete and unavailable cases are named rather than
        averaged away, and an unreported cost prints as `unknown` instead of a
        zero that would read as free.
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

    $show = {
        param($Value)
        if ($null -eq $Value -or "$Value" -eq '') { 'unknown' } else { "$Value" }
    }
    $tick = {
        param($Value)
        if ($null -eq $Value) { 'unknown' } elseif ([bool]$Value) { 'yes' } else { 'no' }
    }

    $cases = @($Result.cases)
    $aggregate = $Result.aggregate
    $lines = [System.Collections.Generic.List[string]]::new()

    # The JSON round-trip parses the ISO timestamp into a DateTime, and a
    # DateTime formats in the reader's locale. A line labelled UTC must say UTC.
    $started = $Result.startedUtc
    if ($started -is [datetime]) { $started = ([datetime]$started).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

    $lines.Add('# DeskPilot parity eval run')
    $lines.Add('')
    $lines.Add("- Run: ``$($Result.runId)`` at $started")
    $lines.Add("- Mode: ``$($Result.mode)``")
    $lines.Add("- DeskPilot commit: ``$($Result.deskPilotSha)``")
    $lines.Add("- Trials per case (k): **$($Result.repeat)**")
    $lines.Add("- Cases: **$($aggregate.caseCount)** over **$($aggregate.totalSamples)** requested samples, **$($aggregate.completedSamples)** completed")
    $lines.Add("- First trial passed: **$($aggregate.firstTrialPassed) / $($aggregate.firstTrialMeasured) measured** ($($aggregate.firstTrialUnknown) unknown)")
    $lines.Add("- pass@k (at least one of k): **$($aggregate.passedAnyTrial) / $($aggregate.caseCount)**")
    $lines.Add("- pass^k (all of k): **$($aggregate.passedAllTrials) / $($aggregate.caseCount)**")
    $lines.Add("- Duration: $($aggregate.durationSeconds)s")
    if ([bool]$aggregate.usage.reported) {
        $partial = if ([bool]$aggregate.usage.partial) { ' (partial: not every trial reported a Usage)' } else { '' }
        $lines.Add("- Usage over $($aggregate.usage.reportedTrials)/$($aggregate.usage.totalTrials) trials: $(& $show $aggregate.usage.promptTokens) prompt + $(& $show $aggregate.usage.completionTokens) completion tokens, $(& $show $aggregate.usage.costUSD) USD$partial")
    }
    else {
        $lines.Add('- Usage: **unknown** - no trial reported a priced Usage. Unknown is not zero.')
    }
    if (@($aggregate.incompleteCases).Count) { $lines.Add("- Incomplete cases (partially sampled): $((@($aggregate.incompleteCases)) -join ', ')") }
    if (@($aggregate.unavailableCases).Count) { $lines.Add("- Unavailable cases (never measured): $((@($aggregate.unavailableCases)) -join ', ')") }
    if (-not [bool]$aggregate.complete) {
        $lines.Add('- **This run is incomplete.** The rates above are over the cases that were measured and must not be quoted as a corpus pass rate.')
    }
    $lines.Add("- Gate: **$(if ([bool]$Result.gate.ok) { 'pass' } else { 'FAIL' })**")
    foreach ($reason in @($Result.gate.reasons)) { $lines.Add("  - $reason") }
    foreach ($caveat in @($Result.caveats)) { $lines.Add("- Caveat: $caveat") }

    $lines.Add('')
    $lines.Add('## Cases')
    $lines.Add('')
    $lines.Add('| Case | Set | Status | first trial | pass@k | pass^k | passed/completed/k | Safety |')
    $lines.Add('|---|---|---|---|---|---|---|---|')
    foreach ($case in $cases) {
        $safety = if ([bool]$case.safetyViolated) { "VIOLATED: $((@($case.safetyFailed)) -join ', ')" } else { 'ok' }
        $lines.Add("| $($case.id) | $($case.set) | $($case.status) | $(& $tick $case.firstTrialPassed) | $(& $tick $case.passedAnyTrial) | $(& $tick $case.passedAllTrials) | $($case.passedTrialCount)/$($case.completedSamples)/$($case.samples) | $safety |")
    }

    $lines.Add('')
    $lines.Add('## Efficiency and Usage (recorded, never graded)')
    $lines.Add('')
    $lines.Add('A cheaper run that is wrong is not better. `unknown` means no Usage was reported; it does not mean free.')
    $lines.Add('')
    $lines.Add('| Case | Duration s | Prompt tok | Completion tok | Cost USD | Trials priced |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($case in $cases) {
        $usage = $case.usage
        $priced = if ($null -eq $usage) { 'unknown' } else { "$($usage.reportedTrials)/$($usage.totalTrials)" }
        $lines.Add("| $($case.id) | $($case.durationSeconds) | $(& $show $usage.promptTokens) | $(& $show $usage.completionTokens) | $(& $show $usage.costUSD) | $priced |")
    }

    $lines.Add('')
    $lines.Add('## What these numbers are not')
    $lines.Add('')
    $lines.Add('- `first trial` is the single attempt a user would have got. `pass@k` is the best of k. `pass^k` is all of k.')
    $lines.Add('- A case marked `partial` or `unavailable` was not measured k times, so no pass^k claim is made for it.')
    $lines.Add('- Reference: <https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents>')
    $lines.Add('')

    ($lines -join "`n")
}
