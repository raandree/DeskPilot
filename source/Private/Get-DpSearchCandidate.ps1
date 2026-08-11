function Get-DpSearchCandidate {
    <#
    .SYNOPSIS
        Resolves the Workspace Folder and lists the files a search may look at.
    .DESCRIPTION
        The single place the search Tools decide what they are allowed to see, so
        confinement, the ignore rules and the exclusion list are stated once
        instead of once per Tool.

        - The root is the Workspace Folder and nothing else. No Project means no
          search: falling back to the process working directory would silently
          point the model at whatever folder DeskPilot happened to be launched
          from, which is the launcher's folder and not the user's.
        - Inside a git work tree the listing comes from `git ls-files --cached
          --others --exclude-standard`, so .gitignore is honoured for free and an
          ignored secret is never offered to the model. `-- .` keeps a Project
          that sits inside a larger repository from listing its siblings.
        - .git, node_modules, output, bin and obj are dropped whether git tracks
          them or not.
        - Every candidate goes through Resolve-DpWorkspacePath, so a symlink or
          junction that points outside the Workspace Folder is not a way out of
          it - and the search and edit Tools share one confinement test rather
          than two that can drift.

        Never throws. An unusable root, an exhausted budget and an over-large
        tree are all reported on the result.
    .PARAMETER Root
        The Workspace Folder. Empty, missing or not a folder yields ok = $false.
    .PARAMETER DeadlineUtc
        The wall-clock deadline shared with the caller's own matching. Reaching
        it stops enumeration and sets timedOut, so a slow folder costs part of
        the result rather than the whole Tool call.
    .PARAMETER MaxFiles
        The most candidates to enumerate. Over the cap enumeration stops and
        truncated is set.
    .OUTPUTS
        System.Collections.Hashtable with ok, error, message, root, paths
        (workspace-relative, forward-slash), truncated and timedOut.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Root,

        [datetime]$DeadlineUtc = ([datetime]::UtcNow.AddSeconds(10)),

        [ValidateRange(1, 500000)]
        [int]$MaxFiles = 20000
    )

    $noWorkspace = @{
        ok        = $false
        error     = 'no-workspace'
        message   = ''
        root      = ''
        paths     = @()
        truncated = $false
        timedOut  = $false
    }

    $rootResolution = Resolve-DpWorkspaceRoot -Root $Root
    if (-not $rootResolution.ok) {
        $noWorkspace.message = [string]$rootResolution.message
        return $noWorkspace
    }
    $resolvedRoot = [string]$rootResolution.root

    $excluded = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('.git', 'node_modules', 'output', 'bin', 'obj'),
        [StringComparer]::OrdinalIgnoreCase)

    $expired = { [datetime]::UtcNow -ge $DeadlineUtc }


    $timedOut = $false
    $truncated = $false
    $relativePaths = @()

    $inside = $null
    $budgetSeconds = [int][Math]::Ceiling(($DeadlineUtc - [datetime]::UtcNow).TotalSeconds)
    if ($budgetSeconds -le 0) {
        $timedOut = $true
    }
    else {
        # Invoke-DpGitCommand reads 0 seconds as "wait forever", so no git call is
        # ever made with none of the budget left.
        $inside = Invoke-DpGitCommand -Path $resolvedRoot -Arguments @('rev-parse', '--is-inside-work-tree') -TimeoutSeconds $budgetSeconds
    }

    $isRepo = $null -ne $inside -and $inside.Ok -and $inside.StdOut.Trim() -eq 'true'

    if ($isRepo) {
        $budgetSeconds = [int][Math]::Ceiling(($DeadlineUtc - [datetime]::UtcNow).TotalSeconds)
        if ($budgetSeconds -le 0) {
            $timedOut = $true
        }
        else {
            $listed = Invoke-DpGitCommand -Path $resolvedRoot -Arguments @('ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', '.') -TimeoutSeconds $budgetSeconds
            if ($listed.TimedOut) { $timedOut = $true }
            elseif ($listed.Ok) { $relativePaths = @($listed.StdOut -split "`0" | Where-Object { $_ }) }
            # A failed ls-files inside a repository would silently become "no
            # matches", which reads as a false negative. Say the search was cut
            # short instead.
            else { $timedOut = $true }
        }
    }
    elseif (-not $timedOut) {
        $found = [System.Collections.Generic.List[string]]::new()
        $pending = [System.Collections.Generic.Stack[object]]::new()
        $pending.Push(@{ Dir = $resolvedRoot; Prefix = '' })
        while ($pending.Count -gt 0) {
            if (& $expired) { $timedOut = $true; break }
            if ($found.Count -ge $MaxFiles) { $truncated = $true; break }
            $node = $pending.Pop()
            try {
                foreach ($file in [System.IO.Directory]::EnumerateFiles($node.Dir)) {
                    $found.Add($node.Prefix + [System.IO.Path]::GetFileName($file))
                }
                foreach ($child in [System.IO.Directory]::EnumerateDirectories($node.Dir)) {
                    $name = [System.IO.Path]::GetFileName($child)
                    if ($excluded.Contains($name)) { continue }
                    # A junction is the cheapest way out of the Workspace Folder,
                    # so the walk refuses to follow one that leaves it.
                    try {
                        $childLink = [System.IO.Directory]::ResolveLinkTarget($child, $true)
                        if ($childLink -and -not (Resolve-DpWorkspacePath -Root $resolvedRoot -Path $childLink.FullName)) { continue }
                    }
                    catch { continue }
                    $pending.Push(@{ Dir = $child; Prefix = ($node.Prefix + $name + '/') })
                }
            }
            catch {
                # An unreadable folder costs its own contents, never the search.
                $enumerationError = $_
                Write-Verbose "Could not list '$($node.Dir)': $enumerationError"
            }
        }
        $relativePaths = @($found)
    }

    $accepted = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $checked = 0
    foreach ($relative in $relativePaths) {
        $checked++
        if (($checked % 256) -eq 0 -and (& $expired)) { $timedOut = $true; break }
        if ($accepted.Count -ge $MaxFiles) { $truncated = $true; break }

        $normalized = ($relative -replace '\\', '/')
        $segments = @($normalized -split '/' | Where-Object { $_ -and $_ -ne '.' })
        if ($segments.Count -eq 0) { continue }
        $skip = $false
        foreach ($segment in $segments) {
            if ($segment -eq '..' -or $excluded.Contains($segment)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $normalized = $segments -join '/'
        if (-not $seen.Add($normalized)) { continue }
        if (-not (Resolve-DpWorkspacePath -Root $resolvedRoot -Path $normalized)) { continue }
        $accepted.Add($normalized)
    }

    # Sorted so a capped result set is the same result set every time: the walk
    # yields whatever order the file system does, and "the first 200" has to mean
    # something stable or a repeated search looks like a changed repository.
    @{
        ok        = $true
        error     = ''
        message   = ''
        root      = $resolvedRoot
        paths     = @($accepted | Sort-Object -CaseSensitive:$false)
        truncated = $truncated
        timedOut  = $timedOut
    }
}
