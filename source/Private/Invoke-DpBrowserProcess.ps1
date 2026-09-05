function Invoke-DpBrowserProcess {
    <#
    .SYNOPSIS
        Runs one install-time process under a deadline and captures its output.
    .DESCRIPTION
        Used by the browser runtime install for npm and the Playwright CLI. Both
        can hang on a proxy, a stalled registry or an interrupted download, and a
        hang during a user-initiated install would look identical to a slow
        network forever. The deadline turns that into a reported failure.

        On a timeout the process tree is killed rather than orphaned. A half-run
        npm leaves a broken node_modules, which Get-DpBrowserRuntime then reports
        as not ready - the honest outcome, and the one that offers repair.

        Output is bounded. An installer that decides to print a progress bar a
        few hundred thousand times must not become the thing that exhausts
        memory.
    .PARAMETER FilePath
        The executable to run.
    .PARAMETER Arguments
        Arguments, passed as a list so nothing is re-parsed by a shell.
    .PARAMETER WorkingDirectory
        Where to run it.
    .PARAMETER TimeoutSeconds
        Wall-clock deadline.
    .PARAMETER Environment
        Extra environment variables for the child only.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkingDirectory,

        [ValidateRange(5, 3600)]
        [int]$TimeoutSeconds = 900,

        [hashtable]$Environment = @{}
    )

    $maxOutputChars = 200000

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($argument in @($Arguments)) { $psi.ArgumentList.Add([string]$argument) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($key in $Environment.Keys) { $psi.Environment[$key] = [string]$Environment[$key] }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            return @{ success = $false; exitCode = -1; output = "Could not start $FilePath." }
        }

        # Both streams are read concurrently as tasks. Reading one to the end
        # before the other deadlocks the moment the child fills the pipe it is
        # not being drained on, which npm reliably does.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { $null = $_ }
            return @{ success = $false; exitCode = -1; output = "Timed out after $TimeoutSeconds seconds." }
        }

        $text = ''
        foreach ($task in @($stdout, $stderr)) {
            try { $text += $task.GetAwaiter().GetResult() } catch { $null = $_ }
        }
        if ($text.Length -gt $maxOutputChars) {
            $text = $text.Substring(0, $maxOutputChars) + "`n...[truncated]"
        }

        @{ success = ($process.ExitCode -eq 0); exitCode = $process.ExitCode; output = $text }
    }
    finally {
        $process.Dispose()
    }
}
