function Get-DpRouteMatch {
    <#
    .SYNOPSIS
        Matches an HTTP method and path against a route table.
    .DESCRIPTION
        Returns the first route whose method matches and whose pattern (with
        '{name}' placeholders) matches the path, together with the captured path
        parameters. Returns $null when nothing matches.
    .PARAMETER Method
        The HTTP method, for example 'GET'.
    .PARAMETER Path
        The request path, for example '/api/conversations/c_1'.
    .PARAMETER Route
        An array of route descriptors, each a hashtable with Method, Pattern and
        Handler keys.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object[]]$Route
    )

    foreach ($candidate in $Route) {
        if ($candidate.Method -ne $Method) { continue }
        # [regex]::Escape escapes '{' (to '\{') but leaves '}' literal, so the
        # placeholder pattern matches '\{name}' rather than '\{name\}'.
        $escaped = [regex]::Escape($candidate.Pattern)
        $regex = '^' + ($escaped -replace '\\\{(\w+)\}', '(?<$1>[^/]+)') + '/?$'
        $match = [regex]::Match($Path, $regex)
        if ($match.Success) {
            $routeParams = @{}
            foreach ($group in $match.Groups) {
                if ($group.Success -and $group.Name -notmatch '^\d+$') {
                    $routeParams[$group.Name] = [uri]::UnescapeDataString($group.Value)
                }
            }
            return @{ Route = $candidate; Params = $routeParams }
        }
    }
    $null
}
