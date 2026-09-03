function Test-DpCommandSafe {
    <#
    .SYNOPSIS
        Decides whether a Terminal command may run without asking.
    .DESCRIPTION
        The classifier per-call approval rests on, so it is written to be wrong
        only in the safe direction: anything it does not positively recognise
        returns false and prompts.

        Shell metacharacters disqualify a command outright, before any matching.
        `git status; rm -rf /` begins with an allow-listed prefix, and without
        this check the allow-list would authorise everything after the semicolon.
        The same reasoning covers pipes, redirection, command substitution,
        background operators, newlines and cmd-style variable expansion - each is
        a way to smuggle a second command past a check aimed at the first.

        This function never reads Settings. The caller supplies the list, so the
        classifier stays pure and the widening decision stays where policy lives.
    .PARAMETER Command
        The command line the Model proposes.
    .PARAMETER SafeCommand
        The allow-list entries, each with command and match (exact or prefix).
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Command,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SafeCommand
    )

    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    # A command long enough to hide something in is not a routine read.
    if ($Command.Length -gt 500) { return $false }

    # Any of these can turn one allow-listed command into two commands.
    if ($Command -match '[;&|<>`\r\n]' -or $Command -match '\$\(' -or $Command -match '\$\{' -or $Command -match '%\w+%') {
        return $false
    }

    $normalized = ($Command -replace '\s+', ' ').Trim()

    foreach ($entry in @($SafeCommand)) {
        if (-not $entry) { continue }
        $pattern = [string](Get-DpPropertyValue -InputObject $entry -Name @('command') -Default '')
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $pattern = ($pattern -replace '\s+', ' ').Trim()
        $mode = [string](Get-DpPropertyValue -InputObject $entry -Name @('match') -Default 'exact')

        if ($mode -eq 'prefix') {
            # The boundary matters: 'ls' must not authorise 'lsof'.
            if ($normalized.Equals($pattern, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            if ($normalized.StartsWith($pattern + ' ', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            continue
        }

        if ($normalized.Equals($pattern, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    $false
}
