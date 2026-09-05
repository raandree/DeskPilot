function New-DpIsolatedTerminalSession {
    <#
    .SYNOPSIS
        Creates a Turn-scoped isolated Terminal controller.
    .DESCRIPTION
        Uses the installed Docker Desktop Linux daemon and a bundled image pin.
        No missing dependency is downloaded and no Local fallback is selected.
    .PARAMETER Context
        Trusted Turn context, including the Project and Terminal execution policy.
    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][hashtable]$Context)

    if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'Isolated Terminal execution requires Windows and PowerShell 7.4 or newer.'
    }
    $docker = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Docker' 'Docker' 'resources' 'bin' 'docker.exe'
    if (-not (Test-Path -LiteralPath $docker -PathType Leaf)) { throw 'Docker Desktop is not installed. Local execution was not selected.' }
    $root = Get-DpIsolationAssetRoot
    $manifest = Get-Content -LiteralPath (Join-Path $root 'runtime.json') -Raw | ConvertFrom-Json -ErrorAction Stop
    $dataDirectory = [string](Get-DpPropertyValue -InputObject $Context -Name 'dataDirectory' -Default (Get-DpDataDir))
    $recordPath = Join-Path $dataDirectory 'isolation' 'runtime.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw 'Prepare the Terminal runtime from Diagnostics before selecting Isolated.' }
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($record.image -notmatch '^sha256:[a-f0-9]{64}$' -or $record.powerShellVersion -ne $manifest.powerShellVersion) { throw 'The Terminal runtime record is incompatible.' }
    foreach ($name in @('Dockerfile', 'Start-DpProxy.ps1', 'runtime.json')) {
        if ($record.hashes[$name] -ne (Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash) {
            throw 'The Terminal runtime must be prepared again for this DeskPilot build.'
        }
    }
    if (-not ('DeskPilot.Isolation.TerminalSession' -as [type])) {
        Add-Type -Path (Join-Path $root 'TerminalSession.cs') -ErrorAction Stop
    }
    $policy = ConvertTo-DpTerminalExecution -InputObject $Context.terminalExecution
    $arguments = @($docker, [string]$Context.workingDirectory, $dataDirectory, [string]$record.image,
        [string]$manifest.powerShellVersion, ($policy | ConvertTo-Json -Depth 6 -Compress))
    New-Object -TypeName 'DeskPilot.Isolation.TerminalSession' -ArgumentList $arguments
}
