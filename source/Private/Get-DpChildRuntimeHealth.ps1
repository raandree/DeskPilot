function Get-DpChildRuntimeHealth {
    <#
    .SYNOPSIS
        Reads the prepared backend and owned-resource health without mutation.
    .PARAMETER Runtime
        The immutable prepared image identities.
    .PARAMETER DataDirectory
        Installation-owned claims to check for unresolved cleanup.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Runtime,
        [Parameter(Mandatory)][string]$DataDirectory
    )
    $health = @{ ready = $false; checkedUtc = [datetime]::UtcNow.ToString('o'); toolImage = ''; engineImage = ''; cleanupClear = $false; code = 'runtime-unavailable' }
    try {
        if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') { return $health }
        foreach ($image in @($Runtime.image, $Runtime.engineImage)) {
            if ($image -cnotmatch '^sha256:[a-f0-9]{64}$') { return $health }
        }
        $info = Invoke-DpDockerControl -Argument @('info', '--format', '{{json .}}') -TimeoutSeconds 5 | ConvertFrom-Json -AsHashtable
        if ($info.OSType -cne 'linux' -or $info.CgroupVersion -ne '2' -or -not $info.MemoryLimit -or
            -not $info.CpuCfsQuota -or -not $info.PidsLimit) { return $health }
        $health.toolImage = Invoke-DpDockerControl -Argument @('image', 'inspect', $Runtime.image, '--format', '{{.Id}}') -TimeoutSeconds 5
        $health.engineImage = Invoke-DpDockerControl -Argument @('image', 'inspect', $Runtime.engineImage, '--format', '{{.Id}}') -TimeoutSeconds 5
        if ($health.toolImage -cne $Runtime.image -or $health.engineImage -cne $Runtime.engineImage) { return $health }
        $remaining = Invoke-DpDockerControl -Argument @('ps', '--all', '--filter', 'label=io.deskpilot.child=1', '--format', '{{.ID}}') -TimeoutSeconds 5
        if ($remaining) { $health.code = 'owned-resources-present'; return $health }
        $root = Join-Path $DataDirectory 'child-runs'
        if (Test-Path -LiteralPath $root) {
            $count = 0
            foreach ($directory in [IO.Directory]::EnumerateDirectories($root)) {
                if (++$count -gt 4096 -or ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint)) { return $health }
                $claim = Get-Item -LiteralPath (Join-Path $directory 'claim.json') -ErrorAction Stop
                if ($claim.Length -gt 4096 -or ($claim.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $health }
                $record = [IO.File]::ReadAllText($claim.FullName) | ConvertFrom-Json -AsHashtable
                if ($record.state -cne 'stopped' -or $record.cleanupSucceeded -isnot [bool] -or -not $record.cleanupSucceeded) {
                    $health.code = 'cleanup-unresolved'
                    return $health
                }
            }
        }
        $health.cleanupClear = $true
        $health.ready = $true
        $health.code = ''
    } catch { $health.ready = $false }
    $health
}
