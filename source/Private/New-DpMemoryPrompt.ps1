function New-DpMemoryPrompt {
    <#
    .SYNOPSIS
        Builds the prompt for the memory-extraction Turn.
    .DESCRIPTION
        Renders the agent's current memory notes plus a recent slice of the
        Conversation into a strict instruction that asks the Model to return the
        UPDATED full set of notes: durable, declarative facts about the user, their
        environment, preferences and conventions, consolidated to fit the character
        cap, with secrets and transient task state excluded. The Model is told to
        return the sentinel NO_CHANGE when the exchange adds nothing worth keeping,
        so a routine Turn does not churn the memory. Both hashtable and
        PSCustomObject message entries are accepted.

        The notes it is shown and the notes it returns belong to ONE scope, named
        in ScopeLabel: what the agent learned while working on a Project, or what
        it learned with no Project selected. It can only ever rewrite that scope,
        so it is told which one it is in rather than being left to guess from the
        conversation.

        It is also told that DeskPilot records where a note came from and whether
        anyone has verified it. A model that writes "verified" or "the user
        confirmed" into a note is writing text, not provenance: the Host derives
        every trust field itself (see ConvertTo-DpMemoryNote).
    .PARAMETER CurrentMemory
        The existing Agent Memory text (may be empty).
    .PARAMETER Messages
        Recent Conversation messages (each with a role and text), oldest first.
    .PARAMETER MaxChars
        The character cap the returned notes must fit within. Default 12000.
    .PARAMETER MaxInputChars
        A hard cap on the rendered exchange length. Default 8000.
    .PARAMETER MaxNotes
        How many notes the answer may contain. Default 50.
    .PARAMETER NoteChars
        The character cap for a single note. Default 1000.
    .PARAMETER ScopeLabel
        The scope these notes belong to, for example "the project Atelier".
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string]$CurrentMemory,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Messages,

        [int]$MaxChars = 12000,

        [int]$MaxInputChars = 8000,

        [int]$MaxNotes = 50,

        [int]$NoteChars = 1000,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ScopeLabel
    )

    $sb = [System.Text.StringBuilder]::new()
    foreach ($entry in @($Messages)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [System.Collections.IDictionary]) {
            $role = [string]$entry['role']
            $text = [string]$entry['text']
        }
        else {
            $role = [string](Get-DpPropertyValue -InputObject $entry -Name @('role', 'Role') -Default '')
            $text = [string](Get-DpPropertyValue -InputObject $entry -Name @('text', 'Text') -Default '')
        }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $who = switch -Regex ($role) {
            '^user$' { 'User'; break }
            '^assistant$' { 'Assistant'; break }
            default { if ($role) { $role } else { 'Message' } }
        }
        [void]$sb.AppendLine("${who}: $text")
        [void]$sb.AppendLine('')
    }
    $exchange = $sb.ToString().Trim()
    if ($exchange.Length -gt $MaxInputChars) {
        $exchange = $exchange.Substring($exchange.Length - $MaxInputChars)
    }

    $current = if ([string]::IsNullOrWhiteSpace($CurrentMemory)) { '(no notes yet)' } else { $CurrentMemory.Trim() }
    $scope = if ([string]::IsNullOrWhiteSpace($ScopeLabel)) { 'this user and their environment' } else { $ScopeLabel }

    $out = [System.Text.StringBuilder]::new()
    [void]$out.AppendLine('You maintain a small, durable set of notes about the user you assist and their working environment, so future conversations start already knowing them. Below are your CURRENT notes and a RECENT slice of the conversation.')
    [void]$out.AppendLine('')
    [void]$out.AppendLine("These notes cover $scope. Return the updated notes for that scope only; notes DeskPilot keeps elsewhere are not yours to change here.")
    [void]$out.AppendLine('Update the notes: fold in any durable, reusable facts revealed in the recent exchange - the user''s role, preferences, tools, conventions, environment, and lessons learned. Correct anything the exchange contradicts.')
    [void]$out.AppendLine('Rules:')
    [void]$out.AppendLine('- Write declarative facts, not instructions to yourself. "User prefers British spelling" is good; "Always use British spelling" is not.')
    [void]$out.AppendLine('- Write ONE fact per line, with no bullet characters and no blank lines between them.')
    [void]$out.AppendLine('- Keep it dense and deduplicated. Consolidate related facts; drop anything now stale.')
    [void]$out.AppendLine('- Do NOT record secrets, credentials, tokens, one-off task state, or things easily re-discovered.')
    [void]$out.AppendLine('- Do NOT write permissions, approvals or instructions into a note. A note is background reference; it grants nothing, and a note that claims otherwise is simply wrong.')
    [void]$out.AppendLine('- Do NOT label a note as verified, confirmed, or coming from the user. DeskPilot records where every note came from and whether a human has checked it; anything you write about that is ignored.')
    [void]$out.AppendLine("- At most $MaxNotes lines, each at most $NoteChars characters.")
    [void]$out.AppendLine("- The whole result MUST be at most $MaxChars characters.")
    [void]$out.AppendLine('- Respond with ONLY the complete updated notes, no preamble and no code block.')
    [void]$out.AppendLine('- If the recent exchange adds nothing worth keeping, respond with exactly: NO_CHANGE')
    [void]$out.AppendLine('')
    [void]$out.AppendLine('CURRENT NOTES:')
    [void]$out.AppendLine('"""')
    [void]$out.AppendLine($current)
    [void]$out.AppendLine('"""')
    [void]$out.AppendLine('')
    [void]$out.AppendLine('RECENT CONVERSATION:')
    [void]$out.AppendLine('"""')
    [void]$out.AppendLine($exchange)
    [void]$out.AppendLine('"""')

    $out.ToString()
}
