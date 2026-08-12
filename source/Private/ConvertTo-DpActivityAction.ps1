function ConvertTo-DpActivityAction {
    <#
    .SYNOPSIS
        Classifies one Engine tool call as one ordered Activity action.
    .DESCRIPTION
        The Activity of a Turn used to exist only as unordered sets on the Engine
        result - files read, files written, commands run - which arrive when the
        Turn is already over. This is the shape that lets the window say what the
        agent is touching WHILE it touches it, and then keep that account in order.

        **The detail is whitelisted, never copied.** The tool name selects one
        argument field - the path for a file tool, the URL for fetch_url, the
        command for run_command - and a tool this does not know about contributes
        its name and nothing else. The arguments hold the written file body, the
        replacement text and whatever else a future tool invents, so a blacklist
        would have to be right about every one of them; a whitelist is wrong only
        in the safe direction. This mirrors New-DpTranscriptRecord, which redacts
        the same arguments the same way for the same reason.

        manage_todo_list is deliberately absent: the Task List has its own live
        panel, and repeating every one of its updates as an action would bury the
        tool calls that have nowhere else to be seen.
    .PARAMETER Tool
        The Engine's tool name from the structured ToolCall record.
    .PARAMETER Arguments
        The provider's raw JSON argument string. Parsed, never stored whole.
    .PARAMETER MaxDetail
        The most characters the detail may carry.
    .OUTPUTS
        System.Collections.Hashtable

        One action { tool; kind; detail }, or nothing when the record describes no
        action worth showing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Tool,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Arguments,

        [ValidateRange(16, 2000)]
        [int]$MaxDetail = 300
    )

    if ([string]::IsNullOrWhiteSpace($Tool)) { return }
    $name = $Tool.Trim()
    if ($name -eq 'manage_todo_list') { return }

    $known = @{
        read_file        = @{ kind = 'read'; field = 'path' }
        list_directory   = @{ kind = 'list'; field = 'path' }
        write_file       = @{ kind = 'write'; field = 'path' }
        replace_in_file  = @{ kind = 'write'; field = 'path' }
        # Its own kind, not a write: a folder has no diff and is never a pending
        # change, so treating it as one would put a dead review row on the Turn.
        create_directory = @{ kind = 'create'; field = 'path' }
        run_command      = @{ kind = 'run'; field = 'command' }
        fetch_url        = @{ kind = 'fetch'; field = 'url' }
        search_files     = @{ kind = 'search'; field = 'pattern' }
        search_text      = @{ kind = 'search'; field = 'query' }
        ask_user         = @{ kind = 'ask'; field = 'question' }
        # The Questionnaire is nested JSON and the wizard card already shows it.
        ask_questions    = @{ kind = 'ask'; field = '' }
        load_skill       = @{ kind = 'load'; field = 'name' }
        load_instruction = @{ kind = 'load'; field = 'name' }
    }

    $kind = 'other'
    $field = ''
    if ($known.ContainsKey($name)) {
        $kind = [string]$known[$name].kind
        $field = [string]$known[$name].field
    }
    elseif ($name -like 'mcp_*') {
        # A tool from an attached MCP server, which the Engine namespaces as
        # mcp_<alias>_<tool>. Its own kind rather than 'other' because this is the
        # one class of tool whose code nobody here wrote and whose reach no
        # Permission or tool policy narrows - the panel should say so, not blend it
        # in with the built-ins. No detail is derived: the argument shape is the
        # server's own JSON Schema, so there is no field this can know, and the
        # alias cannot be split back out of the name reliably because both halves
        # may contain an underscore.
        $kind = 'mcp'
    }

    $detail = ''
    if ($field -and -not [string]::IsNullOrWhiteSpace($Arguments)) {
        try {
            $parsed = $Arguments | ConvertFrom-Json -ErrorAction Stop
            $detail = [string](Get-DpPropertyValue -InputObject $parsed -Name @($field) -Default '')
        }
        catch {
            # Truncated or malformed provider JSON costs this action its detail. It
            # must never cost it the raw argument string instead.
            $detail = ''
        }
    }
    if ($detail) {
        # A command can be several lines and a URL can be a paragraph; the row that
        # shows this is one line either way.
        $detail = ($detail -replace '\s+', ' ').Trim()
        if ($detail.Length -gt $MaxDetail) { $detail = $detail.Substring(0, $MaxDetail - 1) + '…' }
    }

    @{ tool = $name; kind = $kind; detail = $detail }
}
