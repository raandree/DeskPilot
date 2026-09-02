function New-DpDiagnosticLog {
    <#
    .SYNOPSIS
        Creates a bounded in-memory Host Server diagnostic log.
    .DESCRIPTION
        Returns the transient state owned by one Host Server launch. Entries are
        protected by one lock so sequence assignment, append, and eviction are
        atomic even when producers run on different threads.
    .PARAMETER MaxEntries
        Maximum number of retained entries.
    .PARAMETER MaxBytes
        Maximum UTF-8 bytes retained across entry summaries and metadata.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs transient in-memory state and performs no external change.')]
    param(
        [ValidateRange(1, 10000)]
        [int]$MaxEntries = 500,

        [ValidateRange(256, 104857600)]
        [long]$MaxBytes = 1048576
    )

    @{
        SyncRoot    = [object]::new()
        Entries     = [System.Collections.Generic.List[object]]::new()
        MaxEntries  = $MaxEntries
        MaxBytes    = $MaxBytes
        CurrentBytes = [long]0
        NextSequence = [long]0
    }
}