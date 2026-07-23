function Resolve-DpAttachmentPath {
    <#
    .SYNOPSIS
        Resolves image Attachment paths recorded by the upload route.
    .DESCRIPTION
        Requires an absolute path recorded in the Host Server's per-launch
        Attachment store, an image content type, and an existing file. The store
        contains only paths successfully written by POST /api/uploads, so a
        Project change after upload does not invalidate the Attachment and a
        crafted Message cannot nominate an arbitrary local file.
    .PARAMETER Path
        One or more local Attachment paths to validate.
    .PARAMETER AttachmentStore
        The per-launch map of normalized uploaded paths to content types.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyCollection()]
        [string[]]$Path,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string]]$AttachmentStore
    )

    process {
        foreach ($candidate in $Path) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if (-not [System.IO.Path]::IsPathFullyQualified($candidate)) {
                throw "Attachment path '$candidate' must be absolute."
            }

            $fullPath = [System.IO.Path]::GetFullPath($candidate)
            $contentType = ''
            if (-not $AttachmentStore.TryGetValue($fullPath, [ref]$contentType)) {
                throw "Attachment path '$candidate' is not a current upload."
            }
            if (-not $contentType.StartsWith('image/', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Attachment path '$candidate' is not an image."
            }
            if (-not [System.IO.File]::Exists($fullPath)) {
                throw "Attachment path '$candidate' does not exist or is not a file."
            }

            $fullPath
        }
    }
}