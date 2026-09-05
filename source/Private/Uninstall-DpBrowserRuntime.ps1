function Uninstall-DpBrowserRuntime {
    <#
    .SYNOPSIS
        Removes the browser runtime DeskPilot downloaded.
    .DESCRIPTION
        The other half of the install lifecycle, and the reason it exists is
        proportion: consenting to a few hundred megabytes of browser engine is
        much easier to do when taking it back is one button rather than a hunt
        through an application data folder.

        Leftover processes are closed first. Deleting the folder underneath a
        running Chromium leaves a half-removed install that reports as broken
        rather than absent, which is the worse of the two states because it
        offers repair for something the user asked to be rid of.

        Only the runtime folder is removed. Node is never touched: DeskPilot did
        not install it, and uninstalling something the user brought themselves
        would be the mirror image of installing something they did not ask for.
    .PARAMETER RuntimeRoot
        Where the runtime is installed. Defaults to the data directory.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([hashtable])]
    param(
        [string]$RuntimeRoot
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser'
    }

    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        return @{ removed = $false; error = $null; alreadyAbsent = $true; runtimeRoot = $RuntimeRoot }
    }

    if (-not $PSCmdlet.ShouldProcess($RuntimeRoot, 'Delete the downloaded browser runtime')) {
        return @{ removed = $false; error = 'Removal was not confirmed.'; alreadyAbsent = $false; runtimeRoot = $RuntimeRoot }
    }

    $cleanup = Remove-DpBrowserOrphan -RuntimeRoot $RuntimeRoot -Confirm:$false

    try {
        Remove-Item -LiteralPath $RuntimeRoot -Recurse -Force -ErrorAction Stop
    }
    catch {
        return @{
            removed       = $false
            error         = "The browser files could not all be deleted: $_"
            alreadyAbsent = $false
            runtimeRoot   = $RuntimeRoot
            closed        = [int]$cleanup.closed
        }
    }

    @{ removed = $true; error = $null; alreadyAbsent = $false; runtimeRoot = $RuntimeRoot; closed = [int]$cleanup.closed }
}
