function Get-DpMergeConflict {
    <#
    .SYNOPSIS
        Lists and classifies the conflicted files of an in-progress merge.
    .DESCRIPTION
        Returns the unmerged paths of the current merge, each classified as text or
        binary. For text files it reads the working-tree content (with the
        <<<<<<< ======= >>>>>>> conflict markers) so the AI can propose a Merge
        Plan; binary files carry no content and are resolved by a keep-ours /
        keep-theirs choice instead. Content is capped at MaxBytes. Never throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER MaxBytes
        The per-file content cap for text conflicts.
    .OUTPUTS
        System.Collections.Hashtable with inMerge, files and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [int]$MaxBytes = 200KB
    )

    $result = @{ inMerge = $false; files = @(); error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $mergeHead = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', 'MERGE_HEAD')
    $result.inMerge = $mergeHead.Ok

    # Classify binary vs text via numstat: binary files show "-\t-\t<path>".
    $binarySet = [System.Collections.Generic.HashSet[string]]::new()
    $numstat = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--numstat', '--diff-filter=U')
    if ($numstat.Ok) {
        foreach ($line in ($numstat.StdOut -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t", 3
            if ($parts.Count -ge 3 -and $parts[0] -eq '-' -and $parts[1] -eq '-') { [void]$binarySet.Add($parts[2].Trim()) }
        }
    }

    $names = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--name-only', '--diff-filter=U')
    $files = [System.Collections.Generic.List[hashtable]]::new()
    if ($names.Ok) {
        foreach ($rel in ($names.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $binary = $binarySet.Contains($rel)
            $entry = @{ rel = $rel; binary = $binary; content = $null; truncated = $false }
            if (-not $binary) {
                $full = Join-Path $rootFull $rel
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    try {
                        $bytes = [System.IO.File]::ReadAllBytes($full)
                        if ($bytes -contains 0) { $entry.binary = $true }
                        else {
                            $slice = if ($bytes.Length -gt $MaxBytes) { $entry.truncated = $true; $bytes[0..($MaxBytes - 1)] } else { $bytes }
                            $entry.content = [System.Text.Encoding]::UTF8.GetString($slice).TrimStart([char]0xFEFF)
                        }
                    }
                    catch { $entry.content = $null }
                }
            }
            $files.Add($entry)
        }
    }
    $result.files = $files.ToArray()
    $result
}
