function Invoke-DpTextSearchTool {
    <#
    .SYNOPSIS
        The search_text Tool: finds text or a regex in the Workspace Folder.
    .DESCRIPTION
        Runs inside the Engine Runspace as the backing command of the registered
        search_text Tool, so its parameter names are the JSON argument names the
        model sends and its output is the JSON envelope the model reads. Like
        search_files it takes no root: the Workspace Folder arrives out of band
        on the Runspace-global DeskPilotSearchRoot, and no Project means a
        structured error rather than a search of the launcher's folder.

        A regex is the one place a model-supplied string becomes an expression,
        so it is bounded twice: an unparseable pattern is answered with a
        structured error instead of a thrown exception, and every match runs
        under a one-second regex timeout so a catastrophically backtracking
        pattern costs the file it was matching rather than the Turn.

        Binary files are skipped by looking for a NUL byte in the first block,
        which is what git itself does - returning the middle of a DLL as a
        "match" spends context on noise.

        The result cap, the per-match text length and the wall-clock budget are
        literals rather than parameters: every parameter becomes a field in the
        JSON schema the model is free to fill in, and a cap the model can raise
        is not a cap.
    .PARAMETER query
        The text to find, or the regex when isRegex is true. Case-insensitive.
    .PARAMETER isRegex
        Read query as a .NET regular expression instead of literal text.
    .PARAMETER includePattern
        A glob limiting which files are searched, relative to the Workspace
        Folder. A pattern with no '/' also matches on the file name alone.
    .PARAMETER maxResults
        The most matches to return. Clamped to the Tool's own cap; 0 or absent
        means the cap.
    .OUTPUTS
        System.String

        A compact JSON envelope: query, root, totalMatches, returned, truncated,
        timedOut and matches (path, line, text); or error and message when the
        call could not be served.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$query,

        [bool]$isRegex = $false,

        [AllowEmptyString()]
        [string]$includePattern = '',

        [int]$maxResults = 0
    )

    $resultCap = 200
    $textCap = 200
    $deadline = [datetime]::UtcNow.AddSeconds(10)

    if ([string]::IsNullOrEmpty($query)) {
        return (@{ error = 'invalid-query'; message = 'query is required and must not be empty.'; query = [string]$query } | ConvertTo-Json -Compress -Depth 4)
    }

    if (-not [string]::IsNullOrWhiteSpace($includePattern)) {
        $includeError = Get-DpSearchPatternError -Pattern $includePattern -Name 'includePattern'
        if ($includeError) {
            return (@{ error = 'invalid-pattern'; message = $includeError; query = [string]$query } | ConvertTo-Json -Compress -Depth 4)
        }
    }

    $matcher = $null
    try {
        $expression = if ($isRegex) { $query } else { [regex]::Escape($query) }
        $matcher = [regex]::new($expression, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, [timespan]::FromSeconds(1))
    }
    catch {
        $regexError = $_
        return (@{
                error   = 'invalid-regex'
                message = "query is not a valid regular expression: $($regexError.Exception.Message) Fix the expression, or set isRegex to false to search for it literally."
                query   = [string]$query
            } | ConvertTo-Json -Compress -Depth 4)
    }

    $root = ''
    $rootVariable = Get-Variable -Name 'DeskPilotSearchRoot' -Scope Global -ErrorAction SilentlyContinue
    if ($rootVariable) { $root = [string]$rootVariable.Value }

    $candidates = Get-DpSearchCandidate -Root $root -DeadlineUtc $deadline
    if (-not $candidates.ok) {
        return (@{ error = $candidates.error; message = $candidates.message; query = [string]$query } | ConvertTo-Json -Compress -Depth 4)
    }

    $cap = if ($maxResults -gt 0) { [Math]::Min($maxResults, $resultCap) } else { $resultCap }

    $includeMatcher = $null
    $includeLeaf = $false
    if (-not [string]::IsNullOrWhiteSpace($includePattern)) {
        $includeMatcher = ConvertTo-DpSearchRegex -Glob $includePattern
        $includeLeaf = ($includePattern -replace '\\', '/') -notmatch '/'
    }

    $total = 0
    $found = [System.Collections.Generic.List[hashtable]]::new()
    $timedOut = [bool]$candidates.timedOut

    foreach ($relative in $candidates.paths) {
        if ([datetime]::UtcNow -ge $deadline) { $timedOut = $true; break }

        if ($includeMatcher) {
            $included = $includeMatcher.IsMatch($relative)
            if (-not $included -and $includeLeaf) { $included = $includeMatcher.IsMatch(($relative -split '/')[-1]) }
            if (-not $included) { continue }
        }

        $full = [System.IO.Path]::Combine($candidates.root, ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-DpBinaryFile -Path $full) { continue }

        $lineNumber = 0
        try {
            foreach ($line in [System.IO.File]::ReadLines($full)) {
                $lineNumber++
                if (($lineNumber % 2048) -eq 0 -and [datetime]::UtcNow -ge $deadline) { $timedOut = $true; break }
                if (-not $matcher.IsMatch($line)) { continue }
                $total++
                if ($found.Count -ge $cap) { continue }
                $text = ($line -replace '\p{C}', ' ').Trim()
                if ($text.Length -gt $textCap) { $text = $text.Substring(0, $textCap - 1) + '…' }
                $found.Add(@{ path = $relative; line = $lineNumber; text = $text })
            }
        }
        catch {
            # An unreadable, locked or pathologically slow file costs its own
            # lines, never the search.
            $readError = $_
            Write-Verbose "Could not search '$relative': $readError"
        }
        if ($timedOut) { break }
    }

    @{
        query        = [string]$query
        root         = [string]$candidates.root
        totalMatches = $total
        returned     = $found.Count
        truncated    = ($found.Count -lt $total) -or [bool]$candidates.truncated -or $timedOut
        timedOut     = $timedOut
        matches      = @($found)
    } | ConvertTo-Json -Compress -Depth 4
}
