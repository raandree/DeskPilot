function Invoke-DpSelfUpdate {
    <#
    .SYNOPSIS
        Installs the newest DeskPilot and ShellPilot from the PowerShell Gallery.
    .DESCRIPTION
        Performs the consent-gated self-update. It installs the newest DeskPilot
        and, so the Engine keeps pace, the newest ShellPilot into the CurrentUser
        scope. When -IncludePrerelease is set (because DeskPilot is being updated
        to a preview) prereleases are allowed for BOTH modules; otherwise both are
        pinned to stable. This is the single place the "a preview DeskPilot update
        also accepts a preview ShellPilot" rule lives.

        The installed versions land in new, version-scoped module folders, so the
        DeskPilot and ShellPilot copies the running Host Server and Engine Runspace
        already loaded are never touched; the update takes effect on the next
        DeskPilot launch. The function reports each module's outcome and never
        throws - a per-module install failure is captured and returned.

        The installer and version reader are injectable so the orchestration (which
        modules, and the prerelease flag per module) is unit-tested without a real
        Gallery install.
    .PARAMETER IncludePrerelease
        Allow prerelease (preview) versions for every module. Set when the DeskPilot
        update target is itself a prerelease.
    .PARAMETER ModuleName
        The modules to update, in order. Defaults to DeskPilot then ShellPilot.
        DeskPilot (the first) is the module whose failure fails the whole update.
    .PARAMETER Installer
        A script block invoked as { param($Name, $AllowPrerelease) } to install one
        module. Defaults to Install-Module into the CurrentUser scope. Overridable
        for testing.
    .PARAMETER VersionReader
        A script block invoked as { param($Name) } returning the newest installed
        version string for a module, for the result. Defaults to a Get-Module
        -ListAvailable lookup. Overridable for testing.
    .OUTPUTS
        System.Collections.Hashtable with keys Ok, IncludePrerelease, Modules, Error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch]$IncludePrerelease,

        [string[]]$ModuleName = @('DeskPilot', 'ShellPilot'),

        [scriptblock]$Installer,

        [scriptblock]$VersionReader
    )

    if (-not $Installer) {
        $Installer = {
            param([string]$Name, [bool]$AllowPrerelease)
            $installParameters = @{
                Name        = $Name
                Scope       = 'CurrentUser'
                Repository  = 'PSGallery'
                Force       = $true
                AllowClobber = $true
                ErrorAction = 'Stop'
            }
            if ($AllowPrerelease) { $installParameters['AllowPrerelease'] = $true }
            Install-Module @installParameters
        }
    }

    if (-not $VersionReader) {
        $VersionReader = {
            param([string]$Name)
            # Report the newest INSTALLED version including its prerelease label.
            # Module.Version (a [System.Version]) drops the label and cannot order
            # two prereleases sharing a base version, so compose the full SemVer
            # string (Get-DpModuleVersionString) and sort prerelease-aware.
            Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $label = ''
                    if ($_.PrivateData -is [hashtable] -and $_.PrivateData.ContainsKey('PSData')) {
                        $psData = $_.PrivateData['PSData']
                        if ($psData -is [hashtable] -and $psData.ContainsKey('Prerelease')) {
                            $label = [string]$psData['Prerelease']
                        }
                    }
                    Get-DpModuleVersionString -Version $_.Version.ToString() -Prerelease $label
                } |
                Sort-Object -Property { $sem = $null; $null = [System.Management.Automation.SemanticVersion]::TryParse($_, [ref] $sem); $sem } -Descending |
                Select-Object -First 1
        }
    }

    $result = @{
        Ok                = $true
        IncludePrerelease = [bool]$IncludePrerelease
        Modules           = @()
        Error             = $null
    }

    $allowPrerelease = [bool]$IncludePrerelease
    $first = $true
    foreach ($name in $ModuleName) {
        $moduleResult = @{ name = $name; version = $null; installed = $false; error = $null }
        try {
            & $Installer $name $allowPrerelease
            $moduleResult.installed = $true
            try { $moduleResult.version = [string](& $VersionReader $name) } catch { $moduleResult.version = $null }
        }
        catch {
            $moduleResult.error = "$($_.Exception.Message)"
            # The first module (DeskPilot) is the update itself; its failure fails
            # the whole operation. A later module (ShellPilot) failure is reported
            # but does not, on its own, mark the DeskPilot update as failed.
            if ($first) {
                $result.Ok = $false
                if (-not $result.Error) { $result.Error = "Could not update '$name': $($_.Exception.Message)" }
            }
            elseif (-not $result.Error) {
                $result.Error = "Updated DeskPilot, but could not update '$name': $($_.Exception.Message)"
            }
        }
        $result.Modules += $moduleResult
        $first = $false
    }

    $result
}
