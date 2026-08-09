function Restore-DpCheckpoint {
    <#
    .SYNOPSIS
        Puts a Conversation and its files back to how they were before a prompt.
    .DESCRIPTION
        A Checkpoint is the pre-Turn snapshot DeskPilot already takes, made
        addressable from the transcript. Restoring one drops the prompt and
        everything after it, and puts back the files the discarded Turns wrote.

        The file restore is deliberately **bounded to what the agent changed**,
        taken from each discarded assistant Message's Activity, rather than
        checking the whole folder out of the snapshot. A wholesale revert would
        also throw away the edits the user made by hand in the meantime - which is
        exactly the distinction between "undo what the AI did" and "revert to the
        last commit" that the pending change set exists to draw (spec 090).

        A file that was not in the snapshot is one the agent created, so restoring
        means deleting it. A Project that is not a Git repository has no snapshot;
        the Conversation is still truncated and the caller reports that the files
        were left alone.
    .PARAMETER Conversation
        The Conversation to restore.
    .PARAMETER MessageId
        The user Message whose Checkpoint to go back to. It and everything after
        it are removed.
    .PARAMETER Root
        The Project folder, or empty when none is selected.
    .PARAMETER SkipFiles
        Truncate the Conversation only, leaving the files as they are.
    .PARAMETER Preview
        Report what would be discarded and changed without touching anything, so a
        confirmation prompt can state exact numbers rather than a guess.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The caller confirms with the user before calling; a second prompt on the Host Server thread would hang it.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Conversation,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MessageId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Root,

        [switch]$SkipFiles,

        [switch]$Preview
    )

    $result = @{
        ok              = $false
        error           = $null
        prompt          = ''
        restored        = @()
        removed         = @()
        skipped         = @()
        files           = @()
        messagesDropped = 0
        filesTried      = $false
    }

    $messages = @($Conversation.messages)
    $index = -1
    for ($i = 0; $i -lt $messages.Count; $i++) {
        if ([string]$messages[$i].id -eq $MessageId) { $index = $i; break }
    }
    if ($index -lt 0) { $result.error = 'That checkpoint is no longer in this conversation.'; return $result }
    if ([string]$messages[$index].role -ne 'user') { $result.error = 'A checkpoint belongs to a message you sent.'; return $result }

    $checkpoint = Get-DpPropertyValue -InputObject $messages[$index] -Name @('checkpoint') -Default $null
    $sha = [string](Get-DpPropertyValue -InputObject $checkpoint -Name @('sha') -Default '')

    # What the discarded Turns wrote is what needs putting back. Collected before
    # the Conversation is truncated, because that is what removes them. Normalised
    # to the same Project-relative, forward-slash form the pending change set uses,
    # so the same path matches an entry, a git pathspec, and a later removal.
    $rootTrim = ''
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        try { $rootTrim = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') } catch { $rootTrim = '' }
    }

    $written = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($rootTrim) {
        for ($i = $index; $i -lt $messages.Count; $i++) {
            $activity = Get-DpPropertyValue -InputObject $messages[$i] -Name @('activity') -Default $null
            foreach ($path in @(Get-DpPropertyValue -InputObject $activity -Name @('filesWritten') -Default @())) {
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                $candidate = if ([System.IO.Path]::IsPathRooted($path)) { [string]$path } else { Join-Path $rootTrim ([string]$path) }
                try { $full = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/') } catch { continue }
                # The Project stays the boundary: a path outside it is never touched.
                if (-not $full.StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $relative = $full.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
                if ($seen.Add($relative)) { $written.Add($relative) }
            }
        }
    }

    $result.files = @($written)
    $result.messagesDropped = $messages.Count - $index

    if ($Preview) {
        $result.ok = $true
        $result.prompt = [string]$messages[$index].text
        $result.filesTried = (-not $SkipFiles -and $sha -and $rootTrim -and $written.Count -gt 0)
        return $result
    }

    if (-not $SkipFiles -and $sha -and $rootTrim -and $written.Count -gt 0) {
        $result.filesTried = $true
        # Reuse the per-file undo: an entry is just "this path, against that
        # snapshot", which is exactly what a Checkpoint restore needs per file.
        $entries = foreach ($relative in $written) { @{ rel = $relative; snapshotSha = $sha } }
        $undo = Invoke-DpChangeUndo -Root $Root -Entries @($entries)
        if ($undo.error) { $result.error = $undo.error; return $result }
        $result.restored = @($undo.restored)
        $result.removed = @($undo.removed)
        $result.skipped = @($undo.skipped)
    }

    $prompt = Reset-DpConversationForRerun -Conversation $Conversation -FromMessageId $MessageId
    if ($null -eq $prompt) { $result.error = 'That checkpoint could not be restored.'; return $result }

    # The files are back as they were, so nothing from those Turns is pending.
    if ($rootTrim -and $written.Count -gt 0) {
        $null = Remove-DpChangeEntry -Store $script:DeskPilot.Changes -Root $Root -Paths ([string[]]$written)
    }

    $result.ok = $true
    $result.prompt = $prompt
    $result
}
