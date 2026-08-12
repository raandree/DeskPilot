function Get-DpMcpRegisterParameter {
    <#
    .SYNOPSIS
        Builds the Register-ShpMcpServer parameters for one configured MCP server
        row.
    .DESCRIPTION
        Maps DeskPilot's persisted row onto the Engine's two parameter sets: a
        command line it launches, or a configuration file the user named and the
        Engine parses.

        **This is where a secret is resolved, and the only place it exists.** The
        row persists environment variable names; the values are read from the Host
        Server's own environment here, on the way into the registration, and are
        never written back to settings.json, returned to the browser or put in a
        fingerprint. A variable that is not set is left out rather than passed as
        an empty string, so the server fails with its own "missing credential"
        message instead of a confusing authentication error.
    .PARAMETER Server
        One normalised server row from ConvertTo-DpMcpServer.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Server
    )

    # -Force so a re-attach of a row whose alias is still held (a crashed server,
    # or a refresh) replaces it instead of failing on the name; the reconciler has
    # already decided that this row must be (re)started.
    $parameter = @{ Force = $true; Confirm = $false }

    if ($Server.source -eq 'file') {
        $parameter.Path = [string]$Server.path
        if ($Server.name) { $parameter.Name = [string]$Server.name }
    }
    else {
        $parameter.Name = [string]$Server.name
        $parameter.Command = [string]$Server.command
        if (@($Server.args).Count -gt 0) { $parameter.Argument = @($Server.args) }
        if ($Server.cwd) { $parameter.WorkingDirectory = [string]$Server.cwd }

        $environment = @{}
        foreach ($key in @($Server.envKeys)) {
            $value = [System.Environment]::GetEnvironmentVariable($key)
            if ($null -ne $value) { $environment[$key] = $value }
        }
        if ($environment.Count -gt 0) { $parameter.Environment = $environment }
    }

    if (@($Server.tools).Count -gt 0) { $parameter.ToolName = @($Server.tools) }

    $parameter
}
