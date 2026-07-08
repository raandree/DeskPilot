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

    # Runtime dependency: the Engine. Declared here so the build/test session can
    # import the built DeskPilot module (whose manifest requires ShellPilot >= 0.2.0),
    # pinned to the minimum tested Gallery version.
    ShellPilot            = '0.2.0'
}
