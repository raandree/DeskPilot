function New-DpConflictPrompt {
    <#
    .SYNOPSIS
        Builds a ready-to-send prompt that asks the agent to fix a merge conflict.
    .DESCRIPTION
        The Merge Wizard's own plan flow reasons over the conflicted text inside a
        Tool-free Turn. This helper covers the other half: when a conflict shows up
        outside that flow - after a Sync, or when the user would rather drive the
        fix in the Conversation - DeskPilot hands the user a prepared prompt they
        can review, edit and send, so the agent resolves the conflict with its File
        Tools. Keeping it a suggestion, not an automatic Turn, means nothing is
        written until the user chooses to send it.
    .PARAMETER Files
        The conflicted files (repository-relative paths).
    .PARAMETER SourceBranch
        The Branch whose changes are coming in, when known.
    .PARAMETER TargetBranch
        The Branch being merged into, when known.
    .PARAMETER Root
        The repository folder, named in the prompt so the agent works in the right
        place.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Files,

        [string]$SourceBranch,

        [string]$TargetBranch,

        [string]$Root
    )

    $list = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('Please resolve the Git merge conflicts in my project.')
    [void]$sb.AppendLine('')
    if (-not [string]::IsNullOrWhiteSpace($Root)) { [void]$sb.AppendLine("Repository: $Root") }
    if (-not [string]::IsNullOrWhiteSpace($SourceBranch) -and -not [string]::IsNullOrWhiteSpace($TargetBranch)) {
        [void]$sb.AppendLine("Merging: $SourceBranch into $TargetBranch (""ours"" is $TargetBranch, ""theirs"" is $SourceBranch).")
    }
    [void]$sb.AppendLine("Conflicted file$(if ($list.Count -eq 1) { '' } else { 's' }): $($list.Count)")
    foreach ($f in $list) { [void]$sb.AppendLine("- $f") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('For each file:')
    [void]$sb.AppendLine('1. Read it and find every conflict block (<<<<<<<, =======, >>>>>>>).')
    [void]$sb.AppendLine('2. Combine both sides so no intended change is lost. Do not simply pick one side unless the other is genuinely obsolete.')
    [void]$sb.AppendLine('3. Write the file back with every conflict marker removed and all unrelated lines untouched.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Then tell me, per file, what you kept from each side and anything you were unsure about.')
    [void]$sb.AppendLine('Do not run any git commands, do not stage and do not commit — I will complete the merge in DeskPilot once I have reviewed your changes.')

    $sb.ToString()
}
