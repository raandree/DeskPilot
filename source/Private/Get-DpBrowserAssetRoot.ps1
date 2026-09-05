function Get-DpBrowserAssetRoot {
    <#
    .SYNOPSIS
        Resolves the folder holding the browser supervisor and its manifest.
    .DESCRIPTION
        browser/ is bundled into the module by ModuleBuilder (build.yaml
        CopyPaths), exactly as web/ is, so for a Gallery install it sits beside
        DeskPilot.psm1. A source checkout and the test harness find it one level
        up from source/Private instead, and DESKPILOT_BROWSER_ROOT overrides both
        so the supervisor can be edited without a rebuild.

        This is the *asset* root - read-only source that ships with the module.
        The *runtime* root, where npm and the browser binaries are installed,
        is under the data directory instead, because a module folder may be
        read-only, shared between users, or replaced wholesale by an update.
    .OUTPUTS
        System.String, or $null when the assets cannot be found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:DESKPILOT_BROWSER_ROOT)) {
        if (Test-Path -LiteralPath $env:DESKPILOT_BROWSER_ROOT -PathType Container) {
            return (Resolve-Path -LiteralPath $env:DESKPILOT_BROWSER_ROOT).Path
        }
    }

    foreach ($candidate in @(
            (Join-Path $PSScriptRoot 'browser'),
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'browser')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $null
}
