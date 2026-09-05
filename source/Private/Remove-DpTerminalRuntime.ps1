function Remove-DpTerminalRuntime {
    <#
    .SYNOPSIS
        Removes only owned inactive Terminal containers and optional runtime data.
    .PARAMETER DataDirectory
        DeskPilot data directory containing the runtime record.
    .PARAMETER Uninstall
        Also remove this installation's runtime tag and provenance record.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$DataDirectory, [switch]$Uninstall)

    $listed = Invoke-DpDockerControl -Argument @('ps', '--all', '--filter', 'label=io.deskpilot.terminal=1', '--format', '{{json .}}')
    $removed = 0
    foreach ($line in @($listed -split '\r?\n' | Where-Object { $_ })) {
        $row = $line | ConvertFrom-Json -ErrorAction Stop
        if ($row.Names -notmatch '^deskpilot-terminal-[a-f0-9]{32}(-proxy)?$' -or $row.ID -notmatch '^[a-f0-9]{12,64}$') { continue }
        $owner = Invoke-DpDockerControl -Argument @('inspect', '--format', '{{index .Config.Labels "io.deskpilot.owner"}}', $row.ID)
        $ownerId = 0
        if (-not [int]::TryParse($owner, [ref]$ownerId)) { continue }
        if ($ownerId -ne $PID -and (Get-Process -Id $ownerId -ErrorAction SilentlyContinue)) { continue }
        if ($PSCmdlet.ShouldProcess($row.Names, 'Remove inactive owned Terminal container')) {
            $null = Invoke-DpDockerControl -Argument @('rm', '--force', $row.ID)
            $removed++
        }
    }
    if ($Uninstall) {
        $root = [IO.Path]::GetFullPath((Join-Path $DataDirectory 'isolation'))
        $ancestor = $root
        while ($ancestor) {
            if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Terminal runtime removal refuses linked data directories.'
            }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        $path = Join-Path $root 'runtime.json'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($record.tag -notmatch '^deskpilot-terminal:[a-f0-9]{32}$') { throw 'The runtime record does not identify an owned image tag.' }
            if ($PSCmdlet.ShouldProcess('DeskPilot Terminal runtime', 'Remove owned runtime tag and record')) {
                $null = Invoke-DpDockerControl -Argument @('image', 'rm', '--no-prune', $record.tag)
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        }
    }
    @{ removed = $removed; uninstalled = [bool]$Uninstall }
}
