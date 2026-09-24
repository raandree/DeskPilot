#requires -Version 7.0

# Conformance diagnostics for Agent Skills (SKILL.md files), measured against the
# open specification at https://agentskills.io/specification.
#
# These tests are the contract in both directions: what DeskPilot surfaces about a
# Skill, and what it refuses to do while looking. Scanning never executes a
# script, never follows a reference or a link out of a configured root, and never
# turns a declared `allowed-tools` into a Permission. A malformed Skill stays
# listed and editable so the user can repair it.

BeforeDiscovery {
    # Creating a file symlink needs Administrator or Developer Mode on Windows.
    # Probe once here so the link-escape test skips with a reason rather than
    # failing on a machine that cannot create one.
    $script:canSymlink = $false
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-symlink-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $probeDir -Force -ErrorAction Stop | Out-Null
        $probeTarget = Join-Path $probeDir 'target.txt'
        Set-Content -LiteralPath $probeTarget -Value 'x' -NoNewline
        New-Item -ItemType SymbolicLink -Path (Join-Path $probeDir 'link.txt') -Target $probeTarget -ErrorAction Stop | Out-Null
        $script:canSymlink = $true
    }
    catch { $script:canSymlink = $false }
    finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }

    # Whether two paths differing only in case are two folders here. Case
    # comparison is a platform property, not a preference, and the regression
    # for it can only run where the file system actually distinguishes them.
    $script:caseSensitiveFs = $false
    $caseProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-case-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path ($caseProbe + 'A') -Force -ErrorAction Stop | Out-Null
        $script:caseSensitiveFs = -not (Test-Path -LiteralPath ($caseProbe + 'a'))
    }
    catch { $script:caseSensitiveFs = $false }
    finally { Remove-Item -LiteralPath ($caseProbe + 'A') -Recurse -Force -ErrorAction SilentlyContinue }
}

BeforeAll {
    $script:directoryLinkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    $script:repoRoot = Join-Path $PSScriptRoot '..' '..' | Convert-Path
    $script:webRoot = Join-Path $script:repoRoot 'source' 'web'

    function New-DpTestSkill {
        <#
            Writes a SKILL.md into <Root>/<Folder> and returns its path. UTF-8
            without a BOM, exactly as New-DpCustomization writes a scaffold.
        #>
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Folder,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Content
        )
        $dir = Join-Path $Root $Folder
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'SKILL.md'
        [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
        $path
    }

    function New-DpSkillRoot {
        param([string]$Name = ([guid]::NewGuid().ToString('N')))
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }

    function Get-DpCode {
        param($Result)
        @($Result.warnings | ForEach-Object { $_.code })
    }

    function Get-DpSkillItem {
        param($List, [string]$Name)
        ($List.categories | Where-Object id -EQ 'skill').items | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    }
}

