function Invoke-DpGitCommand {
    <#
    .SYNOPSIS
        Runs a git command in a folder and captures its output and exit code.
    .DESCRIPTION
        Invokes `git -C <Path> <Arguments>` via System.Diagnostics.Process so the
        arguments are passed as a list (no shell, so no argument injection) and
        stdout/stderr/exit code are captured separately. Returns a hashtable with
        Ok (exit code 0), ExitCode, StdOut, StdErr. When git is not installed the
        result has Ok = $false, ExitCode = -1 and a StdErr explaining that.
    .PARAMETER Path
        The working directory for git (passed via -C).
    .PARAMETER Arguments
        The git arguments (for example @('status', '--porcelain')).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.ArgumentList.Add('-C')
    $psi.ArgumentList.Add($Path)
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add([string]$arg) }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        @{
            Ok       = ($proc.ExitCode -eq 0)
            ExitCode = $proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    }
    catch {
        @{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = "git is not available: $($_.Exception.Message)" }
    }
}
