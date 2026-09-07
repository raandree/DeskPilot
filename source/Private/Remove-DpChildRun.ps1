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
    .PARAMETER ExpireCompleted
        Removes only verified inactive records whose configured retention age
        has expired. Explicit cleanup and Host Server recovery may request it.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$DataDirectory,

        [switch]$DiscardCompleted,

        [switch]$ExpireCompleted
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
            $providerPath = Join-Path $directory 'provider.json'
            if ([IO.File]::Exists($providerPath)) {
                $providerFile = Get-Item -LiteralPath $providerPath
                if ($providerFile.Length -gt 2048 -or ($providerFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Child cleanup refused invalid provider ownership.'
                }
                $provider = [IO.File]::ReadAllText($providerPath) | ConvertFrom-Json -AsHashtable
                if ($provider.schemaVersion -ne 1 -or $provider.runId -cne $identity.runId -or
                    $provider.processId -isnot [long] -and $provider.processId -isnot [int] -or
                    $provider.startTimeUtcTicks -isnot [long]) { throw 'Child cleanup refused invalid provider identity.' }
                $process = Get-Process -Id $provider.processId -ErrorAction SilentlyContinue
                if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq $provider.startTimeUtcTicks -and -not $process.HasExited) {
                    throw 'A recorded provider process is still alive; cleanup cannot be verified.'
                }
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

            $engineIdentityPath = Join-Path $directory 'engine-ownership.json'
            if ([IO.File]::Exists($engineIdentityPath)) {
                $engineFile = Get-Item -LiteralPath $engineIdentityPath -ErrorAction Stop
                if ($engineFile.Length -gt 2048 -or ($engineFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Child cleanup refused invalid Engine ownership.'
                }
                $engineIdentity = [IO.File]::ReadAllText($engineIdentityPath) | ConvertFrom-Json -AsHashtable
                if ($engineIdentity.schemaVersion -ne 1 -or $engineIdentity.runId -cne $identity.runId -or
                    $engineIdentity.name -cne ('deskpilot-child-engine-' + $identity.runId) -or
                    $engineIdentity.image -cnotmatch '^sha256:[a-f0-9]{64}$') {
                    throw 'Child cleanup refused an inconsistent Engine identity.'
                }
                $engineClaim = $engineIdentity.Clone()
                $enginePath = Join-Path $directory 'engine.json'
                if ([IO.File]::Exists($enginePath)) {
                    $engineFile = Get-Item -LiteralPath $enginePath
                    if ($engineFile.Length -gt 2048 -or ($engineFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        throw 'Child cleanup refused invalid Engine state.'
                    }
                    try { $engineClaim = [IO.File]::ReadAllText($enginePath) | ConvertFrom-Json -AsHashtable }
                    catch { $engineClaim = $engineIdentity.Clone() }
                    if ($engineClaim.runId -cne $identity.runId -or $engineClaim.name -cne $engineIdentity.name -or
                        $engineClaim.image -cne $engineIdentity.image) { throw 'Child Engine ownership changed.' }
                }
                $engineFound = @(Invoke-DpDockerControl -Argument @('ps', '--all', '--no-trunc', '--filter', "name=^/$($engineIdentity.name)$", '--filter', "label=io.deskpilot.child.run=$($identity.runId)", '--format', '{{.ID}}') -TimeoutSeconds 5) -join ''
                if ($engineFound) {
                    if ($engineFound -cnotmatch '^[a-f0-9]{64}$' -or ($engineClaim.containerId -and $engineClaim.containerId -cne $engineFound)) {
                        throw 'Child cleanup refused an ambiguous Engine container.'
                    }
                    $engineInspection = @(Invoke-DpDockerControl -Argument @('inspect', $engineFound) -TimeoutSeconds 5 | ConvertFrom-Json -AsHashtable)[0]
                    if ($engineInspection.Name -cne ('/' + $engineIdentity.name) -or $engineInspection.Image -cne $engineIdentity.image -or
                        $engineInspection.Config.Labels['io.deskpilot.child'] -ne '1' -or
                        $engineInspection.Config.Labels['io.deskpilot.child.run'] -cne $identity.runId -or
                        $engineInspection.Config.Labels['io.deskpilot.child.component'] -cne 'engine') {
                        throw 'Child cleanup refused mismatched Engine container ownership.'
                    }
                    $null = Invoke-DpDockerControl -Argument @('rm', '--force', $engineFound) -TimeoutSeconds 10
                    $remainingEngine = Invoke-DpDockerControl -Argument @('ps', '--all', '--no-trunc', '--filter', "name=^/$($engineIdentity.name)$", '--format', '{{.ID}}') -TimeoutSeconds 5
                    if ($remainingEngine) { throw 'Child cleanup could not verify Engine removal.' }
                    $summary.containersRemoved++
                }
                $engineClaim.state = 'stopped'
                $engineClaim.cleanupSucceeded = $true
                $engineBytes = [Text.Encoding]::UTF8.GetBytes(($engineClaim | ConvertTo-Json -Depth 6 -Compress))
                if ($engineBytes.Length -gt 2048) { throw 'Child Engine cleanup record exceeds its limit.' }
                [IO.File]::WriteAllBytes($enginePath, $engineBytes)
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

            $runPath = Join-Path $directory 'run.json'
            if ([IO.File]::Exists($runPath)) {
                $runFile = Get-Item -LiteralPath $runPath
                if ($runFile.Length -gt 67108864 -or ($runFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Child recovery refused an invalid result record.'
                }
                $run = [IO.File]::ReadAllText($runPath) | ConvertFrom-Json -AsHashtable -Depth 24
                if ($run.id -cne $identity.runId) { throw 'Child recovery refused a result identity mismatch.' }
                if ($run.status -cnotin @('completed', 'failed', 'stopped')) {
                    $run.status = 'failed'
                    $run.code = 'interrupted'
                    $run.phase = 'recovered'
                    $run.cleanupSucceeded = $true
                    $run.hasProposal = $false
                    $runBytes = [Text.Encoding]::UTF8.GetBytes(($run | ConvertTo-Json -Depth 24 -Compress))
                    if ($runBytes.Length -gt [long]$claim.retainedBytes - 8192) { throw 'Recovered child record exceeds its reserved capacity.' }
                    [IO.File]::WriteAllBytes($runPath, $runBytes)
                }
            }

            $expired = $false
            if ($ExpireCompleted) {
                $expires = [datetime]::MinValue
                if (-not [datetime]::TryParse([string]$claim.expiresUtc, [ref]$expires)) { throw 'Child retention expiry is invalid.' }
                $expired = $expires.ToUniversalTime() -le [datetime]::UtcNow
            }
            if ($DiscardCompleted -or $expired) {
                $fileCount = 0
                foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                    if (++$fileCount -gt 9 -or
                        [IO.Path]::GetFileName($entry) -cnotin @('ownership.json', 'claim.json', 'config.json', 'provider.json', 'AppData', 'engine-ownership.json', 'engine.json', 'run.json', 'proposal.json') -or
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
