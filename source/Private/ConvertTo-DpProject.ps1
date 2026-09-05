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

    # Hosts this Project's browser automation may reach without raising a card,
    # on top of the site the task itself names. Widened only from Settings, never
    # from a button beside an approval prompt - see decision 0008 on safeCommands
    # for why "always allow this" next to a question is the wrong affordance.
    #
    # A bad entry throws rather than being dropped: silently discarding one would
    # report the domain as remembered and then keep asking, and silently widening
    # to something unintended would be permanent. This runs on the API patch path
    # where the user can still be told. Get-DpBrowserScope, which runs per Turn
    # where nobody can be told, drops instead.
    $browserDomains = [System.Collections.Generic.List[string]]::new()
    $seenDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @(& $read $InputObject 'browserDomains')) {
        $domain = ([string]$entry).Trim().TrimEnd('.').ToLowerInvariant()
        if (-not $domain) { continue }
        # Two or more labels of letters, digits and inner hyphens. Rejects
        # wildcards, schemes, ports, paths, spaces and single-label intranet names.
        if ($domain -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') {
            throw "'$entry' is not a domain DeskPilot can allow. Use a host name such as example.com."
        }
        if ($seenDomains.Add($domain)) { $browserDomains.Add($domain) }
    }
    if ($browserDomains.Count -gt 200) { throw 'At most 200 browser domains can be added to a project.' }

    # What the browser may do beyond reading. The read-only slice has no action
    # with an external effect, which is what breaks the agency leg of the lethal
    # trifecta by architecture; every capability here gives some of it back, so
    # each is granted per Project, defaults absent, and is approved per call.
    #
    # There is no 'delete' capability because there is no delete action: removing
    # something on a site is a button press, so it is covered by 'submit' and
    # shown on that button's approval card. A capability named after an intention
    # rather than a mechanism would imply DeskPilot can tell the two apart.
    $knownActions = @('fill', 'submit', 'upload', 'download')
    $browserActions = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(& $read $InputObject 'browserActions')) {
        $action = ([string]$entry).Trim().ToLowerInvariant()
        if (-not $action) { continue }
        if ($knownActions -notcontains $action) {
            throw "'$entry' is not a browser action DeskPilot knows. Allowed: $($knownActions -join ', ')."
        }
        if ($browserActions -notcontains $action) { $browserActions.Add($action) }
    }

    @{
        id             = $id
        name           = $name
        path           = $path
        intercom       = $intercom
        intercomGroup  = $intercomGroup
        browserDomains = $browserDomains.ToArray()
        browserActions = $browserActions.ToArray()
    }
}
