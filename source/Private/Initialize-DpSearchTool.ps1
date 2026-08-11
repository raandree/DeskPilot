function Initialize-DpSearchTool {
    <#
    .SYNOPSIS
        Registers DeskPilot's search Tools in the Engine Runspace.
    .DESCRIPTION
        The Engine ships no search Tool of any kind, so every act of discovery -
        find a file, find a symbol, find a string - costs a run_command round
        trip that returns unstructured console text. The consequence is not that
        DeskPilot searches badly but that it searches rarely, and so reasons from
        less evidence. These two Tools make discovery cheap and structured.

        The implementation is not written twice. The backing commands are
        ordinary DeskPilot functions - unit-tested and analysed in this
        repository - and this helper re-declares them inside the Engine Runspace
        from their own definitions, because that runspace has ShellPilot imported
        and DeskPilot not. Their dependencies are injected with them; nothing in
        the injected set may call a DeskPilot function that is not in it.

        The Workspace Folder arrives out of band, as a Runspace global rather
        than a Tool parameter. Every parameter becomes a field in the JSON schema
        the model is free to fill in, so a root parameter would be an invitation
        to search C:\Users. Because ShellPilot derives that schema from parameter
        metadata alone - each property described as "The pattern parameter of
        Invoke-DpFileSearchTool" - the whole argument contract has to live in the
        Tool description, exactly as ask_questions does.
    .PARAMETER Runspace
        The long-lived Engine Runspace with ShellPilot already imported.
    .PARAMETER Root
        The Workspace Folder to confine both Tools to. Empty means no Project is
        selected, and both Tools then answer with a structured error.
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
        'Test-DpBinaryFile'
        'Get-DpSearchCandidate'
        'Invoke-DpFileSearchTool'
        'Invoke-DpTextSearchTool'
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('param([AllowEmptyString()][string]$SearchRoot)')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotSearchRoot -Scope Global -Value $SearchRoot')
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

Register-ShpTool -Command 'Invoke-DpFileSearchTool' -ToolName 'search_files' -Description $fileDescription -Confirm:$false
Register-ShpTool -Command 'Invoke-DpTextSearchTool' -ToolName 'search_text' -Description $textDescription -Confirm:$false
'@)

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript($builder.ToString()).AddArgument([string]$Root)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not register the search tools.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $true
}
