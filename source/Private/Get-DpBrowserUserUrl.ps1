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

        A run of addresses with no space between them is **not** split. Splitting
        on every inner `https://` was tried, to make
        `https://a.example,https://b.example/` yield both, and it promoted a URL
        *inside* a URL into user-named scope: an OAuth link's
        `?redirect_uri=https://attacker.test/cb` seeded `attacker.test` and its
        whole subtree, chosen by whoever sent the user the link rather than by
        the user (B5-1, 2026-09-05). The unsplit behaviour drops the second
        address, which costs one approval card. That is the safe direction and
        the cosmetic case was never worth a scope-widening path.

        The length bound discards a match that reaches the cut. `Substring` slices
        mid-token, so a long pasted blob followed by the user's own address turned
        `news.bbc.co.uk/weather` into `news.bbc.co` - a live registrable domain
        the message never named, whose whole subtree scope then inherited, at a
        byte offset an attacker who supplied the pasted content chooses (B4-2,
        2026-09-05).
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

    $truncated = $Text.Length -gt 8000
    $bounded = if ($truncated) { $Text.Substring(0, 8000) } else { $Text }

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($bounded, '(?<![A-Za-z0-9+.\-])https://[^\s"''<>)\]]+')) {
        if ($truncated -and ($match.Index + $match.Length) -ge $bounded.Length) { continue }
        $candidate = $match.Value -replace '[.,;:!?''"`]+$', ''
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $found.Add($candidate) }
    }

    $found.ToArray()
}
