function Test-DpGitBranchName {
    <#
    .SYNOPSIS
        Validates a proposed Branch name before it reaches git.
    .DESCRIPTION
        Applies git's own ref-name rules locally so the Branch Wizard can explain a
        bad name in plain language instead of surfacing a git fatal. Rejects empty
        names, whitespace, control characters, the characters git forbids in a ref,
        the '..' and '@{' sequences, a leading dash (which git would read as an
        option), and the usual leading/trailing separator cases. Never throws.
    .PARAMETER Name
        The proposed Branch name.
    .OUTPUTS
        System.Collections.Hashtable with ok, name and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Name
    )

    $trimmed = if ($null -eq $Name) { '' } else { $Name.Trim() }
    $result = @{ ok = $false; name = $trimmed; error = $null }

    if ([string]::IsNullOrWhiteSpace($trimmed)) { $result.error = 'A branch name is required.'; return $result }
    if ($trimmed.Length -gt 200) { $result.error = 'That branch name is too long (200 characters at most).'; return $result }
    if ($trimmed.StartsWith('-')) { $result.error = 'A branch name cannot start with a dash.'; return $result }
    if ($trimmed.StartsWith('/') -or $trimmed.EndsWith('/')) { $result.error = 'A branch name cannot start or end with a slash.'; return $result }
    if ($trimmed.StartsWith('.') -or $trimmed.EndsWith('.')) { $result.error = 'A branch name cannot start or end with a dot.'; return $result }
    if ($trimmed.EndsWith('.lock')) { $result.error = 'A branch name cannot end with ".lock".'; return $result }
    if ($trimmed.Contains('..')) { $result.error = 'A branch name cannot contain "..".'; return $result }
    if ($trimmed.Contains('//')) { $result.error = 'A branch name cannot contain "//".'; return $result }
    if ($trimmed.Contains('@{')) { $result.error = 'A branch name cannot contain "@{".'; return $result }
    if ($trimmed -eq '@') { $result.error = 'A branch name cannot be just "@".'; return $result }

    $forbidden = '~^:?*[\'
    foreach ($char in $trimmed.ToCharArray()) {
        if ([char]::IsControl($char)) { $result.error = 'A branch name cannot contain control characters.'; return $result }
        if ([char]::IsWhiteSpace($char)) { $result.error = 'A branch name cannot contain spaces. Use a dash or a slash instead.'; return $result }
        if ($forbidden.IndexOf($char) -ge 0) { $result.error = 'A branch name cannot contain any of ~ ^ : ? * [ \'; return $result }
    }

    $result.ok = $true
    $result
}
