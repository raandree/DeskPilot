function Resolve-DpEngineModule {
    <#
    .SYNOPSIS
        Resolves the Engine (ShellPilot) module, installing it from the PowerShell
        Gallery into the CurrentUser scope when it is not already available.
    .DESCRIPTION
        Resolution order:
          1. An explicit module path (a .psd1 manifest or a module folder), when
             given. No Gallery install is attempted in this case.
          2. An already-available module on PSModulePath (any scope, newest
             version first) - this includes a prior CurrentUser-scope install.
          3. A fresh install from the PowerShell Gallery into the CurrentUser
             scope, then a re-resolve. Prerelease (preview) versions are allowed
             unless -StableOnly is set.

        Returns the resolved manifest/module path, whether an install was
        performed, and any error encountered. This function never imports the
        module; the caller (Initialize-DpEngine) imports it into the Engine
        Runspace.
    .PARAMETER Path
        Optional explicit path to a ShellPilot manifest (.psd1) or module folder.
        When supplied, no Gallery install is attempted.
    .PARAMETER Name
        The Engine module name as published on the PowerShell Gallery.
        Defaults to ShellPilot.
    .PARAMETER StableOnly
        Exclude prerelease (preview) versions when installing from the Gallery.
    .PARAMETER SkipInstall
        Do not install from the Gallery when the module is not already available;
        report it as missing instead.
    .OUTPUTS
        System.Collections.Hashtable with keys Path, Installed, and Error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path,

        [string]$Name = 'ShellPilot',

        [switch]$StableOnly,

        [switch]$SkipInstall
    )

    $result = @{ Path = $null; Installed = $false; Error = $null }

    if ($Path) {
        if (Test-Path -LiteralPath $Path) {
            $result.Path = (Resolve-Path -LiteralPath $Path).Path
        }
        else {
            $result.Error = "Engine module path not found: $Path"
        }
        return $result
    }

    $found = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($found) {
        $result.Path = $found.Path
        return $result
    }

    if ($SkipInstall) {
        $result.Error = "Engine '$Name' is not installed and installation was skipped."
        return $result
    }

    try {
        $installParameters = @{
            Name        = $Name
            Scope       = 'CurrentUser'
            Force       = $true
            ErrorAction = 'Stop'
        }
        if (-not $StableOnly) { $installParameters['AllowPrerelease'] = $true }
        Install-Module @installParameters
        $result.Installed = $true
    }
    catch {
        $result.Error = "Failed to install Engine '$Name' from the PowerShell Gallery into the CurrentUser scope: $_"
        return $result
    }

    $found = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($found) {
        $result.Path = $found.Path
    }
    else {
        $result.Error = "Engine '$Name' was installed but could not be located on PSModulePath."
    }

    return $result
}