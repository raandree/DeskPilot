@{
    RootModule        = 'DeskPilot.psm1'
    ModuleVersion     = '0.0.1'
    GUID              = 'b8f3a2d1-7c4e-4a9b-9f1d-2e6c5a0b3d77'
    Author            = 'Raimund Andree'
    CompanyName       = 'Raimund Andree'
    Copyright         = '(c) Raimund Andree. MIT licensed.'
    Description       = 'DeskPilot is a local, desktop-style web UI that fronts the ShellPilot engine to give non-technical users the full GitHub Copilot agent toolset (browse, read/write files, run commands, skills, instructions) with visible permissions and honest cost - no terminal or IDE required. The web UI is bundled in the module and served on loopback; ShellPilot and a Copilot-enabled GitHub account are required.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Start-DeskPilot')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Copilot', 'GitHubCopilot', 'ShellPilot', 'Agent', 'AI', 'GUI', 'AgenticOperatingModel', 'PSEdition_Core', 'Windows', 'Linux', 'macOS')
            LicenseUri   = 'https://github.com/raandree/DeskPilot/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/raandree/DeskPilot'
            IconUri      = 'https://raw.githubusercontent.com/raandree/DeskPilot/main/source/web/assets/logo-mark.png'
            ReleaseNotes = 'See CHANGELOG.md and the GitHub releases at https://github.com/raandree/DeskPilot/releases for notable changes.'
            Prerelease   = ''
        }
    }
}
