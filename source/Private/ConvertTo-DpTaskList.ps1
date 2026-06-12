function ConvertTo-DpTaskList {
    <#
    .SYNOPSIS
        Normalises a raw Task List into trusted, well-formed Tasks.
    .DESCRIPTION
        Defensive boundary normaliser for the in-Turn Task List. The Engine's
        ConvertTo-ShpTodoList already enforces the same invariants on the Engine
        side, but a Task List reaches DeskPilot either inside a ShpProgress
        Information record (Kind 'TodoList') or on the result's TodoList member,
        and those records can in principle arrive from any code path. This
        re-validates the input so the rest of DeskPilot only ever sees one
        canonical shape, regardless of whether the raw items are PSCustomObjects
        or hashtables and regardless of PowerShell-version JSON shaping.

        Invariants enforced (mirroring the Engine):
        - status is one of not-started, in-progress or completed; any other value
          (or none) becomes not-started.
        - At most one Task may be in-progress: the first in-progress Task wins and
          every later in-progress Task is demoted to not-started.
        - title is trimmed and must be non-empty; a Task whose title is empty or
          whitespace is dropped. A title longer than 200 characters is truncated.
        - id is kept when it is a positive integer; otherwise it is assigned
          sequentially (1-based) by emitted position.
        - Input order is preserved.

        The function is pure and has no side effects, and never throws on a
        malformed item: bad rows are simply dropped.
    .PARAMETER InputObject
        The raw Task List: an array (or single item) of objects/hashtables each
        carrying id, title and status. $null or an empty array yields an empty
        array.
    .OUTPUTS
        System.Object[]

        An ordered array of hashtables, each with id (int), title (string) and
        status (string) keys.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Returns a single array of normalised Task hashtables via the unary comma operator; PSScriptAnalyzer cannot statically verify the declared object[] output type.')]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject
    )

    $maxTitleLength = 200
    $validStatuses = @('not-started', 'in-progress', 'completed')

    # Reads a member by name from either a hashtable/IDictionary (key access) or a
    # PSCustomObject (property access). Returns $null when absent so StrictMode
    # never throws on a missing member of an arbitrary input shape.
    $readMember = {
        param($Item, [string]$Name)
        if ($null -eq $Item) { return $null }
        if ($Item -is [System.Collections.IDictionary]) {
            if ($Item.Contains($Name)) { return $Item[$Name] }
            return $null
        }
        $prop = $Item.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        $null
    }

    $normalised = [System.Collections.Generic.List[object]]::new()
    $seenInProgress = $false
    $emitted = 0

    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }

        # Title: trim, drop when empty/whitespace, cap the length.
        $title = [string](& $readMember $item 'title')
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $title = $title.Trim()
        if ($title.Length -gt $maxTitleLength) { $title = $title.Substring(0, $maxTitleLength) }

        # Status: coerce to the known set, then allow only one in-progress.
        $status = ([string](& $readMember $item 'status')).Trim().ToLowerInvariant()
        if ($validStatuses -notcontains $status) { $status = 'not-started' }
        if ($status -eq 'in-progress') {
            if ($seenInProgress) { $status = 'not-started' }
            else { $seenInProgress = $true }
        }

        $emitted++

        # Id: keep a positive integer, otherwise assign by emitted position.
        $id = $emitted
        $rawId = & $readMember $item 'id'
        if ($null -ne $rawId) {
            $parsedId = 0
            if ([int]::TryParse([string]$rawId, [ref]$parsedId) -and $parsedId -gt 0) {
                $id = $parsedId
            }
        }

        $null = $normalised.Add(@{
                id     = $id
                title  = $title
                status = $status
            })
    }

    , $normalised.ToArray()
}
