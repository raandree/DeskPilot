function Get-DpSubagentCatalog {
    <#
    .SYNOPSIS
        Lists the Subagents one Turn may dispatch through run_subagent.
    .DESCRIPTION
        A Subagent is an Agent the Model runs on a self-contained task. The
        catalog is what the run_subagent Tool describes to the Model and the only
        set it accepts a name from, so a name the Model invents can never reach
        an arbitrary path.

        An Agent is offered when its file declares a name and a description - the
        Engine refuses a definition without either - stays within the Engine's
        256 KiB definition cap, and does not set disable-model-invocation, which
        is how an Agent's author says "only people pick me". The selected Agent's
        own agents list narrows the set the way it does in VS Code: absent or '*'
        allows every eligible Agent, a list allows those names, and [] dispatches
        none at all.

        DeskPilot's bundled general-purpose Subagent comes first so the Tool has a
        default even when every user Agent opts out. A user Agent with the same
        name replaces it. Names that could not be carried safely in a Tool
        description are left out rather than escaped; descriptions are flattened
        to one bounded line. Agent files are metadata here: nothing in them can
        widen what a Subagent may do.
    .PARAMETER Root
        The Agents folder (Settings.agentsRoot). May be empty or missing.
    .PARAMETER SelectedAgent
        The id (file name) of the Agent the Turn runs as, whose agents list
        narrows the catalog. Empty for no selected Agent.
    .PARAMETER BuiltInRoot
        The folder holding the bundled general-purpose definition.
    .PARAMETER MaxEntries
        The most Subagents the catalog carries, built-in included.
    .OUTPUTS
        System.Collections.Hashtable

        allowed, reason and entries; each entry carries name, description, path,
        root and builtIn.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyString()]
        [string]$Root,

        [AllowEmptyString()]
        [string]$SelectedAgent,

        [string]$BuiltInRoot = (Get-DpSubagentAssetRoot),

        [ValidateRange(1, 64)]
        [int]$MaxEntries = 24
    )

    $maxDefinitionBytes = 256KB
    $namePattern = '^[\p{L}\p{N}][\p{L}\p{N} ._-]{0,63}$'
    $flatten = {
        param([string]$Text)
        $line = (($Text -replace '[\x00-\x1f\x7f]+', ' ') -replace '\s+', ' ').Trim()
        if ($line.Length -gt 200) { $line = $line.Substring(0, 199).TrimEnd() + [char]0x2026 }
        $line
    }

    $readDefinition = {
        param([System.IO.FileInfo]$File, [bool]$BuiltIn)
        if ($File.Length -gt $maxDefinitionBytes) { return }
        $meta = $null
        try { $meta = Read-DpAgentFile -Path $File.FullName } catch { return }
        $name = ([string]$meta.name).Trim()
        $description = & $flatten ([string]$meta.description)
        if ($name -notmatch $namePattern -or -not $description) { return }
        if ($meta.disableModelInvocation) { return }
        @{
            name        = $name
            description = $description
            path        = $File.FullName
            root        = $File.DirectoryName
            builtIn     = $BuiltIn
        }
    }

    $userEntries = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allowList = $null
    if (-not [string]::IsNullOrWhiteSpace($Root) -and (Test-Path -LiteralPath $Root -PathType Container)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Root -Filter '*.agent.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($SelectedAgent -and $file.Name -eq $SelectedAgent) {
                try { $allowList = (Read-DpAgentFile -Path $file.FullName).agents } catch { $allowList = $null }
            }
            $entry = & $readDefinition $file $false
            if ($null -eq $entry -or -not $seen.Add($entry.name)) { continue }
            $userEntries.Add($entry)
        }
    }

    if ($null -ne $allowList -and @($allowList).Count -eq 0) {
        return @{
            allowed = $false
            reason  = 'The selected Agent declares agents: [], so it dispatches no Subagent.'
            entries = @()
        }
    }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    if (-not $seen.Contains('general-purpose') -and $BuiltInRoot) {
        $builtInFile = Get-Item -LiteralPath (Join-Path $BuiltInRoot 'general-purpose.agent.md') -ErrorAction SilentlyContinue
        if ($builtInFile) {
            $builtIn = & $readDefinition $builtInFile $true
            if ($builtIn) { $entries.Add($builtIn) }
        }
    }
    $wildcard = $null -eq $allowList -or @($allowList) -contains '*'
    foreach ($entry in $userEntries) {
        if ($entries.Count -ge $MaxEntries) { break }
        if (-not $wildcard) {
            $stem = [IO.Path]::GetFileName($entry.path) -replace '\.agent\.md$', ''
            if (-not (@($allowList) | Where-Object { $_ -eq $entry.name -or $_ -eq $stem })) { continue }
        }
        $entries.Add($entry)
    }

    @{ allowed = $true; reason = ''; entries = @($entries | Select-Object -First $MaxEntries) }
}
