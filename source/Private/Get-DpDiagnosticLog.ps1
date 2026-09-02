function Get-DpDiagnosticLog {
    <#
    .SYNOPSIS
        Returns an ordered snapshot of the diagnostic log.
    .PARAMETER Log
        The state returned by New-DpDiagnosticLog.
    .PARAMETER AfterSequence
        Return only entries newer than this sequence number.
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Log,

        [ValidateRange(0, [long]::MaxValue)]
        [long]$AfterSequence = 0
    )

    [System.Threading.Monitor]::Enter($Log.SyncRoot)
    try {
        @($Log.Entries | Where-Object { [long]$_.sequence -gt $AfterSequence })
    }
    finally {
        [System.Threading.Monitor]::Exit($Log.SyncRoot)
    }
}