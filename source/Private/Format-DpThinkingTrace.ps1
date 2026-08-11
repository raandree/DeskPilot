function Format-DpThinkingTrace {
    <#
    .SYNOPSIS
        Rewrites one Engine trace line into a readable, structured form.
    .DESCRIPTION
        Under -ShowThinking the Engine writes its trace as host lines, and two of
        them are machine-shaped rather than human-shaped:

        - A tool call is written as '-> name({json})', carrying the provider's raw
          JSON argument string on ONE line. Every newline inside a written file
          therefore arrives as a literal backslash-n and every Windows path as a
          doubled backslash, so the Thinking pane shows an unreadable wall.
        - The iteration banner '=== iteration N (mode) ===' reads as debug output.

        This function lays such a line out: the tool name on its own line, then one
        indented entry per argument - a short scalar inline, a long or multi-line
        value as an indented block whose escaped newlines are real line breaks
        again. A nested object or array is re-serialised as indented JSON.

        Anything it does not recognise is returned unchanged, so the model's own
        reasoning prose - which already carries real newlines and streams token by
        token - is never rewritten. It never truncates: the pane bounds its own
        height, so no part of the trace is lost.
    .PARAMETER Text
        One trace line as the Engine wrote it, ANSI already stripped. Leading
        whitespace (the blank line the Engine puts before a banner) is preserved.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $lead = [regex]::Match($Text, '^\s*').Value
    $core = $Text.Trim()

    $banner = [regex]::Match($core, '^===\s*iteration\s+(?<n>\S+)\s*\((?<mode>[^)]*)\)\s*===$')
    if ($banner.Success) {
        return '{0}── Iteration {1} ({2}) ──' -f $lead, $banner.Groups['n'].Value, $banner.Groups['mode'].Value
    }

    $call = [regex]::Match($core, '(?s)^->\s*(?<name>[^\s(]+)\((?<args>.*)\)$')
    if (-not $call.Success) { return $Text }

    $name = $call.Groups['name'].Value
    $arguments = $call.Groups['args'].Value.Trim()
    if ($arguments.Length -eq 0 -or $arguments -eq '{}') { return "$lead→ $name" }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$lead→ $name")

    $parsed = $null
    try { $parsed = $arguments | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }

    if ($parsed -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $parsed.PSObject.Properties) {
            $value = $property.Value
            $rendered = if ($null -eq $value) {
                ''
            }
            elseif ($value -is [string] -or $value -is [ValueType]) {
                [string]$value
            }
            else {
                ConvertTo-Json -InputObject $value -Depth 8
            }
            $rendered = $rendered -replace "`r`n", "`n" -replace "`r", "`n"

            if ($rendered.Length -le 100 -and -not $rendered.Contains("`n")) {
                $lines.Add("  $($property.Name): $rendered")
            }
            else {
                $lines.Add("  $($property.Name):")
                foreach ($line in $rendered.Split("`n")) {
                    # An indented blank line is trailing whitespace, not structure.
                    $lines.Add($(if ($line.Length -eq 0) { '' } else { "    $line" }))
                }
            }
        }
    }
    else {
        # Malformed or truncated JSON: decode the escapes that cause the wall in one
        # pass, so a doubled backslash is never mistaken for an escaped newline.
        $decoded = [regex]::Replace($arguments, '\\(.)', {
                param($match)
                switch -CaseSensitive ($match.Groups[1].Value) {
                    'n' { "`n" }
                    'r' { "`n" }
                    't' { "`t" }
                    '"' { '"' }
                    '\' { '\' }
                    default { $match.Value }
                }
            })
        foreach ($line in ($decoded -replace "`r`n", "`n").Split("`n")) {
            $lines.Add($(if ($line.Length -eq 0) { '' } else { "  $line" }))
        }
    }

    $lines -join "`n"
}
