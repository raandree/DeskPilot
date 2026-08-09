function Get-DpCheckpointSha {
    <#
    .SYNOPSIS
        Lists the snapshot commits Checkpoints still depend on.
    .DESCRIPTION
        A Checkpoint is the pre-Turn snapshot made addressable from the transcript,
        so its commit has to outlive the pending change set that originally created
        it. Keeping and saving both clear pending entries, and the ref cleanup that
        follows would otherwise delete the very commit a Checkpoint restores from -
        leaving a "Restore checkpoint" button that could not.

        Read from the live Conversation store rather than passed in, so a new call
        site cannot forget to protect them.
    .PARAMETER Root
        Optional Project folder; when given, only Checkpoints taken in that Project
        are returned.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Root
    )

    $state = $script:DeskPilot
    if (-not $state -or -not $state.Conversations) { return @() }

    $wantedRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        try { $wantedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar) } catch { $wantedRoot = '' }
    }

    $shas = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($conversation in @($state.Conversations.Values)) {
        foreach ($message in @(Get-DpPropertyValue -InputObject $conversation -Name @('messages') -Default @())) {
            $checkpoint = Get-DpPropertyValue -InputObject $message -Name @('checkpoint') -Default $null
            if (-not $checkpoint) { continue }
            $sha = [string](Get-DpPropertyValue -InputObject $checkpoint -Name @('sha') -Default '')
            if ([string]::IsNullOrWhiteSpace($sha)) { continue }
            if ($wantedRoot) {
                $checkpointRoot = [string](Get-DpPropertyValue -InputObject $checkpoint -Name @('root') -Default '')
                if ($checkpointRoot) {
                    try { $checkpointRoot = [System.IO.Path]::GetFullPath($checkpointRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) } catch { $checkpointRoot = '' }
                }
                if ($checkpointRoot -and -not [string]::Equals($checkpointRoot, $wantedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            }
            [void]$shas.Add($sha)
        }
    }

    @($shas)
}
