function Get-DpAtelierSource {
    <#
    .SYNOPSIS
        Downloads the CopilotAtelier repository content into a working folder.
    .DESCRIPTION
        Fetches the CopilotAtelier repository as a zip archive over HTTPS and
        extracts it into a folder literally named 'CopilotAtelier' under the
        working directory. Setup-CopilotSettings.ps1 derives its canonical target
        folder name from its own parent folder, so the fixed 'CopilotAtelier'
        name yields the expected '<OneDrive>/CopilotAtelier' layout. Any previous
        working copy is removed first so the content is always fresh.

        The source URL is fixed to the first-party repository and is never taken
        from user input, so there is no request-forgery surface. The function is
        designed never to throw: a failure is reported in the Error field.

        Returns a hashtable with Ok, Path (the folder that contains
        Setup-CopilotSettings.ps1) and Error.
    .PARAMETER WorkingDirectory
        The folder the repository is downloaded into. Defaults to
        '<data dir>/atelier'.
    .PARAMETER Branch
        The repository branch to download. Defaults to 'main'.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$WorkingDirectory,

        [string]$Branch = 'main'
    )

    $repoUrl = 'https://github.com/raandree/CopilotAtelier'
    $scriptName = 'Setup-CopilotSettings.ps1'

    try {
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $WorkingDirectory = Join-Path (Get-DpDataDir) 'atelier'
        }
        if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
            New-Item -ItemType Directory -Path $WorkingDirectory -Force -ErrorAction Stop | Out-Null
        }

        $target = Join-Path $WorkingDirectory 'CopilotAtelier'
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        }

        $zipPath = Join-Path $WorkingDirectory "CopilotAtelier-$Branch.zip"
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
        $extractDir = Join-Path $WorkingDirectory ('_extract-' + [guid]::NewGuid().ToString('N'))

        # Prefer TLS 1.2+ on older hosts; harmless on modern ones. The progress
        # bar makes Invoke-WebRequest extremely slow, so suppress it locally.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        catch { $null = $_ }

        $zipUrl = "$repoUrl/archive/refs/heads/$Branch.zip"
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -MaximumRedirection 5 -ErrorAction Stop
        }
        finally {
            $ProgressPreference = $previousProgress
        }

        New-Item -ItemType Directory -Path $extractDir -Force -ErrorAction Stop | Out-Null
        Microsoft.PowerShell.Archive\Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop

        # A GitHub source archive extracts to a single '<repo>-<branch>' folder;
        # rename it to the canonical 'CopilotAtelier' the setup script expects.
        $top = @(Get-ChildItem -LiteralPath $extractDir -Directory) | Select-Object -First 1
        if (-not $top) { throw 'The downloaded archive was empty.' }
        Move-Item -LiteralPath $top.FullName -Destination $target -Force -ErrorAction Stop

        # Best-effort cleanup of the intermediate artefacts.
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        $scriptPath = Join-Path $target $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            return @{ Ok = $false; Path = $null; Error = "The setup script '$scriptName' was not found in the downloaded content." }
        }

        return @{ Ok = $true; Path = $target; Error = $null }
    }
    catch {
        return @{ Ok = $false; Path = $null; Error = "Could not download CopilotAtelier: $($_.Exception.Message)" }
    }
}
