function Get-DpBrowserPinnedVersion {
    <#
    .SYNOPSIS
        The Playwright version this build of DeskPilot is tested against.
    .DESCRIPTION
        Read from the shipped browser/package.json so the pin has one home and
        cannot drift between what npm installs and what DeskPilot checks for.

        Returns an empty string when the manifest is missing or unreadable, which
        Get-DpBrowserRuntime treats as not ready. Guessing a version here would
        let a damaged install report as healthy.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $root = Get-DpBrowserAssetRoot
    if (-not $root) { return '' }

    $manifest = Join-Path $root 'package.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return '' }

    try {
        $parsed = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        return ([string]$parsed.dependencies.playwright).Trim()
    }
    catch {
        return ''
    }
}
