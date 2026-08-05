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
    $userPromptBridge = Initialize-DpUserPromptBridge -Runspace $runspace

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

    # DeskPilot detects a completed sign-in by the presence of the Engine's
    # cached OAuth token file, so it must look at the exact path the Engine
    # writes. That default is NOT stable across Engine versions - ShellPilot
    # renamed it from '.copilot-demo-token' to '.shellpilot-token' - and a
    # hardcoded name silently drifts: the user completes the device flow, the
    # Engine writes the new file, DeskPilot checks the old name, finds nothing,
    # and reports "sign-in did not complete" on every attempt. So ask the
    # imported Engine for its own default instead. $script:DefaultTokenPath is
    # the Engine's single source of truth (every -TokenPath parameter defaults
    # to it); read it in the module's own scope. Fall back to a best-effort path
    # only when the probe is unavailable (Engine not imported, or a future
    # rename of that variable).
    $tokenPath = $null
    if ($imported) {
        $probeShell = [powershell]::Create()
        $probeShell.Runspace = $runspace
        try {
            $null = $probeShell.AddScript('$m = Get-Module -Name ShellPilot | Select-Object -First 1; if ($m) { & $m { $script:DefaultTokenPath } }')
            $probed = $probeShell.Invoke()
            if (-not $probeShell.HadErrors -and $probed.Count -gt 0) {
                $candidate = [string]($probed | Select-Object -First 1)
                if (-not [string]::IsNullOrWhiteSpace($candidate)) { $tokenPath = $candidate }
            }
        }
        catch { $null = $_ }
        finally { $probeShell.Dispose() }
    }

    if (-not $tokenPath) {
        # Prefer the current Engine token name; still recognise an existing
        # legacy token so a machine signed in with an older Engine keeps counting
        # as authenticated; otherwise default to the current name.
        $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
        $currentTokenName = Join-Path $userHome '.shellpilot-token'
        $legacyTokenName = Join-Path $userHome '.copilot-demo-token'
        $tokenPath = if (Test-Path -LiteralPath $currentTokenName) { $currentTokenName }
            elseif (Test-Path -LiteralPath $legacyTokenName) { $legacyTokenName }
            else { $currentTokenName }
    }

    @{
        Runspace         = $runspace
        Imported         = $imported
        Installed        = $resolution.Installed
        ModulePath       = $resolved
        ImportError      = $importError
        TokenPath        = $tokenPath
        UserPromptBridge = $userPromptBridge
    }
}
