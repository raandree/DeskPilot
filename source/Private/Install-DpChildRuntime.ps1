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
    .PARAMETER EngineModulePath
        Explicit built Engine manifest. When supplied, also freezes the Engine
        bytes and prepares a separate credentialless image. Never installs an
        Engine or enables child execution.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$DataDirectory,
        [string]$EngineModulePath
    )

    if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw 'Child execution requires Windows and PowerShell 7.4 or newer.'
    }
    $source = Get-DpChildAssetRoot
    if ($EngineModulePath) {
        $manifest = Get-Item -LiteralPath $EngineModulePath -ErrorAction Stop
        if ($manifest.Name -cne 'ShellPilot.psd1' -or $manifest.PSIsContainer) {
            throw 'Complete child preparation requires the built ShellPilot manifest.'
        }
        $engineSourceRoot = $manifest.DirectoryName
        $parseErrors = @()
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $engineSourceRoot 'ShellPilot.psm1'), [ref]$null, [ref]$parseErrors)
        $invoke = $moduleAst.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Invoke-Shp' }, $true)
        $parameters = @($invoke.Body.ParamBlock.Parameters.Name.VariablePath.UserPath)
        if ($parseErrors.Count -gt 0 -or 'RequestTransport' -cnotin $parameters -or 'RequestBudgetMode' -cnotin $parameters -or
            -not $moduleAst.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Get-ShpChildProviderUsage' }, $true)) {
            throw 'The selected Engine does not support the complete child transport contract.'
        }
    }
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
    if ($EngineModulePath) {
        $engineRoot = Join-Path $staging 'engine'
        $null = New-Item -Path (Join-Path $engineRoot 'data') -ItemType Directory -Force
        $engineHashes = @{}
        foreach ($relative in @('ShellPilot.psd1', 'ShellPilot.psm1', 'ShellPilot.Format.ps1xml', 'data/PriceTable.psd1')) {
            $original = Get-Item -LiteralPath (Join-Path $engineSourceRoot $relative) -ErrorAction Stop
            if ($original.PSIsContainer -or $original.Length -gt 16777216 -or ($original.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'The selected Engine contains unsupported or oversized runtime data.'
            }
            for ($ancestor = $original.Directory; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
                if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Engine preparation refuses linked runtime paths.' }
            }
            $expectedHash = (Get-FileHash -LiteralPath $original.FullName).Hash
            $destination = Join-Path $engineRoot $relative
            Copy-Item -LiteralPath $original.FullName -Destination $destination
            $copiedHash = (Get-FileHash -LiteralPath $destination).Hash
            if ($copiedHash -cne $expectedHash) { throw 'The Engine changed during preparation.' }
            $engineHashes[$relative] = $copiedHash
        }
        foreach ($name in @('Engine.Dockerfile', 'Start-DpChildEngine.ps1', 'Start-DpChildProvider.ps1', 'ChildTools.ps1')) {
            Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $staging $name)
        }
        $engineTag = 'deskpilot-child-engine:' + [guid]::NewGuid().ToString('N')
        $null = Invoke-DpDockerControl -Argument @('build', '--network', 'none', '--progress', 'plain', '--file', (Join-Path $staging 'Engine.Dockerfile'), '--build-arg', "BASE_IMAGE=$($base.tag)", '--tag', $engineTag, $staging) -TimeoutSeconds 300
        $engineImage = Invoke-DpDockerControl -Argument @('image', 'inspect', $engineTag, '--format', '{{.Id}}')
        if ($engineImage -notmatch '^sha256:[a-f0-9]{64}$') { throw 'The prepared Engine image has no immutable identity.' }
        $runtime.schemaVersion = 2
        $runtime.engineImage = $engineImage
        $runtime.engineTag = $engineTag
        $runtime.engineManifest = Join-Path $engineRoot 'ShellPilot.psd1'
        $runtime.engineSourceManifest = $manifest.FullName
        $runtime.engineHashes = $engineHashes
        $runtime.providerEntry = Join-Path $staging 'Start-DpChildProvider.ps1'
    }
    $runtime | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runtimeRoot 'runtime.json') -Encoding utf8
    $runtime
}
