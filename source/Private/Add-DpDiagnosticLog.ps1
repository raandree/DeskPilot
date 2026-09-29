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
    .PARAMETER Context
        Optional content-free correlation and Usage scalars. Unknown fields are
        excluded; invalid values in the allow-list are rejected before append.
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

        [datetime]$Timestamp = [datetime]::UtcNow,

        [AllowNull()]
        [System.Collections.IDictionary]$Context
    )

    $safeContext = [ordered]@{}
    if ($null -ne $Context) {
        foreach ($key in @(
                'conversationId', 'turnId', 'toolSequence', 'action', 'outcome',
                'durationMs', 'promptTokens', 'completionTokens', 'totalTokens',
                'costUSD', 'estimated', 'partial'
            )) {
            if (-not $Context.Contains($key)) { continue }
            $value = $Context[$key]
            if ($null -eq $value) {
                $safeContext[$key] = $null
                continue
            }
            switch ($key) {
                { $_ -in @('conversationId', 'turnId') } {
                    $prefix = if ($key -eq 'conversationId') { 'c' } else { 'm' }
                    if ($value -isnot [string] -or $value -cnotmatch ('^{0}_[0-9a-f]{{10,32}}$' -f $prefix)) {
                        throw "Diagnostic context '$key' must be a Host Server identifier."
                    }
                    $safeContext[$key] = $value
                }
                'action' {
                    if ($value -isnot [string] -or $value -cnotin @(
                            'read', 'list', 'write', 'create', 'run', 'fetch',
                            'browse', 'search', 'ask', 'load', 'mcp', 'approval', 'other'
                        )) {
                        throw "Diagnostic context '$key' is not a recognized Activity kind."
                    }
                    $safeContext[$key] = $value
                }
                'outcome' {
                    if ($value -isnot [string] -or $value -cnotin @(
                            'started', 'observed', 'completed', 'failed', 'stopped',
                            'budget-exhausted', 'requested', 'approved', 'denied', 'retry'
                        )) {
                        throw "Diagnostic context '$key' is not a recognized outcome."
                    }
                    $safeContext[$key] = $value
                }
                { $_ -in @('estimated', 'partial') } {
                    if ($value -isnot [bool]) { throw "Diagnostic context '$key' must be a boolean or null." }
                    $safeContext[$key] = $value
                }
                default {
                    if ($value.GetType().FullName -notin @(
                            'System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16',
                            'System.Int32', 'System.UInt32', 'System.Int64', 'System.UInt64',
                            'System.Single', 'System.Double', 'System.Decimal'
                        )) {
                        throw "Diagnostic context '$key' must be a nonnegative number or null."
                    }
                    $number = [double]$value
                    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
                        $number -lt 0 -or $number -gt 9007199254740991) {
                        throw "Diagnostic context '$key' must be a finite, nonnegative JSON-safe number."
                    }
                    if ($key -ne 'costUSD' -and $number -ne [math]::Truncate($number)) {
                        throw "Diagnostic context '$key' must be a whole number."
                    }
                    $safeContext[$key] = if ($key -eq 'costUSD') { $number } else { [long]$number }
                }
            }
        }
    }

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
        if ($safeContext.Count -gt 0) { $entry.context = $safeContext }
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