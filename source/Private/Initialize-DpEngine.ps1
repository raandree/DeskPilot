function Initialize-DpEngine {
    <#
    .SYNOPSIS
        Creates the Engine Runspace and imports the Engine (ShellPilot) into it.
    .DESCRIPTION
        Resolves the Engine module via Resolve-DpEngineModule (an explicit path,
        an already-installed module, or a fresh PowerShell Gallery install into
        the CurrentUser scope, prerelease allowed), opens a dedicated long-lived
        runspace, imports the module, and reports whether the import succeeded
        along with the cached token path used for auth detection.
    .PARAMETER EngineModulePath
        Optional explicit path to a ShellPilot manifest or module folder. When
        supplied, no Gallery install is attempted.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$EngineModulePath
    )

    $resolution = Resolve-DpEngineModule -Path $EngineModulePath
    $resolved = $resolution.Path
    $importError = $resolution.Error
    $imported = $false

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()

    $importShell = [powershell]::Create()
    $importShell.Runspace = $runspace
    try {
        $importName = if ($resolved) { $resolved } else { 'ShellPilot' }
        $null = $importShell.AddCommand('Import-Module').AddParameter('Name', $importName).AddParameter('ErrorAction', 'Stop')
        $importShell.Invoke() | Out-Null
        if ($importShell.HadErrors) {
            $firstError = $importShell.Streams.Error | Select-Object -First 1
            if (-not $importError) {
                $importError = if ($firstError) { $firstError.ToString() } else { 'Engine import failed.' }
            }
        }
        else {
            $imported = $true
            $importError = $null
        }
    }
    catch {
        if (-not $importError) { $importError = "$_" }
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
        Installed   = $resolution.Installed
        ModulePath  = $resolved
        ImportError = $importError
        TokenPath   = $tokenPath
    }
}
