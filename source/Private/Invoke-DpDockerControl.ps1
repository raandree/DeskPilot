function Invoke-DpDockerControl {
    <#
    .SYNOPSIS
        Runs a bounded Docker control operation against the local Linux daemon.
    .PARAMETER Argument
        Separate arguments, never shell text.
    .PARAMETER TimeoutSeconds
        Deadline for this control operation.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$Argument,
        [ValidateRange(1, 1200)][int]$TimeoutSeconds = 15
    )

    if (-not $IsWindows) { throw 'Isolated Terminal requires Docker Desktop on Windows.' }
    $docker = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Docker' 'Docker' 'resources' 'bin' 'docker.exe'
    if (-not (Test-Path -LiteralPath $docker -PathType Leaf)) { throw 'Docker Desktop is not installed.' }
    $start = [Diagnostics.ProcessStartInfo]::new($docker)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = Split-Path -Parent $docker
    $start.Environment.Clear()
    foreach ($name in @('SystemRoot', 'TEMP', 'TMP', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'ProgramData', 'ProgramFiles')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $start.Environment[$name] = $value }
    }
    $start.Environment['PATH'] = Split-Path -Parent $docker
    $start.ArgumentList.Add('--host')
    $start.ArgumentList.Add('npipe:////./pipe/dockerDesktopLinuxEngine')
    foreach ($value in $Argument) { $start.ArgumentList.Add($value) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $process.StandardInput.Close()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw 'Docker control operation timed out.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($outputTask, $errorTask), 5000)) { throw 'Docker control output did not close.' }
        if ($process.ExitCode -ne 0) { throw "Docker control operation failed: $($errorTask.Result)" }
        $outputTask.Result.Trim()
    }
    finally { $process.Dispose() }
}
