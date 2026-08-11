function Get-DpWorkspaceContext {
    <#
    .SYNOPSIS
        Describes the Workspace Folder for the system prompt: repository state and
        a bounded file tree.
    .DESCRIPTION
        The Engine's system prompt names the Workspace Folder and nothing else, so
        the model begins a Turn knowing only a path. Everything an editor-hosted
        assistant is handed for free - which branch, whether the tree is dirty,
        what files exist - has to be bought here with tool calls, and measurably
        often is not bought at all: the model answers from the path alone.

        This gathers the cheap half of that context once per Turn:

        - Repository state: the branch (or a short commit id when detached),
          whether the working tree has uncommitted changes, and the upstream
          branch. Never the diff and never the log - those are large, and the model
          can ask for them.
        - A file tree, bounded by entry count and by depth.

        The cost is capped three ways. Inside a repository `git ls-files` supplies
        the listing, which is faster than walking the tree and honours .gitignore
        for free. Everything is bounded by one wall-clock budget, so a slow or
        enormous folder yields NO context rather than delaying the Turn. And over
        the entry cap the tree collapses its deepest folders to "name/ (12 files)"
        instead of truncating: a truncated listing teaches the model that the
        repository ends where the budget did.

        Never throws. A missing folder, a missing git, a non-repository folder and
        an exhausted budget are all reported as an empty text.
    .PARAMETER Path
        The Workspace Folder to describe. Empty or missing yields no context.
    .PARAMETER MaxEntries
        The most tree lines to emit. Over the cap the tree is re-rendered one
        folder level shallower until it fits.
    .PARAMETER MaxDepth
        The most path segments any entry may show.
    .PARAMETER TimeoutSeconds
        The overall wall-clock budget. Exceeding it yields no context.
    .OUTPUTS
        System.Collections.Hashtable with:
        - text: the composed system-prompt part, or '' when there is nothing to say
        - entryCount: the number of tree lines emitted
        - collapsed: whether any folder was collapsed to a file count
        - truncated: whether entries had to be dropped outright
        - isRepo: whether the folder is inside a git work tree
        - branch: the branch name, or the short commit id when detached
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [ValidateRange(10, 20000)]
        [int]$MaxEntries = 400,

        [ValidateRange(1, 32)]
        [int]$MaxDepth = 4,

        [ValidateRange(1, 60)]
        [int]$TimeoutSeconds = 2
    )

    $empty = @{ text = ''; entryCount = 0; collapsed = $false; truncated = $false; isRepo = $false; branch = $null }

    if ([string]::IsNullOrWhiteSpace($Path)) { return $empty }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $empty }

    $excluded = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('.git', 'node_modules', 'output', 'bin', 'obj'),
        [StringComparer]::OrdinalIgnoreCase)

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetMs = $TimeoutSeconds * 1000

    # Every git call is bounded by what is LEFT of the budget, and none is made
    # with nothing left: Invoke-DpGitCommand reads 0 seconds as "wait forever",
    # which on the single accept thread is the same sentence as a frozen window.
    $runGit = {
        param([string[]]$GitArgument)
        $leftMs = $budgetMs - [int]$clock.ElapsedMilliseconds
        if ($leftMs -le 0) { return $null }
        $outcome = Invoke-DpGitCommand -Path $Path -Arguments $GitArgument -TimeoutSeconds ([int][Math]::Ceiling($leftMs / 1000.0))
        if ($outcome.TimedOut) { return $null }
        $outcome
    }

    $isRepo = $false
    $branch = $null
    $detached = $false
    $upstream = $null
    $dirty = $false

    $inside = & $runGit @('rev-parse', '--is-inside-work-tree')
    if ($null -eq $inside) { return $empty }
    # A folder that is not a repository - and a machine with no git at all - still
    # gets a tree. Only the repository line is withheld.
    if ($inside.Ok -and $inside.StdOut.Trim() -eq 'true') { $isRepo = $true }

    $relativePaths = @()

    if ($isRepo) {
        $current = & $runGit @('branch', '--show-current')
        if ($null -eq $current) { return $empty }
        $branch = if ($current.Ok) { $current.StdOut.Trim() } else { '' }
        if (-not $branch) {
            $detached = $true
            $short = & $runGit @('rev-parse', '--short', 'HEAD')
            if ($null -eq $short) { return $empty }
            $branch = if ($short.Ok) { $short.StdOut.Trim() } else { 'detached' }
        }

        $tracking = & $runGit @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
        if ($null -eq $tracking) { return $empty }
        if ($tracking.Ok) { $upstream = $tracking.StdOut.Trim() }

        # Bounded to the Project with `-- .`, like every other read: a Project
        # inside a larger repository must not report its siblings' edits as its own.
        $status = & $runGit @('status', '--porcelain', '--untracked-files=normal', '--', '.')
        if ($null -eq $status) { return $empty }
        if ($status.Ok) { $dirty = -not [string]::IsNullOrWhiteSpace($status.StdOut) }

        # Inside a repository this listing IS the answer, and it is the one that
        # honours .gitignore. A failure here would make the context wrong rather
        # than partial, so nothing is added at all.
        $listed = & $runGit @('ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', '.')
        if ($null -eq $listed -or -not $listed.Ok) { return $empty }
        $relativePaths = @($listed.StdOut -split "`0" | Where-Object { $_ })
    }
    else {
        $found = [System.Collections.Generic.List[string]]::new()
        $pending = [System.Collections.Generic.Stack[object]]::new()
        $pending.Push(@{ Dir = $Path; Prefix = '' })
        while ($pending.Count -gt 0) {
            # With no repository to ask, the budget is the only bound there is - a
            # junction loop or a home directory would otherwise walk forever - so it
            # is checked per folder rather than once at the end.
            if ($clock.ElapsedMilliseconds -ge $budgetMs) { return $empty }
            $node = $pending.Pop()
            try {
                foreach ($file in [System.IO.Directory]::EnumerateFiles($node.Dir)) {
                    $found.Add($node.Prefix + [System.IO.Path]::GetFileName($file))
                }
                foreach ($child in [System.IO.Directory]::EnumerateDirectories($node.Dir)) {
                    $name = [System.IO.Path]::GetFileName($child)
                    if ($excluded.Contains($name)) { continue }
                    $pending.Push(@{ Dir = $child; Prefix = ($node.Prefix + $name + '/') })
                }
            }
            catch {
                # An unreadable folder costs its own contents, never the block.
                $enumerationError = $_
                Write-Verbose "Could not list '$($node.Dir)': $enumerationError"
            }
        }
        $relativePaths = @($found)
    }

    $root = @{ dirs = [ordered]@{}; files = [System.Collections.Generic.List[string]]::new(); count = 0 }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($relative in $relativePaths) {
        if (-not $seen.Add($relative)) { continue }
        $segments = @(($relative -replace '\\', '/') -split '/' | Where-Object { $_ -and $_ -ne '.' })
        if ($segments.Count -eq 0) { continue }

        $skip = $false
        foreach ($segment in $segments) {
            if ($excluded.Contains($segment)) { $skip = $true; break }
        }
        if ($skip) { continue }

        # One line per entry only holds if no name carries a line break, and a line
        # break is a legal character in a file name on Linux.
        $segments = @($segments | ForEach-Object { ($_ -replace '\p{C}', ' ').Trim() } | Where-Object { $_ })
        if ($segments.Count -eq 0) { continue }

        $node = $root
        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
            $node.count++
            $name = $segments[$i]
            if (-not $node.dirs.Contains($name)) {
                $node.dirs[$name] = @{ dirs = [ordered]@{}; files = [System.Collections.Generic.List[string]]::new(); count = 0 }
            }
            $node = $node.dirs[$name]
        }
        $node.count++
        $node.files.Add($segments[-1])
    }

    # Depth-first, folders before files, so a folder's contents follow its own line.
    $renderTree = {
        param([int]$EffectiveDepth)
        $lines = [System.Collections.Generic.List[string]]::new()
        $collapsedAny = $false
        $work = [System.Collections.Generic.Stack[object]]::new()
        $pushChildren = {
            param($Parent, [int]$Depth)
            $fileNames = @($Parent.files | Sort-Object)
            for ($i = $fileNames.Count - 1; $i -ge 0; $i--) {
                $work.Push(@{ kind = 'file'; name = $fileNames[$i]; depth = $Depth })
            }
            $dirNames = @($Parent.dirs.Keys | Sort-Object)
            for ($i = $dirNames.Count - 1; $i -ge 0; $i--) {
                $work.Push(@{ kind = 'dir'; name = $dirNames[$i]; node = $Parent.dirs[$dirNames[$i]]; depth = $Depth })
            }
        }
        & $pushChildren $root 1
        while ($work.Count -gt 0) {
            $item = $work.Pop()
            $indent = '  ' * ($item.depth - 1)
            if ($item.kind -eq 'file') {
                $lines.Add($indent + $item.name)
                continue
            }
            if ($item.depth -ge $EffectiveDepth) {
                $noun = if ($item.node.count -eq 1) { 'file' } else { 'files' }
                $lines.Add(('{0}{1}/ ({2} {3})' -f $indent, $item.name, $item.node.count, $noun))
                $collapsedAny = $true
                continue
            }
            $lines.Add($indent + $item.name + '/')
            & $pushChildren $item.node ($item.depth + 1)
        }
        @{ lines = $lines; collapsed = $collapsedAny }
    }

    $effectiveDepth = $MaxDepth
    $rendered = & $renderTree $effectiveDepth
    while ($rendered.lines.Count -gt $MaxEntries -and $effectiveDepth -gt 1) {
        $effectiveDepth--
        $rendered = & $renderTree $effectiveDepth
    }

    $lines = @($rendered.lines)
    $truncated = $false
    $dropped = 0
    if ($lines.Count -gt $MaxEntries) {
        # One level deep and still over the cap: there is nothing left to collapse,
        # so the only honest option is to drop entries and say how many.
        $dropped = $lines.Count - $MaxEntries
        $lines = @($lines[0..($MaxEntries - 1)])
        $truncated = $true
    }

    $block = [System.Collections.Generic.List[string]]::new()
    $block.Add('Workspace context, gathered for you before this turn. Use it instead of spending tool calls to rediscover it.')

    if ($isRepo) {
        $where = if ($detached) { "detached at commit $branch" } else { "on branch $branch" }
        $track = if ($upstream) { ", tracking $upstream" } else { '' }
        $state = if ($dirty) { 'the working tree has uncommitted changes' } else { 'the working tree is clean' }
        $block.Add("Git repository: $where$track; $state.")
    }

    if ($lines.Count -eq 0) {
        $block.Add('The workspace folder contains no files.')
    }
    else {
        $bound = "Files, relative to the workspace folder. Ignored files and the folders .git, node_modules, output, bin and obj are never listed, and the listing is bounded to $MaxEntries entries and $effectiveDepth folder levels - treat it as partial and use list_directory to go deeper."
        if ($rendered.collapsed) {
            $bound += ' A folder written as "name/ (12 files)" holds that many files and was not expanded.'
        }
        if ($truncated) {
            $bound += " $dropped further entries did not fit and are not listed."
        }
        $block.Add($bound)
        $block.Add(($lines -join "`n"))
    }

    @{
        text       = ($block -join "`n`n")
        entryCount = $lines.Count
        collapsed  = [bool]$rendered.collapsed
        truncated  = $truncated
        isRepo     = $isRepo
        branch     = $branch
    }
}
