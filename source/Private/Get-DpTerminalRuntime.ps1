function Get-DpTerminalRuntime {
    <#
    .SYNOPSIS
        Reports prepared Terminal runtime, daemon, image and cleanup health.
    .PARAMETER DataDirectory
        DeskPilot data directory containing the trusted runtime record.
    .PARAMETER Probe
        Also inspect the local Docker daemon and owned container state.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$DataDirectory = (Get-DpDataDir), [switch]$Probe)

    $result = @{
        ready = $false; state = 'unavailable'; image = ''; powerShellVersion = ''; dockerVersion = ''
        orphanCount = 0; issues = @(); checkedUtc = [datetime]::UtcNow.ToString('o')
    }
    try {
        if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') { throw 'Isolated Terminal requires Windows and PowerShell 7.4 or newer.' }
        $root = Get-DpIsolationAssetRoot
        $recordPath = Join-Path $DataDirectory 'isolation' 'runtime.json'
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw 'Prepare the Terminal runtime from Diagnostics.' }
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $manifest = Get-Content -LiteralPath (Join-Path $root 'runtime.json') -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($record.image -notmatch '^sha256:[a-f0-9]{64}$' -or $record.powerShellVersion -ne $manifest.powerShellVersion) { throw 'The Terminal runtime record is incompatible.' }
        foreach ($name in @('Dockerfile', 'Start-DpProxy.ps1', 'runtime.json')) {
            if ($record.hashes[$name] -ne (Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash) { throw 'Prepare the Terminal runtime again for this DeskPilot build.' }
        }
        $result.image = $record.image
        $result.powerShellVersion = $record.powerShellVersion
        if ($Probe) {
            $version = Invoke-DpDockerControl -Argument @('version', '--format', '{{json .Server}}') -TimeoutSeconds 3 | ConvertFrom-Json -ErrorAction Stop
            if ($version.Os -ne 'linux' -or $version.Arch -ne 'amd64') { throw 'Docker Desktop must use Linux amd64 containers.' }
            $result.dockerVersion = [string]$version.Version
            $identity = Invoke-DpDockerControl -Argument @('image', 'inspect', $record.image, '--format', '{{.Id}}') -TimeoutSeconds 3
            if ($identity -ne $record.image) { throw 'The prepared Terminal image is missing or changed.' }
            $owned = Invoke-DpDockerControl -Argument @('ps', '--all', '--filter', 'label=io.deskpilot.terminal=1', '--format', '{{.ID}}') -TimeoutSeconds 3
            $result.orphanCount = @($owned -split '\r?\n' | Where-Object { $_ }).Count
            if ($result.orphanCount -gt 0) { throw 'Owned Terminal containers remain. Stop active work or run Terminal cleanup before another Isolated Turn.' }
        }
        $result.ready = [bool]$Probe
        $result.state = if ($Probe) { 'healthy' } else { 'unavailable' }
        if (-not $Probe) { $result.issues = @('The runtime is prepared. Run the Terminal check before use.') }
    }
    catch { $result.issues = @($_.Exception.Message) }
    $result
}
