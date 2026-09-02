function Clear-DpDiagnosticLog {
    <#
    .SYNOPSIS
        Clears the transient Host Server diagnostic log.
    .DESCRIPTION
        Removes every retained entry under the log lock while preserving the
        sequence counter so a polling cursor cannot confuse a new entry with an
        entry observed before the clear.
    .PARAMETER Log
        The state returned by New-DpDiagnosticLog.
    .OUTPUTS
        System.Int32
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Log
    )

    [System.Threading.Monitor]::Enter($Log.SyncRoot)
    try {
        $removed = $Log.Entries.Count
        $Log.Entries.Clear()
        $Log.CurrentBytes = [long]0
        $removed
    }
    finally {
        [System.Threading.Monitor]::Exit($Log.SyncRoot)
    }
}