function Get-DpUsagePayload {
    <#
    .SYNOPSIS
        Builds the GET /api/usage response from the running state.
    .DESCRIPTION
        Returns a hashtable with the session counter, the persisted lifetime
        counter, and the session per-Model breakdown, ready to serialise to JSON.
        Reads $script:DeskPilot.Usage and $script:DeskPilot.LifetimeUsage.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $session = $script:DeskPilot.Usage
    $life = $script:DeskPilot.LifetimeUsage

    $byModel = @($session.byModel.Keys | ForEach-Object {
            $entry = $session.byModel[$_]
            @{
                model         = $_
                totalTokens   = $entry.totalTokens
                costUSD       = $entry.costUSD
                credits       = if ($entry.ContainsKey('credits')) { $entry.credits } else { 0.0 }
                turns         = if ($entry.ContainsKey('turns')) { $entry.turns } else { 0 }
                unpricedTurns = if ($entry.ContainsKey('unpricedTurns')) { $entry.unpricedTurns } else { 0 }
            }
        })

    # The persisted daily history (up to the 60-day retention window), oldest
    # first, for the usage graph. The popover charts a 7-, 14- or 30-day window
    # client-side, so returning the whole retained set keeps every range covered.
    # Each entry: { date 'yyyy-MM-dd', credits, costUSD, totalTokens, turns }.
    $dailyAll = @($life.daily)
    $daily = @($dailyAll | Select-Object -Last 60 | ForEach-Object {
            @{
                date        = [string]$_.date
                credits     = [double]$_.credits
                costUSD     = [double]$_.costUSD
                totalTokens = [int]$_.totalTokens
                turns       = [int]$_.turns
            }
        })

    @{
        session  = @{
            promptTokens     = $session.promptTokens
            completionTokens = $session.completionTokens
            totalTokens      = $session.totalTokens
            costUSD          = $session.costUSD
            credits          = $session.credits
            turns            = $session.turns
            unpricedTurns    = if ($session.ContainsKey('unpricedTurns')) { $session.unpricedTurns } else { 0 }
        }
        lifetime = @{
            promptTokens     = $life.promptTokens
            completionTokens = $life.completionTokens
            totalTokens      = $life.totalTokens
            costUSD          = $life.costUSD
            credits          = $life.credits
            turns            = $life.turns
            unpricedTurns    = if ($life.ContainsKey('unpricedTurns')) { $life.unpricedTurns } else { 0 }
            sinceUtc         = $life.sinceUtc
        }
        byModel  = $byModel
        daily    = $daily
    }
}
