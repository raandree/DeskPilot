function Get-DpScopedSettings {
    <#
    .SYNOPSIS
        Returns a copy of Settings with a bounded set of keys overridden.
    .DESCRIPTION
        A scheduled or otherwise unattended Turn has to run somewhere other than
        the Project the window happens to have open, without editing the Settings
        the window is showing. This returns a clone with only allow-listed keys
        replaced, so no other Setting can be reached through the scope.

        Permissions are the reason this is a function rather than a splat: a
        scoped permission is ANDed with the live one, so a scope can only ever
        take authority away. Widening is structurally impossible rather than
        merely unintended.
    .PARAMETER Settings
        The live Settings hashtable. It is never mutated.
    .PARAMETER Scope
        The overrides. Keys outside the allow-list are ignored.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [AllowNull()]
        [hashtable]$Scope
    )

    $scoped = @{}
    foreach ($key in $Settings.Keys) { $scoped[$key] = $Settings[$key] }
    if ($Settings.ContainsKey('permissions') -and $Settings.permissions) {
        $permissions = @{}
        foreach ($key in $Settings.permissions.Keys) { $permissions[$key] = $Settings.permissions[$key] }
        $scoped.permissions = $permissions
    }
    if ($null -eq $Scope -or $Scope.Count -eq 0) { return $scoped }

    $allowed = @('workspaceFolder', 'selectedProjectId', 'selectedAgent', 'model')
    foreach ($key in $Scope.Keys) {
        if ($allowed -contains $key) { $scoped[$key] = $Scope[$key]; continue }
        if ($key -ne 'permissions') { continue }
        $requested = $Scope['permissions']
        if (-not $requested) { continue }
        foreach ($permission in @($requested.Keys)) {
            if (-not $scoped.permissions.ContainsKey($permission)) { continue }
            $scoped.permissions[$permission] = ([bool]$scoped.permissions[$permission]) -and ([bool]$requested[$permission])
        }
    }

    $scoped
}
