function Get-DpSafeCommandList {
    <#
    .SYNOPSIS
        The shipped list of Terminal commands that run without asking.
    .DESCRIPTION
        The tier that decides whether per-call approval interrupts you. It is an
        **allow-list**, so it fails closed: a command nobody recognised prompts.
        A deny-list would have been the opposite - wrong forever about everything
        it had not heard of, and evaded by `rm -r -f`, an alias or a wrapper.

        Two match modes, because one is not enough:

        - `exact` - the command must be exactly this. Used where a trailing
          argument changes what the command does. `git branch` lists; `git branch
          -D main` destroys.
        - `prefix` - trailing arguments are allowed. Used only where every
          argument the subcommand accepts is still a read.

        Nothing here writes, deletes, installs, pushes, or executes a script that
        could. `npm test` and `dotnet run` are deliberately absent: they run
        arbitrary code the repository happens to contain, which is precisely the
        thing approval exists to look at.

        Entries are reviewed additions, not a convenience list. A wrong entry is a
        permanent hole with no second line of defence.
    .OUTPUTS
        System.Collections.Hashtable[] with command and match.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()

    @(
        # Git, read-only subcommands.
        @{ command = 'git status'; match = 'prefix' }
        @{ command = 'git log'; match = 'prefix' }
        @{ command = 'git diff'; match = 'prefix' }
        @{ command = 'git show'; match = 'prefix' }
        @{ command = 'git rev-parse'; match = 'prefix' }
        @{ command = 'git ls-files'; match = 'prefix' }
        @{ command = 'git remote -v'; match = 'exact' }
        # Lists branches; any trailing argument can delete or rename one.
        @{ command = 'git branch'; match = 'exact' }

        # PowerShell readers. Get-* is not blanket-allowed: Get-Credential and
        # Get-Content on a secret are still reads, but they are reads of things
        # worth naming individually.
        @{ command = 'Get-ChildItem'; match = 'prefix' }
        @{ command = 'Get-Content'; match = 'prefix' }
        @{ command = 'Get-Location'; match = 'prefix' }
        @{ command = 'Get-Command'; match = 'prefix' }
        @{ command = 'Get-Module'; match = 'prefix' }
        @{ command = 'Get-Process'; match = 'prefix' }
        @{ command = 'Test-Path'; match = 'prefix' }
        @{ command = 'Resolve-Path'; match = 'prefix' }
        @{ command = 'Select-String'; match = 'prefix' }
        @{ command = 'Measure-Object'; match = 'prefix' }

        # Shell readers.
        @{ command = 'pwd'; match = 'exact' }
        @{ command = 'ls'; match = 'prefix' }
        @{ command = 'dir'; match = 'prefix' }
        @{ command = 'cat'; match = 'prefix' }
        @{ command = 'head'; match = 'prefix' }
        @{ command = 'tail'; match = 'prefix' }
        @{ command = 'wc'; match = 'prefix' }

        # Version probes.
        @{ command = 'node --version'; match = 'exact' }
        @{ command = 'npm --version'; match = 'exact' }
        @{ command = 'dotnet --version'; match = 'exact' }
        @{ command = 'python --version'; match = 'exact' }
        @{ command = 'pwsh --version'; match = 'exact' }
        @{ command = 'git --version'; match = 'exact' }
    )
}