Describe 'Get-DpSkillConformance' -Tag 'Unit' {

    Context 'A conformant Skill' {
        BeforeAll {
            $script:okRoot = New-DpSkillRoot
            $script:okPath = New-DpTestSkill -Root $script:okRoot -Folder 'pdf-processing' -Content @'
---
name: pdf-processing
description: Extract PDF text, fill forms, merge files. Use when handling PDFs.
---

# pdf-processing

MARKER-BODY-TEXT
'@
        }

        It 'surfaces the declared name and description' {
            $r = Get-DpSkillConformance -Path $script:okPath -Root $script:okRoot
            $r.name | Should -Be 'pdf-processing'
            $r.description | Should -Be 'Extract PDF text, fill forms, merge files. Use when handling PDFs.'
        }

        It 'reports no problems' {
            $r = Get-DpSkillConformance -Path $script:okPath -Root $script:okRoot
            @($r.warnings) | Should -BeNullOrEmpty
            $r.conformant | Should -BeTrue
        }

        It 'keeps the body out of the catalog metadata' {
            $r = Get-DpSkillConformance -Path $script:okPath -Root $script:okRoot
            $r.ContainsKey('body') | Should -BeFalse -Because 'progressive disclosure loads the body on activation, not while listing'
            ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'MARKER-BODY-TEXT'
        }

        It 'declares no optional field the Skill did not declare' {
            $r = Get-DpSkillConformance -Path $script:okPath -Root $script:okRoot
            foreach ($key in 'license', 'compatibility', 'version', 'origin', 'allowedTools') {
                $r.metadata.ContainsKey($key) | Should -BeFalse -Because "'$key' is absent from the file and must not be invented"
            }
        }
    }

    Context 'Declared optional fields' {
        BeforeAll {
            $script:optRoot = New-DpSkillRoot
            $script:optPath = New-DpTestSkill -Root $script:optRoot -Folder 'pdf-processing' -Content @'
---
name: pdf-processing
description: Extract PDF text. Use when handling PDFs.
license: Apache-2.0
compatibility: Requires Python 3.14+ and uv
metadata:
  author: example-org
  version: "1.0"
---

Body.
'@
        }

        It 'surfaces license, compatibility, version and origin' {
            $r = Get-DpSkillConformance -Path $script:optPath -Root $script:optRoot
            $r.metadata.license | Should -Be 'Apache-2.0'
            $r.metadata.compatibility | Should -Be 'Requires Python 3.14+ and uv'
            $r.metadata.version | Should -Be '1.0'
            $r.metadata.origin | Should -Be 'example-org'
        }

        It 'keeps the whole metadata mapping addressable' {
            $r = Get-DpSkillConformance -Path $script:optPath -Root $script:optRoot
            $r.metadata.entries.author | Should -Be 'example-org'
            $r.metadata.entries.version | Should -Be '1.0'
        }

        It 'accepts the documented optional fields without complaint' {
            (Get-DpSkillConformance -Path $script:optPath -Root $script:optRoot).conformant | Should -BeTrue
        }
    }

    Context 'Required fields' {
        It 'reports a missing name' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'no-name' -Content "---`ndescription: Something useful. Use when needed.`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'name-missing'
            $r.conformant | Should -BeFalse
        }

        It 'falls back to the directory name so the Skill is still identifiable' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'no-name' -Content "---`ndescription: Something useful.`n---`nBody."
            (Get-DpSkillConformance -Path $p -Root $root).name | Should -Be 'no-name'
        }

        It 'reports a missing or empty description' -ForEach @(
            @{ Front = "name: thing" }
            @{ Front = "name: thing`ndescription:" }
            @{ Front = "name: thing`ndescription: '   '" }
        ) {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'thing' -Content "---`n$Front`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'description-missing'
            $r.conformant | Should -BeFalse
        }
    }

    Context 'Documented field limits' {
        It 'reports a name over 64 characters' {
            $root = New-DpSkillRoot
            $long = 'a' * 65
            $p = New-DpTestSkill -Root $root -Folder $long -Content "---`nname: $long`ndescription: A description.`n---`nBody."
            Get-DpCode (Get-DpSkillConformance -Path $p -Root $root) | Should -Contain 'name-too-long'
        }

        It 'accepts a name of exactly 64 characters' {
            $root = New-DpSkillRoot
            $name = 'a' * 64
            $p = New-DpTestSkill -Root $root -Folder $name -Content "---`nname: $name`ndescription: A description.`n---`nBody."
            Get-DpCode (Get-DpSkillConformance -Path $p -Root $root) | Should -Not -Contain 'name-too-long'
        }

        It 'reports a description over 1024 characters and caps what it surfaces' {
            $root = New-DpSkillRoot
            $desc = 'd' * 5000
            $p = New-DpTestSkill -Root $root -Folder 'wordy' -Content "---`nname: wordy`ndescription: $desc`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'description-too-long'
            $r.description.Length | Should -BeLessOrEqual 1024 -Because 'an oversized value must not flood the catalog response'
        }

        It 'reports a compatibility value over 500 characters' {
            $root = New-DpSkillRoot
            $compat = 'c' * 501
            $p = New-DpTestSkill -Root $root -Folder 'compat' -Content "---`nname: compat`ndescription: A description.`ncompatibility: $compat`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'compatibility-too-long'
            $r.metadata.compatibility.Length | Should -BeLessOrEqual 500
        }
    }

    Context 'Name syntax' {
        It 'accepts <Name>' -ForEach @(
            @{ Name = 'pdf-processing' }
            @{ Name = 'data-analysis' }
            @{ Name = 'a' }
            @{ Name = 'a1-2b' }
        ) {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder $Name -Content "---`nname: $Name`ndescription: A description.`n---`nBody."
            Get-DpCode (Get-DpSkillConformance -Path $p -Root $root) | Should -Not -Contain 'name-invalid'
        }

        It 'refuses <Name>' -ForEach @(
            @{ Name = 'PDF-Processing' }
            @{ Name = '-pdf' }
            @{ Name = 'pdf-' }
            @{ Name = 'pdf--processing' }
            @{ Name = 'pdf_processing' }
            @{ Name = 'pdf processing' }
            @{ Name = 'pdf/processing' }
        ) {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'holder' -Content "---`nname: $Name`ndescription: A description.`n---`nBody."
            Get-DpCode (Get-DpSkillConformance -Path $p -Root $root) | Should -Contain 'name-invalid'
        }

        It 'reports a name that does not match its directory' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'pdf-tools' -Content "---`nname: pdf-processing`ndescription: A description.`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'name-directory-mismatch'
            $r.directory | Should -Be 'pdf-tools'
        }
    }

    Context 'Malformed frontmatter' {
        It 'reports a file with no frontmatter at all' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'bare' -Content "# Just Markdown`n`nNo frontmatter here."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'frontmatter-missing'
            $r.name | Should -Be 'bare' -Because 'the Skill must stay identifiable so the user can repair it'
        }

        It 'reports an unterminated frontmatter block' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'unterminated' -Content "---`nname: unterminated`ndescription: Never closed.`n`nBody without a closing fence."
            Get-DpCode (Get-DpSkillConformance -Path $p -Root $root) | Should -Contain 'frontmatter-malformed'
        }

        It 'never throws on an unreadable or missing file' {
            $root = New-DpSkillRoot
            $r = Get-DpSkillConformance -Path (Join-Path $root 'ghost/SKILL.md') -Root $root
            $r | Should -Not -BeNullOrEmpty
            Get-DpCode $r | Should -Contain 'unreadable'
        }
    }

    Context 'Unsupported optional field types' {
        It 'reports a metadata value that is not a mapping' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'flat' -Content "---`nname: flat`ndescription: A description.`nmetadata: just-a-string`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'metadata-not-a-map'
            $r.metadata.ContainsKey('entries') | Should -BeFalse
        }

        It 'reports a metadata entry whose value is not a string' {
            $root = New-DpSkillRoot
            $content = "---`nname: nested`ndescription: A description.`nmetadata:`n  authors:`n    - one`n    - two`n---`nBody."
            $p = New-DpTestSkill -Root $root -Folder 'nested' -Content $content
            Get-DpCode (Get-DpSkillConformance -Path $p -Root $root) | Should -Contain 'metadata-value-not-a-string'
        }

        It 'reports allowed-tools declared as a sequence rather than a string' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'seq' -Content "---`nname: seq`ndescription: A description.`nallowed-tools: [Read, Bash]`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'allowed-tools-not-a-string'
            $r.metadata.ContainsKey('allowedTools') | Should -BeFalse
        }

        It 'reports a field the specification does not define' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'extra' -Content "---`nname: extra`ndescription: A description.`nmodel: gpt-5`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'field-unsupported'
            ($r.warnings | Where-Object code -EQ 'field-unsupported').message | Should -Match 'model'
        }

        It 'still surfaces a top-level version or author while flagging the placement' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'legacy' -Content "---`nname: legacy`ndescription: A description.`nversion: 2.1`nauthor: contoso`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            $r.metadata.version | Should -Be '2.1'
            $r.metadata.origin | Should -Be 'contoso'
            Get-DpCode $r | Should -Contain 'field-unsupported'
        }
    }

    Context 'allowed-tools is descriptive only' {
        BeforeAll {
            $script:atRoot = New-DpSkillRoot
            $script:atPath = New-DpTestSkill -Root $script:atRoot -Folder 'tooled' -Content "---`nname: tooled`ndescription: A description.`nallowed-tools: Bash(rm:*) Read`n---`nBody."
        }

        It 'surfaces the declared string verbatim' {
            (Get-DpSkillConformance -Path $script:atPath -Root $script:atRoot).metadata.allowedTools | Should -Be 'Bash(rm:*) Read'
        }

        It 'marks the field non-authoritative' {
            (Get-DpSkillConformance -Path $script:atPath -Root $script:atRoot).metadata.allowedToolsAuthoritative | Should -BeFalse
        }

        It 'says so in a diagnostic rather than leaving the reader to assume' {
            $r = Get-DpSkillConformance -Path $script:atPath -Root $script:atRoot
            Get-DpCode $r | Should -Contain 'allowed-tools-not-a-permission'
            ($r.warnings | Where-Object code -EQ 'allowed-tools-not-a-permission').severity | Should -Be 'info'
        }

        It 'leaves the Skill conformant - a declared allowed-tools is legal' {
            (Get-DpSkillConformance -Path $script:atPath -Root $script:atRoot).conformant | Should -BeTrue
        }

        It 'is read by nothing that grants a Permission' {
            # A static guard: the only places allowed-tools may appear are the
            # scanner that reads it, the surface that displays it, its tests and
            # its documentation. A grant path would have to add a fifth.
            $allowed = @(
                'source/Private/Get-DpSkillConformance.ps1'
                'source/web/assets/app.js'
                'source/web/assets/locales/en.js'
                'source/web/assets/locales/de.js'
                'source/web/index.html'
                'tests/Unit/SkillConformance.Tests.ps1'
                'tests/Unit/skill-conformance-ui.test.mjs'
                'docs/skill-compatibility.md'
                'specs/030-api-contract.md'
            )
            $hits = Get-ChildItem -Path (Join-Path $script:repoRoot 'source'), (Join-Path $script:repoRoot 'tests'), (Join-Path $script:repoRoot 'docs'), (Join-Path $script:repoRoot 'specs') -Recurse -File -Include '*.ps1', '*.psm1', '*.js', '*.mjs', '*.html', '*.md' |
                Select-String -Pattern 'allowedTools|allowed-tools' -List |
                ForEach-Object { $_.Path.Substring($script:repoRoot.Length).TrimStart('\', '/').Replace('\', '/') }
            @($hits | Where-Object { $allowed -notcontains $_ }) | Should -BeNullOrEmpty -Because 'allowed-tools is experimental metadata, never an authority'
        }
    }

    Context 'Hostile and oversized input' {
        It 'strips control characters out of a surfaced value and reports it' {
            $root = New-DpSkillRoot
            $desc = "Legit text{0}{1} and more" -f [char]7, [char]27
            $p = New-DpTestSkill -Root $root -Folder 'hostile' -Content "---`nname: hostile`ndescription: $desc`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'value-control-characters'
            ($r.description.ToCharArray() | Where-Object { [char]::IsControl($_) }) | Should -BeNullOrEmpty
        }

        It 'reads only a bounded head of an oversized file' {
            $root = New-DpSkillRoot
            $body = 'x' * 4000
            $p = New-DpTestSkill -Root $root -Folder 'huge' -Content "---`nname: huge`ndescription: A description.`n---`n$body"
            $r = Get-DpSkillConformance -Path $p -Root $root -MaxBytes 200
            Get-DpCode $r | Should -Contain 'file-too-large'
            $r.description | Should -Be 'A description.' -Because 'the frontmatter is inside the bounded head and still parses'
        }

        It 'reports a frontmatter block with more lines than it will scan' {
            $root = New-DpSkillRoot
            $filler = (1..40 | ForEach-Object { "key$_`: value$_" }) -join "`n"
            $p = New-DpTestSkill -Root $root -Folder 'verbose' -Content "---`nname: verbose`ndescription: A description.`n$filler`n---`nBody."
            Get-DpCode (Get-DpSkillConformance -Path $p -Root $root -MaxFrontmatterLines 10) | Should -Contain 'frontmatter-too-long'
        }

        It 'caps how many diagnostics one Skill can produce' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'Broken Thing' -Content "---`nname: -Broken--Name-`nmodel: x`nmetadata: flat`nallowed-tools: [a]`n---`nBody."
            @((Get-DpSkillConformance -Path $p -Root $root -MaxWarnings 3).warnings).Count | Should -BeLessOrEqual 3
        }

        It 'bounds the metadata mapping it copies' {
            $root = New-DpSkillRoot
            $entries = (1..50 | ForEach-Object { "  k$_`: v$_" }) -join "`n"
            $p = New-DpTestSkill -Root $root -Folder 'many' -Content "---`nname: many`ndescription: A description.`nmetadata:`n$entries`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            $r.metadata.entries.Count | Should -BeLessOrEqual 32
            Get-DpCode $r | Should -Contain 'metadata-too-many-entries'
        }
    }

    Context 'Progressive disclosure and inert scanning' {
        BeforeAll {
            $script:pdRoot = New-DpSkillRoot
            $script:pdPath = New-DpTestSkill -Root $script:pdRoot -Folder 'layered' -Content "---`nname: layered`ndescription: A description. See [guide](references/REFERENCE.md).`n---`nBody with https://example.invalid/should-not-be-fetched"
            $skillDir = Split-Path -Parent $script:pdPath
            New-Item -ItemType Directory -Path (Join-Path $skillDir 'references'), (Join-Path $skillDir 'scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $skillDir 'references/REFERENCE.md') -Value 'MARKER-REFERENCE-BODY' -NoNewline
            Set-Content -LiteralPath (Join-Path $skillDir 'scripts/run.ps1') -Value 'throw "MARKER-SCRIPT-RAN"' -NoNewline
        }

        It 'notes which resource folders exist' {
            $r = Get-DpSkillConformance -Path $script:pdPath -Root $script:pdRoot
            $r.resources.references | Should -BeTrue
            $r.resources.scripts | Should -BeTrue
            $r.resources.assets | Should -BeFalse
        }

        It 'never reads a referenced file or runs a script while scanning' {
            $json = Get-DpSkillConformance -Path $script:pdPath -Root $script:pdRoot | ConvertTo-Json -Depth 10
            $json | Should -Not -Match 'MARKER-REFERENCE-BODY'
            $json | Should -Not -Match 'MARKER-SCRIPT-RAN'
        }
    }

    Context 'Link and root confinement' {
        BeforeAll {
            # One external Skill, seeded with sentinels in every field a scan
            # could leak: the name, the description, an optional field and the
            # body. Nothing from this file may reach a caller.
            $script:outsideRoot = New-DpSkillRoot 'outside-tree'
            $script:outsidePath = New-DpTestSkill -Root $script:outsideRoot -Folder 'real' -Content @'
---
name: leaked-outside-name
description: LEAKED-DESCRIPTION-SENTINEL
license: LEAKED-LICENSE-SENTINEL
---

LEAKED-BODY-SENTINEL
'@
            $outsideDir = Split-Path -Parent $script:outsidePath
            New-Item -ItemType Directory -Path (Join-Path $outsideDir 'references') -Force | Out-Null
        }

        It 'refuses a SKILL.md that is a link out of the configured root' -Skip:(-not $script:canSymlink) {
            $root = New-DpSkillRoot
            $linkDir = Join-Path $root 'linked'
            New-Item -ItemType Directory -Path $linkDir -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $linkDir 'SKILL.md') -Target $script:outsidePath -ErrorAction Stop | Out-Null
            $r = Get-DpSkillConformance -Path (Join-Path $linkDir 'SKILL.md') -Root $root
            Get-DpCode $r | Should -Contain 'link-below-root'
            $r.conformant | Should -BeFalse
        }

        It 'leaks nothing from the external target it refused' -Skip:(-not $script:canSymlink) {
            $root = New-DpSkillRoot
            $linkDir = Join-Path $root 'linked'
            New-Item -ItemType Directory -Path $linkDir -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $linkDir 'SKILL.md') -Target $script:outsidePath -ErrorAction Stop | Out-Null
            $r = Get-DpSkillConformance -Path (Join-Path $linkDir 'SKILL.md') -Root $root

            $r.name | Should -Be 'linked' -Because 'the folder inside the root names it, never the file outside'
            $r.declaredName | Should -BeNullOrEmpty
            $r.description | Should -BeNullOrEmpty
            $r.metadata.Count | Should -Be 0
            $r.resources.references | Should -BeFalse -Because 'a refused Skill is not probed for resources either'
            ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'LEAKED-'
        }

        It 'proves confinement before it opens the file' -Skip:(-not $script:canSymlink) {
            $root = New-DpSkillRoot
            $linkDir = Join-Path $root 'linked'
            New-Item -ItemType Directory -Path $linkDir -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $linkDir 'SKILL.md') -Target $script:outsidePath -ErrorAction Stop | Out-Null

            # Hold the external target exclusively. Any attempt to read it would
            # fail and be reported as 'unreadable', so the refusal code is proof
            # that the check ran first and no read was attempted.
            $held = [System.IO.File]::Open($script:outsidePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                $codes = Get-DpCode (Get-DpSkillConformance -Path (Join-Path $linkDir 'SKILL.md') -Root $root)
                $codes | Should -Contain 'link-below-root'
                $codes | Should -Not -Contain 'unreadable'
            }
            finally { $held.Dispose() }
        }

        It 'refuses a Skill reached through a linked sub-folder without reading it' {
            $root = New-DpSkillRoot
            New-Item -ItemType $script:directoryLinkType -Path (Join-Path $root 'linked') -Target (Split-Path -Parent $script:outsidePath) -ErrorAction Stop | Out-Null

            # Reached through a junction the leaf is an ordinary file with a real
            # size, so this is where an early read would actually happen. Holding
            # it exclusively turns "did not read" into something observable.
            $held = [System.IO.File]::Open($script:outsidePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                $r = Get-DpSkillConformance -Path (Join-Path $root 'linked/SKILL.md') -Root $root
                $codes = Get-DpCode $r
                $codes | Should -Contain 'link-below-root' -Because 'an ancestor link escapes just as surely as the leaf does'
                $codes | Should -Not -Contain 'unreadable' -Because 'nothing was opened, so nothing could fail to open'
                $r.name | Should -Be 'linked'
                $r.declaredName | Should -BeNullOrEmpty
                $r.description | Should -BeNullOrEmpty
                $r.metadata.Count | Should -Be 0
                $r.resources.references | Should -BeFalse
                $r.conformant | Should -BeFalse
                ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'LEAKED-'
            }
            finally { $held.Dispose() }
        }

        It 'refuses a link whose target only looks like it is inside the root' -Skip:(-not $script:canSymlink) {
            # The leaf points at a path under the root - and that path is itself a
            # junction leading out. Judging the target by how it reads would let
            # this through; refusing the link outright does not.
            $root = New-DpSkillRoot
            New-Item -ItemType $script:directoryLinkType -Path (Join-Path $root 'relay') -Target (Split-Path -Parent $script:outsidePath) -ErrorAction Stop | Out-Null
            $linkDir = Join-Path $root 'linked'
            New-Item -ItemType Directory -Path $linkDir -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $linkDir 'SKILL.md') -Target (Join-Path $root 'relay/SKILL.md') -ErrorAction Stop | Out-Null

            $r = Get-DpSkillConformance -Path (Join-Path $linkDir 'SKILL.md') -Root $root
            Get-DpCode $r | Should -Contain 'link-below-root'
            $r.description | Should -BeNullOrEmpty
            ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'LEAKED-'
        }

        It 'refuses a dangling link without resolving it' -Skip:(-not $script:canSymlink) {
            $root = New-DpSkillRoot
            $linkDir = Join-Path $root 'dangling'
            New-Item -ItemType Directory -Path $linkDir -Force | Out-Null
            $inside = New-DpTestSkill -Root $root -Folder 'temporary' -Content "---`nname: temporary`ndescription: A description.`n---`nBody."
            New-Item -ItemType SymbolicLink -Path (Join-Path $linkDir 'SKILL.md') -Target $inside -ErrorAction Stop | Out-Null
            Remove-Item -LiteralPath $inside -Force
            $r = Get-DpSkillConformance -Path (Join-Path $linkDir 'SKILL.md') -Root $root
            Get-DpCode $r | Should -Contain 'link-below-root'
            $r.conformant | Should -BeFalse
        }

        It 'refuses a path that is not inside the configured root at all' {
            $root = New-DpSkillRoot
            $held = [System.IO.File]::Open($script:outsidePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                $r = Get-DpSkillConformance -Path $script:outsidePath -Root $root
                $codes = Get-DpCode $r
                $codes | Should -Contain 'path-outside-root'
                $codes | Should -Not -Contain 'unreadable' -Because 'containment is settled before anything is opened'
                $r.description | Should -BeNullOrEmpty
                $r.metadata.Count | Should -Be 0
                ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'LEAKED-'
            }
            finally { $held.Dispose() }
        }

        It 'compares paths case-insensitively only on Windows' {
            # A confinement boundary must not treat a case-spelling alias as the
            # same folder anywhere a file system might disagree. Windows is the
            # one platform where case-insensitive comparison is guaranteed
            # correct. Everywhere else - macOS included, whose volumes can be
            # formatted case-sensitively - the exact comparison is the safe one:
            # refusing a case-spelling alias costs a diagnostic, reading a
            # different directory costs confinement.
            $source = Get-Content -LiteralPath (Join-Path $script:repoRoot 'source' 'Private' 'Get-DpSkillConformance.ps1') -Raw
            $source | Should -Match '\$pathCase\s*=\s*if\s*\(\s*\$null\s*-eq\s*\$IsWindows\s*-or\s*\$IsWindows\s*\)'
            $source | Should -Match '\[System\.StringComparison\]::OrdinalIgnoreCase'
            $source | Should -Match '\[System\.StringComparison\]::Ordinal\b'
            $source | Should -Not -Match 'IsMacOS' -Because 'a case-insensitive macOS volume is a default, not a guarantee'
        }

        It 'treats a case-distinct folder as a different folder where the file system does' -Skip:(-not $script:caseSensitiveFs) {
            # On a case-sensitive file system /tmp/Skills-private and
            # /tmp/skills-private are two folders. Comparing them case-blind
            # would accept a Skill the configured root never covered.
            $configured = Join-Path $TestDrive 'Skills-private'
            $other = Join-Path $TestDrive 'skills-private'
            New-Item -ItemType Directory -Path $configured, $other -Force | Out-Null
            $outside = New-DpTestSkill -Root $other -Folder 'sneaky' -Content "---`nname: sneaky`ndescription: LEAKED-CASE-SENTINEL.`n---`nBody."
            $r = Get-DpSkillConformance -Path $outside -Root $configured
            Get-DpCode $r | Should -Contain 'path-outside-root'
            ($r | ConvertTo-Json -Depth 10) | Should -Not -Match 'LEAKED-'
        }

        It 'stays quiet about links when nothing is linked' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'plain' -Content "---`nname: plain`ndescription: A description of what this does and when to use it.`n---`nBody."
            $codes = Get-DpCode (Get-DpSkillConformance -Path $p -Root $root)
            $codes | Should -Not -Contain 'link-below-root'
            $codes | Should -Not -Contain 'path-outside-root'
        }

        It 'accepts a configured root that is itself a directory link' {
            $real = New-DpSkillRoot 'junctioned-real'
            New-DpTestSkill -Root $real -Folder 'pdf-processing' -Content "---`nname: pdf-processing`ndescription: Extract PDF text. Use when handling PDFs.`n---`nBody." | Out-Null
            $configured = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType $script:directoryLinkType -Path $configured -Target $real -ErrorAction Stop | Out-Null
            $r = Get-DpSkillConformance -Path (Join-Path $configured 'pdf-processing/SKILL.md') -Root $configured
            Get-DpCode $r | Should -Not -Contain 'link-below-root' -Because 'the user configured this root; DeskPilot does not second-guess it'
            $r.description | Should -Be 'Extract PDF text. Use when handling PDFs.'
        }
    }

    Context 'Conformance is decided by what was found' {
        It 'does not call a Skill with a broken name conformant' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'holder' -Content "---`nname: Bad_Name`ndescription: A description of what this does and when to use it.`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'name-invalid'
            $r.conformant | Should -BeFalse -Because 'a name the specification refuses is a violation, not a note'
        }

        It 'does not call a Skill that disagrees with its folder conformant' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'pdf-tools' -Content "---`nname: pdf-processing`ndescription: A description of what this does and when to use it.`n---`nBody."
            (Get-DpSkillConformance -Path $p -Root $root).conformant | Should -BeFalse
        }

        It 'does not let the diagnostic budget hide a failure' {
            $root = New-DpSkillRoot
            # The invalid name fills a one-slot budget; the missing description
            # never reaches the returned list. It still decides conformance.
            $p = New-DpTestSkill -Root $root -Folder 'holder' -Content "---`nname: Bad_Name`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root -MaxWarnings 1
            @($r.warnings).Count | Should -Be 1
            @($r.warnings | ForEach-Object { $_.code }) | Should -Not -Contain 'description-missing'
            $r.conformant | Should -BeFalse -Because 'a finding that did not fit on screen still happened'
        }

        It 'does not certify a Skill it could not read in full' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'huge' -Content ("---`nname: huge`ndescription: A description of what this does and when to use it.`n---`n" + ('x' * 4000))
            $r = Get-DpSkillConformance -Path $p -Root $root -MaxBytes 200
            Get-DpCode $r | Should -Contain 'file-too-large'
            $r.conformant | Should -BeFalse -Because 'DeskPilot cannot vouch for the part it never read'
        }

        It 'keeps advice non-failing' -ForEach @(
            @{ Case = 'terse description'; Front = "name: advice`ndescription: Short." }
            @{ Case = 'declared allowed-tools'; Front = "name: advice`ndescription: A description of what this does and when to use it.`nallowed-tools: Read" }
            @{ Case = 'an undefined field'; Front = "name: advice`ndescription: A description of what this does and when to use it.`nmodel: gpt-5" }
        ) {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'advice' -Content "---`n$Front`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            @($r.warnings | Where-Object { $_.severity -ne 'info' }) | Should -BeNullOrEmpty
            $r.conformant | Should -BeTrue -Because "$Case is advice, not a violation"
        }
    }

    Context 'Scalar fields the limited reader cannot interpret' {
        It 'refuses a flow <Form> where <Field> must be a scalar' -ForEach @(
            @{ Field = 'license'; Form = 'sequence'; Raw = 'license: [MIT, Apache-2.0]' }
            @{ Field = 'license'; Form = 'mapping'; Raw = 'license: { name: MIT }' }
            @{ Field = 'compatibility'; Form = 'sequence'; Raw = 'compatibility: [git, docker]' }
        ) {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'flow' -Content "---`nname: flow`ndescription: A description of what this does and when to use it.`n$Raw`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'value-not-a-scalar'
            $r.metadata.ContainsKey($Field) | Should -BeFalse -Because 'a value DeskPilot cannot read must not be shown as if it were text'
            $r.conformant | Should -BeFalse
        }

        It 'refuses a block scalar on a field the reader does not fold' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'block' -Content "---`nname: block`ndescription: A description of what this does and when to use it.`nlicense: |`n  Proprietary.`n  See LICENSE.txt.`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'value-not-a-scalar'
            $r.metadata.ContainsKey('license') | Should -BeFalse
            ($r | ConvertTo-Json -Depth 10) | Should -Not -Match '\|'
        }

        It 'refuses a name that is not a plain scalar' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'holder' -Content "---`nname: [one, two]`ndescription: A description of what this does and when to use it.`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'value-not-a-scalar'
            $r.name | Should -Be 'holder' -Because 'an unreadable name falls back to the folder, like a missing one'
            $r.declaredName | Should -BeNullOrEmpty
        }

        It 'refuses a description that is a flow sequence' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'holder' -Content "---`nname: holder`ndescription: [one, two]`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'value-not-a-scalar'
            $r.description | Should -BeNullOrEmpty
        }

        It 'still folds a block-scalar description through the existing reader' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'folded' -Content "---`nname: folded`ndescription: >-`n  Extract text from PDF files.`n  Use when the user mentions PDFs or forms.`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            $r.description | Should -Be 'Extract text from PDF files. Use when the user mentions PDFs or forms.'
            Get-DpCode $r | Should -Not -Contain 'value-not-a-scalar' -Because 'the existing parser folds this form; nothing new was written for it'
            $r.conformant | Should -BeTrue
        }

        It 'refuses allowed-tools declared as a flow mapping' {
            $root = New-DpSkillRoot
            $p = New-DpTestSkill -Root $root -Folder 'flowtools' -Content "---`nname: flowtools`ndescription: A description of what this does and when to use it.`nallowed-tools: { bash: true }`n---`nBody."
            $r = Get-DpSkillConformance -Path $p -Root $root
            Get-DpCode $r | Should -Contain 'allowed-tools-not-a-string'
            $r.metadata.ContainsKey('allowedTools') | Should -BeFalse
        }
    }
}

