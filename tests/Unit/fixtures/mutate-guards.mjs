// Disables one control at a time and reports which checks notice.
//
// The fifth review round measured 53 of 54 disabling mutations leaving the suite
// green, because the assertions read source text. This turns that measurement
// into a test: each mutation below removes or inverts exactly one control, and
// the run fails if the checks do not notice.
//
// Usage: node mutate-guards.mjs

import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runChecks } from './guard-checks.mjs';

const browserDir = new URL('../../../source/browser/', import.meta.url);
// Every module the checks import, so a mutated copy of one can be loaded beside
// unmutated copies of the rest.
const modules = ['guards.mjs', 'policy.mjs'];
const original = Object.fromEntries(modules.map((name) => [name, readFileSync(new URL(name, browserDir), 'utf8')]));

// Each entry names the control it disables and what the checks must notice.
const mutations = [
    {
        id: 'no-inflight-sharing',
        control: 'concurrent requests for one host share a lookup',
        from: '            let pending = inFlight.get(hostname);',
        to: '            let pending = undefined; inFlight.get(hostname);'
    },
    {
        id: 'budget-disabled',
        control: 'the hostname budget refuses past its limit',
        from: "                if (hostnames >= limits.hostLookups) return 'resource-lookup-budget';",
        to: "                if (false) return 'resource-lookup-budget';"
    },
    {
        id: 'fail-open',
        control: 'a name that will not resolve is refused',
        from: "                    .catch(() => 'resource-unresolved')",
        to: '                    .catch(() => null)'
    },
    {
        id: 'cache-the-failure',
        control: 'a transient resolver failure is not remembered',
        from: "                    .catch(() => 'resource-unresolved')",
        to: "                    .catch(() => { remember(hostname, true); return 'resource-internal-address'; })"
    },
    {
        id: 'no-internal-check',
        control: 'a public name resolving inward is refused',
        from: '                        const internal = addresses.some((address) => isInternal(address));',
        to: '                        const internal = false;'
    },
    {
        id: 'never-expires',
        control: 'a resolution expires so a rebind is re-checked',
        from: '            if (cached && now() - cached.at < limits.hostLookupTtlMs) {',
        to: '            if (cached) {'
    },
    {
        id: 'no-eviction',
        control: 'the cache is bounded by eviction',
        from: '        if (resolved.size >= limits.hostCacheEntries) {',
        to: '        if (false) {'
    },
    {
        id: 'count-past-the-cap',
        control: 'a refusal past the report cap is still answered',
        from: '            if (isMainFrame && String(reason).startsWith(\'navigation-\')) {',
        to: '            if (entries.length < cap && isMainFrame && String(reason).startsWith(\'navigation-\')) {'
    },
    {
        id: 'report-unbounded',
        control: 'the report itself stays bounded',
        from: '            if (entries.length >= cap) return entry;',
        to: '            if (false) return entry;'
    },
    {
        id: 'subframe-answers',
        control: 'a sub-frame refusal does not answer for the main frame',
        from: '            if (isMainFrame && String(reason).startsWith(\'navigation-\')) {',
        to: "            if (String(reason).startsWith('navigation-') || String(reason).startsWith('subframe-')) {"
    },
    {
        id: 'any-refusal-answers',
        control: 'a sub-resource refusal does not answer for a navigation',
        from: '            if (isMainFrame && String(reason).startsWith(\'navigation-\')) {',
        to: '            if (isMainFrame) {'
    },
    {
        id: 'binding-ignores-navigation',
        control: 'a page that navigated and came back is refused',
        from: '    if (expectedNavigation !== undefined && currentNavigation !== expectedNavigation) return \'page-changed\';',
        to: '    if (false) return \'page-changed\';'
    },
    {
        id: 'binding-allows-unknown-page',
        control: 'a missing expectation is a refusal',
        from: "    if (!expectedUrl) return 'unknown-page';",
        to: '    if (!expectedUrl) return null;'
    },
    {
        id: 'download-name-not-a-leaf',
        control: 'a download name is reduced to a leaf',
        from: "    const leaf = String(suggested ?? '').split(/[\\\\/]/).pop() ?? '';",
        to: "    const leaf = String(suggested ?? '');"
    },
    {
        id: 'download-name-unfiltered',
        control: 'nothing outside the allowed set survives a download name',
        from: "        .replace(/[^A-Za-z0-9._-]/g, '_')",
        to: '        .replace(/$^/g, \'_\')'
    },
    {
        id: 'password-box-fillable',
        file: 'policy.mjs',
        control: 'a password box is refused outright',
        from: "    if (type === 'password') return { fillable: false, reason: 'credential-field' };",
        to: '    if (false) return { fillable: false, reason: \'credential-field\' };'
    },
    {
        id: 'credential-autocomplete-fillable',
        file: 'policy.mjs',
        control: 'a field the site declares as a credential is refused',
        from: "    if (CREDENTIAL_AUTOCOMPLETE.has(autocomplete)) return { fillable: false, reason: 'credential-field' };",
        to: '    if (false) return { fillable: false, reason: \'credential-field\' };'
    },
    {
        id: 'credential-name-fillable',
        file: 'policy.mjs',
        control: 'a field named like a credential is refused',
        from: '    if (CREDENTIAL_NAME.test(name)) return { fillable: false, reason: \'credential-field\' };',
        to: '    if (false) return { fillable: false, reason: \'credential-field\' };'
    },
    {
        id: 'hidden-field-fillable',
        file: 'policy.mjs',
        control: 'a field the approver cannot see is refused',
        from: "    if (type === 'hidden') return { fillable: false, reason: 'hidden-field' };",
        to: '    if (false) return { fillable: false, reason: \'hidden-field\' };'
    },
    {
        id: 'invisible-field-fillable',
        file: 'policy.mjs',
        control: 'a field rendered invisible is refused',
        from: "    if (field.visible === false) return { fillable: false, reason: 'not-visible' };",
        to: '    if (false) return { fillable: false, reason: \'not-visible\' };'
    },
    {
        id: 'file-input-fillable',
        file: 'policy.mjs',
        control: 'a file input is a different capability with a different approval',
        from: "    if (type === 'file') return { fillable: false, reason: 'file-input' };",
        to: '    if (false) return { fillable: false, reason: \'file-input\' };'
    }
];

