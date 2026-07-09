function Update-DpEngineModule {
    <#
    .SYNOPSIS
        Force-reloads the Engine (ShellPilot) in the live Engine Runspace.
    .DESCRIPTION
        After a self-update installs a newer ShellPilot into a new version-scoped
        folder, the long-lived Engine Runspace still has the old version imported.
        This re-imports ShellPilot with -Force in that same runspace so the next
        Turn uses the new Engine without restarting DeskPilot.

        This is safe because the Engine Runspace only ever runs Engine cmdlets
        (never DeskPilot's own functions), the OAuth token lives on disk (re-read
        on the next call), and DeskPilot passes the Model per Turn - so no critical
        module-scoped state is lost by the reload. It also re-probes the Engine's
        own default token path (which is version-dependent - ShellPilot has renamed
        it before) and refreshes the cached Engine module path.

        The caller must ensure no Turn is running (the runspace would be busy).
        Never throws; returns a status hashtable.
    .OUTPUTS
        System.Collections.Hashtable with keys Ok, Version, Error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reloads a module inside the in-process Engine Runspace and refreshes cached state; not a user-facing state change needing ShouldProcess.')]
    param()

    $result = @{ Ok = $false; Version = $null; Error = $null }

    $engine = $script:DeskPilot.Engine
    $runspace = if ($engine) { $engine.Runspace } else { $null }
    if (-not $runspace) {
        $result.Error = 'The Engine runspace is not initialised.'
        return $result
    }

    # Prefer the freshly installed module path, but fall back to importing by name
    # (which resolves the newest available version) if resolution is unavailable.
    $resolution = Resolve-DpEngineModule -SkipInstall
    $importName = if ($resolution.Path) { $resolution.Path } else { 'ShellPilot' }

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    try {
        $script = {
            param([string]$ImportName)
            Import-Module -Name $ImportName -Force -ErrorAction Stop
            $module = Get-Module -Name ShellPilot | Select-Object -First 1
            [pscustomobject]@{
                Version    = if ($module) { $module.Version.ToString() } else { $null }
                ModulePath = if ($module) { $module.Path } else { $null }
                TokenPath  = if ($module) { & $module { $script:DefaultTokenPath } } else { $null }
            }
        }
        $null = $shell.AddScript($script).AddArgument($importName)
        $out = $shell.Invoke()
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            $result.Error = if ($firstError) { $firstError.ToString() } else { 'Engine reload failed.' }
            return $result
        }
        $info = $out | Select-Object -First 1
        if ($info) {
            $result.Version = [string]$info.Version
            if ($info.ModulePath) { $engine.ModulePath = [string]$info.ModulePath }
            $tokenPath = [string]$info.TokenPath
            if (-not [string]::IsNullOrWhiteSpace($tokenPath)) { $engine.TokenPath = $tokenPath }
        }
        $engine.Imported = $true
        $result.Ok = $true
        return $result
    }
    catch {
        $result.Error = "$($_.Exception.Message)"
        return $result
    }
    finally {
        $shell.Dispose()
    }
}
