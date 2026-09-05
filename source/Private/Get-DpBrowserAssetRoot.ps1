function Get-DpBrowserAssetRoot {
    <#
    .SYNOPSIS
        Resolves the folder holding the browser supervisor and its manifest.
    .DESCRIPTION
        browser/ is bundled into the module by ModuleBuilder (build.yaml
        CopyPaths), exactly as web/ is, so for a Gallery install it sits beside
        DeskPilot.psm1. A source checkout and the test harness find it one level
        up from source/Private instead.

        DESKPILOT_BROWSER_TEST_ROOT overrides both. It carries the TEST_ prefix
        deliberately: overriding this folder replaces policy.mjs and
        supervisor.mjs, which is the entire in-path boundary plus arbitrary Node
        code running as the user - strictly more powerful than the TLS and
        argument hooks, so it is held to the same guard test, the same ready-line
        flag and the same warning rather than being the one nobody thought about.

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

    $override = [System.Environment]::GetEnvironmentVariable('DESKPILOT_BROWSER_TEST_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override -PathType Container) {
            return (Resolve-Path -LiteralPath $override).Path
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
