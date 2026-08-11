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
    .PARAMETER Path
        The .agent.md file to read.
    .OUTPUTS
        System.Collections.Hashtable with name, description, applyTo and body.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($null -eq $raw) { $raw = '' }

    $name = $null
    $description = $null
    $applyTo = $null
    $body = $raw

    if ($raw -match '(?s)^\uFEFF?---\r?\n(.*?)\r?\n---\r?\n?(.*)$') {
        $front = $Matches[1]
        $body = $Matches[2]
        $lines = $front -split '\r?\n'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*name\s*:\s*(.+?)\s*$') {
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

    @{ name = $name; description = $description; applyTo = $applyTo; body = ([string]$body).Trim() }
}
