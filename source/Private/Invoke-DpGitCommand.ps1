function Invoke-DpGitCommand {
    <#
    .SYNOPSIS
        Runs a git command in a folder and captures its output and exit code.
    .DESCRIPTION
        Invokes `git -C <Path> <Arguments>` via System.Diagnostics.Process so the
        arguments are passed as a list (no shell, so no argument injection) and
        stdout/stderr/exit code are captured separately. Returns a hashtable with
        Ok (exit code 0), ExitCode, StdOut, StdErr, TimedOut. When git is not
        installed the result has Ok = $false, ExitCode = -1 and a StdErr explaining
        that; a timeout yields ExitCode -2 and TimedOut = $true.

        The Host Server accepts on a single thread, so a git command that waits for
        input would freeze the whole UI. Four guards prevent that:

        - GIT_TERMINAL_PROMPT is disabled (a credential helper still works; only
          the blocking terminal prompt is refused).
        - stdin is redirected and closed immediately, so git and anything it
          spawns (ssh, a credential helper, a hook) reads EOF instead of waiting
          on the launcher console.
        - Every call has a timeout, after which the process tree is killed. The
          default covers local commands, which can still run repository hooks;
          networked calls pass a longer one.
        - Both output streams are read asynchronously and the read itself is
          bounded by the same deadline, because WaitForExit(int) does not drain
          them and a grandchild that inherited them can hold them open after git
          exits.

        GIT_LITERAL_PATHSPECS is set so a path is always a path: a file whose name
        begins with a pathspec-magic prefix (`:/`, `:(glob)`) cannot change the
        meaning of a command.
    .PARAMETER Path
        The working directory for git (passed via -C).
    .PARAMETER Arguments
        The git arguments (for example @('status', '--porcelain')).
    .PARAMETER TimeoutSeconds
        Kill git after this many seconds. 0 waits indefinitely and should only be
        used for a command that provably cannot block.
    .PARAMETER Environment
        Extra environment variables for this call only (for example a throwaway
        GIT_INDEX_FILE, so staging never touches the user's index).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [int]$TimeoutSeconds = 120,

        [hashtable]$Environment
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $psi.Environment['GIT_LITERAL_PATHSPECS'] = '1'
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }
    }
    $psi.ArgumentList.Add('-C')
    $psi.ArgumentList.Add($Path)
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add([string]$arg) }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.StandardInput.Close() } catch { $null = $_ }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if ($TimeoutSeconds -le 0) {
            $proc.WaitForExit()
            return @{
                Ok       = ($proc.ExitCode -eq 0)
                ExitCode = $proc.ExitCode
                StdOut   = $outTask.GetAwaiter().GetResult()
                StdErr   = $errTask.GetAwaiter().GetResult()
                TimedOut = $false
            }
        }

        $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
        $budgetMs = $TimeoutSeconds * 1000
        $timedOut = -not $proc.WaitForExit($budgetMs)
        if (-not $timedOut) {
            $remaining = [System.Math]::Max(0, $budgetMs - [int]$elapsed.ElapsedMilliseconds)
            $timedOut = -not [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), $remaining)
        }
        if ($timedOut) {
            try { $proc.Kill($true) } catch { $null = $_ }
            return @{ Ok = $false; ExitCode = -2; StdOut = ''; StdErr = "git did not finish within $TimeoutSeconds seconds and was stopped."; TimedOut = $true }
        }

        @{
            Ok       = ($proc.ExitCode -eq 0)
            ExitCode = $proc.ExitCode
            StdOut   = $outTask.Result
            StdErr   = $errTask.Result
            TimedOut = $false
        }
    }
    catch {
        @{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = "git is not available: $($_.Exception.Message)"; TimedOut = $false }
    }
    finally {
        if ($proc) { try { $proc.Dispose() } catch { $null = $_ } }
    }
}
