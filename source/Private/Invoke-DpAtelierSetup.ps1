function Invoke-DpAtelierSetup {
    <#
    .SYNOPSIS
        Obtains the CopilotAtelier content and runs its Setup-CopilotSettings.ps1.
    .DESCRIPTION
        Orchestrates the opt-in CopilotAtelier setup. It downloads the repository
        content with Get-DpAtelierSource (unless an already-prepared -SourcePath
        is supplied), locates Setup-CopilotSettings.ps1, and - on Windows -
        launches it in a new, visible PowerShell console the user drives. Running
        it in a console the user controls is deliberate: the setup script has its
        own interactive safety prompts (choosing between multiple OneDrive
        accounts, and confirming before replacing a non-empty ~/.copilot folder),
        and DeskPilot must never answer those on the user's behalf.

        On a non-Windows host the script is not launched (it relies on Windows-only
        NTFS junctions and VS Code paths); the downloaded path is returned so the
        user can run or adapt it manually.

        The caller is responsible for obtaining explicit user consent before
        invoking this: it downloads and executes third-party code with the user's
        privileges. The function is designed never to throw.

        Returns a hashtable with Ok, Launched, Windows, SourcePath, ScriptPath,
        Message, Error and Code.
    .PARAMETER SourcePath
        A folder that already contains Setup-CopilotSettings.ps1. When omitted the
        content is downloaded with Get-DpAtelierSource.
    .PARAMETER Launcher
        A script block invoked with the setup script path to start it. Defaults to
        opening a new PowerShell console. Overridable for testing.
    .PARAMETER IsWindowsPlatform
        Whether the host is Windows. Defaults to the automatic $IsWindows.
        Overridable for testing.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$SourcePath,

        [scriptblock]$Launcher,

        [bool]$IsWindowsPlatform = [bool]$IsWindows
    )

    $result = @{
        Ok         = $false
        Launched   = $false
        Windows    = $IsWindowsPlatform
        SourcePath = $null
        ScriptPath = $null
        Message    = $null
        Error      = $null
        Code       = $null
    }

    # 1. Obtain the content unless a prepared source folder was supplied.
    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $source = Get-DpAtelierSource
        if (-not $source.Ok) {
            $result.Error = $source.Error
            $result.Code = 'download_failed'
            return $result
        }
        $SourcePath = $source.Path
    }
    $result.SourcePath = $SourcePath

    # 2. Locate the setup script.
    $scriptPath = Join-Path $SourcePath 'Setup-CopilotSettings.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        $result.Error = "The setup script was not found at '$scriptPath'."
        $result.Code = 'script_missing'
        return $result
    }
    $result.ScriptPath = $scriptPath

    # 3. Non-Windows: do not run (the script uses Windows-only junctions and VS
    #    Code paths). Hand back the path for a manual run.
    if (-not $IsWindowsPlatform) {
        $result.Ok = $true
        $result.Launched = $false
        $result.Message = "CopilotAtelier setup uses Windows-only NTFS junctions. The files were downloaded to '$SourcePath'; run Setup-CopilotSettings.ps1 there manually."
        return $result
    }

    # 4. Launch the script in a console the user drives, so its interactive
    #    prompts work. DeskPilot deliberately does not answer them.
    if (-not $Launcher) {
        $Launcher = {
            param([string]$Path)
            $dir = Split-Path -Parent $Path
            Start-Process -FilePath 'pwsh' -WorkingDirectory $dir -ArgumentList @(
                '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path
            )
        }
    }

    try {
        & $Launcher $scriptPath
        $result.Ok = $true
        $result.Launched = $true
        $result.Message = 'A PowerShell window opened to run the setup. Complete any prompts there, then refresh.'
        return $result
    }
    catch {
        $result.Error = "Could not start the setup script: $($_.Exception.Message)"
        $result.Code = 'launch_failed'
        return $result
    }
}
