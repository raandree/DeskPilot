function Install-DpTerminalRuntime {
    <#
    .SYNOPSIS
        Explicitly prepares the pinned Terminal runtime and records provenance.
    .PARAMETER DataDirectory
        Trusted DeskPilot data directory for the runtime record.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$DataDirectory = (Get-DpDataDir))

    $root = Get-DpIsolationAssetRoot
    $manifest = Get-Content -LiteralPath (Join-Path $root 'runtime.json') -Raw | ConvertFrom-Json
    $runtimeRoot = Join-Path $DataDirectory 'isolation'
    $null = New-Item -Path $runtimeRoot -ItemType Directory -Force
    if ((Get-Item -LiteralPath $runtimeRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The Terminal runtime directory must not be a link.'
    }
    $tag = 'deskpilot-terminal:' + [guid]::NewGuid().ToString('N')
    $null = Invoke-DpDockerControl -Argument @('build', '--progress', 'plain', '--tag', $tag, $root) -TimeoutSeconds 1200
    $image = Invoke-DpDockerControl -Argument @('image', 'inspect', $tag, '--format', '{{.Id}}')
    if ($image -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Docker did not return an immutable runtime image identity.' }
    $version = Invoke-DpDockerControl -Argument @('run', '--rm', '--pull', 'never', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,nosuid,nodev,size=32m', $image, '-Command', '$PSVersionTable.PSVersion.ToString()')
    if ($version -ne $manifest.powerShellVersion) { throw 'The prepared runtime reports an unexpected PowerShell version.' }
    $hashes = @{}
    foreach ($name in @('Dockerfile', 'Start-DpProxy.ps1', 'runtime.json')) {
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash
    }
    $packages = Invoke-DpDockerControl -Argument @('run', '--rm', '--pull', 'never', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--entrypoint', '/bin/cat', $image, '/opt/deskpilot-packages.txt')
    $record = @{
        schemaVersion = 1
        image = $image
        tag = $tag
        powerShellVersion = $version
        baseImage = $manifest.baseImage
        archiveSha256 = $manifest.powerShellSha256
        hashes = $hashes
        packages = $packages
        createdUtc = [datetime]::UtcNow.ToString('o')
    }
    $temporary = Join-Path $runtimeRoot ('runtime-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination (Join-Path $runtimeRoot 'runtime.json') -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    $record
}
