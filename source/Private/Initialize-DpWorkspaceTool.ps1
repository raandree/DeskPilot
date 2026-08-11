function Initialize-DpWorkspaceTool {
    <#
    .SYNOPSIS
        Registers DeskPilot's workspace Tools in the Engine Runspace.
    .DESCRIPTION
        The Engine ships no search Tool of any kind, and its only edit Tool
        overwrites whole files. Both gaps are closed here with DeskPilot-owned
        User Tools: search_files, search_text and replace_in_file.

        The implementation is not written twice. The backing commands are ordinary
        DeskPilot functions - unit-tested and analysed in this repository - and
        this helper re-declares them inside the Engine Runspace from their own
        definitions, because that runspace has ShellPilot imported and DeskPilot
        not. Their dependencies are injected with them; nothing in the injected
        set may call a DeskPilot function that is not in it.

        Two Runspace globals carry what must not be a Tool parameter. The
        Workspace Folder is one: every parameter becomes a field in the JSON
        schema the model is free to fill in, so a root parameter would be an
        invitation to search or edit C:\Users. The other is the edited-file
        ledger, which replace_in_file appends to - ShellPilot fills
        result.FilesWritten only from its own write_file, so without the ledger an
        edit made here would never reach the Activity card, the pending change set
        or Undo. Both are re-established on every registration, so a Turn starts
        with the current root and an empty ledger.

        Because ShellPilot derives the tool schema from parameter metadata alone -
        each property described as "The pattern parameter of
        Invoke-DpFileSearchTool" - the whole argument contract has to live in the
        Tool description, exactly as ask_questions does.
    .PARAMETER Runspace
        The long-lived Engine Runspace with ShellPilot already imported.
    .PARAMETER Root
        The Workspace Folder to confine every Tool to. Empty means no Project is
        selected, and every Tool then answers with a structured error.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Root
    )

    # Dependencies first: a function must exist in the runspace before the one
    # that calls it is invoked, and re-declaring in call order keeps that obvious.
    $names = @(
        'Invoke-DpGitCommand'
        'ConvertTo-DpSearchRegex'
        'Get-DpSearchPatternError'
        'Resolve-DpWorkspaceRoot'
        'Resolve-DpWorkspacePath'
        'Test-DpBinaryFile'
        'Get-DpSearchCandidate'
        'Invoke-DpFileSearchTool'
        'Invoke-DpTextSearchTool'
        'Invoke-DpReplaceInFileTool'
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('param([AllowEmptyString()][string]$WorkspaceRoot)')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotWorkspaceRoot -Scope Global -Value $WorkspaceRoot')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotFilesEdited -Scope Global -Value ([System.Collections.Generic.List[string]]::new())')
    foreach ($name in $names) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        [void]$builder.AppendLine("function global:$name {")
        [void]$builder.AppendLine($command.Definition)
        [void]$builder.AppendLine('}')
    }

    # Single-quoted so nothing here is expanded in DeskPilot's session: this text
    # is the runspace's own source.
    [void]$builder.AppendLine(@'
$fileDescription = @"
Find files in the user's workspace folder by name or path. ALWAYS use this instead
of run_command with dir, ls, Get-ChildItem or find: it is faster, it is confined to
the workspace folder, it honours .gitignore, and it returns structured JSON.
pattern (string, required): a glob relative to the workspace folder, for example
"**/*.ps1", "source/Private/*.ps1" or "Invoke-DpTurn.ps1". "*" matches inside one
path segment, "**" matches across segments, "?" matches one character. A pattern
with no "/" also matches on the file name alone, so "*.psd1" finds nested files.
Absolute paths, drive letters and ".." are rejected - the search cannot leave the
workspace folder.
maxResults (integer, optional): the most paths to return. Capped at 200.
Returns JSON {pattern, root, totalMatches, returned, truncated, timedOut, paths}
with every path relative to the workspace folder. truncated true means matches were
left out: narrow the pattern rather than concluding the rest do not exist.
"@

$textDescription = @"
Search the text of files in the user's workspace folder for a string or a regular
expression. ALWAYS use this to find where something is defined, used or mentioned,
instead of run_command with grep, rg, findstr or Select-String: it is faster, it is
confined to the workspace folder, it honours .gitignore, it skips binary files, and
it returns structured JSON.
query (string, required): the text to find, or a .NET regular expression when
isRegex is true. Always case-insensitive.
isRegex (boolean, optional): read query as a regular expression. Default false.
includePattern (string, optional): a glob limiting which files are searched, for
example "**/*.ps1" or "source/Private/*.ps1". Same glob rules as search_files;
absolute paths and ".." are rejected.
maxResults (integer, optional): the most matches to return. Capped at 200.
Returns JSON {query, root, totalMatches, returned, truncated, timedOut, matches},
where each match is {path, line, text}: path relative to the workspace folder, line
a 1-based line number, and text the matching line trimmed to 200 characters. One
entry per matching line. truncated true means matches were left out: narrow the
query or set includePattern rather than concluding the rest do not exist.
"@

$replaceDescription = @"
Replace one exact block of text in a file that already exists in the user's
workspace folder. ALWAYS use this to change an existing file. Use write_file ONLY
to create a new file, or when you deliberately mean to replace a whole file:
write_file overwrites everything, so using it for a small change means reproducing
every other line from memory and losing whatever you get wrong.
path (string, required): the file, relative to the workspace folder. Absolute
paths, drive letters and ".." are rejected.
oldText (string, required): the exact text to replace, copied verbatim from the
file including indentation. It must appear EXACTLY ONCE - if it appears more often
the call fails and tells you how many times, so add surrounding lines until it is
unique. Line endings are matched against the file's own, so plain newlines are
fine.
newText (string, required): the replacement text. Pass an empty string to delete
the matched block.
Returns JSON {path, replaced, occurrences, lineStart, lineEnd} naming the lines the
edit landed on, so you do not need to re-read the file. On {error, message} - text
not found, or ambiguous - the file is UNCHANGED. Read the file first so oldText is
exact, and prefer several small precise edits over one large one.
"@

Register-ShpTool -Command 'Invoke-DpFileSearchTool' -ToolName 'search_files' -Description $fileDescription -Confirm:$false
Register-ShpTool -Command 'Invoke-DpTextSearchTool' -ToolName 'search_text' -Description $textDescription -Confirm:$false
Register-ShpTool -Command 'Invoke-DpReplaceInFileTool' -ToolName 'replace_in_file' -Description $replaceDescription -Confirm:$false
'@)

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript($builder.ToString()).AddArgument([string]$Root)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not register the workspace tools.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $true
}
