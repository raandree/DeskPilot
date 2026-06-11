function Initialize-DpEngine {
    <#
    .SYNOPSIS
        Creates the Engine Runspace and imports the Engine (ShellPilot) into it.
    .DESCRIPTION
        Resolves the Engine module (from an explicit path, a probed build output,
        or the module name), opens a dedicated long-lived runspace, imports the
        module, and reports whether the import succeeded along with the cached
        token path used for auth detection.
    .PARAMETER EngineModulePath
        Optional explicit path to a ShellPilot manifest or module folder.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$EngineModulePath
    )

    $resolved = $null
    $importError = $null
    $imported = $false

    if ($EngineModulePath) {
        if (Test-Path -LiteralPath $EngineModulePath) {
            $resolved = (Resolve-Path -LiteralPath $EngineModulePath).Path
        }
        else {
            $importError = "Engine module path not found: $EngineModulePath"
        }
    }
    else {
        $probes = @(
            (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules/ShellPilot')
            'V:/Git/ShellPilot/output/module/ShellPilot'
        )
        foreach ($root in $probes) {
            if (Test-Path -LiteralPath $root) {
                $manifest = Get-ChildItem -LiteralPath $root -Recurse -Filter 'ShellPilot.psd1' -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending | Select-Object -First 1
                if ($manifest) { $resolved = $manifest.FullName; break }
            }
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()

    $importShell = [powershell]::Create()
    $importShell.Runspace = $runspace
    try {
        if ($resolved) {
            $null = $importShell.AddCommand('Import-Module').AddParameter('Name', $resolved).AddParameter('ErrorAction', 'Stop')
        }
        else {
            $null = $importShell.AddCommand('Import-Module').AddParameter('Name', 'ShellPilot').AddParameter('ErrorAction', 'Stop')
        }
        $importShell.Invoke() | Out-Null
        if ($importShell.HadErrors) {
            $firstError = $importShell.Streams.Error | Select-Object -First 1
            $importError = if ($firstError) { $firstError.ToString() } else { 'Engine import failed.' }
        }
        else {
            $imported = $true
        }
    }
    catch {
        $importError = "$_"
    }
    finally {
        $importShell.Dispose()
    }

    $tokenPath = if ($env:USERPROFILE) {
        Join-Path $env:USERPROFILE '.copilot-demo-token'
    }
    else {
        Join-Path $HOME '.copilot-demo-token'
    }

    @{
        Runspace    = $runspace
        Imported    = $imported
        ModulePath  = $resolved
        ImportError = $importError
        TokenPath   = $tokenPath
    }
}
