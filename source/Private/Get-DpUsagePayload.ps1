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
                model       = $_
                totalTokens = $entry.totalTokens
                costUSD     = $entry.costUSD
                credits     = if ($entry.ContainsKey('credits')) { $entry.credits } else { 0.0 }
                turns       = if ($entry.ContainsKey('turns')) { $entry.turns } else { 0 }
            }
        })

    # The last 30 days of the persisted daily history, oldest first, for the
    # usage graph. Each entry: { date 'yyyy-MM-dd', credits, costUSD, totalTokens, turns }.
    $dailyAll = @($life.daily)
    $daily = @($dailyAll | Select-Object -Last 30 | ForEach-Object {
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
        }
        lifetime = @{
            promptTokens     = $life.promptTokens
            completionTokens = $life.completionTokens
            totalTokens      = $life.totalTokens
            costUSD          = $life.costUSD
            credits          = $life.credits
            turns            = $life.turns
            sinceUtc         = $life.sinceUtc
        }
        byModel  = $byModel
        daily    = $daily
    }
}
