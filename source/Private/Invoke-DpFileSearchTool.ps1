function Invoke-DpFileSearchTool {
    <#
    .SYNOPSIS
        The search_files Tool: finds files in the Workspace Folder by name or path.
    .DESCRIPTION
        Runs inside the Engine Runspace as the backing command of the registered
        search_files Tool, so its parameter names are the JSON argument names the
        model sends and its output is the JSON envelope the model reads.

        The root is never a parameter. It is read from the Runspace-global
        DeskPilotWorkspaceRoot that Set-DpWorkspaceTool writes from the Workspace
        Folder, so no argument the model can produce moves the search - and with
        no Project selected the answer is a structured error, never the process
        working directory.

        The result cap and the wall-clock budget are literals rather than
        parameters for the same reason: every parameter becomes a field in the
        JSON schema the model is free to fill in, and a cap the model can raise
        is not a cap. Both bounds are reported - truncated is set whenever
        anything was left out, because a silently short result set teaches the
        model a false negative, which is worse than no search at all.
    .PARAMETER pattern
        The glob, relative to the Workspace Folder. A pattern with no '/' also
        matches on the file name alone, so 'Invoke-DpTurn*' finds a nested file.
    .PARAMETER maxResults
        The most paths to return. Clamped to the Tool's own cap; 0 or absent
        means the cap.
    .OUTPUTS
        System.String

        A compact JSON envelope: pattern, root, totalMatches, returned,
        truncated, timedOut and paths (workspace-relative, forward-slash); or
        error and message when the call could not be served.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$pattern,

        [int]$maxResults = 0
    )

    $resultCap = 200
    $deadline = [datetime]::UtcNow.AddSeconds(10)

    $patternError = Get-DpSearchPatternError -Pattern $pattern -Name 'pattern'
    if ($patternError) {
        return (@{ error = 'invalid-pattern'; message = $patternError; pattern = [string]$pattern } | ConvertTo-Json -Compress -Depth 4)
    }

    $root = ''
    $rootVariable = Get-Variable -Name 'DeskPilotWorkspaceRoot' -Scope Global -ErrorAction SilentlyContinue
    if ($rootVariable) { $root = [string]$rootVariable.Value }

    $candidates = Get-DpSearchCandidate -Root $root -DeadlineUtc $deadline
    if (-not $candidates.ok) {
        return (@{ error = $candidates.error; message = $candidates.message; pattern = [string]$pattern } | ConvertTo-Json -Compress -Depth 4)
    }

    $cap = if ($maxResults -gt 0) { [Math]::Min($maxResults, $resultCap) } else { $resultCap }

    $matcher = ConvertTo-DpSearchRegex -Glob $pattern
    # A bare '*.ps1' is what a model writes when it means "anywhere", and matching
    # it against the whole path would answer "no such file" for a repository full
    # of them. A pattern that names a folder is taken at its word.
    $matchLeaf = ($pattern -replace '\\', '/') -notmatch '/'

    $total = 0
    $paths = [System.Collections.Generic.List[string]]::new()
    $timedOut = [bool]$candidates.timedOut
    $checked = 0
    foreach ($relative in $candidates.paths) {
        $checked++
        if (($checked % 512) -eq 0 -and [datetime]::UtcNow -ge $deadline) { $timedOut = $true; break }
        $hit = $matcher.IsMatch($relative)
        if (-not $hit -and $matchLeaf) { $hit = $matcher.IsMatch(($relative -split '/')[-1]) }
        if (-not $hit) { continue }
        $total++
        if ($paths.Count -lt $cap) { $paths.Add($relative) }
    }

    @{
        pattern      = [string]$pattern
        root         = [string]$candidates.root
        totalMatches = $total
        returned     = $paths.Count
        truncated    = ($paths.Count -lt $total) -or [bool]$candidates.truncated -or $timedOut
        timedOut     = $timedOut
        paths        = @($paths)
    } | ConvertTo-Json -Compress -Depth 4
}
