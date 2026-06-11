function Get-DpMultipartBoundary {
    <#
    .SYNOPSIS
        Extracts the boundary token from a multipart/form-data Content-Type.
    .DESCRIPTION
        Returns the boundary value (without the leading "--") from a header
        such as 'multipart/form-data; boundary=----WebKitFormBoundaryABC'. The
        boundary may be quoted. Returns $null when the header is missing or has
        no boundary parameter.
    .PARAMETER ContentType
        The full Content-Type header value.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ContentType
    )
    if ([string]::IsNullOrWhiteSpace($ContentType)) { return $null }
    if ($ContentType -match 'boundary="?([^";]+)"?') { return $Matches[1] }
    $null
}
