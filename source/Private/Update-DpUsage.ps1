function Update-DpUsage {
    <#
    .SYNOPSIS
        Accumulates a Turn's Usage into the running Host Server totals.
    .PARAMETER Usage
        The per-Turn Usage hashtable (promptTokens, completionTokens, totalTokens,
        costUSD, credits, priced).
    .PARAMETER Model
        The Model id the Turn used, for the per-Model breakdown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Usage,

        [string]$Model
    )

    # A Turn the Engine could not price contributes 0 to the money totals, so the
    # totals are a lower bound rather than the answer. Counting those Turns is what
    # lets the UI say so instead of quietly under-reporting spend.
    $unpriced = if ($Usage.ContainsKey('priced') -and -not $Usage.priced) { 1 } else { 0 }

    $totals = $script:DeskPilot.Usage
    $totals.promptTokens += [int]$Usage.promptTokens
    $totals.completionTokens += [int]$Usage.completionTokens
    $totals.totalTokens += [int]$Usage.totalTokens
    # Round credits (4 dp) and cost (6 dp) on every accrual to match the Engine's
    # per-Turn precision and prevent floating-point drift (e.g. 0.6174999999999999).
    $totals.costUSD = [math]::Round($totals.costUSD + [double]$Usage.costUSD, 6)
    $totals.credits = [math]::Round($totals.credits + [double]$Usage.credits, 4)
    $totals.turns += 1
    if (-not $totals.ContainsKey('unpricedTurns')) { $totals.unpricedTurns = 0 }
    $totals.unpricedTurns += $unpriced

    if ($Model) {
        if (-not $totals.byModel.ContainsKey($Model)) {
            $totals.byModel[$Model] = @{ totalTokens = 0; costUSD = 0.0; credits = 0.0; turns = 0; unpricedTurns = 0 }
        }
        $entry = $totals.byModel[$Model]
        if (-not $entry.ContainsKey('credits')) { $entry.credits = 0.0 }
        if (-not $entry.ContainsKey('turns')) { $entry.turns = 0 }
        if (-not $entry.ContainsKey('unpricedTurns')) { $entry.unpricedTurns = 0 }
        $entry.totalTokens += [int]$Usage.totalTokens
        $entry.costUSD = [math]::Round($entry.costUSD + [double]$Usage.costUSD, 6)
        $entry.credits = [math]::Round($entry.credits + [double]$Usage.credits, 4)
        $entry.turns += 1
        $entry.unpricedTurns += $unpriced
    }

    # Accumulate the persisted lifetime counter and write it through to disk so it
    # survives across sessions.
    $life = $script:DeskPilot.LifetimeUsage
    if ($life) {
        $life.promptTokens += [int]$Usage.promptTokens
        $life.completionTokens += [int]$Usage.completionTokens
        $life.totalTokens += [int]$Usage.totalTokens
        $life.costUSD = [math]::Round($life.costUSD + [double]$Usage.costUSD, 6)
        $life.credits = [math]::Round($life.credits + [double]$Usage.credits, 4)
        $life.turns += 1
        if (-not $life.ContainsKey('unpricedTurns')) { $life.unpricedTurns = 0 }
        $life.unpricedTurns += $unpriced
        $life.daily = Add-DpDailyUsage -Daily $life.daily -Usage $Usage
        if ($script:DeskPilot.DataDir) {
            Save-DpLifetimeUsage -Usage $life -Directory $script:DeskPilot.DataDir
        }
    }
}
