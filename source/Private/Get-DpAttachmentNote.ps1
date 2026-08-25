function Get-DpAttachmentNote {
    <#
    .SYNOPSIS
        States the files attached to a Turn, in the form the model can act on.
    .DESCRIPTION
        Attachment chips are a UI affordance the model never sees, so the paths
        still have to reach it. This composes the one line that names them, which
        the Turn prepends to the prompt - keeping the note out of the user's own
        message text, where it used to be typed and then shown back to them.

        A file inside the Workspace Folder is named relative to it: that folder is
        the Engine's working directory, so a relative name is what its File Tool
        resolves. Anything else - an upload made with no Project selected lands in
        the data directory - is named by its absolute path, the only form that can
        be found from there.
    .PARAMETER Attachment
        The Attachment records for this Turn. Each needs a `path`; a record
        without one is skipped rather than named as an empty file.
    .PARAMETER WorkspaceFolder
        The active Workspace Folder, or empty when no Project is selected.
    .OUTPUTS
        System.String - empty when nothing is attached.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Attachment = @(),

        [string]$WorkspaceFolder
    )

    $root = if ([string]::IsNullOrWhiteSpace($WorkspaceFolder)) { '' } else { $WorkspaceFolder.TrimEnd('\', '/') }

    $named = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Attachment) {
        $path = [string](Get-DpPropertyValue -InputObject $item -Name @('path') -Default '')
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $full = try { [System.IO.Path]::GetFullPath($path) } catch { $path }
        $inWorkspace = $root -and $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
        $named.Add($(if ($inWorkspace) { $full.Substring($root.Length + 1) } else { $full }))
    }

    if ($named.Count -eq 0) { return '' }

    $subject = if ($named.Count -eq 1) { 'File attached' } else { 'Files attached' }
    "$subject to this message: $($named -join ', '). Read them with your file tool when they are relevant to the request."
}
