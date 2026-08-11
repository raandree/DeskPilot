function Write-DpTranscript {
    <#
    .SYNOPSIS
        Flushes a Turn's buffered transcript records to one JSONL file.
    .DESCRIPTION
        Called once, at the end of a Turn, never during it. A per-record file
        write would land on the single thread that holds the SSE stream open -
        the freeze Invoke-DpGitCommand exists to avoid - so the records are
        buffered in memory and written here in one go.

        The write is atomic (temp file then move), matching the convention
        conversations.json already uses, so a crash mid-write cannot leave a
        half-parsed transcript behind. Retention runs on the same call, because a
        diagnostic that only ever grows is a disk leak.

        Best-effort by design: a disk problem must never turn a Turn that produced
        an answer into a failed one, so every failure is reported on the result
        rather than thrown.
    .PARAMETER Directory
        The per-user data directory.
    .PARAMETER ConversationId
        The Conversation the Turn belonged to.
    .PARAMETER MessageId
        The assistant Message the Turn produced.
    .PARAMETER Record
        The buffered records, already ordered and already redacted.
    .PARAMETER MaxTotalBytes
        The retention size bound for the transcript folder.
    .PARAMETER MaxAgeDays
        The retention age bound for the transcript folder.
    .OUTPUTS
        System.Collections.Hashtable with ok, path, records, pruned and error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ConversationId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$MessageId,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Record,

        [long]$MaxTotalBytes = 52428800,

        [int]$MaxAgeDays = 30
    )

    $result = @{ ok = $false; path = ''; records = 0; pruned = 0; error = '' }
    if (@($Record).Count -eq 0) {
        $result.error = 'no records'
        return $result
    }

    $target = Get-DpTranscriptPath -Directory $Directory -ConversationId $ConversationId -MessageId $MessageId
    $result.path = $target.path
    if (-not $PSCmdlet.ShouldProcess($target.path, 'Write Turn transcript')) { return $result }

    try {
        if (-not (Test-Path -LiteralPath $target.directory)) {
            New-Item -ItemType Directory -Path $target.directory -Force -ErrorAction Stop | Out-Null
        }
        $lines = foreach ($entry in @($Record)) { $entry | ConvertTo-Json -Compress -Depth 6 }
        $payload = (@($lines) -join "`n") + "`n"
        $temp = "$($target.path).tmp"
        [System.IO.File]::WriteAllText($temp, $payload, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $target.path -Force -ErrorAction Stop
        $result.ok = $true
        $result.records = @($Record).Count
    }
    catch {
        $writeError = $_
        $result.error = "$writeError"
        return $result
    }

    try {
        $result.pruned = Remove-DpTranscriptOverflow -Directory $target.directory -MaxTotalBytes $MaxTotalBytes -MaxAgeDays $MaxAgeDays -Confirm:$false
    }
    catch {
        $pruneError = $_
        Write-Verbose "Could not prune transcripts: $pruneError"
    }

    $result
}
