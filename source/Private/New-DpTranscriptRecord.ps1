function New-DpTranscriptRecord {
    <#
    .SYNOPSIS
        Builds one ordered, redacted record of a Turn transcript.
    .DESCRIPTION
        DeskPilot's record of a Turn is scattered across four places nothing can
        join: live SSE frames that vanish, ShpProgress records consumed and
        dropped, result.ToolCalls / FilesRead / CommandsRun as unordered sets, and
        a Thinking pane that is a formatted string. This is the one shape that
        orders them.

        **Redaction is by construction, not by pattern.** A tool's arguments are
        never stored verbatim: the tool name selects one whitelisted field to
        summarise - the command for run_command, the path for a file tool, the URL
        for fetch_url - and a tool this does not know about contributes a byte
        count and nothing else. A blacklist would have to be right about every
        future tool; a whitelist is wrong only in the safe direction.

        Free text is bounded the same way, and three kinds are not stored at all.
        A live smoke proved why: asked to write a file containing a secret, the
        model quoted that secret back in its own answer - so `answer`,
        `narration` and `reasoning` contribute a length and nothing else. Nothing
        is lost by that: all three are already persisted verbatim on the Message,
        so a bounded copy here would add no diagnostic value while being the one
        path by which arbitrary user data could reach this file. `error` keeps its
        summary because a failed Turn has no Message to hold it, and debugging a
        failure without the failure is not debugging.

        Every record carries the original length as `bytes`, so the transcript
        still says how much there was without becoming a second copy of it.
    .PARAMETER Seq
        The monotonic sequence number within the Turn.
    .PARAMETER Kind
        What the record is.
    .PARAMETER Timestamp
        When the Engine produced it - the record's own TimeGenerated, never the
        clock: the Turn loop drains the stream in polled batches, so clock time
        measures the poll rather than the event.
    .PARAMETER Iteration
        The tool-calling iteration this belongs to.
    .PARAMETER Tool
        The tool name, for a tool_call or tool_result record.
    .PARAMETER Arguments
        The provider's raw JSON argument string. Summarised, never stored.
    .PARAMETER Text
        Free text (narration, reasoning, answer, error). Bounded, never stored
        whole.
    .PARAMETER Detail
        Extra scalar members for a meta record. Values are stringified and
        bounded; nothing here is read from a tool.
    .PARAMETER MaxSummary
        The most characters any summary may carry.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [int]$Seq,

        [Parameter(Mandatory)]
        [ValidateSet('narration', 'reasoning', 'tool_call', 'tool_result', 'tasks', 'answer', 'error', 'meta')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [datetime]$Timestamp,

        [int]$Iteration = 0,

        [AllowEmptyString()]
        [string]$Tool = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Arguments,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [hashtable]$Detail,

        [ValidateRange(16, 4000)]
        [int]$MaxSummary = 200
    )

    # The one place a tool's arguments become a summary. A tool absent from this
    # map contributes its size and nothing else - which is what must happen to a
    # tool that does not exist yet.
    $argumentField = @{
        run_command      = 'command'
        fetch_url        = 'url'
        read_file        = 'path'
        list_directory   = 'path'
        write_file       = 'path'
        create_directory = 'path'
        replace_in_file  = 'path'
        search_files     = 'pattern'
        search_text      = 'query'
        load_skill       = 'name'
        load_instruction = 'name'
    }

    # Kinds whose text is the model's own prose. Already on the Message, and the
    # only way arbitrary user data could reach this file - so length only.
    $lengthOnly = @('narration', 'reasoning', 'answer')

    $bound = {
        param([string]$Value)
        if ([string]::IsNullOrEmpty($Value)) { return '' }
        $flat = ($Value -replace '\s+', ' ').Trim()
        if ($flat.Length -le $MaxSummary) { return $flat }
        $flat.Substring(0, $MaxSummary - 1) + '…'
    }

    $summary = ''
    $bytes = 0

    if ($PSBoundParameters.ContainsKey('Arguments')) {
        $raw = [string]$Arguments
        $bytes = $raw.Length
        if ($argumentField.ContainsKey($Tool) -and -not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                $summary = & $bound ([string](Get-DpPropertyValue -InputObject $parsed -Name @($argumentField[$Tool]) -Default ''))
            }
            catch {
                # Truncated or malformed provider JSON costs this record its
                # summary. It must never cost it the raw string instead.
                $summary = ''
            }
        }
    }
    elseif ($PSBoundParameters.ContainsKey('Text')) {
        $raw = [string]$Text
        $bytes = $raw.Length
        if ($lengthOnly -notcontains $Kind) { $summary = & $bound $raw }
    }

    $record = [ordered]@{
        seq       = $Seq
        ts        = $Timestamp.ToUniversalTime().ToString('o')
        iteration = $Iteration
        kind      = $Kind
    }
    if ($Tool) { $record.tool = $Tool }
    $record.summary = $summary
    $record.bytes = $bytes

    if ($Detail) {
        foreach ($key in @($Detail.Keys | Sort-Object)) {
            $value = $Detail[$key]
            $record[[string]$key] = $(
                if ($value -is [bool] -or $value -is [int] -or $value -is [long] -or $value -is [double]) { $value }
                else { & $bound ([string]$value) }
            )
        }
    }

    $record
}
