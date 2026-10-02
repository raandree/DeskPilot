function Read-DpAgentFile {
    <#
    .SYNOPSIS
        Reads an .agent.md file into its name, description and body.
    .DESCRIPTION
        Parses the optional YAML frontmatter (the leading '---' block) for the
        'name', 'description' and 'applyTo' keys (a folded/literal '>' or '|'
        description is joined into one line) and returns the Markdown body after the
        frontmatter. The body is the Agent's persona/system prompt. Frontmatter
        parsing is deliberately minimal (no full YAML engine) and tolerant: a
        file with no frontmatter returns the whole content as the body.

        applyTo is only meaningful for an instruction file, where it is the glob
        deciding which files the instruction governs; it is $null everywhere else.

        The Subagent keys are read only at the top level of the frontmatter, so an
        indented 'agent:' inside a handoff never counts. 'tools' and 'agents' are
        inline ([a, b]) or block (- a) lists; absent stays $null, which is not the
        same as a declared empty list. 'disable-model-invocation' is true only
        when it says so, and 'user-invocable' is false only when it says so.
        They are metadata: Get-DpSubagentCatalog decides what they mean.

        Pass -Text instead of -Path to parse markup that has already been read.
        That is how the Skill scanner keeps one parser while reading only a
        bounded head of a file it does not trust the size of.
    .PARAMETER Path
        The .agent.md file to read.
    .PARAMETER Text
        Already-read Markdown to parse instead of opening a file.
    .OUTPUTS
        System.Collections.Hashtable with name, description, applyTo, body, tools,
        agents, disableModelInvocation and userInvocable.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [AllowEmptyString()]
        [string]$Text
    )

    $raw = if ($PSCmdlet.ParameterSetName -eq 'Text') { $Text } else { Get-Content -LiteralPath $Path -Raw -ErrorAction Stop }
    if ($null -eq $raw) { $raw = '' }

    $name = $null
    $description = $null
    $applyTo = $null
    $tools = $null
    $agents = $null
    $disableModelInvocation = $false
    $userInvocable = $true
    $body = $raw

    $unquote = { param([string]$Value) $Value.Trim().Trim('"', "'").Trim() }

    if ($raw -match '(?s)^\uFEFF?---\r?\n(.*?)\r?\n---\r?\n?(.*)$') {
        $front = $Matches[1]
        $body = $Matches[2]
        $lines = $front -split '\r?\n'

        # One list value: inline ([a, 'b']), a lone scalar, or - when the key has no
        # value on its own line - the indented '- item' lines that follow it.
        $readList = {
            param([string]$Value, [int]$Index)
            $text = $Value.Trim()
            if ($text.StartsWith('[')) {
                $inner = $text.TrimStart('[').TrimEnd(']')
                return , @($inner -split ',' | ForEach-Object { & $unquote $_ } | Where-Object { $_ })
            }
            if ($text) { return , @(& $unquote $text) }
            $items = [System.Collections.Generic.List[string]]::new()
            for ($j = $Index + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match '^\s+-\s*(.*)$') {
                    $item = & $unquote $Matches[1]
                    if ($item) { $items.Add($item) }
                }
                elseif ($lines[$j] -match '^\s*$') { continue }
                else { break }
            }
            , $items.ToArray()
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^(tools|agents)\s*:(.*)$') {
                $list = & $readList $Matches[2] $i
                if ($Matches[1] -eq 'tools') { $tools = $list } else { $agents = $list }
            }
            elseif ($line -match '^disable-model-invocation\s*:\s*(.+?)\s*$') {
                $disableModelInvocation = (& $unquote $Matches[1]) -eq 'true'
            }
            elseif ($line -match '^user-invocable\s*:\s*(.+?)\s*$') {
                $userInvocable = (& $unquote $Matches[1]) -ne 'false'
            }
            elseif ($line -match '^\s*name\s*:\s*(.+?)\s*$') {
                $name = $Matches[1].Trim().Trim('"', "'")
            }
            elseif ($line -match '^\s*applyTo\s*:\s*(.+?)\s*$') {
                $applyTo = $Matches[1].Trim().Trim('"', "'")
            }
            elseif ($line -match '^\s*description\s*:\s*(.*)$') {
                $val = $Matches[1].Trim()
                if ($val -match '^[>|][-+]?\s*$') {
                    # Folded/literal block scalar: gather the following indented lines.
                    $buffer = [System.Collections.Generic.List[string]]::new()
                    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                        if ($lines[$j] -match '^\s*$' -or $lines[$j] -match '^\s+\S') { $buffer.Add($lines[$j].Trim()) }
                        else { break }
                    }
                    $description = ($buffer -join ' ').Trim()
                }
                else {
                    $description = $val.Trim().Trim('"', "'")
                }
            }
        }
    }

    @{
        name                   = $name
        description            = $description
        applyTo                = $applyTo
        body                   = ([string]$body).Trim()
        tools                  = $tools
        agents                 = $agents
        disableModelInvocation = $disableModelInvocation
        userInvocable          = $userInvocable
    }
}
