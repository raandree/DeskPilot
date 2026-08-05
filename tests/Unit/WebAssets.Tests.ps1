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
        foreach ($name in 'app.js', 'attachments.js', 'auth.js', 'markdown.js', 'styles.css') {
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

    It 'keeps the device code and link pinned while the sign-in poll runs' {
        $modulePath = Join-Path $script:webRoot 'assets' 'auth.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { parseAuthLine, createAuthProgress, applyAuthLine, AUTH_WAITING_STATUS } =
    await import(pathToFileURL(process.argv[1]).href);

assert.deepEqual(parseAuthLine('1. Open: https://github.com/login/device'),
    { kind: 'url', value: 'https://github.com/login/device' });
assert.deepEqual(parseAuthLine('2. Code: 5D02-A273'), { kind: 'code', value: '5D02-A273' });
assert.deepEqual(parseAuthLine('.'), { kind: 'progress', value: '' });
assert.deepEqual(parseAuthLine('. . .'), { kind: 'progress', value: '' });
assert.deepEqual(parseAuthLine('  '), { kind: 'progress', value: '' });
assert.deepEqual(parseAuthLine('Requesting device code from GitHub'),
    { kind: 'status', value: 'Requesting device code from GitHub' });

let progress = createAuthProgress();
for (const line of [
    'Requesting device code from GitHub',
    '1. Open: https://github.com/login/device',
    '2. Code: 5D02-A273',
    '(code copied to clipboard)',
    '.', '.', '.', '.',
]) {
    progress = applyAuthLine(progress, line);
}
assert.equal(progress.url, 'https://github.com/login/device');
assert.equal(progress.code, '5D02-A273');
assert.equal(progress.status, AUTH_WAITING_STATUS);

const later = applyAuthLine(progress, 'Exchanging the code for a token');
assert.equal(later.status, 'Exchanging the code for a token');
assert.equal(later.code, '5D02-A273');
assert.equal(later.url, 'https://github.com/login/device');
assert.equal(progress.status, AUTH_WAITING_STATUS, 'applyAuthLine must not mutate its input');
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'shows the selected Project folder leaf in the Project chip' {
        $appPath = Join-Path $script:webRoot 'assets' 'app.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(process.argv[1], 'utf8');
const start = source.indexOf('function projects()');
const end = source.indexOf('function buildProjectMenu()', start);
assert.notEqual(start, -1, 'Project helpers must be present');
assert.notEqual(end, -1, 'Project menu boundary must be present');

const label = {};
const button = {};
const context = {
    state: {
        settings: {
            projects: [{ id: 'p_ling', name: 'd:', path: 'D:\\ling' }],
            selectedProjectId: 'p_ling',
        },
    },
    $: (id) => id === 'project-chip-label' ? label : id === 'btn-project' ? button : null,
    syncExplorerAvailability: () => {},
};
vm.runInNewContext(source.slice(start, end) + '\nupdateProjectChip();', context);

assert.equal(label.textContent, 'ling');
assert.equal(label.title, 'ling');
assert.equal(button.title, 'ling');
'@

        $output = & node --input-type=module --eval $nodeScript $appPath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)

        $styles = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'styles.css') -Raw
        $styles | Should -Match '(?s)#btn-project\s*\{[^}]*width:\s*fit-content'
        $styles | Should -Match '(?s)#project-chip-label\s*\{[^}]*max-width:\s*150px[^}]*text-overflow:\s*ellipsis'
    }

    It 'renders Ask-User questions and submits answers while a Turn streams' {
        $app = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $styles = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'styles.css') -Raw

        $app | Should -Match 'question:\s*\(d\)\s*=>'
        $app | Should -Match '/question'
        $app | Should -Match 'userPrompts'
        $styles | Should -Match '\.user-prompt-card'
    }

    It 'switches to an immediate stopping state and renders stopped Turn Usage' {
        $app = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        $app | Should -Match 'stopRequested:\s*false'
        $app | Should -Match 'function\s+setStoppingUI\s*\('
        $app | Should -Match 'stopping:\s*\(d\)\s*=>'
        $app | Should -Match 'stopped:\s*\(m\)\s*=>'
        $app | Should -Match 'estimateScope'
        ([regex]::Matches($app, 'let\s+turnStopped\s*=\s*false;')).Count | Should -Be 2
        ([regex]::Matches($app, 'turnStopped\s*=\s*true;')).Count | Should -Be 4
        ([regex]::Matches($app, 'renderScheduled\s*=\s*false;\s*if\s*\(state\.stopRequested\s*\|\|\s*turnStopped\)\s*return;')).Count |
            Should -Be 2
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
