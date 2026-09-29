function New-DpCompactionPrompt {
    <#
    .SYNOPSIS
        Builds the prompt that asks the Model to summarise a Conversation so its
        replayed history can be compacted.
    .DESCRIPTION
        Renders the Conversation history ({ role, content } entries) into a plain
        transcript and wraps it in a strict instruction asking for a concise,
        information-dense summary suitable for replacing the older Turns in the
        Engine -History. The transcript is capped so a very long Conversation never
        bloats the compaction Turn; when capped, the most recent context is kept
        because it matters most for continuing the Conversation. Both hashtable and
        PSCustomObject history entries are accepted.

        The summary is asked for in five named sections - goals, constraints,
        decisions, unresolved work and source references - because free prose is
        what makes a compaction unmeasurable. Named sections let
        Measure-DpCompactionPreservation check afterwards whether the things that
        must survive a compaction actually did, and they are the things a
        conversation cannot continue without: what the user is trying to achieve,
        what they ruled out, what was already settled, what is still open, and
        which files it all concerns.
    .PARAMETER History
        The Conversation history entries (each with a role and content), oldest
        first.
    .PARAMETER MaxInputChars
        A hard cap on the rendered transcript length. Default 12000.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$History,

        [int]$MaxInputChars = 12000
    )

    $sb = [System.Text.StringBuilder]::new()
    foreach ($entry in @($History)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [System.Collections.IDictionary]) {
            $role = [string]$entry['role']
            $content = $entry['content']
        }
        else {
            $role = [string](Get-DpPropertyValue -InputObject $entry -Name @('role', 'Role') -Default '')
            $content = Get-DpPropertyValue -InputObject $entry -Name @('content', 'Content') -Default ''
        }
        $text = if ($content -is [string]) { $content } else { [string]($content | ConvertTo-Json -Depth 6 -Compress) }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $who = switch -Regex ($role) {
            '^user$' { 'User'; break }
            '^assistant$' { 'Assistant'; break }
            '^system$' { 'System'; break }
            default { if ($role) { $role } else { 'Message' } }
        }
        [void]$sb.AppendLine("${who}: $text")
        [void]$sb.AppendLine('')
    }

    $transcript = $sb.ToString().Trim()
    if ($transcript.Length -gt $MaxInputChars) {
        $transcript = $transcript.Substring($transcript.Length - $MaxInputChars)
    }

    $out = [System.Text.StringBuilder]::new()
    [void]$out.AppendLine('Summarise the conversation transcript below into a concise, information-dense briefing that a new assistant could read to continue the conversation without losing important context.')
    [void]$out.AppendLine('The recent turns stay in the conversation verbatim and nothing the user can see is removed; your briefing replaces only the older turns that are about to be dropped from the replayed context.')
    [void]$out.AppendLine('Use exactly these five labelled sections, in this order, each on its own line and each present even if you write "none":')
    [void]$out.AppendLine('Goals: what the user is trying to achieve.')
    [void]$out.AppendLine('Constraints: what they ruled out, required, or insisted on - including stated preferences.')
    [void]$out.AppendLine('Decisions: what was settled, and the facts established along the way.')
    [void]$out.AppendLine('Unresolved: what is still open, in progress, or waiting on an answer.')
    [void]$out.AppendLine('References: the files, paths, commands and names the work concerns, listed exactly as they appear above.')
    [void]$out.AppendLine('Drop small talk and redundant back-and-forth. Do not add a preamble such as "Here is the summary"; respond with only the five sections and do not wrap them in a code block.')
    [void]$out.AppendLine('Write the summary in the same language as the conversation, but keep the five section labels in English.')
    [void]$out.AppendLine('')
    [void]$out.AppendLine('Transcript:')
    [void]$out.AppendLine('"""')
    [void]$out.AppendLine($transcript)
    [void]$out.AppendLine('"""')

    $out.ToString()
}
