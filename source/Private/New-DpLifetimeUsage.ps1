function New-DpLifetimeUsage {
    <#
    .SYNOPSIS
        Builds a zeroed lifetime Usage counter stamped with the current time.
    .DESCRIPTION
        Returns a fresh lifetime Usage hashtable (all totals zero) with a
        sinceUtc set to now. Used when no persisted counter exists yet and when
        the user resets the lifetime counter.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        promptTokens     = 0
        completionTokens = 0
        totalTokens      = 0
        costUSD          = 0.0
        credits          = 0.0
        turns            = 0
        unpricedTurns    = 0
        sinceUtc         = [DateTime]::UtcNow.ToString('o')
        daily            = @()
    }
}
