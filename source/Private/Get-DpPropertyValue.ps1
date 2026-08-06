function Get-DpPropertyValue {
    <#
    .SYNOPSIS
        Returns the first present property value from a set of candidate names.
    .DESCRIPTION
        Defensive reader for objects whose exact shape is not guaranteed (such as
        the Engine result object). Returns Default when none of the candidate
        names is present on the input object.
    .PARAMETER InputObject
        The object to read.
    .PARAMETER Name
        Candidate property names, tried in order.
    .PARAMETER Default
        Value to return when no candidate is present.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$Name,

        [object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    # A record is a hashtable while it lives in memory and a PSCustomObject once it
    # has been round-tripped through JSON; read both.
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($candidate in $Name) {
            if ($InputObject.Contains($candidate)) { return $InputObject[$candidate] }
        }
        return $Default
    }
    foreach ($candidate in $Name) {
        $prop = $InputObject.PSObject.Properties[$candidate]
        if ($prop) { return $prop.Value }
    }
    $Default
}
