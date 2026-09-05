function Start-DpBrowserSession {
    <#
    .SYNOPSIS
        Starts the supervised browser process for one run.
    .DESCRIPTION
        The browser lives in a child process, never in the Host Server. That is
        what makes Stop able to kill a whole tree, keeps a crashed page from
        taking DeskPilot with it, and keeps browser work off the single Engine
        Runspace everything else already queues behind.

        Scope is pushed once, here, from PowerShell. The supervisor exposes no
        command that widens it from page content, and stdin is its only input
        channel, so there is no path from a page back up to its own policy.

        The environment is narrowed rather than inherited wholesale. A browser
        started with the user's full environment would carry tokens and proxy
        credentials into a process whose whole purpose is to render text written
        by someone else.
    .PARAMETER Scope
        Host entries the run may reach without asking.
    .PARAMETER RuntimeRoot
        Where the runtime is installed. Defaults to the data directory.
    .PARAMETER StartTimeoutSeconds
        How long to wait for the supervisor's ready line.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Scope,

        [string]$RuntimeRoot,

        [ValidateRange(5, 300)]
        [int]$StartTimeoutSeconds = 60,

        # Downloads are a per-Project capability, so the browser is told whether
        # it may accept one at all. Off means Chromium refuses them outright
        # rather than DeskPilot cancelling them afterwards.
        [bool]$AllowDownload = $false,

        [string]$DownloadRoot,

        # The supervisor to run. Present so the protocol can be exercised against
        # a stand-in that speaks it without Playwright installed.
        [string]$SupervisorPath
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser'
    }

    $node = Get-DpNodeCommand
    if (-not $node) { throw 'Node.js is not installed, so the browser cannot start.' }

    if ([string]::IsNullOrWhiteSpace($SupervisorPath)) {
        $assets = Get-DpBrowserAssetRoot
        if (-not $assets) { throw 'The DeskPilot browser files are missing from the module.' }
        Copy-DpBrowserAsset -AssetRoot $assets -RuntimeRoot $RuntimeRoot
        $SupervisorPath = Join-Path $RuntimeRoot 'supervisor.mjs'
    }
    if (-not (Test-Path -LiteralPath $SupervisorPath -PathType Leaf)) {
        throw "The browser supervisor was not found at '$SupervisorPath'."
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $node.path
    $psi.ArgumentList.Add($SupervisorPath)
    $psi.WorkingDirectory = Split-Path -Parent $SupervisorPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Without these .NET falls back to the console code page, which on a Windows
    # machine is typically an OEM one. The card would then show 'Straße', the
    # fingerprint would bind 'Straße', and the supervisor would type 'Stra?e' -
    # the action performed would not be the action approved, silently, for every
    # non-ASCII value.
    $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.CreateNoWindow = $true

    # Deliberately not the caller's environment. Only what the child needs.
    foreach ($name in @('PATH', 'Path', 'SystemRoot', 'windir', 'TEMP', 'TMP', 'HOME', 'USERPROFILE', 'LOCALAPPDATA')) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if ($value) { $psi.Environment[$name] = $value }
    }
    # The hostile-site harness needs a real https origin on a real hostname,
    # because the policy correctly refuses plain http, IP literals and
    # single-label hosts. Its hooks are forwarded by prefix rather than named
    # here, and DeskPilot never assigns one - they can only arrive from the
    # environment the Host Server was started in, which no page and no model can
    # reach. An active hook is reported in the ready line so it cannot be silent.
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if ([string]$entry.Key -like 'DESKPILOT_BROWSER_TEST_*') { $psi.Environment[[string]$entry.Key] = [string]$entry.Value }
    }
    $psi.Environment['PLAYWRIGHT_BROWSERS_PATH'] = Join-Path $RuntimeRoot 'browsers'
    $psi.Environment['NODE_ENV'] = 'production'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'The browser supervisor did not start.' }

    $session = @{
        process     = $process
        nextId      = 1
        faulted     = $false
        scope       = @()
        events      = [System.Collections.Generic.List[object]]::new()
        runtimeRoot = $RuntimeRoot
    }

    $ready = Read-DpBrowserLine -Session $session -TimeoutSeconds $StartTimeoutSeconds
    if ($null -eq $ready -or $ready.event -ne 'ready') {
        Stop-DpBrowserSession -Session $session
        throw 'The browser supervisor started but did not report ready.'
    }
    $session.limits = $ready.limits
    # The asset-root hook is checked here rather than in the supervisor, because
    # by the time the supervisor runs it *is* whatever that folder contained.
    $session.testHooks = [bool]$ready.testHooks -or
        -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable('DESKPILOT_BROWSER_TEST_ROOT'))
    if ($session.testHooks) {
        Write-Warning 'DeskPilot browser test hooks are set in the environment. Certificate checking, browser arguments or the supervisor itself are not the shipped ones.'
    }

    $applied = Invoke-DpBrowserRequest -Session $session -Command 'scope' -Payload @{ hosts = @($Scope) } -TimeoutSeconds 15
    if (-not $applied.ok) {
        Stop-DpBrowserSession -Session $session
        throw 'The browser supervisor refused the allowed-domain list, so no page was opened.'
    }
    $session.scope = @($applied.result.scope)

    $configured = Invoke-DpBrowserRequest -Session $session -Command 'configure' -TimeoutSeconds 15 -Payload @{
        allowDownload = $AllowDownload
        downloadRoot  = [string]$DownloadRoot
    }
    if (-not $configured.ok) {
        Stop-DpBrowserSession -Session $session
        throw 'The browser supervisor refused its capability configuration, so no page was opened.'
    }
    $session.allowDownload = [bool]$configured.result.allowDownload

    $session
}
