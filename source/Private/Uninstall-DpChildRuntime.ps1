function Uninstall-DpChildRuntime {
    <#
    .SYNOPSIS
        Removes only positively owned child preparation after verified cleanup.
    .DESCRIPTION
        The Host Server disables child execution first. This command checks
        exact image tags and identities, refuses linked preparation paths, and
        removes bounded child records. Shared Docker, WSL2, and Terminal-only
        preparation are not removed.
    .PARAMETER DataDirectory
        Installation-owned child preparation and run directory.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$DataDirectory)

    $root = Join-Path ([IO.Path]::GetFullPath($DataDirectory)) 'child-runtime'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @{ removed = $false; alreadyAbsent = $true } }
    for ($ancestor = [IO.DirectoryInfo]::new($root); $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Child removal refuses linked preparation storage.' }
    }
    $recordPath = Join-Path $root 'runtime.json'
    $record = Get-Item -LiteralPath $recordPath
    if ($record.Length -gt 65536 -or ($record.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid child preparation identity.' }
    $runtime = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json -AsHashtable -Depth 16
    $images = @(
        @{ Tag = $runtime.tag; Image = $runtime.image; Pattern = '^deskpilot-child:[a-f0-9]{32}$' }
    )
    if ($runtime.engineTag) { $images += @{ Tag = $runtime.engineTag; Image = $runtime.engineImage; Pattern = '^deskpilot-child-engine:[a-f0-9]{32}$' } }
    foreach ($image in $images) {
        if ($image.Tag -cnotmatch $image.Pattern -or $image.Image -cnotmatch '^sha256:[a-f0-9]{64}$') {
            throw 'Child removal refused an unowned image tag.'
        }
        $actual = Invoke-DpDockerControl -Argument @('image', 'inspect', $image.Tag, '--format', '{{.Id}}') -TimeoutSeconds 5
        if ($actual -cne $image.Image) { throw 'Child removal refused a changed image identity.' }
    }
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($root)
    $count = 0
    while ($pending.Count) {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Dequeue())) {
            if (++$count -gt 2048) { throw 'Child preparation exceeds its supported removal inventory.' }
            $attributes = [IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Child removal refuses linked preparation content.' }
            if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Enqueue($entry) }
        }
    }
    if (-not $PSCmdlet.ShouldProcess('Verified child preparation and private proposals', 'Remove')) { return @{ removed = $false } }
    $null = Remove-DpChildRun -DataDirectory $DataDirectory -DiscardCompleted -Confirm:$false
    foreach ($image in $images) { $null = Invoke-DpDockerControl -Argument @('image', 'rm', $image.Tag) -TimeoutSeconds 10 }
    [IO.Directory]::Delete($root, $true)
    @{ removed = $true; sharedBackendUnchanged = $true }
}
