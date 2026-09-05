function Get-DpBrowserRuntime {
    <#
    .SYNOPSIS
        Reports whether contained browser automation can run, and what is missing.
    .DESCRIPTION
        Four things have to be true before a browser Turn may start: a supported
        Node, the pinned Playwright package installed, that install being the
        pinned version, and the matching browser binary present. This reports all
        four together, because a user told only the first missing piece fixes it
        and is told about the next one.

        It never reports ready optimistically. A probe that cannot answer counts
        as not ready, for the reason decision 0001 records at length: a boundary
        that reports as active without being active is worse than no boundary,
        because the interface then vouches for it.

        The version match is exact, not "at least". Playwright pins its browser
        build to the library version, so a newer library with an older browser is
        an unsupported pair; DeskPilot would be guessing about a combination
        nobody tested. On a mismatch the answer is repair, never a fallback to a
        browser found on the machine - that browser's profile belongs to the user
        and is exactly what the disposable profile exists to avoid touching.
    .PARAMETER RuntimeRoot
        Where the runtime is installed. Defaults to the DeskPilot data directory,
        never the module folder, which may be read-only or shared.
    .PARAMETER PinnedVersion
        The Playwright version this build of DeskPilot supports.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$RuntimeRoot,

        [string]$PinnedVersion
    )

    # Node 20 is Playwright's own floor; DeskPilot does not relax it.
    $minimumNodeMajor = 20

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser'
    }
    if ([string]::IsNullOrWhiteSpace($PinnedVersion)) {
        $PinnedVersion = Get-DpBrowserPinnedVersion
    }

    $issues = [System.Collections.Generic.List[string]]::new()

    $node = Get-DpNodeCommand
    $nodePresent = [bool]$node
    if (-not $nodePresent) {
        $issues.Add('Node.js is not installed, and DeskPilot does not install it for you.')
    }
    elseif ($node.major -lt $minimumNodeMajor) {
        $issues.Add("Node.js $($node.version) is older than the version $minimumNodeMajor that Playwright $PinnedVersion needs.")
    }

    $installedVersion = $null
    $manifest = Join-Path $RuntimeRoot 'node_modules' 'playwright' 'package.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try { $installedVersion = ([string]((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).version)).Trim() }
        catch { $installedVersion = $null }
    }

    $packageInstalled = -not [string]::IsNullOrWhiteSpace($installedVersion)
    if (-not $packageInstalled) {
        $issues.Add('The Playwright package is not installed in the DeskPilot data folder.')
    }

    $versionMatch = $packageInstalled -and $installedVersion -eq $PinnedVersion
    if ($packageInstalled -and -not $versionMatch) {
        $issues.Add("Playwright $installedVersion is installed, but this build of DeskPilot is tested against $PinnedVersion.")
    }

    $browserRoot = Join-Path $RuntimeRoot 'browsers'
    $browserInstalled = $false
    if (Test-Path -LiteralPath $browserRoot -PathType Container) {
        $browserInstalled = [bool](Get-ChildItem -LiteralPath $browserRoot -Directory -Filter 'chromium*' -ErrorAction SilentlyContinue |
                Select-Object -First 1)
    }
    if (-not $browserInstalled) {
        $issues.Add('The browser Playwright drives is not downloaded yet.')
    }

    $ready = $nodePresent -and ($nodePresent -and $node.major -ge $minimumNodeMajor) -and
    $packageInstalled -and $versionMatch -and $browserInstalled

    # A hook that weakens the boundary must reach a surface the user looks at. A
    # warning stream inside the Engine Runspace reaches nobody.
    $testHooks = @(
        foreach ($name in 'DESKPILOT_BROWSER_TEST_ROOT', 'DESKPILOT_BROWSER_TEST_ARGS', 'DESKPILOT_BROWSER_TEST_INSECURE') {
            if (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($name))) { $name }
        })
    if ($testHooks.Count -gt 0) {
        $issues.Add("Browser test hooks are set in the environment ($($testHooks -join ', ')). Certificate checking, browser arguments or the supervisor itself are not the shipped ones.")
    }

    $action = if ($ready) { '' }
    elseif (-not $nodePresent -or ($nodePresent -and $node.major -lt $minimumNodeMajor)) {
        "Install Node.js $minimumNodeMajor or newer from nodejs.org, then set up browser automation from Diagnostics."
    }
    else {
        'Set up browser automation from Diagnostics. DeskPilot will ask before it downloads anything.'
    }

    @{
        ready            = $ready
        nodePresent      = $nodePresent
        nodePath         = if ($node) { $node.path } else { $null }
        nodeVersion      = if ($node) { $node.version } else { $null }
        runtimeRoot      = $RuntimeRoot
        pinnedVersion    = $PinnedVersion
        installedVersion = $installedVersion
        packageInstalled = $packageInstalled
        versionMatch     = $versionMatch
        browserInstalled = $browserInstalled
        testHooks        = $testHooks
        issues           = $issues.ToArray()
        action           = $action
    }
}
