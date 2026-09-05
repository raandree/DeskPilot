function Install-DpBrowserRuntime {
    <#
    .SYNOPSIS
        Installs the pinned Playwright package and browser, on explicit consent.
    .DESCRIPTION
        This downloads and stores executable content, so it is never called on a
        Turn's behalf and never as a side effect of enabling a Permission. The
        caller is a user-initiated route, and the UI states what will be fetched
        and roughly how large it is before this runs. Silently acquiring an
        executable is the thing the security model forbids outright, and a
        browser engine is the largest possible example of it.

        Everything lands under the data directory, not the module folder: a
        Gallery install may be read-only, may be shared between users, and is
        replaced wholesale by an update, which would silently discard a browser
        the user consented to download.

        The supervisor sources are copied on every install and on every session
        start, so the runtime always executes the supervisor that shipped with
        the current module rather than one left behind by an earlier version.

        Failure is reported with the tool output attached and leaves the runtime
        not-ready. A partially installed runtime must never report as usable.
    .PARAMETER RuntimeRoot
        Where to install. Defaults to the DeskPilot data directory.
    .PARAMETER TimeoutSeconds
        Wall-clock limit for each of the two install steps.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([hashtable])]
    param(
        [string]$RuntimeRoot,

        [ValidateRange(30, 3600)]
        [int]$TimeoutSeconds = 900
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser'
    }

    $fail = {
        param([string]$Message, [string]$Log = '')
        @{ installed = $false; error = $Message; log = $Log; runtimeRoot = $RuntimeRoot }
    }

    $node = Get-DpNodeCommand
    if (-not $node) {
        return (& $fail 'Node.js is not installed. Install it from nodejs.org, then try again.')
    }

    $assets = Get-DpBrowserAssetRoot
    if (-not $assets) {
        return (& $fail 'The DeskPilot browser files are missing from the module. Reinstall DeskPilot.')
    }

    if (-not $PSCmdlet.ShouldProcess($RuntimeRoot, 'Download and install the Playwright package and its browser')) {
        return (& $fail 'Installation was not confirmed, so nothing was downloaded.')
    }

    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $RuntimeRoot -Force -ErrorAction Stop | Out-Null
    }

    Copy-DpBrowserAsset -AssetRoot $assets -RuntimeRoot $RuntimeRoot

    $npm = Get-Command -Name 'npm' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npm) {
        return (& $fail 'npm was not found beside Node.js, so the Playwright package cannot be installed.')
    }

    $browsersPath = Join-Path $RuntimeRoot 'browsers'
    $log = [System.Text.StringBuilder]::new()

    # --ignore-scripts: an npm lifecycle script is arbitrary code from a package,
    # and the browser download is invoked explicitly below instead. The pinned
    # version is already in the copied manifest, so nothing here resolves 'latest'.
    $install = Invoke-DpBrowserProcess -FilePath $npm.Source -Arguments @(
        'install', '--omit=dev', '--no-audit', '--no-fund', '--ignore-scripts'
    ) -WorkingDirectory $RuntimeRoot -TimeoutSeconds $TimeoutSeconds -Environment @{
        PLAYWRIGHT_BROWSERS_PATH = $browsersPath
    }
    [void]$log.AppendLine($install.output)
    if (-not $install.success) {
        return (& $fail 'The Playwright package could not be installed.' $log.ToString())
    }

    $cli = Join-Path $RuntimeRoot 'node_modules' 'playwright' 'cli.js'
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
        return (& $fail 'The Playwright package installed without its command line, so the browser cannot be downloaded.' $log.ToString())
    }

    # Chromium only. Downloading three engines to drive one workflow would be a
    # gigabyte the user did not ask for.
    $browser = Invoke-DpBrowserProcess -FilePath $node.path -Arguments @(
        $cli, 'install', 'chromium'
    ) -WorkingDirectory $RuntimeRoot -TimeoutSeconds $TimeoutSeconds -Environment @{
        PLAYWRIGHT_BROWSERS_PATH = $browsersPath
    }
    [void]$log.AppendLine($browser.output)
    if (-not $browser.success) {
        return (& $fail 'The browser could not be downloaded.' $log.ToString())
    }

    $runtime = Get-DpBrowserRuntime -RuntimeRoot $RuntimeRoot
    if (-not $runtime.ready) {
        return (& $fail ('The install finished but the runtime is still not usable: ' + ($runtime.issues -join ' ')) $log.ToString())
    }

    @{ installed = $true; error = $null; log = $log.ToString(); runtimeRoot = $RuntimeRoot; runtime = $runtime }
}
