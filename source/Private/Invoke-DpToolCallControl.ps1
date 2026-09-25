function Invoke-DpToolCallControl {
    <#
    .SYNOPSIS
        Translates the Engine's version-1 PreToolCall request into Host approval.
    .DESCRIPTION
        This hook is called only after Engine policy permits the call. It never
        modifies arguments or executes a Tool. Bind the effective JSON bytes and
        original MCP registration identity, then translate the once-only Host
        decision back to allow or deny. Unknown shapes fail closed.
    .PARAMETER Request
        A detached Engine PreToolCall request, never a Model-supplied capability.
    .PARAMETER Context
        Frozen Host scope and Permissions.
    .PARAMETER Bridge
        The Host approval rendezvous.
    .PARAMETER McpToolMap
        Exact namespaced-to-original identities captured from Engine registrations.
    .PARAMETER TimeoutSeconds
        Maximum approval wait.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Request,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowNull()][object]$Bridge,
        [System.Collections.IDictionary]$McpToolMap = @{},
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
    )
    $deny = { param([string]$Reason); @{ Decision = 'deny'; Reason = $Reason } }
    $schema = Get-DpPropertyValue -InputObject $Request -Name 'SchemaVersion'
    $phase = Get-DpPropertyValue -InputObject $Request -Name 'Phase'
    $name = Get-DpPropertyValue -InputObject $Request -Name 'Tool'
    $origin = Get-DpPropertyValue -InputObject $Request -Name 'Origin'
    $trust = Get-DpPropertyValue -InputObject $Request -Name 'Trust'
    $json = Get-DpPropertyValue -InputObject $Request -Name 'EffectiveArguments'
    $callId = Get-DpPropertyValue -InputObject $Request -Name 'ToolCallId'
    $server = Get-DpPropertyValue -InputObject $Request -Name 'Server' -Default ''
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -ne 1 -or $phase -cne 'Pre' -or
        $name -isnot [string] -or $name -cnotmatch '\A[A-Za-z0-9_-]{1,128}\z' -or
        $origin -cnotin @('BuiltIn', 'User', 'Mcp') -or
        $callId -isnot [string] -or [string]::IsNullOrWhiteSpace($callId) -or $callId.Length -gt 128 -or
        $json -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($json) -gt 262144) {
        return (& $deny 'Unsupported or incomplete Engine pre-call metadata.')
    }
    $expectedTrust = switch ($origin) { BuiltIn { 'ModuleAuthored' } User { 'CallerRegistered' } Mcp { 'ThirdParty' } }
    if ($trust -cne $expectedTrust) { return (& $deny 'The Engine Tool origin could not be verified.') }
    try { $arguments = $json | ConvertFrom-Json -AsHashtable -Depth 32 -ErrorAction Stop }
    catch { return (& $deny 'The effective Tool arguments are malformed.') }
    if ($arguments -isnot [System.Collections.IDictionary]) { return (& $deny 'The effective Tool arguments must be an object.') }
    if ($null -eq $Bridge -or -not $Bridge.Enabled -or $Bridge.Cancelled) {
        return (& $deny 'Host approval is unavailable or cancelled.')
    }

    $material = [ordered]@{ effectiveArguments = $json; tool = $name; origin = $origin; server = $server; callId = $callId }
    foreach ($key in @('RunId', 'TurnId', 'RequestId')) {
        $value = Get-DpPropertyValue -InputObject $Request -Name $key
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 128) {
            return (& $deny 'The Engine request identity is incomplete.')
        }
        $material[$key] = $value
    }

    $permissions = Get-DpPropertyValue -InputObject $Context -Name 'permissions' -Default @{}
    $class = 'UserTool'
    $originalTool = ''
    if ($origin -ceq 'BuiltIn') {
        $readPermission = switch -CaseSensitive ($name) {
            { $_ -cin @('read_file', 'list_directory', 'glob_files', 'grep_files') } { 'file' }
            'fetch_url' { 'browsing' }
            'ask_user' { 'askUser' }
            { $_ -cin @('load_skill', 'load_instruction', 'manage_todo_list', 'search_tools') } { 'engine' }
            default { '' }
        }
        if ($readPermission) {
            if ($readPermission -ceq 'engine' -or [bool](Get-DpPropertyValue -InputObject $permissions -Name $readPermission -Default $false)) {
                return @{ Decision = 'allow'; Reason = 'The read-only Engine Tool retains its category policy.' }
            }
            return (& $deny 'The required Tool Permission is not enabled.')
        }
        if ($name -cin @('write_file', 'edit_file', 'create_directory')) { $class = 'FileWrite' }
        elseif ($name -ceq 'run_command') { $class = 'Terminal' }
        else { return (& $deny 'The built-in Tool is not recognized by the Host approval adapter.') }
    }
    elseif ($origin -ceq 'Mcp') {
        $class = 'Mcp'
        if ($server -isnot [string] -or -not $McpToolMap.Contains($name)) {
            return (& $deny 'The MCP registration identity is unavailable.')
        }
        $identity = $McpToolMap[$name]
        $registeredServer = Get-DpPropertyValue -InputObject $identity -Name 'Server'
        $originalTool = Get-DpPropertyValue -InputObject $identity -Name 'Tool'
        if ($registeredServer -isnot [string] -or $registeredServer -cne $server -or
            $originalTool -isnot [string] -or [string]::IsNullOrWhiteSpace($originalTool)) {
            return (& $deny 'The MCP call does not match its frozen registration identity.')
        }
    }
    elseif (-not [string]::IsNullOrEmpty([string]$server)) {
        return (& $deny 'A User Tool cannot claim an MCP server identity.')
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($material | ConvertTo-Json -Depth 4 -Compress)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $call = @{
        Name = $name; Class = $class; CallId = $callId; ArgumentsJson = $json
        Fingerprint = $fingerprint; Policy = @{ Allowed = $true }
        McpServer = $server; McpTool = $originalTool
    }
    $decision = Invoke-DpToolCallApproval -Call $call -Context $Context -Bridge $Bridge -TimeoutSeconds $TimeoutSeconds
    if ($decision.Allowed -is [bool] -and $decision.Allowed) {
        return @{ Decision = 'allow'; Reason = [string]$decision.Message }
    }
    & $deny ([string]$decision.Message)
}
