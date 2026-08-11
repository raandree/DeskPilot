function Invoke-DpReplaceInFileTool {
    <#
    .SYNOPSIS
        The replace_in_file Tool: changes one exact block of text in one file.
    .DESCRIPTION
        The Engine's only edit Tool is write_file, which overwrites the whole
        file - so changing three lines of a 900-line file means reproducing the
        other 897 from memory. Anything not reproduced is gone, the whole file is
        emitted as output tokens, and a truncated rewrite invites a retry. This
        Tool exists so an edit costs the edit.

        It runs inside the Engine Runspace as the backing command of the
        registered replace_in_file Tool, so its parameter names are the JSON
        argument names the model sends and its output is the JSON envelope the
        model reads. Like the search Tools it takes no root: the Workspace Folder
        arrives out of band on the Runspace global DeskPilotWorkspaceRoot, and the
        same shape check and confinement test apply.

        Three rules make it safe to hand to a model:

        - **Exactly one occurrence, or nothing happens.** Zero matches and two or
          more matches are both refused, with distinct messages, and the file is
          left untouched. Ambiguity plus a silent first-match rule is how an edit
          lands in the wrong place.
        - **Bytes outside the replaced span are preserved.** The file's BOM,
          encoding and dominant line ending are detected and restored, and the
          decoder throws rather than substituting U+FFFD, so a file it cannot
          decode losslessly is refused instead of corrupted. A tool that silently
          rewrites CRLF to LF turns a three-line change into a whole-file diff and
          destroys the review value it exists to create.
        - **The model may write plain newlines.** oldText is matched as sent
          first; if that fails, it is retried converted to the file's own line
          ending, and newText is always converted to it.

        Every successful edit is appended to the Runspace global
        DeskPilotFilesEdited, because ShellPilot fills result.FilesWritten only
        from its own write_file - so without this ledger a file changed here would
        never reach the Activity card, the pending change set, or Undo.
    .PARAMETER path
        The file to edit, relative to the Workspace Folder.
    .PARAMETER oldText
        The exact text to replace. Must occur exactly once.
    .PARAMETER newText
        The replacement text. May be empty to delete the matched span.
    .OUTPUTS
        System.String

        A compact JSON envelope: path, replaced, occurrences, lineStart, lineEnd;
        or error and message when nothing was changed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$oldText,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$newText
    )

    $fail = {
        param([string]$Code, [string]$Message)
        @{ error = $Code; message = $Message; path = [string]$path } | ConvertTo-Json -Compress -Depth 4
    }

    $countOccurrence = {
        param([string]$Haystack, [string]$Needle)
        if ([string]::IsNullOrEmpty($Needle)) { return 0 }
        $found = 0
        $at = 0
        while ($true) {
            $at = $Haystack.IndexOf($Needle, $at, [System.StringComparison]::Ordinal)
            if ($at -lt 0) { break }
            $found++
            $at += $Needle.Length
        }
        $found
    }

    $pathError = Get-DpSearchPatternError -Pattern $path -Name 'path'
    if ($pathError) { return (& $fail 'invalid-path' $pathError) }
    if ($path -match '[*?]') {
        return (& $fail 'invalid-path' 'path must name one file, not a pattern. Use search_files to find the file first, then pass its exact path.')
    }
    if ([string]::IsNullOrEmpty($oldText)) {
        return (& $fail 'invalid-argument' 'oldText is required and must not be empty. Pass the exact text to replace, copied from the file.')
    }
    if ($oldText -ceq $newText) {
        return (& $fail 'invalid-argument' 'oldText and newText are identical, so there is nothing to change.')
    }

    $rootValue = ''
    $rootVariable = Get-Variable -Name 'DeskPilotWorkspaceRoot' -Scope Global -ErrorAction SilentlyContinue
    if ($rootVariable) { $rootValue = [string]$rootVariable.Value }

    $rootResolution = Resolve-DpWorkspaceRoot -Root $rootValue
    if (-not $rootResolution.ok) { return (& $fail $rootResolution.error $rootResolution.message) }
    $root = [string]$rootResolution.root

    $full = Resolve-DpWorkspacePath -Root $root -Path $path
    if (-not $full) {
        return (& $fail 'invalid-path' "path must stay inside the workspace folder; '$path' resolves outside it.")
    }
    if (-not [System.IO.File]::Exists($full)) {
        return (& $fail 'file-not-found' "No file at '$path' in the workspace folder. Use search_files to find it, or write_file to create it.")
    }
    if (Test-DpBinaryFile -Path $full) {
        return (& $fail 'binary-file' "'$path' is a binary file and cannot be edited as text.")
    }

    $bytes = $null
    try { $bytes = [System.IO.File]::ReadAllBytes($full) }
    catch {
        $readError = $_
        return (& $fail 'read-failed' "Could not read '$path': $($readError.Exception.Message)")
    }

    # UTF-32LE starts with the UTF-16LE mark, so the wider BOM has to be tested
    # first. Every decoder throws on invalid bytes: a file this cannot round-trip
    # losslessly must be refused, not silently rewritten with U+FFFD.
    $bomLength = 0
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bomLength = 3
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $bomLength = 4
        $encoding = [System.Text.UTF32Encoding]::new($false, $false, $true)
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $bomLength = 4
        $encoding = [System.Text.UTF32Encoding]::new($true, $false, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $bomLength = 2
        $encoding = [System.Text.UnicodeEncoding]::new($false, $false, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $bomLength = 2
        $encoding = [System.Text.UnicodeEncoding]::new($true, $false, $true)
    }

    $content = $null
    try { $content = $encoding.GetString($bytes, $bomLength, $bytes.Length - $bomLength) }
    catch {
        $decodeError = $_
        return (& $fail 'encoding-unsupported' "'$path' is not valid text in its declared encoding, so it cannot be edited without corrupting it: $($decodeError.Exception.Message)")
    }

    $crlfCount = & $countOccurrence $content "`r`n"
    $lfCount = (& $countOccurrence $content "`n") - $crlfCount
    $eol = if ($crlfCount -gt 0 -and $crlfCount -ge $lfCount) { "`r`n" } else { "`n" }
    $toFileEol = {
        param([string]$Text)
        $flat = $Text -replace "`r`n", "`n"
        if ($eol -eq "`r`n") { $flat -replace "`n", "`r`n" } else { $flat }
    }

    # As sent first: a model that copied the file's own CRLF verbatim must not have
    # its match rewritten. Only when that finds nothing is the line ending suspect.
    $needle = $oldText
    $occurrences = & $countOccurrence $content $needle
    if ($occurrences -eq 0) {
        $converted = & $toFileEol $oldText
        if ($converted -cne $oldText) {
            $convertedCount = & $countOccurrence $content $converted
            if ($convertedCount -gt 0) {
                $needle = $converted
                $occurrences = $convertedCount
            }
        }
    }

    if ($occurrences -eq 0) {
        return (& $fail 'text-not-found' "oldText does not appear in '$path', so nothing was changed. Read the file and copy the text verbatim, including indentation.")
    }
    if ($occurrences -gt 1) {
        return (& $fail 'ambiguous-match' "oldText appears $occurrences times in '$path', so nothing was changed. Include more surrounding lines until it is unique.")
    }

    $index = $content.IndexOf($needle, [System.StringComparison]::Ordinal)
    $updated = $content.Substring(0, $index) + (& $toFileEol $newText) + $content.Substring($index + $needle.Length)

    $lineStart = 1 + (& $countOccurrence $content.Substring(0, $index) "`n")
    $lineEnd = $lineStart + (& $countOccurrence $needle "`n")

    try {
        $body = $encoding.GetBytes($updated)
        $output = [byte[]]::new($bomLength + $body.Length)
        if ($bomLength -gt 0) { [System.Array]::Copy($bytes, 0, $output, 0, $bomLength) }
        [System.Array]::Copy($body, 0, $output, $bomLength, $body.Length)
        [System.IO.File]::WriteAllBytes($full, $output)
    }
    catch {
        $writeError = $_
        return (& $fail 'write-failed' "Could not write '$path': $($writeError.Exception.Message)")
    }

    $relative = $full.Substring($root.TrimEnd('/', '\').Length).TrimStart('/', '\') -replace '\\', '/'
    $ledger = Get-Variable -Name 'DeskPilotFilesEdited' -Scope Global -ErrorAction SilentlyContinue
    if ($ledger -and $ledger.Value -is [System.Collections.IList]) { [void]$ledger.Value.Add($relative) }

    [ordered]@{
        path        = $relative
        replaced    = $true
        occurrences = 1
        lineStart   = $lineStart
        lineEnd     = $lineEnd
    } | ConvertTo-Json -Compress -Depth 4
}
