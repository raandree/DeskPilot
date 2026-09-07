function Get-DpChildRunRecord {
    <#
    .SYNOPSIS
        Reads bounded child data only within its owning Conversation.
    .PARAMETER ConversationId
        The authenticated Conversation route identity.
    .PARAMETER Id
        Host-generated child identity, or current for the latest active result.
    .PARAMETER Proposal
        Returns the independently validated private proposal instead of status.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ConversationId,
        [Parameter(Mandatory)][string]$Id,
        [switch]$Proposal
    )
    $state = $script:DeskPilot
    $child = Get-DpPropertyValue -InputObject $state -Name 'Child'
    if (-not $child) { return $null }
    $snapshot = $null
    if ($child.Controller -and $child.Controller.ConversationId -ceq $ConversationId -and
        ($Id -ceq 'current' -or $child.Controller.Id -ceq $Id)) {
        $snapshot = $child.Controller.Snapshot() | ConvertFrom-Json -AsHashtable -Depth 24
    } elseif ($child.Last -and $child.Last.conversationId -ceq $ConversationId -and
        ($Id -ceq 'current' -or $child.Last.id -ceq $Id)) { $snapshot = $child.Last }
    if ($snapshot -and -not $Proposal) { return $snapshot }
    if ($Id -ceq 'current') { return $null }
    if ($Id -cnotmatch '^[a-f0-9]{32}$') { return $null }
    $directory = Join-Path $state.DataDir ('child-runs/' + $Id)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $null }
    for ($ancestor = [IO.DirectoryInfo]::new($directory); $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked child records are unavailable.' }
    }
    $path = Join-Path $directory 'run.json'
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.Length -gt 67108864 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Child record exceeds its supported bound.' }
    $snapshot = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -Depth 24
    if ($snapshot.id -cne $Id -or $snapshot.conversationId -cne $ConversationId) { return $null }
    if (-not $Proposal) { return $snapshot }
    if (-not $snapshot.cleanupSucceeded -or -not $snapshot.hasProposal -or $snapshot.status -cne 'completed') {
        throw 'A cleaned-up private proposal is not available.'
    }
    $proposalPath = Join-Path $directory 'proposal.json'
    $proposalFile = Get-Item -LiteralPath $proposalPath -ErrorAction Stop
    if ($proposalFile.Length -gt 67108864 -or ($proposalFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Proposal storage is invalid.' }
    $result = [IO.File]::ReadAllText($proposalPath) | ConvertFrom-Json -AsHashtable -Depth 16
    if ($result.runId -cne $Id) { throw 'Proposal identity mismatch.' }
    $result
}
