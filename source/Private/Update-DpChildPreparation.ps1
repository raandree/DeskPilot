function Update-DpChildPreparation {
    <#
    .SYNOPSIS
        Reaps explicit child setup without changing execution consent.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reaps an explicitly requested operation into in-memory Host Server state; it must not prompt in the accept loop.')]
    param()

    $state = $script:DeskPilot
    $child = Get-DpPropertyValue -InputObject $state -Name 'Child'
    if (-not $child -or -not $child.SetupJob -or $child.SetupJob.State -in @('NotStarted', 'Running')) { return }
    $job = $child.SetupJob
    try {
        if ($job.State -ne 'Completed') { throw 'Child preparation failed.' }
        $result = Receive-Job -Job $job -ErrorAction Stop
        if (-not $result) { throw 'Child preparation returned no result.' }
        $child.Runtime = $result.Runtime
        $child.Health = $result.Health
        if ($child.Health -and $child.Health.cleanupClear) {
            if ($child.CleanupBlocked) { $state.TurnRunning = $false }
            $child.CleanupBlocked = $false
        }
        $proofPath = Join-Path $state.DataDir 'child-runtime/profile-proof.json'
        $child.Proof = $null
        if (Test-Path -LiteralPath $proofPath -PathType Leaf) {
            $file = Get-Item -LiteralPath $proofPath
            if ($file.Length -gt 65536 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid profile proof record.' }
            $child.Proof = [IO.File]::ReadAllText($proofPath) | ConvertFrom-Json -AsHashtable -Depth 16
        }
    } catch { $child.Error = 'child-preparation-failed' }
    finally { Remove-Job -Job $job -Force; $child.SetupJob = $null }
}
