function Start-DeskPilot {
    <#
    .SYNOPSIS
        Starts the DeskPilot Host Server and serves the web UI on loopback.
    .DESCRIPTION
        Initialises the Engine Runspace, builds the route table, opens a loopback
        TCP listener (no administrator rights or URL ACL required), prints the
        local URL with a per-launch session token, optionally opens the browser,
        and runs the request accept loop until the process is stopped.
    .PARAMETER Port
        The TCP port to listen on. 0 (default) picks a free port automatically.
    .PARAMETER EngineModulePath
        Optional explicit path to the Engine (ShellPilot) module.
    .PARAMETER DataDir
        Optional override for the per-user data directory where Conversations and
        the lifetime Usage counter are persisted. Defaults to a per-user location
        (see Get-DpDataDir).
    .PARAMETER NoBrowser
        Do not open the default browser on start.
    .EXAMPLE
        Start-DeskPilot

        Starts the Host Server, picks a free port, serves the bundled web UI,
        and opens the browser.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The launcher prints the local URL and status to the console for the user.')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-DeskPilot is an interactive launcher, not a state-changing cmdlet; ShouldProcess is not meaningful.')]
    param(
        [int]$Port = 0,

        [string]$EngineModulePath,

        [string]$DataDir,

        [switch]$NoBrowser
    )

    # Resolve the SPA asset root. web/ is bundled into the module by ModuleBuilder
    # (build.yaml CopyPaths), so for a Gallery install it sits next to this
    # module's DeskPilot.psm1 at $PSScriptRoot/web. There is no public -WebRoot
    # knob; a source checkout and the test harness point the server at source/web
    # via the DESKPILOT_WEB_ROOT environment variable so UI edits hot-reload
    # without a rebuild.
    $webRoot = if (-not [string]::IsNullOrWhiteSpace($env:DESKPILOT_WEB_ROOT)) {
        $env:DESKPILOT_WEB_ROOT
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath 'web'
    }

    # Fail fast, before binding the port, if the bundle is missing or incomplete
    # (corrupt package, antivirus quarantine, partial install).
    if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) {
        throw "DeskPilot web assets were not found at '$webRoot'. The module package may be incomplete - reinstall with: Install-Module DeskPilot -Force"
    }
    $webRootFull = (Resolve-Path -LiteralPath $webRoot).Path
    if (-not (Test-Path -LiteralPath (Join-Path -Path $webRootFull -ChildPath 'index.html') -PathType Leaf)) {
        throw "DeskPilot web assets are incomplete: 'index.html' is missing under '$webRootFull'. Reinstall with: Install-Module DeskPilot -Force"
    }

    Write-Host 'Starting DeskPilot...' -ForegroundColor Cyan
    $engine = Initialize-DpEngine -EngineModulePath $EngineModulePath

    $dataDirFull = if ($DataDir) {
        if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        (Resolve-Path -LiteralPath $DataDir).Path
    }
    else {
        Get-DpDataDir
    }

    $conversations = Import-DpConversationStore -Directory $dataDirFull
    $lifetimeUsage = Import-DpLifetimeUsage -Directory $dataDirFull
    $persistedSettings = Import-DpSettings -Directory $dataDirFull
    $memoryStore = Import-DpMemoryStore -Directory $dataDirFull

    # The running module's full version, including any prerelease label. Module.Version
    # is a [System.Version], which cannot hold a '-preview0004' suffix; that label lives
    # in PrivateData.PSData.Prerelease. Without recombining them a preview install reports
    # itself as the matching stable release and the update check never offers a newer
    # preview (see Get-DpModuleVersionString / Get-DpUpdateStatus).
    $runningModule = $MyInvocation.MyCommand.Module
    $runningVersion = '0.0.0'
    if ($runningModule) {
        $prereleaseLabel = ''
        if ($runningModule.PrivateData -is [hashtable] -and $runningModule.PrivateData.ContainsKey('PSData')) {
            $psData = $runningModule.PrivateData['PSData']
            if ($psData -is [hashtable] -and $psData.ContainsKey('Prerelease')) {
                $prereleaseLabel = [string]$psData['Prerelease']
            }
        }
        $runningVersion = Get-DpModuleVersionString -Version $runningModule.Version.ToString() -Prerelease $prereleaseLabel
    }

    $script:DeskPilot = @{
        Version         = $runningVersion
        Settings        = $persistedSettings
        Conversations   = $conversations
        Usage           = @{ promptTokens = 0; completionTokens = 0; totalTokens = 0; costUSD = 0.0; credits = 0.0; turns = 0; byModel = @{} }
        LifetimeUsage   = $lifetimeUsage
        # Persistent Agent Memory (durable notes about the user + environment),
        # injected into every Turn's system prompt and curated by the memory routes.
        Memory          = $memoryStore
        DataDir         = $dataDirFull
        Engine          = $engine
        WebRoot         = $webRootFull
        Token           = [guid]::NewGuid().ToString('N')
        TurnRunning     = $false
        CancelRequested = $false
        # The accept loop's TcpListener, set once it is started below. The Turn
        # loop (Invoke-DpTurn) reads it through Invoke-DpPendingRequest to service
        # a concurrent POST /stop while it holds this single accept thread.
        Listener        = $null
        # Model capability cache, populated by the /api/models route. Keyed lookups
        # (Get-DpModelReasoningEfforts) use it to send -ReasoningEffort only to a
        # Model that advertises support, so a global reasoning-effort Setting never
        # reaches a Model that rejects it (HTTP 400 invalid_reasoning_effort).
        Models          = @()
        DefaultModel    = $null
        # Update state. The Host Server polls the Gallery for a newer DeskPilot in a
        # background job (Update-DpUpdateCheckState) and caches the result here for
        # GET /api/update; the SPA surfaces it and drives the consent-gated install
        # (Invoke-DpSelfUpdate) via POST /api/update/install. UpdateJob is the
        # in-flight check job; LastUpdateCheckUtc paces the periodic poll.
        Update          = @{
            currentVersion     = $runningVersion
            latestStable       = $null
            latestPrerelease   = $null
            includePrereleases = [bool]$persistedSettings.updateIncludePrereleases
            updateAvailable    = $false
            targetVersion      = $null
            targetIsPrerelease = $false
            notice             = $null
            checkedUtc         = $null
            checking           = $false
            installing         = $false
            installResult      = $null
        }
        UpdateJob          = $null
        LastUpdateCheckUtc = $null
        # Set true by Restart-DpHost (after it spawns a fresh instance) so the accept
        # loop below breaks, the listener is released, and this process winds down -
        # the only safe way to apply a DeskPilot host update (the running module
        # cannot hot-swap its own executing code in-process).
        StopRequested      = $false
        Routes          = @(
            @{ Method = 'GET'; Pattern = '/api/health'; Name = 'health' }
            @{ Method = 'GET'; Pattern = '/api/auth/status'; Name = 'authStatus' }
            @{ Method = 'POST'; Pattern = '/api/auth/start'; Name = 'authStart' }
            @{ Method = 'GET'; Pattern = '/api/models'; Name = 'models' }
            @{ Method = 'GET'; Pattern = '/api/settings'; Name = 'getSettings' }
            @{ Method = 'PUT'; Pattern = '/api/settings'; Name = 'putSettings' }
            @{ Method = 'GET'; Pattern = '/api/settings/export'; Name = 'exportSettings' }
            @{ Method = 'POST'; Pattern = '/api/settings/import'; Name = 'importSettings' }
            @{ Method = 'GET'; Pattern = '/api/agents'; Name = 'agents' }
            @{ Method = 'GET'; Pattern = '/api/customizations'; Name = 'customizations' }
            @{ Method = 'POST'; Pattern = '/api/customizations'; Name = 'createCustomization' }
            @{ Method = 'GET'; Pattern = '/api/customizations/content'; Name = 'customizationContent' }
            @{ Method = 'PUT'; Pattern = '/api/customizations/content'; Name = 'saveCustomizationContent' }
            @{ Method = 'GET'; Pattern = '/api/fs/list'; Name = 'fsList' }
            @{ Method = 'GET'; Pattern = '/api/fs/tree'; Name = 'fsTree' }
            @{ Method = 'GET'; Pattern = '/api/fs/file'; Name = 'fsFile' }
            @{ Method = 'GET'; Pattern = '/api/fs/find'; Name = 'fsFind' }
            @{ Method = 'POST'; Pattern = '/api/fs/mkdir'; Name = 'fsMkdir' }
            @{ Method = 'GET'; Pattern = '/api/git/status'; Name = 'gitStatus' }
            @{ Method = 'POST'; Pattern = '/api/git/init'; Name = 'gitInit' }
            @{ Method = 'POST'; Pattern = '/api/git/checkout'; Name = 'gitCheckout' }
            @{ Method = 'GET'; Pattern = '/api/git/diff'; Name = 'gitDiff' }
            @{ Method = 'POST'; Pattern = '/api/git/restore'; Name = 'gitRestore' }
            @{ Method = 'GET'; Pattern = '/api/git/branches'; Name = 'gitBranches' }
            @{ Method = 'GET'; Pattern = '/api/git/merge/preview'; Name = 'gitMergePreview' }
            @{ Method = 'POST'; Pattern = '/api/git/merge'; Name = 'gitMerge' }
            @{ Method = 'POST'; Pattern = '/api/git/merge/plan'; Name = 'gitMergePlan' }
            @{ Method = 'POST'; Pattern = '/api/git/merge/apply'; Name = 'gitMergeApply' }
            @{ Method = 'POST'; Pattern = '/api/git/merge/abort'; Name = 'gitMergeAbort' }
            @{ Method = 'POST'; Pattern = '/api/git/merge/undo'; Name = 'gitMergeUndo' }
            @{ Method = 'POST'; Pattern = '/api/git/cleanup'; Name = 'gitCleanup' }
            @{ Method = 'GET'; Pattern = '/api/atelier/health'; Name = 'atelierHealth' }
            @{ Method = 'POST'; Pattern = '/api/atelier/setup'; Name = 'atelierSetup' }
            @{ Method = 'GET'; Pattern = '/api/usage'; Name = 'usage' }
            @{ Method = 'POST'; Pattern = '/api/usage/reset'; Name = 'resetUsage' }
            @{ Method = 'GET'; Pattern = '/api/update'; Name = 'getUpdate' }
            @{ Method = 'POST'; Pattern = '/api/update/check'; Name = 'checkUpdate' }
            @{ Method = 'POST'; Pattern = '/api/update/install'; Name = 'installUpdate' }
            @{ Method = 'POST'; Pattern = '/api/update/restart'; Name = 'restartUpdate' }
            @{ Method = 'GET'; Pattern = '/api/memory'; Name = 'getMemory' }
            @{ Method = 'PUT'; Pattern = '/api/memory'; Name = 'updateMemory' }
            @{ Method = 'POST'; Pattern = '/api/memory/learn'; Name = 'learnMemory' }
            @{ Method = 'GET'; Pattern = '/api/conversations'; Name = 'listConversations' }
            @{ Method = 'POST'; Pattern = '/api/conversations'; Name = 'createConversation' }
            @{ Method = 'GET'; Pattern = '/api/conversations/search'; Name = 'searchConversations' }
            @{ Method = 'POST'; Pattern = '/api/conversations/read-all'; Name = 'readAllConversations' }
            @{ Method = 'GET'; Pattern = '/api/conversations/{id}'; Name = 'getConversation' }
            @{ Method = 'PATCH'; Pattern = '/api/conversations/{id}'; Name = 'patchConversation' }
            @{ Method = 'DELETE'; Pattern = '/api/conversations/{id}'; Name = 'deleteConversation' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/messages'; Name = 'postMessage' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/regenerate'; Name = 'regenerateTurn' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/edit'; Name = 'editTurn' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/stop'; Name = 'stopTurn' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/title'; Name = 'titleConversation' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/duplicate'; Name = 'duplicateConversation' }
            @{ Method = 'POST'; Pattern = '/api/conversations/{id}/compact'; Name = 'compactConversation' }
            @{ Method = 'POST'; Pattern = '/api/uploads'; Name = 'uploads' }
        )
    }

    if ($engine.Installed) {
        Write-Host 'Engine downloaded from the PowerShell Gallery (CurrentUser scope).' -ForegroundColor Cyan
    }
    if ($engine.Imported) {
        Write-Host "Engine ready: $($engine.ModulePath)" -ForegroundColor Green
    }
    else {
        Write-Host "Engine not loaded: $($engine.ImportError)" -ForegroundColor Yellow
        Write-Host 'DeskPilot will still start; fix the Engine and reload the page.' -ForegroundColor Yellow
    }

    Write-Host "Data: $dataDirFull ($($conversations.Count) conversation(s) loaded)" -ForegroundColor DarkGray

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $script:DeskPilot.Listener = $listener
    $boundPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $url = "http://127.0.0.1:$boundPort/?t=$($script:DeskPilot.Token)"

    Write-Host ''
    Write-Host '  DeskPilot is running.' -ForegroundColor Green
    Write-Host "  Open: $url" -ForegroundColor White
    Write-Host '  Press Ctrl+C in this window to stop.' -ForegroundColor DarkGray
    Write-Host ''

    if (-not $NoBrowser) {
        try { Start-Process $url } catch { $null = $_ }
    }

    # Best-effort, fail-silent check for a newer Gallery release, surfaced only in
    # the web UI (GET /api/update), never printed to this console. It runs in a
    # background job so it never blocks serving; Update-DpUpdateCheckState kicks off
    # the first check now and, on idle accept-loop iterations below, reaps the
    # finished job and re-triggers the poll every updateCheckIntervalMinutes.
    try { Update-DpUpdateCheckState -Force } catch { $null = $_ }

    try {
        while ($true) {
            # A relaunch (Restart-DpHost) sets StopRequested after spawning a fresh
            # instance; break so the finally releases the listener and this process
            # ends, letting the new instance (with the updated modules) take over.
            if ($script:DeskPilot.StopRequested) { break }
            # AcceptTcpClient() blocks synchronously, and PowerShell can only act
            # on Ctrl+C (a pipeline stop) between statements - never while parked
            # inside a blocking .NET call. So poll the non-blocking Pending() and
            # yield through Start-Sleep when idle. Start-Sleep is a cmdlet and thus
            # a cancellation checkpoint (unlike [Threading.Thread]::Sleep, which is
            # itself a blocking call), so Ctrl+C is observed within one poll and
            # unwinds through the finally below that stops the listener.
            if (-not $listener.Pending()) {
                # Reap a finished update check and re-trigger it when due, without
                # ever blocking the accept loop (the Gallery call is off-thread).
                try { Update-DpUpdateCheckState } catch { $null = $_ }
                Start-Sleep -Milliseconds 50
                continue
            }
            $client = $listener.AcceptTcpClient()
            Invoke-DpClient -Client $client
        }
    }
    finally {
        $script:DeskPilot.Listener = $null
        if ($script:DeskPilot.UpdateJob) { $script:DeskPilot.UpdateJob | Remove-Job -Force -ErrorAction SilentlyContinue; $script:DeskPilot.UpdateJob = $null }
        try { $listener.Stop() } catch { $null = $_ }
        Write-Host 'DeskPilot stopped.' -ForegroundColor DarkGray
    }
}
