function ConvertTo-DpMcpServer {
    <#
    .SYNOPSIS
        Normalises and validates one configured MCP server definition.
    .DESCRIPTION
        Accepts a hashtable or a PSCustomObject (for example parsed from JSON) and
        returns a fresh hashtable describing one MCP server DeskPilot should attach
        to the Engine. Two shapes are accepted, matching the Engine's own two entry
        points: a command line DeskPilot launches (source 'command'), or a path to
        an MCP configuration file the user named and the Engine parses (source
        'file').

        **This throws rather than dropping a bad entry.** ConvertTo-DpProject
        returns $null for an unusable Project because a Project list is assembled
        from folders that may have gone away. A server the user just typed into the
        Settings panel is different: silently discarding it would report success
        and attach nothing, which is the silent no-op this project keeps removing.

        **No secret is ever stored.** An MCP server that needs a token takes it
        from its environment, and the Engine clears the child environment and
        repopulates it from what the caller passes. DeskPilot therefore persists
        environment variable *names* only (envKeys) and resolves their values from
        the Host Server's own environment at registration time, so settings.json -
        which is clear text - never becomes a credential store. A user whose token
        is not already in the environment attaches the server through a config file
        they own instead.
    .PARAMETER InputObject
        The server-like object to normalise.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { throw 'An MCP server entry cannot be empty.' }

    $read = {
        param($obj, $name)
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] }
            return $null
        }
        $prop = $obj.PSObject.Properties[$name]
        if ($prop) { return $prop.Value }
        return $null
    }

    # The alias is not cosmetic: the Engine namespaces every tool it offers as
    # mcp_<alias>_<tool>, sanitising anything outside [A-Za-z0-9_-] to '_'. Refusing
    # those characters here keeps the name in the panel identical to the name in the
    # tool call, so a user watching the Activity feed can tell which server acted.
    $name = ([string](& $read $InputObject 'name')).Trim()
    if ($name -and $name -notmatch '^[A-Za-z0-9_-]{1,32}$') {
        throw "Invalid MCP server name '$name'. Use 1-32 characters from A-Z, a-z, 0-9, underscore or hyphen."
    }

    $source = ([string](& $read $InputObject 'source')).Trim().ToLowerInvariant()
    if (-not $source) { $source = if ((& $read $InputObject 'path')) { 'file' } else { 'command' } }
    if ($source -notin @('command', 'file')) {
        throw "Invalid MCP server source '$source' for '$name'. Use 'command' or 'file'."
    }

    # A command row is one server and has to be named. A file row may be left
    # unnamed, which attaches every entry in the file - the one-row way to reuse an
    # mcp.json that is already driving another host. The reconciler therefore tracks
    # what a row attached rather than assuming one name per row.
    if ($source -eq 'command' -and -not $name) { throw 'An MCP server needs a name.' }

    $id = ([string](& $read $InputObject 'id')).Trim()
    if (-not $id) { $id = New-DpId -Prefix 'mcp' }

    $command = ''
    $arguments = @()
    $cwd = ''
    $envKeys = @()
    $path = ''

    if ($source -eq 'command') {
        $command = ([string](& $read $InputObject 'command')).Trim()
        if (-not $command) { throw "MCP server '$name' needs a command to run." }

        # Drop nulls before the string conversion, not after: an absent args key
        # reads as $null, and @($null) is a one-element array whose element becomes
        # an empty string - which would be passed to the server as a real, empty
        # argument.
        $arguments = @(@(& $read $InputObject 'args') | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $cwd = ([string](& $read $InputObject 'cwd')).Trim()

        $envKeys = @(@(& $read $InputObject 'envKeys') |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ } |
                Select-Object -Unique)
        foreach ($key in $envKeys) {
            if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                throw "Invalid environment variable name '$key' on MCP server '$name'."
            }
        }
        if ($envKeys.Count -gt 32) { throw "MCP server '$name' names more than 32 environment variables." }
    }
    else {
        $path = ([string](& $read $InputObject 'path')).Trim()
        if (-not $path) { throw "MCP server '$name' needs the path of an MCP configuration file." }
    }

    # Reach reduction at the only point where it is honest. The Engine offers every
    # tool a server advertises unless -ToolName narrows it, and a filesystem server
    # can be attached for reading without its write tools ever reaching the model.
    $tools = @(@(& $read $InputObject 'tools') |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique)
    foreach ($tool in $tools) {
        if ($tool -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
            throw "Invalid tool name '$tool' on MCP server '$name'."
        }
    }

    $enabledValue = & $read $InputObject 'enabled'
    $enabled = if ($null -eq $enabledValue) { $true } else { [bool]$enabledValue }

    @{
        id      = $id
        name    = $name
        source  = $source
        command = $command
        args    = $arguments
        cwd     = $cwd
        envKeys = $envKeys
        path    = $path
        tools   = $tools
        enabled = $enabled
    }
}
