function ConvertTo-DpMcpServerView {
    <#
    .SYNOPSIS
        Maps one attached Engine MCP server onto the shape the SPA renders.
    .DESCRIPTION
        The Engine reports an attached server as a ShellPilot.McpServer object.
        This turns it into a plain hashtable the JSON writer can serialise, keeping
        the fields a user actually has to see and dropping the rest.

        Three of them are the point of the panel rather than decoration.
        **sandboxRequested** means the server's own configuration asked for
        sandboxing that neither the Engine nor DeskPilot implements, so the server
        is running with the user's full privileges - the registration warning has
        long scrolled away by the time anyone asks. **faultReason** is why a server
        stopped answering, which is otherwise invisible until a Turn fails.
        **tools** is the frozen list: the Engine lists a server's tools once, at
        registration, so what is shown here is exactly what the model can call
        until the server is refreshed.

        Environment values are absent because the Engine never emits them; only the
        variable names arrive, and only they are passed on.
    .PARAMETER InputObject
        One server object from Get-ShpMcpServer.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return $null }

    @{
        name             = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('Name') -Default '')
        state            = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('State') -Default '')
        running          = [bool](Get-DpPropertyValue -InputObject $InputObject -Name @('Running') -Default $false)
        transport        = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('Transport') -Default '')
        era              = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('Era') -Default '')
        protocolVersion  = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('ProtocolVersion') -Default '')
        toolCount        = [int](Get-DpPropertyValue -InputObject $InputObject -Name @('ToolCount') -Default 0)
        tools            = @(Get-DpPropertyValue -InputObject $InputObject -Name @('Tools') -Default @())
        toolsDropped     = @(Get-DpPropertyValue -InputObject $InputObject -Name @('ToolsDropped') -Default @())
        toolsTruncated   = [bool](Get-DpPropertyValue -InputObject $InputObject -Name @('ToolsTruncated') -Default $false)
        environmentKeys  = @(Get-DpPropertyValue -InputObject $InputObject -Name @('EnvironmentKey') -Default @())
        sandboxRequested = [bool](Get-DpPropertyValue -InputObject $InputObject -Name @('SandboxRequested') -Default $false)
        serverName       = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('ServerName') -Default '')
        serverVersion    = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('ServerVersion') -Default '')
        processId        = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('ProcessId') -Default '')
        faultReason      = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('FaultReason') -Default '')
    }
}
