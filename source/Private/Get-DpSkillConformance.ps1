function Get-DpSkillConformance {
    <#
    .SYNOPSIS
        Reads a SKILL.md into bounded metadata and conformance diagnostics.
    .DESCRIPTION
        Inspects one Agent Skill against the open specification published at
        https://agentskills.io/specification and returns what DeskPilot is willing
        to show about it: the canonical name and description, the optional
        license, compatibility, version and origin when the Skill actually
        declares them, which resource folders exist, and a list of problems worth
        repairing.

        The scan is deliberately inert. Confinement is proved before anything is
        opened, from path text and directory metadata alone: the path must lie
        inside Root (compared case-insensitively on Windows and exactly
        everywhere else, so a case-spelling alias of a distinct folder is
        refused rather than followed), and nothing between Root and the file may
        be a link. Every link below
        Root is refused wherever it points, because trusting a target means
        proving its whole physical chain and a target that reads as though it
        were inside Root can be routed out by another link. A refused Skill
        comes back as a bounded diagnostic with none of its content - not its
        name, description or body - read or returned. Root itself is exempt: a
        configured root that is a junction is a decision made in Settings.
        Beyond that the scan reads at most MaxBytes from the head of the file,
        never loads the Markdown body into the catalog, never opens a file under
        references/, scripts/ or assets/, never runs anything, and never follows
        a URL.

        Frontmatter parsing reuses Read-DpAgentFile for the canonical name and
        description (the same tolerant, minimal reader every Customization uses)
        and scans the same block for the remaining documented fields. There is no
        general YAML engine here: block mappings of string values are read, a
        folded description is folded by that reader, and any other form - a flow
        sequence, a flow mapping, an unfolded block scalar - is reported and
        dropped rather than surfaced as if it were text.

        'conformant' answers whether the Skill was found to meet the
        specification, not whether problems fit on screen. Every normative
        finding counts even when it is deduplicated or past MaxWarnings, and
        content DeskPilot could not read in full (an oversized file, a truncated
        frontmatter) is not certified. Informational advice never fails a Skill.

        The experimental allowed-tools field is surfaced as descriptive metadata
        only. It is never an authority: DeskPilot grants no Permission from it,
        which the returned metadata states and a diagnostic repeats.

        Designed never to throw. An unreadable file is reported in the diagnostics
        so a broken Skill stays visible and editable instead of disappearing.
    .PARAMETER Path
        The SKILL.md file to inspect.
    .PARAMETER Root
        The configured Skill root the file was discovered under. Supplying it
        enables the link-confinement check.
    .PARAMETER MaxBytes
        The most bytes to read from the head of the file. Default 64 KiB.
    .PARAMETER MaxFrontmatterLines
        The most frontmatter lines to scan. Default 200.
    .PARAMETER MaxWarnings
        The most diagnostics to return for one Skill. Default 12.
    .PARAMETER MaxMetadataEntries
        The most metadata mapping entries to copy. Default 32.
    .OUTPUTS
        System.Collections.Hashtable with path, directory, name, declaredName,
        description, metadata, resources, warnings and conformant.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Root,

        [int]$MaxBytes = 65536,

        [int]$MaxFrontmatterLines = 200,

        [int]$MaxWarnings = 12,

        [int]$MaxMetadataEntries = 32
    )

    # Limits from the specification. Values are additionally capped before they
    # are surfaced so a hostile file cannot flood an API response.
    $nameMax = 64
    $descriptionMax = 1024
    $compatibilityMax = 500
    $scalarCeiling = 500
    $entryCeiling = 200
    $terseDescription = 40

    $known = @('name', 'description', 'license', 'compatibility', 'metadata', 'allowed-tools')

    # Path comparison follows the file system, not habit. Windows is the one
    # platform where case-insensitive comparison is guaranteed right; everywhere
    # else the exact comparison is the safe one, because /skills/Private and
    # /skills/private can genuinely be two folders. Refusing a case-spelling
    # alias costs a diagnostic; reading a different folder costs confinement.
    $pathCase = if ($null -eq $IsWindows -or $IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    $skillDirectory = Split-Path -Parent $Path
    $directory = if ($skillDirectory) { Split-Path -Leaf $skillDirectory } else { '' }

    $warnings = [System.Collections.Generic.List[hashtable]]::new()
    $seenCodes = @{}
    $normative = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $warningBudget = [Math]::Max(0, $MaxWarnings)

    function Add-DpSkillWarning {
        param(
            [Parameter(Mandatory)][string]$Code,
            [Parameter(Mandatory)][ValidateSet('error', 'warning', 'info')][string]$Severity,
            [Parameter(Mandatory)][string]$Message
        )
        # Conformance is decided by what was found, not by what fits on screen.
        # A normative finding is recorded here, before deduplication and before
        # the display budget, so neither can turn a violation into a pass.
        # 'info' is advice about a legal file and never fails it.
        if ($Severity -ne 'info') { [void]$normative.Add($Code) }
        if ($seenCodes.ContainsKey($Code)) { return }
        if ($warnings.Count -ge $warningBudget) { return }
        $seenCodes[$Code] = $true
        $warnings.Add(@{ code = $Code; severity = $Severity; message = $Message })
    }

    function Test-DpSkillScalar {
        <#
            True when the limited frontmatter reader can take this raw value as a
            plain string. A YAML flow sequence or mapping, and a block-scalar
            indicator the reader does not fold, are not plain strings - and must
            not be shown as if they were.
        #>
        param([string]$Value)
        if ([string]::IsNullOrEmpty($Value)) { return $true }
        -not ($Value.StartsWith('[') -or $Value.StartsWith('{') -or $Value -match '^[>|][-+]?\d*\s*$')
    }

    function Test-DpSkillLink {
        <#
            True when an entry redirects somewhere else: a symbolic link, a
            junction or a mount point. Not every reparse point is a redirection -
            a cloud placeholder (OneDrive Files On-Demand) carries the same
            attribute, and refusing those would refuse ordinary Skills - so the
            link kind decides, and an entry whose kind cannot be read at all is
            refused rather than assumed harmless.
        #>
        param($Entry)
        if (-not $Entry) { return $false }
        if (-not ($Entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
        $kind = $null
        try { $kind = [string]$Entry.LinkType }
        catch { return $true }
        if ([string]::IsNullOrWhiteSpace($kind)) { return $false }
        $kind -ne 'HardLink'
    }

    $sawControl = $false
    function Limit-DpSkillText {
        param([string]$Value, [int]$Limit)
        if ([string]::IsNullOrEmpty($Value)) { return $Value }
        $clean = [string]::Join('', @($Value.ToCharArray() | Where-Object { -not [char]::IsControl($_) }))
        if ($clean.Length -gt $Limit) { return $clean.Substring(0, $Limit) }
        $clean
    }

    $result = @{
        path         = $Path
        directory    = $directory
        name         = $directory
        declaredName = $null
        description  = $null
        metadata     = @{}
        resources    = @{ scripts = $false; references = $false; assets = $false }
        warnings     = @()
        conformant   = $true
    }

    # --- Prove confinement before anything is opened -------------------------
    # Two questions, both settled with path text and directory metadata only, so
    # a Skill that fails either is refused without a handle ever being opened on
    # it: is the path inside the configured root at all, and is anything between
    # the root and the file a link?
    #
    # Every link below the root is refused, wherever it points. Judging a link
    # by its target means proving the whole physical chain of that target, and a
    # target that reads as if it were inside the root can be routed out by
    # another link along the way. Refusing is cheap, provable and needs no read
    # of the target. The configured root itself is exempt: a root that is a
    # junction is a decision made in Settings - the CopilotAtelier OneDrive
    # layout relies on exactly that - and DeskPilot does not second-guess it.
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $rootFull = $null
        try { $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') } catch { $rootFull = $null }
        $pathFull = $null
        try { $pathFull = [System.IO.Path]::GetFullPath($Path) } catch { $pathFull = $null }
        $rootPrefix = if ($rootFull) { $rootFull + [System.IO.Path]::DirectorySeparatorChar } else { $null }

        if (-not $rootPrefix -or -not $pathFull -or -not $pathFull.TrimEnd('\', '/').StartsWith($rootPrefix, $pathCase)) {
            Add-DpSkillWarning -Code 'path-outside-root' -Severity 'error' -Message 'This path is not inside the configured Skills folder. DeskPilot did not read it.'
            $result.warnings = @($warnings)
            $result.conformant = $false
            return $result
        }

        $cursor = $pathFull
        while ($cursor -and $cursor.TrimEnd('\', '/').StartsWith($rootPrefix, $pathCase)) {
            if (Test-DpSkillLink -Entry (Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue)) {
                Add-DpSkillWarning -Code 'link-below-root' -Severity 'error' -Message 'This Skill is a link, or sits behind one, inside the Skills folder. DeskPilot does not follow links there and did not read it. If the Skill lives somewhere else, configure that folder as a Skills folder; otherwise replace the link with the Skill itself.'
                $result.warnings = @($warnings)
                $result.conformant = $false
                return $result
            }
            $cursor = Split-Path -Parent $cursor
        }
    }

    # --- Read a bounded head of the file -------------------------------------
    $item = $null
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch { $item = $null }

    if (-not $item -or $item.PSIsContainer) {
        Add-DpSkillWarning -Code 'unreadable' -Severity 'error' -Message 'DeskPilot could not read this SKILL.md.'
        $result.warnings = @($warnings)
        $result.conformant = $false
        return $result
    }

    $head = ''
    try {
        $readLen = [int][Math]::Min([long][Math]::Max(0, $MaxBytes), $item.Length)
        $buffer = New-Object byte[] $readLen
        if ($readLen -gt 0) {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $offset = 0
                while ($offset -lt $readLen) {
                    $got = $fs.Read($buffer, $offset, $readLen - $offset)
                    if ($got -le 0) { break }
                    $offset += $got
                }
            }
            finally { $fs.Dispose() }
            $start = 0
            if ($readLen -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { $start = 3 }
            $head = [System.Text.Encoding]::UTF8.GetString($buffer, $start, $readLen - $start)
        }
        if ($item.Length -gt $MaxBytes) {
            Add-DpSkillWarning -Code 'file-too-large' -Severity 'warning' -Message "This SKILL.md is larger than the $MaxBytes byte scan limit. DeskPilot read only the head of it, and an agent loading the whole body spends that context on every activation."
        }
    }
    catch {
        Add-DpSkillWarning -Code 'unreadable' -Severity 'error' -Message 'DeskPilot could not read this SKILL.md.'
        $result.warnings = @($warnings)
        $result.conformant = $false
        return $result
    }

    # --- Resource folders (presence only; nothing is opened) -----------------
    foreach ($folder in 'scripts', 'references', 'assets') {
        $result.resources[$folder] = [bool](Test-Path -LiteralPath (Join-Path $skillDirectory $folder) -PathType Container)
    }

    # --- Frontmatter ---------------------------------------------------------
    if ($head -notmatch '(?s)^\uFEFF?---\r?\n(.*?)\r?\n---\r?\n?(.*)$') {
        if ($head -match '^\uFEFF?---\r?\n') {
            Add-DpSkillWarning -Code 'frontmatter-malformed' -Severity 'error' -Message 'The YAML frontmatter block is never closed. Add a line containing only --- after the last field.'
        }
        else {
            Add-DpSkillWarning -Code 'frontmatter-missing' -Severity 'error' -Message 'This SKILL.md has no YAML frontmatter. A Skill needs a --- block declaring name and description.'
        }
        $result.warnings = @($warnings)
        $result.conformant = $false
        return $result
    }

    $front = $Matches[1]
    $parsed = Read-DpAgentFile -Text $head

    $lines = $front -split '\r?\n'
    if ($lines.Count -gt $MaxFrontmatterLines) {
        Add-DpSkillWarning -Code 'frontmatter-too-long' -Severity 'warning' -Message "The frontmatter is longer than the $MaxFrontmatterLines line scan limit. DeskPilot read only the first $MaxFrontmatterLines lines of it."
        $lines = $lines[0..($MaxFrontmatterLines - 1)]
    }

    # A control character surviving the line split was written into a value, not
    # produced by the file's line endings.
    $sawControl = [bool]@($lines | Where-Object { $_ -and @($_.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0 }).Count

    $license = $null
    $compatibility = $null
    $allowedTools = $null
    $metadataEntries = $null
    $topLevel = @{}
    $unreadableFields = [System.Collections.Generic.List[string]]::new()
    $unsupported = [System.Collections.Generic.List[string]]::new()

    # A value the limited reader cannot take as a plain string is reported and
    # dropped rather than surfaced verbatim. The one exception is description:
    # Read-DpAgentFile already folds a block scalar there, so that form is read,
    # not refused. Nothing here parses YAML beyond what that reader does.
    $refuseNonScalar = {
        param([string]$Field, [string]$Raw, [bool]$AllowBlock)
        if ([string]::IsNullOrEmpty($Raw)) { return $false }
        if ($AllowBlock -and $Raw -match '^[>|][-+]?\d*\s*$') { return $false }
        if (Test-DpSkillScalar -Value $Raw) { return $false }
        $unreadableFields.Add($Field)
        $true
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        # Indented lines belong to the field above (a block scalar or a mapping
        # entry) and are consumed where that field is handled.
        if ($line -match '^\s') { continue }
        if ($line -notmatch '^([A-Za-z0-9_.\-]+)\s*:\s*(.*?)\s*$') { continue }

        $key = $Matches[1]
        $value = $Matches[2].Trim().Trim('"', "'")
        $lowered = $key.ToLowerInvariant()
        $topLevel[$lowered] = $value

        if ($lowered -eq 'license') {
            if (-not (& $refuseNonScalar 'license' $value $false)) { $license = $value }
        }
        elseif ($lowered -eq 'compatibility') {
            if (-not (& $refuseNonScalar 'compatibility' $value $false)) { $compatibility = $value }
        }
        elseif ($lowered -eq 'allowed-tools') {
            if ([string]::IsNullOrWhiteSpace($value) -or -not (Test-DpSkillScalar -Value $value)) {
                Add-DpSkillWarning -Code 'allowed-tools-not-a-string' -Severity 'warning' -Message 'allowed-tools must be a single space-separated string, for example "Bash(git:*) Read". DeskPilot did not read this value.'
            }
            else { $allowedTools = $value }
        }
        elseif ($lowered -eq 'metadata') {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                Add-DpSkillWarning -Code 'metadata-not-a-map' -Severity 'warning' -Message 'metadata must be a block mapping of string keys to string values. DeskPilot did not read this value.'
            }
            else {
                $entries = [ordered]@{}
                $overflow = $false
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    $entry = $lines[$j]
                    if ($entry -match '^\s*$') { continue }
                    if ($entry -notmatch '^\s') { break }
                    if ($entry -match '^\s*-\s') {
                        Add-DpSkillWarning -Code 'metadata-value-not-a-string' -Severity 'warning' -Message 'Every metadata value must be a string. DeskPilot skipped an entry holding a list or a nested mapping.'
                        continue
                    }
                    if ($entry -notmatch '^\s+([A-Za-z0-9_.\-]+)\s*:\s*(.*?)\s*$') { continue }
                    $entryKey = $Matches[1]
                    $entryValue = $Matches[2].Trim().Trim('"', "'")
                    if ([string]::IsNullOrWhiteSpace($entryValue)) {
                        Add-DpSkillWarning -Code 'metadata-value-not-a-string' -Severity 'warning' -Message 'Every metadata value must be a string. DeskPilot skipped an entry holding a list or a nested mapping.'
                        continue
                    }
                    if ($entries.Count -ge $MaxMetadataEntries) { $overflow = $true; continue }
                    $entries[(Limit-DpSkillText -Value $entryKey -Limit $entryCeiling)] = (Limit-DpSkillText -Value $entryValue -Limit $entryCeiling)
                }
                if ($overflow) {
                    Add-DpSkillWarning -Code 'metadata-too-many-entries' -Severity 'warning' -Message "DeskPilot shows at most $MaxMetadataEntries metadata entries; the rest were not read."
                }
                if ($entries.Count -gt 0) { $metadataEntries = $entries }
            }
        }
        elseif ($known -notcontains $lowered) { $unsupported.Add($key) }
    }

    # --- Name ----------------------------------------------------------------
    # A name the reader cannot take as a plain string is treated as undeclared,
    # exactly like a missing one: the folder names the Skill and nothing
    # uninterpretable is shown as if it were the name.
    $nameUnreadable = & $refuseNonScalar 'name' ([string]$topLevel['name']) $false
    $declared = if ($nameUnreadable) { $null } else { Limit-DpSkillText -Value $parsed.name -Limit $scalarCeiling }
    if ([string]::IsNullOrWhiteSpace($declared)) {
        if (-not $nameUnreadable) {
            Add-DpSkillWarning -Code 'name-missing' -Severity 'error' -Message 'A Skill must declare a name in its frontmatter. DeskPilot is showing the folder name instead.'
        }
    }
    else {
        $result.declaredName = $declared
        $result.name = $declared
        if ($declared.Length -gt $nameMax) {
            Add-DpSkillWarning -Code 'name-too-long' -Severity 'warning' -Message "A Skill name may be at most $nameMax characters; this one is $($declared.Length)."
        }
        if ($declared -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
            Add-DpSkillWarning -Code 'name-invalid' -Severity 'warning' -Message 'A Skill name may hold only lowercase letters, digits and single hyphens, and may not start or end with a hyphen.'
        }
        if ($directory -and -not $declared.Equals($directory, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-DpSkillWarning -Code 'name-directory-mismatch' -Severity 'warning' -Message "The declared name does not match the folder '$directory'. The specification requires them to be the same, and clients that key on the folder will disagree with this file."
        }
    }

    # --- Description ---------------------------------------------------------
    # A block scalar is legitimate here and the existing reader folds it; a flow
    # sequence or mapping is not, and is dropped rather than shown as text.
    $descriptionUnreadable = & $refuseNonScalar 'description' ([string]$topLevel['description']) $true
    $description = if ($descriptionUnreadable) { $null } else { Limit-DpSkillText -Value $parsed.description -Limit $descriptionMax }
    if ([string]::IsNullOrWhiteSpace($description)) {
        if (-not $descriptionUnreadable) {
            Add-DpSkillWarning -Code 'description-missing' -Severity 'error' -Message 'A Skill must declare a non-empty description. It is the only text an agent sees before deciding whether to use the Skill.'
        }
    }
    else {
        $result.description = $description
        $rawLength = ([string]$parsed.description).Length
        if ($rawLength -gt $descriptionMax) {
            Add-DpSkillWarning -Code 'description-too-long' -Severity 'warning' -Message "A description may be at most $descriptionMax characters; this one is $rawLength. DeskPilot shows the first $descriptionMax."
        }
        elseif ($description.Trim().Length -lt $terseDescription) {
            Add-DpSkillWarning -Code 'description-terse' -Severity 'info' -Message 'This description reads as a label. Say what the Skill does and when to use it, so an agent has something to match a task against.'
        }
    }

    # --- Optional documented fields -----------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($license)) {
        $result.metadata.license = Limit-DpSkillText -Value $license -Limit $entryCeiling
    }
    if (-not [string]::IsNullOrWhiteSpace($compatibility)) {
        $result.metadata.compatibility = Limit-DpSkillText -Value $compatibility -Limit $compatibilityMax
        if ($compatibility.Length -gt $compatibilityMax) {
            Add-DpSkillWarning -Code 'compatibility-too-long' -Severity 'warning' -Message "A compatibility value may be at most $compatibilityMax characters; this one is $($compatibility.Length)."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($allowedTools)) {
        $result.metadata.allowedTools = Limit-DpSkillText -Value $allowedTools -Limit $scalarCeiling
        $result.metadata.allowedToolsAuthoritative = $false
        Add-DpSkillWarning -Code 'allowed-tools-not-a-permission' -Severity 'info' -Message 'allowed-tools is experimental metadata. DeskPilot shows it and grants nothing from it: what the agent may run is decided by your Permission settings alone.'
    }
    if ($metadataEntries) {
        $result.metadata.entries = @{}
        foreach ($entryKey in $metadataEntries.Keys) { $result.metadata.entries[$entryKey] = $metadataEntries[$entryKey] }
    }

    # version and origin come from the metadata mapping the specification defines
    # for them, and fall back to the top-level keys older Skills used so a real
    # file still shows what it declares - with the placement flagged.
    $version = $null
    $origin = $null
    if ($metadataEntries) {
        if ($metadataEntries.Contains('version')) { $version = $metadataEntries['version'] }
        foreach ($candidate in 'origin', 'author', 'source') {
            if (-not $origin -and $metadataEntries.Contains($candidate)) { $origin = $metadataEntries[$candidate] }
        }
    }
    if (-not $version -and $topLevel.ContainsKey('version')) { $version = Limit-DpSkillText -Value $topLevel['version'] -Limit $entryCeiling }
    if (-not $origin) {
        foreach ($candidate in 'origin', 'author', 'source') {
            if (-not $origin -and $topLevel.ContainsKey($candidate)) { $origin = Limit-DpSkillText -Value $topLevel[$candidate] -Limit $entryCeiling }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($version)) { $result.metadata.version = $version }
    if (-not [string]::IsNullOrWhiteSpace($origin)) { $result.metadata.origin = $origin }

    if ($unsupported.Count -gt 0) {
        $named = @($unsupported | Select-Object -Unique -First 5) -join ', '
        Add-DpSkillWarning -Code 'field-unsupported' -Severity 'info' -Message "The specification does not define these frontmatter fields: $named. Move anything you want to keep under metadata; DeskPilot does not interpret them."
    }

    if ($unreadableFields.Count -gt 0) {
        $named = @($unreadableFields | Select-Object -Unique -First 5) -join ', '
        Add-DpSkillWarning -Code 'value-not-a-scalar' -Severity 'warning' -Message "These fields must hold a plain string: $named. DeskPilot reads the frontmatter with a deliberately limited reader, did not interpret a list, a mapping or an unfolded block there, and is showing nothing for them."
    }

    if ($sawControl) {
        Add-DpSkillWarning -Code 'value-control-characters' -Severity 'warning' -Message 'A frontmatter value contained control characters. DeskPilot removed them before showing the value.'
    }

    $result.warnings = @($warnings)
    $result.conformant = $normative.Count -eq 0
    $result
}
