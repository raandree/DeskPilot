function New-DpMergePlanPrompt {
    <#
    .SYNOPSIS
        Builds the prompt that asks the Model for a Merge Plan (conflict fix).
    .DESCRIPTION
        Composes a single prompt describing the merge conflict and every conflicted
        text file (with its <<<<<<< ======= >>>>>>> markers), and instructs the
        Model to return a strict JSON object DeskPilot can apply deterministically:
        the complete resolved content of each file with all conflict markers
        removed. Binary conflicts are not included (they are resolved by a
        keep-ours / keep-theirs choice, not by the Model).
    .PARAMETER SourceBranch
        The Branch being merged.
    .PARAMETER DefaultBranch
        The Default Branch being merged into.
    .PARAMETER Files
        The conflicted text files from Get-DpMergeConflict (each with rel + content).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceBranch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Files
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("You are resolving a Git merge conflict for a non-technical user.")
    [void]$sb.AppendLine("The branch '$SourceBranch' is being merged into '$DefaultBranch'.")
    [void]$sb.AppendLine("Below is each conflicted file with Git conflict markers (<<<<<<<, =======, >>>>>>>).")
    [void]$sb.AppendLine("'ours' is the '$DefaultBranch' side; 'theirs' is the '$SourceBranch' side.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("For every file, produce the COMPLETE final file content with all conflict")
    [void]$sb.AppendLine("markers removed, combining both sides so no intended change is lost. Do not add")
    [void]$sb.AppendLine("commentary inside the file content. Preserve all unrelated lines exactly.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Respond with ONLY a single JSON object in a ```json code block, shaped:")
    [void]$sb.AppendLine('{ "resolutions": [ { "path": "<repo-relative path>", "content": "<full resolved file>" } ], "notes": "<one short sentence on what you did>" }')
    [void]$sb.AppendLine("Include one resolutions entry per file below, using its exact path.")
    [void]$sb.AppendLine("")

    foreach ($f in $Files) {
        if (-not $f) { continue }
        $rel = [string]$f.rel
        $content = [string]$f.content
        [void]$sb.AppendLine("===== FILE: $rel =====")
        [void]$sb.AppendLine($content)
        [void]$sb.AppendLine("===== END FILE: $rel =====")
        [void]$sb.AppendLine("")
    }

    $sb.ToString()
}
