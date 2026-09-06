function Install-DpChildRuntime {
    <#
    .SYNOPSIS
        Explicitly prepares the private child Tool runtime.
    .DESCRIPTION
        Reuses the pinned Terminal base preparation and compiles tracked child
        sources into a new immutable image. Preparation does not enable children
        or claim that the complete Engine execution profile is ready.
    .PARAMETER DataDirectory
        The installation-owned directory for preparation records.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$DataDirectory)

    if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'Child execution requires Windows and PowerShell 7.4 or newer.'
    }
    $source = Get-DpChildAssetRoot
    $runtimeRoot = Join-Path $DataDirectory 'child-runtime'
    $null = New-Item -Path $runtimeRoot -ItemType Directory -Force
    $base = Install-DpTerminalRuntime -DataDirectory (Join-Path $runtimeRoot 'base')
    $staging = Join-Path $runtimeRoot ('build-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $staging -ItemType Directory
    $assembly = Join-Path $staging 'ChildRuntime.dll'
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $staging
    $start.Environment.Clear()
    $start.Environment['SystemRoot'] = [Environment]::GetEnvironmentVariable('SystemRoot')
    $start.Environment['TEMP'] = $staging
    $start.Environment['TMP'] = $staging
    $start.Environment['USERPROFILE'] = $staging
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $source 'Build-DpChildRuntime.ps1'), '-SourceDirectory', $source, '-OutputAssembly', $assembly)) {
        $start.ArgumentList.Add($argument)
    }
    $compiler = [Diagnostics.Process]::Start($start)
    try {
        $compiler.StandardInput.Close()
        $output = $compiler.StandardOutput.ReadToEndAsync()
        $errors = $compiler.StandardError.ReadToEndAsync()
        if (-not $compiler.WaitForExit(60000)) {
            $compiler.Kill($true)
            throw 'Child runtime compilation exceeded its deadline.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($output, $errors), 5000) -or $compiler.ExitCode -ne 0) {
            throw 'Child runtime compilation failed in its isolated compiler process.'
        }
    }
    finally { $compiler.Dispose() }
    foreach ($name in @('Dockerfile', 'Start-DpChildSupervisor.ps1', 'Invoke-DpChildFile.ps1')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $staging $name)
    }
    $tag = 'deskpilot-child:' + [guid]::NewGuid().ToString('N')
    $null = Invoke-DpDockerControl -Argument @('build', '--network', 'none', '--progress', 'plain', '--build-arg', "BASE_IMAGE=$($base.tag)", '--tag', $tag, $staging) -TimeoutSeconds 300
    $image = Invoke-DpDockerControl -Argument @('image', 'inspect', $tag, '--format', '{{.Id}}')
    if ($image -notmatch '^sha256:[a-f0-9]{64}$') { throw 'The prepared child image has no immutable identity.' }
    $hashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $source -File) {
        $hashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $runtime = @{
        schemaVersion = 1
        image = $image
        tag = $tag
        baseImage = $base.image
        baseTag = $base.tag
        powerShellVersion = $base.powerShellVersion
        assembly = $assembly
        assemblySha256 = (Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash
        hashes = $hashes
        storagePrepared = $true
        ready = $false
        createdUtc = [datetime]::UtcNow.ToString('o')
    }
    $runtime | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runtimeRoot 'runtime.json') -Encoding utf8
    $runtime
}
