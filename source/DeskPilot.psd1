@{
    RootModule        = 'DeskPilot.psm1'
    ModuleVersion     = '0.0.1'
    GUID              = 'b8f3a2d1-7c4e-4a9b-9f1d-2e6c5a0b3d77'
    Author            = 'DeskPilot contributors'
    CompanyName       = 'DeskPilot'
    Copyright         = '(c) DeskPilot contributors. MIT licensed.'
    Description       = 'DeskPilot Host Server: a local HTTP + SSE bridge that fronts the ShellPilot Engine with a modern deep-teal web UI for GitHub Copilot agents.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Start-DeskPilot')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Copilot', 'ShellPilot', 'Agent', 'GUI', 'AgenticOperatingModel')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/raandree/AgenticOperatingModel'
            ReleaseNotes = ''
            Prerelease   = ''
        }
    }
}
