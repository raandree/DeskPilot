#requires -Version 7.0

<#
.SYNOPSIS
    Screenshots the approval card and browser settings at each supported width.
.DESCRIPTION
    The approval card is the whole point of the write capabilities: if it does
    not render what is being approved, legibly, at the width someone is actually
    using, the gate is decoration. This renders it at every breakpoint the
    stylesheet defines and saves a PNG per width per case.

    It renders the **real** functions rather than a hand-written copy of their
    markup. app.js is a module with no exports that boots the whole SPA on load,
    so the harness slices the relevant definitions out by brace matching and runs
    those against the real stylesheet. A fixture written by hand would drift from
    the code it claims to picture, which is the failure this feature already had
    once.

        pwsh -File tests/live/Invoke-DpBrowserUiScreenshot.ps1
.PARAMETER RuntimeRoot
    Where the browser runtime is installed.
.PARAMETER OutputRoot
    Where to write the screenshots.
.OUTPUTS
    System.Collections.Hashtable
#>
[CmdletBinding()]
[OutputType([hashtable])]
param(
    [string]$RuntimeRoot,

    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Get-ChildItem -Path (Join-Path $repoRoot 'source' 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser' }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dp-ui-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$runtime = Get-DpBrowserRuntime -RuntimeRoot $RuntimeRoot
if (-not $runtime.ready) {
    Write-Host 'Browser automation is not set up, so the screenshots cannot be taken.' -ForegroundColor Yellow
    return @{ ran = $false; reason = 'runtime-not-ready' }
}

$webRoot = Join-Path $repoRoot 'source' 'web' 'assets'
$appJs = Get-Content -LiteralPath (Join-Path $webRoot 'app.js') -Raw

# Slice a top-level definition out of app.js by matching braces from its opening
# one. Fails loudly rather than silently producing a partial function, because a
# half-extracted renderer would picture something that does not exist.
function Get-DpJsDefinition {
    param([string]$Source, [string]$Pattern, [string]$Name)

    $match = [regex]::Match($Source, $Pattern)
    if (-not $match.Success) { throw "Could not find '$Name' in app.js. The screenshot harness is out of date." }

    $start = $match.Index
    # Balance whichever bracket opens the body. An array of objects opens with
    # '[', and matching '{' instead would stop at the first element's close and
    # silently return a truncated definition.
    $brace = $Source.IndexOf('{', $start)
    $bracket = $Source.IndexOf('[', $start)
    if ($brace -lt 0 -and $bracket -lt 0) { throw "Could not find the body of '$Name'." }
    $index = if ($bracket -ge 0 -and ($brace -lt 0 -or $bracket -lt $brace)) { $bracket } else { $brace }
    $open = $Source[$index]
    $close = if ($open -eq '[') { ']' } else { '}' }

    $depth = 0
    for ($i = $index; $i -lt $Source.Length; $i++) {
        $char = $Source[$i]
        if ($char -eq $open) { $depth++ }
        elseif ($char -eq $close) {
            $depth--
            if ($depth -eq 0) { return $Source.Substring($start, $i - $start + 1) }
        }
    }
    throw "Unbalanced brackets while extracting '$Name'."
}

$pieces = @(
    (Get-DpJsDefinition -Source $appJs -Pattern 'const el = \(cls' -Name 'el')
    (Get-DpJsDefinition -Source $appJs -Pattern 'const APPROVAL_TITLES = \{' -Name 'APPROVAL_TITLES')
    (Get-DpJsDefinition -Source $appJs -Pattern 'function approvalRow\(' -Name 'approvalRow')
    (Get-DpJsDefinition -Source $appJs -Pattern 'function approvalDetail\(' -Name 'approvalDetail')
    (Get-DpJsDefinition -Source $appJs -Pattern 'const BROWSER_CAPABILITIES = \[' -Name 'BROWSER_CAPABILITIES')
) -join ";`n`n"

# The card builder, with the two calls a live SPA supplies stubbed out.
$renderApproval = (Get-DpJsDefinition -Source $appJs -Pattern 'function renderApproval\(' -Name 'renderApproval')
$renderApproval = $renderApproval -replace 'scrollThread\(\);', '' -replace 'deny\.focus\(\);', ''

$renderProjectBrowser = Get-DpJsDefinition -Source $appJs -Pattern 'function renderProjectBrowser\(' -Name 'renderProjectBrowser'

# Inlined rather than imported: an ES module import from a file:// page is
# blocked by CORS, and serving the fixture over http just to read one object
# would be more moving parts than the picture is worth.
$enSource = Get-Content -LiteralPath (Join-Path $webRoot 'locales' 'en.js') -Raw
$enStrings = (Get-DpJsDefinition -Source $enSource -Pattern 'export const en = \{' -Name 'en') -replace '^export\s+', ''

# Single-quoted here-string: the fixture is JavaScript, full of $ and {}, and
# PowerShell must not interpret any of it. The extracted code is spliced in by
# token replacement instead.
$template = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<link rel="stylesheet" href="./styles.css">
<style>body { padding: 16px; } h2 { font: 600 13px system-ui; color: #888; margin: 18px 0 6px; }</style>
</head><body>
<div id="cards"></div>
<h2>Project browser settings</h2>
<div class="project-row"><div class="project-meta" id="settings"></div></div>
<script type="module">
/*__LOCALE__*/;
const t = (key) => en[key] ?? key;
/*__PIECES__*/
/*__RENDER_APPROVAL__*/
const projects = () => [];
const projectAction = () => {};
/*__RENDER_SETTINGS__*/

const cases = [
  { id: 'x1', class: 'Terminal', risk: 'This runs a command on your computer with your account. It can read, change or delete files, and it can reach the network.',
    summary: { command: 'git status --porcelain', workingDirectory: 'D:\\Git\\DeskPilot', project: 'DeskPilot' } },
  { id: 'x2', class: 'BrowserNavigation', risk: 'This opens an address outside the site this task started on. Check the whole address, including anything after the question mark - that is where a page tries to send information it should not have.',
    summary: { url: 'https://wx-fallback.example/?ctx=D%3A%5CGit%5CDeskPilot&note=the+last+thing+you+asked+for', host: 'wx-fallback.example' } },
  { id: 'x3', class: 'BrowserAction', risk: 'This types these values into the page and may send them. Check every value: whatever is here leaves your computer.',
    summary: { action: 'fill_form', url: 'https://portal.test/change/new', host: 'portal.test', control: 'Save change',
      fields: [ { name: 'Window start', value: 'Monday 02:00' }, { name: 'Window end', value: 'Monday 04:00' },
                { name: 'Change ticket', value: 'CHG0041299' }, { name: 'Notes', value: '' } ] } },
  { id: 'x4', class: 'BrowserAction', risk: 'This presses a control on the page. It may send, change, buy or delete something on that site, and DeskPilot cannot undo it.',
    summary: { action: 'click_button', url: 'https://portal.test/change/CHG0041299', host: 'portal.test', control: 'Delete change' } },
  { id: 'x5', class: 'BrowserAction', risk: 'This sends a file from your computer to the website. Check the file and the site: once it is sent, DeskPilot cannot take it back.',
    summary: { action: 'upload_file', url: 'https://portal.test/change/attach', host: 'portal.test', control: 'Evidence', filePath: 'D:\\Git\\DeskPilot\\docs\\report.pdf' } },
  { id: 'x6', class: 'BrowserAction', risk: 'This saves a file from the website onto your computer. DeskPilot puts it in a holding folder and never opens or runs it.',
    summary: { action: 'download_file', url: 'https://portal.test/export', host: 'portal.test', control: 'Export', filePath: 'C:\\Users\\you\\AppData\\Local\\DeskPilot\\browser\\downloads' } },
  { id: 'x7', class: 'BrowserAction', risk: 'This performs an action that may change something on your computer.', summary: {} }
];

const host = document.getElementById('cards');
for (const request of cases) renderApproval(host, request, 'c-1');

document.getElementById('settings').appendChild(
  renderProjectBrowser({ id: 'p1', name: 'Ops', browserActions: ['fill', 'submit'], browserDomains: ['portal.test', 'cdn.portal.test'] })
);
document.body.dataset.ready = '1';
</script>
</body></html>
'@

$fixture = $template.
    Replace('/*__LOCALE__*/', $enStrings).
    Replace('/*__PIECES__*/', $pieces).
    Replace('/*__RENDER_APPROVAL__*/', $renderApproval).
    Replace('/*__RENDER_SETTINGS__*/', $renderProjectBrowser)

$fixturePath = Join-Path $webRoot '__ui-screenshot-fixture.html'
Set-Content -LiteralPath $fixturePath -Value $fixture -Encoding utf8

# Every breakpoint the stylesheet defines, plus a comfortable desktop width and
# a narrow phone.
$widths = @(1440, 820, 720, 700, 620, 400)
$captured = @()

try {
    $node = Get-DpNodeCommand
    if (-not $node) { throw 'Node.js is not installed.' }

    # Node resolves an import by walking up from the importing file, so the
    # script has to run from beside the runtime's node_modules.
    $script = Join-Path $RuntimeRoot 'ui-screenshot.mjs'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ui-screenshot.mjs') -Destination $script -Force
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $node.path
    foreach ($argument in @($script, $fixturePath, $OutputRoot, ($widths -join ','))) { $psi.ArgumentList.Add($argument) }
    $psi.WorkingDirectory = $RuntimeRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Environment['PLAYWRIGHT_BROWSERS_PATH'] = Join-Path $RuntimeRoot 'browsers'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(180000)) {
        try { $process.Kill($true) } catch { $null = $_ }
        throw 'The screenshot run timed out.'
    }
    if ($process.ExitCode -ne 0) { throw "The screenshot run failed: $($stderr.Result)" }

    $captured = @(($stdout.Result | ConvertFrom-Json).captured)
    foreach ($shot in $captured) { Write-Host "[+] $($shot.width) px -> $($shot.path)" -ForegroundColor Green }
    $process.Dispose()
}
finally {
    Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "UI screenshots: $($captured.Count)/$($widths.Count) widths captured in $OutputRoot" `
    -ForegroundColor $(if ($captured.Count -eq $widths.Count) { 'Green' } else { 'Red' })

@{ ran = $true; widths = $widths; captured = @($captured); outputRoot = $OutputRoot }
