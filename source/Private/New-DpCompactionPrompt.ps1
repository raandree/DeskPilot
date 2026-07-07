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
    [void]$out.AppendLine('Preserve the user goals and constraints, decisions made, facts established, file and code names, open questions, and any explicit instructions or preferences. Drop small talk and redundant back-and-forth.')
    [void]$out.AppendLine('Write in compact prose or short bullet points. Do not add a preamble such as "Here is the summary"; respond with only the summary and do not wrap it in a code block.')
    [void]$out.AppendLine('Write the summary in the same language as the conversation.')
    [void]$out.AppendLine('')
    [void]$out.AppendLine('Transcript:')
    [void]$out.AppendLine('"""')
    [void]$out.AppendLine($transcript)
    [void]$out.AppendLine('"""')

    $out.ToString()
}
