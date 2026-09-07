function Initialize-DpChildState {
    <#
    .SYNOPSIS
        Loads explicit child preparation and reconciles owned interrupted work.
    .DESCRIPTION
        Does not install dependencies, authenticate, change Settings, or replay
        work. Uncertain ownership keeps child admission blocked.
    .PARAMETER DataDirectory
        The installation-owned runtime and child record directory.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$DataDirectory)

    $state = @{
        Controller = $null; Runtime = $null; Proof = $null; Health = $null; Last = $null
        CleanupBlocked = $false; Recorded = $false; Prompt = ''; Error = ''; SetupJob = $null
    }
    try {
        foreach ($entry in @(
            @{ Name = 'Runtime'; File = 'runtime.json' }
            @{ Name = 'Proof'; File = 'profile-proof.json' }
        )) {
            $path = Join-Path $DataDirectory ('child-runtime/' + $entry.File)
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $file = Get-Item -LiteralPath $path -ErrorAction Stop
                if ($file.Length -gt 65536 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Invalid child preparation record.'
                }
                $state[$entry.Name] = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -Depth 16
            }
        }
        if (Test-Path -LiteralPath (Join-Path $DataDirectory 'child-runs')) {
            $null = Remove-DpChildRun -DataDirectory $DataDirectory -ExpireCompleted -Confirm:$false
        }
        if ($state.Runtime -and $state.Runtime.schemaVersion -eq 2) {
            $state.Health = Get-DpChildRuntimeHealth -Runtime $state.Runtime -DataDirectory $DataDirectory
        }
    } catch {
        $state.CleanupBlocked = $true
        $state.Error = 'child-cleanup-unresolved'
    }
    $state
}
