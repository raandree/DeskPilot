function Get-DpTranscriptPath {
    <#
    .SYNOPSIS
        Resolves the transcript file for one Turn inside the data directory.
    .DESCRIPTION
        One file per Turn, named by Conversation and Message, under a transcripts
        folder in the per-user data directory. Both ids are DeskPilot's own
        (`c_...`, `m_...`), but they arrive from a request on the read path, so
        every character outside a conservative set is replaced rather than
        trusted: a transcript name is never a way to address a file elsewhere on
        the disk.
    .PARAMETER Directory
        The per-user data directory.
    .PARAMETER ConversationId
        The Conversation the Turn belonged to.
    .PARAMETER MessageId
        The assistant Message the Turn produced.
    .OUTPUTS
        System.Collections.Hashtable with directory and path.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ConversationId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$MessageId
    )

    $safe = {
        param([string]$Value)
        $cleaned = ([string]$Value) -replace '[^A-Za-z0-9_.-]', '_'
        if ([string]::IsNullOrWhiteSpace($cleaned)) { $cleaned = 'unknown' }
        if ($cleaned.Length -gt 64) { $cleaned = $cleaned.Substring(0, 64) }
        $cleaned
    }

    $folder = Join-Path $Directory 'transcripts'
    @{
        directory = $folder
        path      = Join-Path $folder ("{0}-{1}.jsonl" -f (& $safe $ConversationId), (& $safe $MessageId))
    }
}
