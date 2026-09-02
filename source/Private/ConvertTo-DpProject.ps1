function ConvertTo-DpProject {
    <#
    .SYNOPSIS
        Normalises a Project-like object into a { id, name, path } hashtable.
    .DESCRIPTION
        Accepts a hashtable or a PSCustomObject (for example parsed from JSON) and
        returns a fresh hashtable with id, name and path. The path is required; an
        item with no path returns $null so the caller can drop it. A missing id is
        generated; a missing name defaults to the path's leaf folder name.

        The two remote-control flags are normalised here too, both defaulting to
        false, so a Project written before either existed loads as opted out rather
        than as a StrictMode missing-key throw.
    .PARAMETER InputObject
        The Project-like object to normalise.
    .OUTPUTS
        System.Collections.Hashtable, or $null when no usable path is present.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return $null }

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

    $path = ([string](& $read $InputObject 'path')).Trim()
    if (-not $path) { return $null }

    $id = ([string](& $read $InputObject 'id')).Trim()
    if (-not $id) { $id = New-DpId -Prefix 'p' }

    $name = ([string](& $read $InputObject 'name')).Trim()
    if (-not $name) { $name = Split-Path -Leaf $path }

    # Whether this Project may be controlled from a phone (spec 110). Off unless
    # explicitly set: remote control is opted into per Project, never inherited.
    $intercom = [bool](& $read $InputObject 'intercom')

    # And whether an allow-listed *group* may control it, which is a second, wider
    # grant: everyone in the group holds it, and Telegram decides who that is. It
    # defaults off even for a Project that already allows the operator's own phone,
    # so switching group access on cannot silently widen a Project that was opted
    # in when the operator was the only possible caller.
    $intercomGroup = [bool](& $read $InputObject 'intercomGroup')

    @{ id = $id; name = $name; path = $path; intercom = $intercom; intercomGroup = $intercomGroup }
}