Describe 'Get-DpCustomizationList with Skill conformance' -Tag 'Unit' {

    BeforeAll {
        $script:lRootA = New-DpSkillRoot 'skills-a'
        $script:lRootB = New-DpSkillRoot 'skills-b'
        $script:lAgents = New-DpSkillRoot 'agents'
        Set-Content -LiteralPath (Join-Path $script:lAgents 'legal.agent.md') -Value "---`nname: Legal`ndescription: Law.`n---`nBody." -NoNewline

        New-DpTestSkill -Root $script:lRootA -Folder 'pdf-processing' -Content "---`nname: pdf-processing`ndescription: Extract PDF text. Use when handling PDFs.`nlicense: MIT`n---`nMARKER-LIST-BODY" | Out-Null
        New-DpTestSkill -Root $script:lRootA -Folder 'broken' -Content "---`nname: broken`nno closing fence here" | Out-Null
        New-DpTestSkill -Root $script:lRootB -Folder 'pdf-processing' -Content "---`nname: pdf-processing`ndescription: A second copy in another root.`n---`nBody." | Out-Null

        $script:lSettings = @{
            agentsRoot       = $script:lAgents
            skillRoots       = @($script:lRootA, $script:lRootB)
            instructionRoots = @()
            promptRoots      = @()
        }
        $script:lList = Get-DpCustomizationList -Settings $script:lSettings -HomeDirectory $TestDrive
    }

    It 'keeps every field existing consumers already read' {
        $item = Get-DpSkillItem $script:lList 'broken'
        foreach ($key in 'id', 'category', 'name', 'description', 'path', 'root', 'scope') {
            $item.ContainsKey($key) | Should -BeTrue -Because "'$key' is part of the published contract"
        }
    }

    It 'attaches Skill metadata to a Skill item' {
        $item = ($script:lList.categories | Where-Object id -EQ 'skill').items |
            Where-Object { $_.root -eq $script:lRootA -and $_.name -eq 'pdf-processing' } | Select-Object -First 1
        $item.metadata.license | Should -Be 'MIT'
        $item.conformant | Should -BeTrue
    }

    It 'leaves the other categories untouched' {
        $agent = ($script:lList.categories | Where-Object id -EQ 'agent').items[0]
        $agent.ContainsKey('warnings') | Should -BeFalse
        $agent.ContainsKey('metadata') | Should -BeFalse
    }

    It 'lists a malformed Skill instead of dropping it' {
        $item = Get-DpSkillItem $script:lList 'broken'
        $item | Should -Not -BeNullOrEmpty
        @($item.warnings | ForEach-Object { $_.code }) | Should -Contain 'frontmatter-malformed'
        $item.conformant | Should -BeFalse
    }

    It 'keeps a malformed Skill readable so the user can repair it' {
        $item = Get-DpSkillItem $script:lList 'broken'
        $content = Get-DpCustomizationContent -Settings $script:lSettings -Category 'skill' -Path $item.path
        $content.error | Should -BeNullOrEmpty
        $content.text | Should -Match 'no closing fence'
    }

    It 'keeps the body out of the catalog' {
        ($script:lList | ConvertTo-Json -Depth 12) | Should -Not -Match 'MARKER-LIST-BODY'
    }

    It 'reports a duplicate identity on both copies' {
        $copies = @(($script:lList.categories | Where-Object id -EQ 'skill').items | Where-Object { $_.name -eq 'pdf-processing' })
        $copies.Count | Should -Be 2
        foreach ($copy in $copies) {
            @($copy.warnings | ForEach-Object { $_.code }) | Should -Contain 'duplicate-name'
        }
    }

    It 'gives the configured root order a visible precedence' {
        $copies = @(($script:lList.categories | Where-Object id -EQ 'skill').items | Where-Object { $_.name -eq 'pdf-processing' })
        ($copies | Where-Object { $_.root -eq $script:lRootA }).precedence | Should -Be 'primary'
        ($copies | Where-Object { $_.root -eq $script:lRootB }).precedence | Should -Be 'shadowed'
    }

    It 'says plainly that DeskPilot listing order is not Engine discovery order' {
        $copy = @(($script:lList.categories | Where-Object id -EQ 'skill').items | Where-Object { $_.root -eq $script:lRootB })[0]
        ($copy.warnings | Where-Object code -EQ 'duplicate-name').message | Should -Match 'Engine'
    }

    It 'marks a single unambiguous Skill as primary' {
        (Get-DpSkillItem $script:lList 'broken').precedence | Should -Be 'primary'
    }

    It 'keeps the existing deterministic order' {
        $names = @(($script:lList.categories | Where-Object id -EQ 'skill').items | ForEach-Object { $_.name })
        $names | Should -Be @($names | Sort-Object)
    }

    It 'does not traverse a junction that points out of the root' {
        $root = New-DpSkillRoot
        $outside = New-DpSkillRoot 'junction-target'
        New-DpTestSkill -Root $outside -Folder 'smuggled' -Content "---`nname: smuggled`ndescription: Outside the root.`n---`nBody." | Out-Null
        New-Item -ItemType $script:directoryLinkType -Path (Join-Path $root 'link') -Target $outside -ErrorAction Stop | Out-Null
        $list = Get-DpCustomizationList -Settings @{ agentsRoot = $null; skillRoots = @($root); instructionRoots = @(); promptRoots = @() } -HomeDirectory $TestDrive
        @(($list.categories | Where-Object id -EQ 'skill').items | Where-Object { $_.name -eq 'smuggled' }) | Should -BeNullOrEmpty
    }

    It 'does not widen the configured roots' {
        $before = @(Get-DpCustomizationRoot -Settings $script:lSettings -Category 'skill')
        $null = Get-DpCustomizationList -Settings $script:lSettings -HomeDirectory $TestDrive
        $after = @(Get-DpCustomizationRoot -Settings $script:lSettings -Category 'skill')
        $after | Should -Be $before
        $script:lSettings.skillRoots.Count | Should -Be 2
    }
}

