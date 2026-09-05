function Test-DpBrowserResourceAllowed {
    <#
    .SYNOPSIS
        The conformance oracle for the supervisor's sub-resource rule. NOT an
        enforcement point.
    .DESCRIPTION
        Enforcement happens in the supervisor's request interceptor, which is the
        only place a sub-resource request is visible; PowerShell never sees one.
        This function exists so the shared corpus can hold both implementations
        to the same answers, and it has no runtime caller by design. The synopsis
        says so explicitly because this repository has a recorded history of
        controls that were asserted in a docstring and absent from the code, and
        a function named Test-...Allowed reads like a gate.

        Navigation is the Model's choice; sub-resources are the page's. That
        asymmetry is the whole rule, because the two parties know different
        things: the Model holds the conversation, the Workspace Folder path and
        prior Turn content, and the page holds nothing it did not already have.

        So an off-origin image leaks nothing, while an off-origin navigation can
        carry the Model's context out in a query string. Blocking every
        third-party resource would break ordinary sites and buy no security;
        blocking the active ones buys all of it.

        What stays blocked off-origin, each for its own reason:

        - **script** rewrites the page after a screenshot was approved, so "what
          you saw is what happened" stops holding, and it makes injection
          dynamic rather than something a single read can characterise.
        - **xhr, fetch, websocket, eventsource** are channels that outlive the
          Tool call and never appear in the navigation record, which would void
          the Activity trail rather than merely add to it.
        - **document** off-origin is a navigation wearing a sub-resource's
          clothes, and belongs on the approval path instead.
        - **anything unrecognised**, because a resource type this function has
          not heard of is one it cannot reason about.

        The decision delegates to Resolve-DpBrowserUrlDecision rather than
        re-deriving scope, so the two can never disagree about what is in scope
        or about which URLs are refused outright.
    .PARAMETER Url
        The resource URL the page requested.
    .PARAMETER ResourceType
        Playwright's resource type for the request.
    .PARAMETER Scope
        Host entries currently in scope.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Url,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Scope
    )

    $passive = @('image', 'stylesheet', 'font', 'media')

    $decision = Resolve-DpBrowserUrlDecision -Url $Url -Scope $Scope
    switch ($decision.decision) {
        'allow' { return $true }
        'deny' { return $false }
    }

    # Off-scope: passive only, and an unknown type is not passive.
    $passive -contains ([string]$ResourceType).Trim().ToLowerInvariant()
}
