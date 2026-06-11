function New-DpId {
    <#
    .SYNOPSIS
        Generates a short opaque identifier with a prefix.
    .PARAMETER Prefix
        The id prefix, for example 'c' for a Conversation or 'm' for a Message.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix
    )
    '{0}_{1}' -f $Prefix, ([guid]::NewGuid().ToString('N').Substring(0, 10))
}
