function Get-DpBrowserUserUrl {
    <#
    .SYNOPSIS
        The complete https:// addresses present in the user's own message.
    .DESCRIPTION
        One extractor, because two callers need the same answer and a second
        implementation is a boundary that drifts. Scope seeding asks which hosts
        the user's message named; the provenance test asks whether a particular
        address appears in it. When those two disagreed about what counts as a
        URL, one of them was wrong about what the user had authorised.

        The lookbehind is the point of the pattern. An unanchored search matched
        the scheme inside a longer token, so `xhttps://evil.example/a` and
        `ftphttps://weird.example/` authorised hosts the message never named
        (B3-2, 2026-09-05).

        Trailing sentence punctuation is stripped because it belongs to the
        sentence: `see https://example.com, then go` used to yield nothing at all,
        since the comma stayed on the host and the host then failed validation.

        Bounded on purpose - a very long message must not turn this into a scan.
    .PARAMETER Text
        The user's message.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $bounded = if ($Text.Length -gt 8000) { $Text.Substring(0, 8000) } else { $Text }

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($bounded, '(?<![A-Za-z0-9+.\-])https://[^\s"''<>)\]]+')) {
        $candidate = $match.Value -replace '[.,;:!?''"]+$', ''
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $found.Add($candidate) }
    }

    $found.ToArray()
}
