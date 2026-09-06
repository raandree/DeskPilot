function Remove-DpChildRun {
    <#
    .SYNOPSIS
        Reconciles positively identified child resources without replaying work.
    .DESCRIPTION
        Takes exclusive installation admission, validates immutable ownership,
        removes only matching containers, and records unfinished work as
        interrupted. Retained data is discarded only when explicitly requested.
    .PARAMETER DataDirectory
        The installation-owned control directory.
    .PARAMETER DiscardCompleted
        Also removes verified, inactive run records and retained proposals.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$DataDirectory,

        [switch]$DiscardCompleted
    )

    $summary = @{ removed = 0; containersRemoved = 0; interrupted = 0; retained = 0 }
    $root = Join-Path ([IO.Path]::GetFullPath($DataDirectory)) 'child-runs'
    if (-not [IO.Directory]::Exists($root)) { return $summary }
    for ($ancestor = [IO.DirectoryInfo]::new($root); $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Child cleanup refuses a reparse-point control directory.'
        }
    }
    if (-not $PSCmdlet.ShouldProcess('Owned child runs and proposals', 'Reconcile containers and requested retained data')) {
        return $summary
    }

    $admission = [IO.FileStream]::new((Join-Path $root 'active.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $count = 0
        foreach ($directory in [IO.Directory]::EnumerateDirectories($root)) {
            if (++$count -gt 4096 -or [IO.Path]::GetFileName($directory) -cnotmatch '^[a-f0-9]{32}$' -or
                ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Child cleanup refused an unrecognized run directory or exceeded its record limit.'
            }
            $identityPath = Join-Path $directory 'ownership.json'
            $claimPath = Join-Path $directory 'claim.json'
            $identityFile = Get-Item -LiteralPath $identityPath -ErrorAction Stop
            if ($identityFile.Length -gt 2048 -or ($identityFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Child cleanup refused invalid ownership data.'
            }
            $identity = [IO.File]::ReadAllText($identityPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($identity.schemaVersion -ne 1 -or $identity.runId -cne [IO.Path]::GetFileName($directory) -or
                $identity.name -cnotmatch '^deskpilot-child-[a-f0-9]{32}$') {
                throw 'Child cleanup could not positively identify the run.'
            }
            $claim = $identity.Clone()
            if ([IO.File]::Exists($claimPath)) {
                $claimFile = Get-Item -LiteralPath $claimPath -ErrorAction Stop
                if ($claimFile.Length -gt 4096 -or ($claimFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Child cleanup refused invalid state data.'
                }
                try { $claim = [IO.File]::ReadAllText($claimPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
                catch { $claim = $identity.Clone() }
                if ($claim.runId -cne $identity.runId -or $claim.name -cne $identity.name) {
                    throw 'Child cleanup refused inconsistent ownership identities.'
                }
            }

            $arguments = @('ps', '--all', '--no-trunc', '--filter', "name=^/$($identity.name)$", '--filter', "label=io.deskpilot.child.run=$($identity.runId)", '--format', '{{.ID}}')
            $found = @(Invoke-DpDockerControl -Argument $arguments -TimeoutSeconds 5) -join ''
            if ($found) {
                if ($found -cnotmatch '^[a-f0-9]{64}$') { throw 'Child cleanup found an ambiguous container identity.' }
                $inspection = @(Invoke-DpDockerControl -Argument @('inspect', $found) -TimeoutSeconds 5 | ConvertFrom-Json -AsHashtable)[0]
                if ($inspection.Config.Labels['io.deskpilot.child'] -ne '1' -or
                    $inspection.Config.Labels['io.deskpilot.child.run'] -cne $identity.runId -or
                    $inspection.Name -cne ('/' + $identity.name) -or
                    ($claim.containerId -and $claim.containerId -cne $found)) {
                    throw 'Child cleanup refused a container whose identity did not match the owned claim.'
                }
                $null = Invoke-DpDockerControl -Argument @('rm', '--force', $found) -TimeoutSeconds 15
                $remaining = Invoke-DpDockerControl -Argument @('ps', '--all', '--no-trunc', '--filter', "id=$found", '--format', '{{.ID}}') -TimeoutSeconds 5
                if ($remaining) { throw 'Child cleanup could not verify container removal.' }
                $summary.containersRemoved++
            }
            if (-not $claim.cleanupSucceeded -or $claim.state -ne 'stopped') {
                $claim.outcome = 'interrupted'
                $summary.interrupted++
            }
            $claim.state = 'stopped'
            $claim.cleanupSucceeded = $true
            $claim.reconciledUtc = [datetime]::UtcNow.ToString('o')
            $bytes = [Text.Encoding]::UTF8.GetBytes(($claim | ConvertTo-Json -Depth 6 -Compress))
            if ($bytes.Length -gt 4096) { throw 'Child cleanup state exceeds its record limit.' }
            $stateFile = [IO.FileStream]::new($claimPath, 'Create', 'Write', 'None')
            try { $stateFile.Write($bytes); $stateFile.Flush($true) }
            finally { $stateFile.Dispose() }

            if ($DiscardCompleted) {
                $fileCount = 0
                foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                    if (++$fileCount -gt 4 -or
                        ([IO.File]::GetAttributes($entry) -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory))) {
                        throw 'Child cleanup refused unrecognized retained data.'
                    }
                }
                [IO.Directory]::Delete($directory, $true)
                $summary.removed++
            }
            else { $summary.retained++ }
        }
    }
    finally { $admission.Dispose() }
    $summary
}
