#requires -Version 7.0

# Guards for the web/ assets that are bundled into the module and published to
# the PowerShell Gallery (see build.yaml CopyPaths). These tests read the SOURCE
# assets under source/web, which is exactly what ModuleBuilder copies.

Describe 'Web assets bundle' -Tag 'Unit' {
    BeforeAll {
        $script:webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
    }

    It 'has index.html at the web root' {
        Test-Path -LiteralPath (Join-Path $script:webRoot 'index.html') -PathType Leaf | Should -BeTrue
    }

    It 'has the core SPA files under assets/' {
        foreach ($name in 'app.js', 'attachments.js', 'markdown.js', 'styles.css') {
            Test-Path -LiteralPath (Join-Path $script:webRoot 'assets' $name) -PathType Leaf | Should -BeTrue
        }
    }

    It 'extracts clipboard files without intercepting text-only paste data' {
        $modulePath = Join-Path $script:webRoot 'assets' 'attachments.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { getClipboardFiles, getImagePaths, wireClipboardAttachments } = await import(pathToFileURL(process.argv[1]).href);
const screenshot = { name: 'image.png', type: 'image/png' };
const documentFile = { name: 'brief.pdf', type: 'application/pdf' };

assert.deepEqual(getClipboardFiles({ files: [screenshot], items: [] }), [screenshot]);
assert.deepEqual(getClipboardFiles({
    files: [],
    items: [
        { kind: 'string', getAsFile: () => null },
        { kind: 'file', getAsFile: () => documentFile },
    ],
}), [documentFile]);
assert.deepEqual(getClipboardFiles({ files: [], items: [{ kind: 'string' }] }), []);
assert.deepEqual(getImagePaths([
    { path: 'C:/uploads/image.png', contentType: 'image/png' },
    { path: 'C:/uploads/brief.pdf', contentType: 'application/pdf' },
]), ['C:/uploads/image.png']);

let pasteHandler;
const uploaded = [];
const target = { addEventListener: (name, handler) => { if (name === 'paste') pasteHandler = handler; } };
wireClipboardAttachments(target, (files) => uploaded.push(...files));

let prevented = false;
pasteHandler({ clipboardData: { files: [screenshot] }, preventDefault: () => { prevented = true; } });
assert.equal(prevented, true);
assert.deepEqual(uploaded, [screenshot]);

prevented = false;
pasteHandler({ clipboardData: { files: [], items: [{ kind: 'string' }] }, preventDefault: () => { prevented = true; } });
assert.equal(prevented, false);
assert.deepEqual(uploaded, [screenshot]);
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }
}

Describe 'Web asset reference casing' -Tag 'Unit' {
    # Linux install paths are case-sensitive. An href/src/srcset/url() that
    # disagrees with the on-disk filename works on Windows/macOS but 404s on a
    # Gallery install running on Linux. Assert every LOCAL, relative asset
    # reference in the HTML/CSS resolves with EXACT case. (Inter-module ESM
    # imports are validated separately by the app.js ESM check.)
    BeforeAll {
        $script:webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
    }

    It 'references every local asset with its exact on-disk case' {
        $textFiles = Get-ChildItem -LiteralPath $script:webRoot -Recurse -File |
            Where-Object { $_.Extension -in '.html', '.css' }

        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $textFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $found = [System.Collections.Generic.List[string]]::new()

            foreach ($m in [regex]::Matches($content, '(?:href|src)\s*=\s*"([^"]+)"|(?:href|src)\s*=\s*''([^'']+)''')) {
                $found.Add($(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }))
            }
            foreach ($m in [regex]::Matches($content, 'srcset\s*=\s*"([^"]+)"|srcset\s*=\s*''([^'']+)''')) {
                $set = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                foreach ($cand in ($set -split ',')) {
                    $url = ($cand.Trim() -split '\s+')[0]
                    if ($url) { $found.Add($url) }
                }
            }
            foreach ($m in [regex]::Matches($content, 'url\(\s*''?"?([^''")]+)''?"?\s*\)')) {
                $found.Add($m.Groups[1].Value)
            }

            foreach ($ref in $found) {
                $clean = ($ref -split '[?#]')[0].Trim()
                if ([string]::IsNullOrWhiteSpace($clean)) { continue }
                if ($clean -match '^(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|//|/|#|data:)') { continue }

                $target = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $clean))
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                    $problems.Add("$($file.Name): references missing asset '$clean'")
                    continue
                }
                $dir = [System.IO.Path]::GetDirectoryName($target)
                $leaf = [System.IO.Path]::GetFileName($target)
                if (-not (Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -ceq $leaf })) {
                    $problems.Add("$($file.Name): case mismatch on '$clean' (would 404 on Linux)")
                }
            }
        }

        $problems | Should -BeNullOrEmpty
    }
}

Describe 'Web assets contain no secrets' -Tag 'Unit' {
    # web/ ships to the public Gallery (world-readable and permanent). Guard
    # against accidentally bundling a token, key, or absolute local path.
    BeforeAll {
        $script:webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
    }

    It 'has no embedded secret or absolute local path in any bundled file' {
        $files = Get-ChildItem -LiteralPath $script:webRoot -Recurse -File |
            Where-Object { $_.Extension -in '.html', '.css', '.js', '.json', '.svg' }

        $patterns = @(
            'ghp_[A-Za-z0-9]{20,}'
            'gho_[A-Za-z0-9]{20,}'
            'github_pat_[A-Za-z0-9_]{20,}'
            'xox[baprs]-[A-Za-z0-9-]{10,}'
            'AKIA[0-9A-Z]{16}'
            '-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----'
            '[A-Za-z]:\\Users\\[^\\/:*?"<>|\r\n]+'
        )

        $hits = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $files) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if ([string]::IsNullOrEmpty($content)) { continue }
            foreach ($pattern in $patterns) {
                if ($content -match $pattern) {
                    $hits.Add("$($file.Name): matched /$pattern/")
                }
            }
        }

        $hits | Should -BeNullOrEmpty
    }
}
