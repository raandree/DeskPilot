function Remove-DpTranscriptOverflow {
    <#
    .SYNOPSIS
        Prunes the Turn transcript folder to its size and age bounds.
    .DESCRIPTION
        A diagnostic that writes a file per Turn and never deletes one is a disk
        leak, so retention is part of writing rather than a follow-up. Two bounds,
        applied in that order: anything older than MaxAgeDays goes regardless of
        size, then the oldest remaining files go until the folder is within
        MaxTotalBytes.

        Oldest-first, because the transcript that matters is the one from the Turn
        being investigated, which is the newest. Never throws: a locked or
        vanished file costs its own deletion and nothing else.
    .PARAMETER Directory
        The transcript folder.
    .PARAMETER MaxTotalBytes
        The most the folder may occupy after pruning.
    .PARAMETER MaxAgeDays
        The oldest a transcript may be.
    .OUTPUTS
        System.Int32 - how many files were removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [ValidateRange(1024, 10737418240)]
        [long]$MaxTotalBytes = 52428800,

        [ValidateRange(1, 3650)]
        [int]$MaxAgeDays = 30
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return 0 }

    $files = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.jsonl' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc)
    }
    catch {
        $listError = $_
        Write-Verbose "Could not list transcripts in '$Directory': $listError"
        return 0
    }

    $removed = 0
    $cutoff = [datetime]::UtcNow.AddDays(-$MaxAgeDays)
    $surviving = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $files) {
        if ($file.LastWriteTimeUtc -lt $cutoff) {
            if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove aged transcript')) {
                try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removed++ }
                catch {
                    $ageError = $_
                    Write-Verbose "Could not remove '$($file.FullName)': $ageError"
                    $surviving.Add($file)
                }
            }
            continue
        }
        $surviving.Add($file)
    }

    $total = ($surviving | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $total) { $total = 0 }
    foreach ($file in $surviving) {
        if ($total -le $MaxTotalBytes) { break }
        if (-not $PSCmdlet.ShouldProcess($file.FullName, 'Remove oldest transcript')) { continue }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $total -= $file.Length
            $removed++
        }
        catch {
            $sizeError = $_
            Write-Verbose "Could not remove '$($file.FullName)': $sizeError"
        }
    }

    $removed
}
