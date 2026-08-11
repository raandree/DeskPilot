function Read-DpTranscript {
    <#
    .SYNOPSIS
        Reads one Turn's transcript back from the data directory.
    .DESCRIPTION
        Parses the JSONL file a Turn wrote and returns its records in order. A
        line that will not parse is skipped and counted rather than throwing: a
        transcript is a diagnostic, and half of one is more useful than an
        exception.
    .PARAMETER Directory
        The per-user data directory.
    .PARAMETER ConversationId
        The Conversation the Turn belonged to.
    .PARAMETER MessageId
        The assistant Message the Turn produced.
    .OUTPUTS
        System.Collections.Hashtable with ok, path, records, unreadable and error.
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

    $target = Get-DpTranscriptPath -Directory $Directory -ConversationId $ConversationId -MessageId $MessageId
    $result = @{ ok = $false; path = $target.path; records = @(); unreadable = 0; error = '' }

    if (-not (Test-Path -LiteralPath $target.path -PathType Leaf)) {
        $result.error = 'No transcript was recorded for this message.'
        return $result
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $unreadable = 0
    try {
        foreach ($line in [System.IO.File]::ReadLines($target.path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $records.Add(($line | ConvertFrom-Json -ErrorAction Stop)) }
            catch { $unreadable++ }
        }
    }
    catch {
        $readError = $_
        $result.error = "$readError"
        return $result
    }

    $result.ok = $true
    $result.records = @($records)
    $result.unreadable = $unreadable
    $result
}