const workspace = mkdtempSync(join(tmpdir(), 'dp-mutate-guards-'));
const results = [];

try {
    const baseline = await runChecks(await load('baseline', {}));
    const baselineFailures = baseline.filter((check) => !check.pass).map((check) => check.name);

    for (const mutation of mutations) {
        const file = mutation.file ?? 'guards.mjs';
        if (!original[file].includes(mutation.from)) {
            results.push({ id: mutation.id, control: mutation.control, applied: false, noticedBy: [] });
            continue;
        }
        let noticed = [];
        try {
            const checks = await runChecks(await load(mutation.id, { [file]: original[file].replace(mutation.from, mutation.to) }));
            noticed = checks.filter((check) => !check.pass).map((check) => check.name);
        }
        catch (error) {
            noticed = [`threw: ${error?.message ?? error}`];
        }
        results.push({ id: mutation.id, control: mutation.control, applied: true, noticedBy: noticed });
    }

    process.stdout.write(JSON.stringify({ baselineFailures, results }));
}
finally {
    rmSync(workspace, { recursive: true, force: true });
}

// One directory per variant, holding a full set of modules so the relative
// imports between them resolve to the copies rather than back to the originals.
async function load(name, overrides) {
    const target = join(workspace, name);
    mkdirSync(target, { recursive: true });
    for (const module of modules) {
        const contents = overrides[module] ?? original[module];
        writeFileSync(join(target, module), contents, 'utf8');
    }
    const guards = await import(pathToFileURL(join(target, 'guards.mjs')).href);
    const policy = await import(pathToFileURL(join(target, 'policy.mjs')).href);
    return { ...guards, ...policy };
}
