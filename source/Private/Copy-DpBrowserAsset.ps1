function Copy-DpBrowserAsset {
    <#
    .SYNOPSIS
        Copies the shipped supervisor sources into the runtime directory.
    .DESCRIPTION
        Node resolves an import by walking up from the importing file, so the
        supervisor has to sit beside the node_modules it needs. node_modules
        lives in the data directory, and the supervisor ships in the module, so
        the two are brought together here.

        Called on every install and every session start rather than once, so a
        module update cannot leave an old supervisor driving a new policy. The
        files are a few kilobytes; the alternative is a staleness bug that only
        appears after an upgrade.

        Only the two known sources are copied. Mirroring the whole folder would
        carry node_modules and any lock file along with it.
    .PARAMETER AssetRoot
        The module's browser/ folder.
    .PARAMETER RuntimeRoot
        The runtime directory under the data folder.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AssetRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RuntimeRoot
    )

    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $RuntimeRoot -Force -ErrorAction Stop | Out-Null
    }

    foreach ($name in @('package.json', 'policy.mjs', 'supervisor.mjs')) {
        $source = Join-Path $AssetRoot $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $RuntimeRoot $name) -Force -ErrorAction Stop
        }
    }
}
