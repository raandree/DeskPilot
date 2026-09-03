#requires -Version 7.0

# Localization guards. Deterministic and executable: the catalogs are compared
# as key sets, the JavaScript runs under node against the real Intl APIs, and
# the static markup is scanned for user-facing text that carries no key.

BeforeAll {
    $script:webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
    $script:i18nPath = Join-Path $script:webRoot 'assets' 'i18n.js'
    $script:htmlPath = Join-Path $script:webRoot 'index.html'

    function Get-DpCatalogKeys {
        param([string]$Locale)
        $path = Join-Path $script:webRoot 'assets' 'locales' "$Locale.js"
        $raw = Get-Content -LiteralPath $path -Raw
        @([regex]::Matches($raw, "(?m)^\s{4}'([^']+)':") | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-DpCatalogEntries {
        param([string]$Locale)
        $path = Join-Path $script:webRoot 'assets' 'locales' "$Locale.js"
        $raw = Get-Content -LiteralPath $path -Raw
        $map = @{}
        foreach ($match in [regex]::Matches($raw, "(?m)^\s{4}'([^']+)':\s*(.+?),\s*$")) {
            $map[$match.Groups[1].Value] = $match.Groups[2].Value
        }
        $map
    }

    function Invoke-DpNodeModule {
        param([string]$Script)
        $output = & node --input-type=module --eval $Script $script:i18nPath 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}

Describe 'Locale catalogs' -Tag 'Unit' {
    It 'ships the i18n module and both locale catalogs' {
        Test-Path -LiteralPath $script:i18nPath -PathType Leaf | Should -BeTrue
        foreach ($locale in 'en', 'de') {
            Test-Path -LiteralPath (Join-Path $script:webRoot 'assets' 'locales' "$locale.js") -PathType Leaf | Should -BeTrue
        }
    }

    It 'declares exactly the same keys in every locale' {
        $en = Get-DpCatalogKeys -Locale 'en'
        $de = Get-DpCatalogKeys -Locale 'de'

        $en.Count | Should -BeGreaterThan 50
        @($en | Where-Object { $de -notcontains $_ }) | Should -BeNullOrEmpty -Because 'a key missing from de would silently render English'
        @($de | Where-Object { $en -notcontains $_ }) | Should -BeNullOrEmpty -Because 'an orphaned de key can never be reached'
    }

    It 'declares no key twice' {
        foreach ($locale in 'en', 'de') {
            $keys = Get-DpCatalogKeys -Locale $locale
            ($keys | Sort-Object -Unique).Count | Should -Be $keys.Count -Because "$locale must not shadow one of its own keys"
        }
    }

    It 'uses the same placeholders in every locale' {
        $en = Get-DpCatalogEntries -Locale 'en'
        $de = Get-DpCatalogEntries -Locale 'de'
        $problems = [System.Collections.Generic.List[string]]::new()

        foreach ($key in $en.Keys) {
            $enTokens = @([regex]::Matches($en[$key], '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $deTokens = @([regex]::Matches($de[$key], '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            if (($enTokens -join ',') -ne ($deTokens -join ',')) {
                $problems.Add("$key : en[$($enTokens -join ',')] de[$($deTokens -join ',')]")
            }
        }

        $problems | Should -BeNullOrEmpty
    }

    It 'carries a plural form for every plural key in both locales' {
        foreach ($locale in 'en', 'de') {
            $keys = Get-DpCatalogKeys -Locale $locale
            foreach ($one in @($keys | Where-Object { $_.EndsWith('.one') })) {
                $keys | Should -Contain ($one -replace '\.one$', '.other')
            }
        }
    }

    It 'actually translates the safety copy rather than copying the English' {
        $en = Get-DpCatalogEntries -Locale 'en'
        $de = Get-DpCatalogEntries -Locale 'de'
        $safety = @($en.Keys | Where-Object { $_.StartsWith('warn.') })

        $safety.Count | Should -BeGreaterThan 4
        foreach ($key in $safety) {
            $de[$key] | Should -Not -Be $en[$key]
            # Meaning over brevity: a warning must not be cut down to fit.
            $de[$key].Length | Should -BeGreaterThan ([int]($en[$key].Length * 0.6)) -Because "the German $key must not drop the consequence"
        }
    }
}

Describe 'Translator behaviour' -Tag 'Unit' {
    It 'falls back to English for a missing key and reports it once' {
        $node = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { createTranslator, CATALOGS } = await import(pathToFileURL(process.argv[1]).href);
CATALOGS.zz = { 'schedules.title': 'ZZ' };
const missing = [];
const t = createTranslator('zz', { onMissing: (key) => missing.push(key) });
assert.equal(t('schedules.title'), 'ZZ');
assert.equal(t('schedules.runNow'), CATALOGS.en['schedules.runNow'], 'missing key must fall back to English');
t('schedules.runNow');
assert.deepEqual(missing, ['schedules.runNow'], 'a missing key is reported once, not on every render');
assert.equal(t('no.such.key.anywhere'), 'no.such.key.anywhere', 'an unknown key renders as itself, never as empty');
'@
        $result = Invoke-DpNodeModule -Script $node
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'renders HTML-like values as text and leaves unknown placeholders alone' {
        $node = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { createTranslator } = await import(pathToFileURL(process.argv[1]).href);
const t = createTranslator('en');
const out = t('warn.schedule.delete', { name: '<img src=x onerror=alert(1)>' });
assert.ok(out.includes('<img src=x onerror=alert(1)>'), 'the value is substituted verbatim as text');
assert.ok(!out.includes('&lt;'), 'the translator must not HTML-encode; callers use textContent');
assert.ok(t('schedules.next', {}).includes('{when}'), 'an unsupplied placeholder stays visible rather than rendering empty');
'@
        $result = Invoke-DpNodeModule -Script $node
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'writes translations through DOM APIs, never innerHTML' {
        $source = Get-Content -LiteralPath $script:i18nPath -Raw
        $source | Should -Match 'node\.textContent = t\('
        $source | Should -Match 'node\.setAttribute\(attr, t\(key\)\)'
        $source | Should -Not -Match 'innerHTML'
    }

    It 'selects German plural forms through Intl' {
        $node = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { createTranslator } = await import(pathToFileURL(process.argv[1]).href);
const t = createTranslator('de');
assert.ok(t('schedules.queue', { count: 1 }).startsWith('1 Lauf '), t('schedules.queue', { count: 1 }));
assert.ok(t('schedules.queue', { count: 3 }).startsWith('3 Läufe '), t('schedules.queue', { count: 3 }));
assert.ok(t('schedules.queue', { count: 0 }).startsWith('0 Läufe '), 'zero takes the plural form in German');
'@
        $result = Invoke-DpNodeModule -Script $node
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'formats German numbers, dates, currencies, lists and relative times' {
        $node = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const m = await import(pathToFileURL(process.argv[1]).href);
assert.equal(m.formatNumber('de', 1234.5), '1.234,5');
assert.equal(m.formatDateTime('de', '2026-05-04T08:00:00Z', { dateStyle: 'medium', timeZone: 'UTC' }), '04.05.2026');
assert.ok(m.formatCurrency('de', 12.5, 'EUR').includes('12,50'), m.formatCurrency('de', 12.5, 'EUR'));
assert.equal(m.formatList('de', ['a', 'b', 'c']), 'a, b und c');
assert.equal(m.formatRelativeTime('de', '2026-05-04T05:00:00Z', '2026-05-04T08:00:00Z'), 'vor 3 Stunden');
assert.equal(m.formatDateTime('de', 'not a date'), '', 'an unparseable value must not throw');
'@
        $result = Invoke-DpNodeModule -Script $node
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'detects the system language on first run and honours an explicit choice' {
        $node = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { resolveLocale } = await import(pathToFileURL(process.argv[1]).href);
const available = ['en', 'de'];
assert.equal(resolveLocale('', ['de-AT', 'en-US'], available), 'de', 'a regional tag resolves to its base language');
assert.equal(resolveLocale('auto', ['fr-FR', 'de-DE'], available), 'de', 'the first supported system language wins');
assert.equal(resolveLocale('auto', ['fr-FR'], available), 'en', 'an unsupported system language falls back to English');
assert.equal(resolveLocale('en', ['de-DE'], available), 'en', 'an explicit choice beats the system language');
assert.equal(resolveLocale('zz', ['de-DE'], available), 'de', 'a stored locale we no longer ship falls through to detection');
assert.equal(resolveLocale(null, null, available), 'en', 'no preference and no system list is still English');
'@
        $result = Invoke-DpNodeModule -Script $node
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }
}

Describe 'Markup coverage' -Tag 'Unit' {
    It 'references only keys that exist in every locale' {
        $html = Get-Content -LiteralPath $script:htmlPath -Raw
        $en = Get-DpCatalogKeys -Locale 'en'
        $de = Get-DpCatalogKeys -Locale 'de'

        $used = [System.Collections.Generic.List[string]]::new()
        foreach ($match in [regex]::Matches($html, 'data-i18n="([^"]+)"')) { $used.Add($match.Groups[1].Value) }
        foreach ($match in [regex]::Matches($html, 'data-i18n-attr="([^"]+)"')) {
            foreach ($pair in $match.Groups[1].Value -split ',') {
                $parts = $pair -split ':'
                if ($parts.Count -eq 2) { $used.Add($parts[1].Trim()) }
            }
        }

        $used.Count | Should -BeGreaterThan 30
        foreach ($key in ($used | Sort-Object -Unique)) {
            $en | Should -Contain $key
            $de | Should -Contain $key
        }
    }

    It 'persists the language choice and applies it before the first render' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $js | Should -Match "localStorage\.setItem\('ad_lang'"
        $js | Should -Match "localStorage\.getItem\('ad_lang'\) \|\| 'auto'"
        $js | Should -Match 'document\.documentElement\.lang = locale'
        # applyLanguage has to run before anything paints, or the first frame is English.
        $initAt = $js.IndexOf('async function init() {')
        $applyAt = $js.IndexOf('applyLanguage();', $initAt)
        $themeAt = $js.IndexOf('applyTheme();', $initAt)
        $applyAt | Should -BeGreaterThan $initAt
        $themeAt | Should -BeGreaterThan $applyAt
        # A language select exists in Settings and is wired.
        $js | Should -Match 'id="set-language"'
        $js | Should -Match ([regex]::Escape('$(''set-language'').onchange'))
    }

    It 'maps server error codes to localized text without changing the wire contract' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $js | Should -Match 'function errorText\(error\)'
        $js | Should -Match ([regex]::Escape('const key = `error.${code}`'))
        $en = Get-DpCatalogKeys -Locale 'en'
        foreach ($code in 'busy', 'not_found', 'bad_schedule', 'already_queued', 'queue_full', 'auth_required', 'unknown') {
            $en | Should -Contain "error.$code"
        }
    }

    It 'reports the user-facing strings still awaiting extraction and does not let that number grow' {
        # A static scan, as the localization contract requires: every visible
        # attribute and label in the shell that carries no key is counted. The
        # baseline is deliberately recorded so extraction can only move down.
        $html = Get-Content -LiteralPath $script:htmlPath -Raw
        $unmarked = [System.Collections.Generic.List[string]]::new()

        foreach ($match in [regex]::Matches($html, '(?s)<(button|label|legend|option|h1|h2|h3|p)\b([^>]*)>(.*?)</\1>')) {
            $attributes = $match.Groups[2].Value
            if ($attributes -match 'data-i18n') { continue }
            # A container whose visible text comes entirely from marked children is
            # already extracted; counting it would report a gap that does not exist.
            $inner = $match.Groups[3].Value -replace '(?s)<([a-zA-Z0-9]+)\b[^>]*data-i18n[^>]*>.*?</\1>', ''
            $text = ($inner -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()
            if (-not $text) { continue }
            if ($text -notmatch '[A-Za-z]{3}') { continue }
            $unmarked.Add("$($match.Groups[1].Value): $text")
        }
        foreach ($match in [regex]::Matches($html, '<[^>]*\b(title|aria-label|placeholder)="([^"]+)"[^>]*>')) {
            $tag = $match.Groups[0].Value
            if ($tag -match 'data-i18n') { continue }
            if ($match.Groups[2].Value -notmatch '[A-Za-z]{3}') { continue }
            $unmarked.Add("$($match.Groups[1].Value): $($match.Groups[2].Value)")
        }

        # Baseline lowered to 97 on 2026-09-03 (was 105): the scan no longer
        # counts a container whose visible text comes entirely from marked
        # children. Lower this whenever strings are extracted; never raise it.
        # The ratchet is what stops localization rotting.
        $unmarked.Count | Should -BeLessOrEqual 97 -Because ("unextracted strings:`n" + ($unmarked -join "`n"))
    }
}
