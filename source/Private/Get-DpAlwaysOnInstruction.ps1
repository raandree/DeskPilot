function Get-DpAlwaysOnInstruction {
    <#
    .SYNOPSIS
        Returns the bodies of instruction files that must be pushed, not pulled.
    .DESCRIPTION
        The Engine injects instruction files as a CATALOG - name, description and
        applyTo glob - and offers a load_instruction tool to fetch a body. That is
        the right design for an instruction that only sometimes applies, and the
        wrong one for an instruction that always applies: the model has to decide to
        call the tool, and measurably often does not. A mandatory pre-flight or
        post-flight instruction that is never loaded is simply not in force.

        This selects the instructions whose applyTo is UNCONDITIONAL and returns
        their bodies composed into one system-prompt part. Everything else is left
        to the catalog, where the model can still load it once it knows which files
        it is touching.

        The rule is deliberately narrow: applyTo must be exactly '**', '**/*' or
        '*'. A comma-separated or extension-scoped glob is not unconditional, and a
        file with no applyTo at all is not pushed either - an instruction that does
        not say when it applies should not be forced into every Turn.

        Glob matching against the workspace tree is NOT attempted. It is expensive,
        it is wrong before the model has chosen which files to touch, and it would
        end with the whole instruction library in every prompt.

        The result is bounded. Over budget, files are taken in a stable
        alphabetical order and the ones that do not fit are NAMED with a pointer to
        load_instruction, so a dropped instruction is visible rather than silent. A
        body is never truncated mid-file: it is included whole or not at all.
    .PARAMETER Root
        The instruction root folders to scan. Missing roots are ignored.
    .PARAMETER MaxLength
        Total character budget across all pushed bodies. Defaults to 24 KB.
    .OUTPUTS
        System.Collections.Hashtable with:
        - text: the composed system-prompt part, or '' when nothing qualifies
        - included: the names whose bodies were pushed, in order
        - omitted: the names that qualified but did not fit
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Root = @(),

        [Parameter()]
        [ValidateRange(1024, 262144)]
        [int]$MaxLength = 24576
    )

    $empty = @{ text = ''; included = @(); omitted = @() }

    $candidates = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($folder in @($Root)) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }

        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.instructions.md' -File -ErrorAction Stop) }
        catch {
            $scanError = $_
            Write-Verbose "Could not scan instruction root '$folder': $scanError"
            continue
        }

        foreach ($file in $files) {
            $parsed = $null
            try { $parsed = Read-DpAgentFile -Path $file.FullName }
            catch {
                # A malformed or locked instruction file costs its own body, never
                # the Turn.
                $readError = $_
                Write-Warning "Skipping unreadable instruction file '$($file.FullName)': $readError"
                continue
            }
            if ($null -eq $parsed) { continue }

            $applyTo = [string]$parsed.applyTo
            if ($applyTo.Trim() -notin @('**', '**/*', '*')) { continue }

            $name = if (-not [string]::IsNullOrWhiteSpace($parsed.name)) { $parsed.name.Trim() }
            else { $file.Name -replace '\.instructions\.md$', '' }
            if (-not $seen.Add($name)) { continue }

            $body = [string]$parsed.body
            if ([string]::IsNullOrWhiteSpace($body)) { continue }

            $candidates.Add(@{ name = $name; body = $body.Trim() })
        }
    }

    if ($candidates.Count -eq 0) { return $empty }

    $ordered = @($candidates | Sort-Object -Property { $_.name })

    $included = [System.Collections.Generic.List[hashtable]]::new()
    $omitted = [System.Collections.Generic.List[string]]::new()
    $used = 0
    foreach ($candidate in $ordered) {
        if (($used + $candidate.body.Length) -gt $MaxLength) {
            $omitted.Add($candidate.name)
            continue
        }
        $used += $candidate.body.Length
        $included.Add($candidate)
    }

    if ($included.Count -eq 0) { return $empty }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add(@'
Repository instructions that apply to every task in this workspace. Follow them
as written; they take precedence over your general habits. Further instructions
that apply only to particular files are available through the load_instruction
tool.
'@)
    foreach ($candidate in $included) {
        $parts.Add(("--- {0} ---`n{1}" -f $candidate.name, $candidate.body))
    }
    if ($omitted.Count -gt 0) {
        $parts.Add(('Not included above because the budget was reached - load them with load_instruction when relevant: {0}' -f ($omitted -join ', ')))
    }

    @{
        text     = ($parts -join "`n`n")
        included = @($included | ForEach-Object { $_.name })
        omitted  = @($omitted)
    }
}
