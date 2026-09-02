function Add-DpDiagnosticLog {
    <#
    .SYNOPSIS
        Appends one already-redacted entry to the diagnostic log.
    .DESCRIPTION
        Assigns a monotonic sequence and evicts the oldest entries until both
        retention bounds hold. The whole operation is protected by the log lock.
    .PARAMETER Log
        The state returned by New-DpDiagnosticLog.
    .PARAMETER Severity
        The event severity.
    .PARAMETER Component
        The bounded DeskPilot component name.
    .PARAMETER EventId
        A stable event identifier.
    .PARAMETER Summary
        A redacted, human-readable summary.
    .PARAMETER Timestamp
        The event time in UTC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Log,

        [Parameter(Mandatory)]
        [ValidateSet('debug', 'information', 'warning', 'error', 'critical')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Component,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EventId,

        [AllowEmptyString()]
        [string]$Summary = '',

        [datetime]$Timestamp = [datetime]::UtcNow
    )

    [System.Threading.Monitor]::Enter($Log.SyncRoot)
    try {
        $safeComponent = (($Component -replace '[^A-Za-z0-9.-]', '-').Trim('-'))
        if ($safeComponent.Length -gt 40) { $safeComponent = $safeComponent.Substring(0, 40) }
        $safeEventId = (($EventId -replace '[^A-Za-z0-9._-]', '-').Trim('-'))
        if ($safeEventId.Length -gt 80) { $safeEventId = $safeEventId.Substring(0, 80) }
        $safeSummary = Protect-DpDiagnosticText -Text $Summary -MaxLength 500

        $Log.NextSequence = [long]$Log.NextSequence + 1
        $entry = [ordered]@{
            sequence  = [long]$Log.NextSequence
            timestamp = $Timestamp.ToUniversalTime().ToString('o')
            severity  = $Severity
            component = $safeComponent
            eventId   = $safeEventId
            summary   = $safeSummary
            bytes     = 0
        }
        do {
            $previousBytes = [long]$entry.bytes
            $entry.bytes = [System.Text.Encoding]::UTF8.GetByteCount(($entry | ConvertTo-Json -Compress))
        } while ($entry.bytes -ne $previousBytes)

        $Log.Entries.Add($entry)
        $Log.CurrentBytes = [long]$Log.CurrentBytes + [long]$entry.bytes

        while ($Log.Entries.Count -gt 0 -and
            ($Log.Entries.Count -gt [int]$Log.MaxEntries -or $Log.CurrentBytes -gt [long]$Log.MaxBytes)) {
            $oldest = $Log.Entries[0]
            $Log.Entries.RemoveAt(0)
            $Log.CurrentBytes = [math]::Max(0, [long]$Log.CurrentBytes - [long]$oldest.bytes)
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($Log.SyncRoot)
    }
}