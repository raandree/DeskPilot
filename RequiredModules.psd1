@{
    InvokeBuild           = 'latest'
    PSScriptAnalyzer      = 'latest'
    Pester                = 'latest'
    ModuleBuilder         = 'latest'
    Configuration         = 'latest'
    Metadata              = 'latest'
    ChangelogManagement   = 'latest'
    Sampler               = 'latest'
    'Sampler.GitHubTasks' = 'latest'
    MarkdownLinkCheck     = 'latest'

    # The Engine. DeskPilot resolves ShellPilot at runtime via
    # Resolve-DpEngineModule; it is intentionally NOT a hard manifest
    # RequiredModule, so importing DeskPilot never fails when ShellPilot is
    # absent. Declared here as 'latest' so the build/test session has it
    # available, matching the other dependencies.
    ShellPilot            = 'latest'
}
