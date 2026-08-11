function Get-DpStreamFrame {
    <#
    .SYNOPSIS
        Classifies one Engine Information record into an SSE frame decision.
    .DESCRIPTION
        The Engine Runspace's Information stream carries two kinds of record
        during a Turn:
        - Structured ShpProgress records (Write-Information -Tags 'ShpProgress'),
          whose MessageData is a payload with a Kind member. Kind 'TodoList'
          carries the full normalised Task List for the Turn; Kind 'ToolCall'
          announces a tool invocation; any other Kind is reserved for future use.
        - Ordinary host echo (Write-Host) carrying the streamed answer tokens and,
          under -ShowThinking, a colour-coded reasoning/iteration/tool trace.

        This function maps a single record to at most one frame decision so the
        Turn loop can stream it. It is pure and never writes anything itself.

        Mapping:
        - ShpProgress + Kind 'TodoList' -> a 'tasks' frame carrying the full
          normalised Task List (also exposed on the decision's Tasks member so the
          caller can remember the latest list). The list is an idempotent replace,
          not a delta.
        - ShpProgress + any other Kind (ToolCall, future kinds) -> no frame.
          Activity is reconstructed from the result; tool traces are not echoed,
          and unknown kinds are ignored for forward-compatibility.
        - A non-ShpProgress trace line (model reasoning, '=== iteration', '-> tool',
          or a DarkGray/DarkCyan/Cyan/Yellow host colour) -> a 'reasoning' frame
          when ShowThinking is on, otherwise no frame.
        - Any other host text -> a 'delta' frame carrying the answer token(s).
        - Empty/whitespace text or a $null record -> no frame.

        Line breaks: each Write-Host call surfaces as one record whose
        HostInformationMessage.Message carries the text WITHOUT the trailing
        newline - that line break lives in the separate NoNewLine flag ($false for
        a complete line, $true for a -NoNewline streamed token). The client
        concatenates the streamed 'reasoning'/'delta' frames, so a complete-line
        write must re-attach its newline; otherwise distinct thinking lines glue
        together into one unreadable run. Only an explicit NoNewLine of $false gets
        a newline back - a $true token and an unspecified ($null) write are left to
        concatenate as the Engine intended.

        Readability: a complete-line trace also goes through Format-DpThinkingTrace,
        which lays out the tool call the Engine writes as one line of raw provider
        JSON. A streamed reasoning token is never rewritten - it is prose, and only
        the concatenation of many tokens is a whole thought.
    .PARAMETER Record
        One Information record from the Engine Runspace stream.
    .PARAMETER ShowThinking
        When set, the model's reasoning/tool trace is surfaced as 'reasoning'
        frames; otherwise it is dropped.
    .OUTPUTS
        System.Collections.Hashtable

        A frame decision { event; data } (plus Tasks for a 'tasks' decision), or
        nothing when the record yields no frame.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Record,

        [switch]$ShowThinking
    )

    if ($null -eq $Record) { return }

    # Structured progress records take precedence and never leak into the answer.
    $tags = Get-DpPropertyValue -InputObject $Record -Name @('Tags') -Default @()
    if (@($tags) -contains 'ShpProgress') {
        $payload = Get-DpPropertyValue -InputObject $Record -Name @('MessageData') -Default $null
        $kind = [string](Get-DpPropertyValue -InputObject $payload -Name @('Kind') -Default '')
        if ($kind -eq 'TodoList') {
            # Assign the normaliser's output directly: it returns the array via the
            # unary-comma pattern, and wrapping that in @() would nest it (collapsing
            # a multi-Task list to a single element).
            $list = ConvertTo-DpTaskList -InputObject (Get-DpPropertyValue -InputObject $payload -Name @('TodoList') -Default @())
            return @{ event = 'tasks'; data = @{ tasks = $list }; Tasks = $list }
        }
        # ToolCall and any future Kind are consumed silently (no answer leak).
        return
    }

    # Ordinary host echo: extract the text, optional foreground colour, and whether
    # the Engine wrote a complete line. A complete-line write (NoNewLine -eq $false)
    # must re-attach its newline so the client-side concatenation of streamed frames
    # keeps distinct lines apart; a streamed token ($true) and an unspecified ($null)
    # write are left untouched.
    $messageData = Get-DpPropertyValue -InputObject $Record -Name @('MessageData') -Default $null
    $text = $null
    $foreground = $null
    $completeLine = $false
    if ($messageData -is [System.Management.Automation.HostInformationMessage]) {
        $text = $messageData.Message
        $foreground = $messageData.ForegroundColor
        $completeLine = ($messageData.NoNewLine -eq $false)
    }
    elseif ($messageData -is [string]) { $text = $messageData }
    elseif ($null -ne $messageData) { $text = "$messageData" }
    if ($null -eq $text) { return }

    $ansi = "$([char]27)\[[0-9;]*m"
    $clean = $text -replace $ansi, ''
    if ($clean.Length -eq 0) { return }

    # Under -ShowThinking the Engine emits a host-only colour trace that is NOT
    # part of the answer: the model's reasoning (DarkGray / ANSI 3;90m /
    # "thinking:"), per-iteration banners ("=== iteration N (chat) ===", DarkCyan),
    # tool-call traces ("-> run_command(...)", Cyan) and the odd Yellow note. The
    # real answer tokens are echoed uncoloured. Route the whole trace to the
    # reasoning channel so only the answer streams into the Message body; the final
    # clean text still comes from .Content. When -ShowThinking is off the Engine
    # emits none of this, so the delta stream is already clean.
    $isTrace = (
        $foreground -in @(
            [System.ConsoleColor]::DarkGray,
            [System.ConsoleColor]::DarkCyan,
            [System.ConsoleColor]::Cyan,
            [System.ConsoleColor]::Yellow
        ) -or
        $text -match "$([char]27)\[3;90m" -or
        $clean -match '^\s*thinking:' -or
        $clean -match '^\s*===\s*iteration\s' -or
        $clean -match '^\s*->\s'
    )
    # Re-attach the newline the Engine's complete-line write implied so the client
    # side concatenation preserves line breaks (the Thinking pane is white-space:
    # pre-wrap; the answer delta is Markdown-rendered). The JSON-encoded SSE payload
    # carries the newline as an escaped sequence, so it survives the frame flatten.
    if ($isTrace) {
        if (-not $ShowThinking) { return }
        # A tool call and an iteration banner each arrive as one complete host line,
        # so both can be laid out here. A streamed reasoning token (NoNewLine) is
        # left exactly as it arrived - it is prose the client concatenates.
        $traceText = if ($completeLine) { (Format-DpThinkingTrace -Text $clean) + "`n" } else { $clean }
        return @{ event = 'reasoning'; data = @{ text = $traceText } }
    }
    $emitText = if ($completeLine) { $clean + "`n" } else { $clean }
    @{ event = 'delta'; data = @{ text = $emitText } }
}
