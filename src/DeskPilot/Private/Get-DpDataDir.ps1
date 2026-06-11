function Get-DpDataDir {
    <#
    .SYNOPSIS
        Resolves (and creates) the per-user DeskPilot data directory.
    .DESCRIPTION
        Returns the folder where DeskPilot persists Conversations and the
        lifetime Usage counter, outside the repository. Resolution order:
        $LOCALAPPDATA/DeskPilot (Windows), $XDG_DATA_HOME/DeskPilot, then
        ~/.local/share/DeskPilot. The directory is created if it does not exist.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
    elseif ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME }
    else { Join-Path $HOME '.local/share' }

    $dir = Join-Path $base 'DeskPilot'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $dir
}
