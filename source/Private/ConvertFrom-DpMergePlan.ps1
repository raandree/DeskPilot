function ConvertFrom-DpMergePlan {
    <#
    .SYNOPSIS
        Parses a Model response into a structured Merge Plan.
    .DESCRIPTION
        Extracts the JSON object the Model returned (preferring a ```json fenced
        block, else the first balanced-looking {...} span) and normalises it to a
        Merge Plan: a list of { path, content } resolutions plus optional notes.
        Never throws: a missing or unparseable payload is reported in 'error' with
        an empty resolutions list.
    .PARAMETER Text
        The Model response text (Invoke-Shp .Content).
    .OUTPUTS
        System.Collections.Hashtable with ok, resolutions, notes and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Text
    )

    $result = @{ ok = $false; resolutions = @(); notes = $null; error = $null }

    if ([string]::IsNullOrWhiteSpace($Text)) { $result.error = 'The model returned no merge plan.'; return $result }

    $json = $null
    $fence = [regex]::Match($Text, '```(?:json)?\s*([\s\S]*?)```', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($fence.Success) {
        $json = $fence.Groups[1].Value.Trim()
    }
    else {
        $first = $Text.IndexOf('{')
        $last = $Text.LastIndexOf('}')
        if ($first -ge 0 -and $last -gt $first) { $json = $Text.Substring($first, $last - $first + 1) }
    }

    if ([string]::IsNullOrWhiteSpace($json)) { $result.error = 'Could not find a JSON merge plan in the response.'; return $result }

    try { $obj = $json | ConvertFrom-Json -ErrorAction Stop }
    catch { $result.error = "The merge plan was not valid JSON: $($_.Exception.Message)"; return $result }

    $list = [System.Collections.Generic.List[hashtable]]::new()
    if ($obj.PSObject.Properties['resolutions'] -and $obj.resolutions) {
        foreach ($r in @($obj.resolutions)) {
            if (-not $r) { continue }
            $path = if ($r.PSObject.Properties['path']) { [string]$r.path } else { $null }
            $content = if ($r.PSObject.Properties['content']) { [string]$r.content } else { $null }
            if ([string]::IsNullOrWhiteSpace($path) -or $null -eq $content) { continue }
            $list.Add(@{ path = $path; content = $content })
        }
    }

    if ($obj.PSObject.Properties['notes']) { $result.notes = [string]$obj.notes }
    $result.resolutions = $list.ToArray()
    if ($result.resolutions.Count -eq 0) { $result.error = 'The merge plan contained no file resolutions.'; return $result }
    $result.ok = $true
    $result
}
