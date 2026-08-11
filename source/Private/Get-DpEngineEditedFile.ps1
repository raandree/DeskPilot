function Get-DpEngineEditedFile {
    <#
    .SYNOPSIS
        Drains the Engine Runspace's ledger of files replace_in_file changed.
    .DESCRIPTION
        ShellPilot fills result.FilesWritten only from its own write_file tool
        (`ShellPilot.psm1:4202`), and a registered User Tool cannot reach that
        list - so a file changed through replace_in_file would be invisible to the
        Activity card, to the pending change set, and therefore to Undo.

        Invoke-DpReplaceInFileTool appends every successful edit to a Runspace
        global instead, and this reads it back once the Turn's pipeline is
        complete and the runspace is idle again. The read clears the ledger, so a
        Turn that fails before this point cannot leak its edits into the next.

        Best-effort by design: a runspace that never had the Tools registered, or
        one left unusable by a hard Stop, yields an empty list rather than
        breaking a Turn that has already produced its answer.
    .PARAMETER Runspace
        The idle Engine Runspace.
    .OUTPUTS
        System.String[]

        Workspace-relative paths, in the order they were edited, without repeats.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )

    if ($null -eq $Runspace -or $Runspace.RunspaceStateInfo.State -ne 'Opened') { return [string[]]@() }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript(@'
$ledger = Get-Variable -Name DeskPilotFilesEdited -Scope Global -ErrorAction SilentlyContinue
$drained = @()
if ($ledger -and $ledger.Value) { $drained = @($ledger.Value) }
Set-Variable -Name DeskPilotFilesEdited -Scope Global -Value ([System.Collections.Generic.List[string]]::new())
, $drained
'@)
        $drained = $shell.Invoke()
        if ($shell.HadErrors) { return [string[]]@() }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        return [string[]]@(foreach ($item in @($drained | Select-Object -Last 1)) {
                foreach ($entry in @($item)) {
                    $text = [string]$entry
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    if ($seen.Add($text)) { $text }
                }
            })
    }
    catch {
        $drainError = $_
        Write-Verbose "Could not drain the edited-file ledger: $drainError"
        return [string[]]@()
    }
    finally {
        $shell.Dispose()
    }
}
