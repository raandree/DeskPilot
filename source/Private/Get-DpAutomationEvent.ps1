function Get-DpAutomationEvent {
    <#
    .SYNOPSIS
        Reports files inside a Project that have finished being written.
    .DESCRIPTION
        The detection half of a file trigger. It scans the Project for paths
        matching a bounded pattern and reports one event per file that has been
        observed twice with the same size and last-write time at least
        StabilitySeconds apart - which is what separates "a file arrived" from
        "a file is still arriving". A half-written file must never be handed to
        an Agent as completed input.

        Everything about it is deliberately conservative:

        - The first sighting of a file never fires. There is nothing yet to
          compare it against, so nothing is known to be stable.
        - A file fires once per distinct signature. Replacing the file with new
          content fires again; leaving it alone does not.
        - A deleted file is forgotten, so the state cannot grow without bound
          across a long-running Host Server.
        - A directory that is a reparse point is pruned rather than followed, so
          a junction cannot walk the scan out of the Project.
        - A file over the size bound is refused and reported, never truncated.

        Caller-supplied state is passed in and handed back rather than held here,
        so a restart resumes from what was persisted and the function stays
        testable with an injected clock.
    .PARAMETER Root
        The Project folder to scan.
    .PARAMETER Glob
        The Project-relative pattern, validated by ConvertTo-DpSchedule.
    .PARAMETER Seen
        Signature per relative path from the previous scan.
    .PARAMETER Now
        The reference instant, in UTC.
    .PARAMETER StabilitySeconds
        How long a file must hold the same signature before it counts as complete.
    .PARAMETER MaxFileBytes
        Size ceiling; a larger file is refused rather than processed.
    .PARAMETER MaxFiles
        Scan ceiling, so a huge Project cannot stall the accept loop.
    .OUTPUTS
        System.Collections.Hashtable with events, refused and seen.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Glob,

        [Parameter(Mandatory)]
        [AllowNull()]
        [hashtable]$Seen,

        [Parameter(Mandatory)]
        [datetime]$Now,

        [int]$StabilitySeconds = 3,

        [long]$MaxFileBytes = 20971520,

        [int]$MaxFiles = 5000
    )

    $events = [System.Collections.Generic.List[hashtable]]::new()
    $refused = [System.Collections.Generic.List[hashtable]]::new()
    $next = @{}
    $previous = if ($Seen) { $Seen } else { @{} }

    $result = @{ events = @($events); refused = @($refused); seen = $next }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $result }

    try { $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar) }
    catch { return $result }

    # Glob to regex over the forward-slash relative path: '**/' spans directories,
    # '*' and '?' never cross one.
    $pattern = '^' + ([regex]::Escape($Glob) -replace '\\\*\\\*/', '(?:.*/)?' -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]') + '$'
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $regexOptions = if ($IsWindows) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }

    $scanned = 0
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($rootFull)

    while ($pending.Count -gt 0 -and $scanned -lt $MaxFiles) {
        $directory = $pending.Dequeue()
        $children = @()
        try { $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) } catch { continue }

        foreach ($child in $children) {
            if ($scanned -ge $MaxFiles) { break }
            # A junction or symlink is not followed: it is how a scan leaves the Project.
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($child.PSIsContainer) { $pending.Enqueue($child.FullName); continue }

            $scanned++
            $full = $child.FullName
            if (-not $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison)) { continue }
            $relative = $full.Substring($rootFull.Length + 1).Replace('\', '/')
            if (-not [regex]::IsMatch($relative, $pattern, $regexOptions)) { continue }

            $signature = '{0}:{1}' -f $child.Length, $child.LastWriteTimeUtc.Ticks
            $recorded = if ($previous.ContainsKey($relative)) { [string]$previous[$relative] } else { '' }

            if ($recorded -eq "$signature|fired") {
                $next[$relative] = $recorded
                continue
            }

            $parts = $recorded -split '\|', 2
            if ($parts[0] -ne $signature) {
                # New, or changed since the last scan: start its stability window now.
                $next[$relative] = '{0}|{1}' -f $signature, $Now.Ticks
                continue
            }

            $sinceTicks = [long]$parts[1]
            if (($Now - [datetime]::new($sinceTicks, [DateTimeKind]::Utc)).TotalSeconds -lt $StabilitySeconds) {
                $next[$relative] = $recorded
                continue
            }

            $next[$relative] = "$signature|fired"
            if ($child.Length -gt $MaxFileBytes) {
                $refused.Add(@{
                        relativePath = $relative
                        bytes        = [long]$child.Length
                        reason       = "The file is larger than the $MaxFileBytes-byte limit for this trigger."
                    })
                continue
            }
            $events.Add(@{
                    relativePath = $relative
                    fullPath     = $full
                    bytes        = [long]$child.Length
                    detectedUtc  = $Now.ToString('o')
                })
        }
    }

    @{ events = @($events); refused = @($refused); seen = $next }
}
