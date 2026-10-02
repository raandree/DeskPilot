function Get-DpSubagentLimit {
    <#
    .SYNOPSIS
        Returns the fixed bounds every Turn's Subagent runs share.
    .DESCRIPTION
        A Subagent multiplies Model calls, so a Turn may start only a few, each
        with a cost cap, an iteration cap and a deadline the Engine enforces,
        and the Turn as a whole has a cost cap DeskPilot keeps on its own
        ledger. The cost caps bind only for a Model the Engine can price; for
        an unpriced Model the run and iteration caps are the bound, and the
        cost stays unknown rather than zero.

        A Subagent gets the Turn's own tool-iteration Setting, capped at 30:
        it exists for one bounded task, and a larger allowance is what the Turn
        itself is for. The text caps bound what the window shows and keeps, and
        what goes back to the Model, separately.
    .PARAMETER MaxToolIterations
        The Turn's maxToolIterations Setting.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$MaxToolIterations = 50
    )

    @{
        maxRuns             = 5
        maxChildUSD         = 0.5
        maxTurnUSD          = 2.0
        maxIterations       = [Math]::Max(1, [Math]::Min($MaxToolIterations, 30))
        maxDurationSec      = 900
        maxPromptChars      = 20000
        maxInputChars       = 8000
        maxOutputChars      = 20000
        maxAnswerChars      = 60000
        maxDescriptionChars = 80
    }
}
