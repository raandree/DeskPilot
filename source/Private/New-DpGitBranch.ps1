function New-DpGitBranch {
    <#
    .SYNOPSIS
        Creates a Branch (optionally switching to it) for the Branch Wizard.
    .DESCRIPTION
        Validates the proposed name, refuses a name that already exists, resolves
        the start point (an explicit ref, else the current HEAD), then creates the
        Branch and optionally checks it out. A repository with no commit yet has no
        HEAD to branch from, so the unborn case is created with `git checkout -b`,
        which git allows. Never throws: every failure is reported in 'error'.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Name
        The new Branch name.
    .PARAMETER From
        The start point (a Branch name or commit). Defaults to the current HEAD.
    .PARAMETER Checkout
        Switch to the new Branch after creating it.
    .OUTPUTS
        System.Collections.Hashtable with created, checkedOut, name, from and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$From,

        [switch]$Checkout
    )

    $result = @{ created = $false; checkedOut = $false; name = $null; from = $null; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $valid = Test-DpGitBranchName -Name $Name
    if (-not $valid.ok) { $result.error = $valid.error; return $result }
    $branchName = $valid.name
    $result.name = $branchName

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $exists = Invoke-DpGitCommand -Path $rootFull -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branchName")
    if ($exists.Ok) { $result.error = "A branch named '$branchName' already exists."; return $result }

    $startPoint = $null
    if (-not [string]::IsNullOrWhiteSpace($From)) {
        $verify = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', "$From^{commit}")
        if (-not $verify.Ok) { $result.error = "Unknown starting point '$From'."; return $result }
        $startPoint = $From
    }
    $result.from = if ($startPoint) { $startPoint } else { $status.branch }

    $hasHead = (Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')).Ok
    if (-not $hasHead) {
        # Unborn HEAD: there is nothing to branch from, but git can still start a
        # new branch here. Creating it always implies switching to it.
        $create = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', '-b', $branchName)
        if (-not $create.Ok) { $result.error = if ($create.StdErr) { $create.StdErr.Trim() } else { 'Could not create the branch.' }; return $result }
        $result.created = $true
        $result.checkedOut = $true
        return $result
    }

    $createArgs = @('branch', $branchName)
    if ($startPoint) { $createArgs += $startPoint }
    $create = Invoke-DpGitCommand -Path $rootFull -Arguments $createArgs
    if (-not $create.Ok) { $result.error = if ($create.StdErr) { $create.StdErr.Trim() } else { 'Could not create the branch.' }; return $result }
    $result.created = $true

    if ($Checkout) {
        $co = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', $branchName)
        if ($co.Ok) { $result.checkedOut = $true }
        else { $result.error = "The branch was created, but switching to it failed: $($co.StdErr.Trim())" }
    }

    $result
}
