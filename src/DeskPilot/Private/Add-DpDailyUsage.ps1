function Add-DpDailyUsage {
    <#
    .SYNOPSIS
        Adds one Turn's Usage to the per-day (UTC) usage history.
    .DESCRIPTION
        Returns a new array of daily buckets ({ date 'yyyy-MM-dd', credits,
        costUSD, totalTokens, turns }) with the given Turn folded into today's
        bucket (created if absent). Existing entries are normalised to hashtables,
        credits are rounded to 4 decimals and cost to 6 (matching the Engine's
        per-Turn precision) to avoid floating-point drift, the result is sorted by
        date, and entries older than RetainDays are trimmed. Pure (does not mutate
        the input) so it is easy to test.
    .PARAMETER Daily
        The existing daily history (hashtables or PSCustomObjects from JSON).
    .PARAMETER Usage
        The per-Turn Usage hashtable (credits, costUSD, totalTokens).
    .PARAMETER Date
        The reference time; defaults to now. The bucket key is its UTC date.
    .PARAMETER RetainDays
        How many days of history to keep (default 60).
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [object]$Daily,

        [Parameter(Mandatory)]
        [hashtable]$Usage,

        [datetime]$Date = [datetime]::UtcNow,

        [int]$RetainDays = 60
    )

    $byDate = @{}
    $order = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($Daily)) {
        if ($null -eq $entry) { continue }
        $rawDate = if ($entry -is [System.Collections.IDictionary]) { $entry['date'] } else { $entry.date }
        # NB: do not name this $date - PowerShell variables are case-insensitive, so
        # $date would alias the typed [datetime]$Date parameter and coerce a string
        # assignment back into a DateTime, corrupting both the key and $today.
        $dayKey = ConvertTo-DpDayKey -Value $rawDate
        if ([string]::IsNullOrWhiteSpace($dayKey)) { continue }

        $getNum = {
            param($name)
            if ($entry -is [System.Collections.IDictionary]) { $entry[$name] } else { $entry.$name }
        }
        if (-not $byDate.ContainsKey($dayKey)) { $order.Add($dayKey) }
        $byDate[$dayKey] = @{
            date        = $dayKey
            credits     = [double](& $getNum 'credits')
            costUSD     = [double](& $getNum 'costUSD')
            totalTokens = [int](& $getNum 'totalTokens')
            turns       = [int](& $getNum 'turns')
        }
    }

    $today = $Date.ToUniversalTime().ToString('yyyy-MM-dd')
    if (-not $byDate.ContainsKey($today)) {
        $byDate[$today] = @{ date = $today; credits = 0.0; costUSD = 0.0; totalTokens = 0; turns = 0 }
        $order.Add($today)
    }
    $bucket = $byDate[$today]
    $bucket.credits = [math]::Round([double]$bucket.credits + [double]$Usage.credits, 4)
    $bucket.costUSD = [math]::Round([double]$bucket.costUSD + [double]$Usage.costUSD, 6)
    $bucket.totalTokens = [int]$bucket.totalTokens + [int]$Usage.totalTokens
    $bucket.turns = [int]$bucket.turns + 1

    $cutoff = $Date.ToUniversalTime().AddDays(-$RetainDays).ToString('yyyy-MM-dd')
    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($key in ($order | Sort-Object -Unique)) {
        if ($key -ge $cutoff) { $result.Add($byDate[$key]) }
    }
    , $result.ToArray()
}

function ConvertTo-DpDayKey {
    <#
    .SYNOPSIS
        Normalises a date value to a plain 'yyyy-MM-dd' calendar string.
    .DESCRIPTION
        Accepts a string or [datetime] (ConvertFrom-Json can re-type a stored
        date) and returns 'yyyy-MM-dd' WITHOUT any timezone conversion. Parsing a
        date-only string to local midnight and then converting to UTC would shift
        the day by the local offset, splitting one day into two buckets, so this
        never calls ToUniversalTime on an already-formatted value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd') }
    $text = [string]$Value
    if ($text -match '^\d{4}-\d{2}-\d{2}') { return $text.Substring(0, 10) }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($text, [ref]$dt)) { return $dt.ToString('yyyy-MM-dd') }
    $text
}

