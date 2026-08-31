function Get-DpExecutableExtension {
    <#
    .SYNOPSIS
        Returns the file extensions DeskPilot refuses to hand to the operating
        system's shell association.
    .DESCRIPTION
        Every extension a supported platform treats as directly executable or as
        input to a script host. The agent writes into the same Project folder the
        file tree lists, so opening one of these with its associated program is
        indistinguishable from running it - the refusal removes that whole class
        rather than trying to judge the file's content. All of them are still
        readable in DeskPilot's own viewer.

        Extensions are lowercase and include the leading dot.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    # Windows: PE images, installers, control-panel and console shells, script
    # hosts, registry and setup scripts, and shortcut formats that name a target.
    # POSIX/macOS: shells, interpreted scripts, bundles, installers and launchers.
    [string[]]@(
        '.app', '.appimage', '.application', '.appref-ms', '.bash', '.bat', '.cab', '.chm',
        '.cmd', '.com', '.command', '.cpl', '.deb', '.desktop', '.dll', '.dmg', '.exe',
        '.gadget', '.hta', '.inf', '.ins', '.inx', '.isu', '.jar', '.job', '.js', '.jse',
        '.ksh', '.lnk', '.msc', '.msi', '.msp', '.mst', '.msu', '.out', '.paf', '.pkg',
        '.pl', '.pif', '.ps1', '.ps1xml', '.ps2', '.psc1', '.psd1', '.psm1', '.py', '.pyc',
        '.pyw', '.rb', '.reg', '.rgs', '.rpm', '.run', '.scf', '.scpt', '.scr', '.sct',
        '.sh', '.shb', '.shs', '.so', '.u3p', '.url', '.vb', '.vbe', '.vbs', '.vbscript',
        '.workflow', '.ws', '.wsf', '.wsh', '.zsh'
    )
}
