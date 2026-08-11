function Get-DpSearchPatternError {
    <#
    .SYNOPSIS
        Rejects a search pattern that would point outside the Workspace Folder.
    .DESCRIPTION
        A search Tool the model can aim at C:\Users is a data-exfiltration path
        wearing a search Tool's name, so a pattern is only ever a relative path
        inside the Workspace Folder. Anything that even asks to leave - an
        absolute or drive-qualified path, a UNC share, a home-relative path, or a
        `..` segment - is refused here by shape, before it can reach the file
        system and before any resolution can make it look harmless.

        This is the lexical half of the guard; Get-DpSearchCandidate confines
        every resolved candidate as well, so a link that escapes is caught even
        when the pattern that found it was innocent.
    .PARAMETER Pattern
        The glob supplied by the model.
    .PARAMETER Name
        The parameter name to quote back in the message, so the model is told
        which of its arguments to fix.
    .OUTPUTS
        System.String

        An empty string when the pattern is acceptable, otherwise the message to
        return to the model.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Pattern,

        [string]$Name = 'pattern'
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return "$Name is required and must not be empty."
    }

    $normalized = ($Pattern -replace '\\', '/').Trim()

    if ($normalized.StartsWith('~')) {
        return "$Name must be relative to the workspace folder; a home-relative path such as '$Pattern' is not searchable."
    }
    if ($normalized.StartsWith('//')) {
        return "$Name must be relative to the workspace folder; a network path such as '$Pattern' is not searchable."
    }
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or [System.IO.Path]::IsPathRooted($Pattern)) {
        return "$Name must be relative to the workspace folder; the absolute path '$Pattern' is outside it. Search is confined to the selected Project."
    }
    if (@($normalized -split '/') -contains '..') {
        return "$Name must stay inside the workspace folder; '..' is not allowed in '$Pattern'. Search is confined to the selected Project."
    }

    ''
}