Describe 'Skill conformance surface' -Tag 'Unit' {

    BeforeAll {
        $script:appJs = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $script:indexHtml = Get-Content -LiteralPath (Join-Path $script:webRoot 'index.html') -Raw

        function Get-DpLocaleKeys {
            param([string]$Locale)
            $raw = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'locales' "$Locale.js") -Raw
            @([regex]::Matches($raw, "(?m)^\s{4}'([^']+)':") | ForEach-Object { $_.Groups[1].Value })
        }
    }

    It 'renders the conformance panel from the catalog it already loaded' {
        $script:appJs | Should -Match 'function custSkillMetaLines\('
        $script:appJs | Should -Match 'function custSkillDiagnosticLines\('
        $script:appJs | Should -Match 'function custSkillPrecedenceLine\('
        $script:indexHtml | Should -Match 'id="cust-editor-conformance"'
    }

    It 'writes Skill metadata as text, never as markup' {
        $start = $script:appJs.IndexOf('// ===== Skill conformance display =====')
        $end = $script:appJs.IndexOf('// ===== end Skill conformance display =====')
        $start | Should -BeGreaterThan 0
        $end | Should -BeGreaterThan $start
        $block = $script:appJs.Substring($start, $end - $start)
        $block | Should -Not -Match 'innerHTML'
        $script:appJs | Should -Not -Match 'cust-editor-conformance.*innerHTML ='
    }

    It 'localizes every Skill string it renders' {
        $en = Get-DpLocaleKeys -Locale 'en'
        $de = Get-DpLocaleKeys -Locale 'de'
        $used = @([regex]::Matches($script:appJs, "tr\('(skill\.[^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $used.Count | Should -BeGreaterThan 5
        foreach ($key in $used) {
            # A plural key lives in the catalog as <key>.one / <key>.other.
            $forms = if ($en -contains $key) { @($key) } else { @("$key.one", "$key.other") }
            foreach ($form in $forms) {
                $en | Should -Contain $form
                $de | Should -Contain $form
            }
        }
    }

    It 'ships a localized message for every diagnostic code the scanner emits' {
        $scanner = Get-Content -LiteralPath (Join-Path $script:repoRoot 'source' 'Private' 'Get-DpSkillConformance.ps1') -Raw
        $list = Get-Content -LiteralPath (Join-Path $script:repoRoot 'source' 'Private' 'Get-DpCustomizationList.ps1') -Raw
        $codes = @([regex]::Matches(($scanner + $list), "(?:-Code\s+|code\s*=\s*)'([a-z][a-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $codes.Count | Should -BeGreaterThan 10
        $en = Get-DpLocaleKeys -Locale 'en'
        $de = Get-DpLocaleKeys -Locale 'de'
        foreach ($code in $codes) {
            $en | Should -Contain "skill.warn.$code"
            $de | Should -Contain "skill.warn.$code"
        }
    }

    It 'states that allowed-tools grants nothing, in both languages' {
        foreach ($locale in 'en', 'de') {
            (Get-DpLocaleKeys -Locale $locale) | Should -Contain 'skill.meta.allowedTools.note'
        }
    }
}

Describe 'Skill compatibility documentation' -Tag 'Unit' {
    BeforeAll {
        $script:docPath = Join-Path $script:repoRoot 'docs' 'skill-compatibility.md'
    }

    It 'exists' {
        Test-Path -LiteralPath $script:docPath -PathType Leaf | Should -BeTrue
    }

    It 'documents the supported subset, the limits and how to back out' {
        $doc = Get-Content -LiteralPath $script:docPath -Raw
        $doc | Should -Match '(?im)^##\s+.*supported'
        $doc | Should -Match '(?im)^##\s+.*limitation'
        $doc | Should -Match '(?im)^##\s+.*(migration|rollback)'
        $doc | Should -Match 'agentskills\.io/specification'
    }

    It 'says that allowed-tools is descriptive and grants no Permission' {
        (Get-Content -LiteralPath $script:docPath -Raw) | Should -Match '(?s)allowed-tools.{0,400}(no Permission|grants nothing|not a Permission)'
    }

    It 'points at the existing eval harness for trigger evaluation and claims no improvement' {
        $doc = Get-Content -LiteralPath $script:docPath -Raw
        $doc | Should -Match 'Invoke-DpParityEval'
        $doc | Should -Match '(?i)no.{0,40}(trigger|activation).{0,40}(rate|improvement)|not measured|no measured'
    }
}
