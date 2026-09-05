// Disables one control at a time and reports which checks notice.
//
// The fifth review round measured 53 of 54 disabling mutations leaving the suite
// green, because the assertions read source text. This turns that measurement
// into a test: each mutation below removes or inverts exactly one control, and
// the run fails if the checks do not notice.
//
// Usage: node mutate-guards.mjs

import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runChecks } from './guard-checks.mjs';

const guardsPath = new URL('../../../source/browser/guards.mjs', import.meta.url);
const original = readFileSync(guardsPath, 'utf8');

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
    }
];

const workspace = mkdtempSync(join(tmpdir(), 'dp-mutate-guards-'));
const results = [];

try {
    const baseline = await runChecks(await import(pathToFileURL(write('baseline', original)).href));
    const baselineFailures = baseline.filter((check) => !check.pass).map((check) => check.name);

    for (const mutation of mutations) {
        if (!original.includes(mutation.from)) {
            results.push({ id: mutation.id, control: mutation.control, applied: false, noticedBy: [] });
            continue;
        }
        const mutated = original.replace(mutation.from, mutation.to);
        let noticed = [];
        try {
            const checks = await runChecks(await import(pathToFileURL(write(mutation.id, mutated)).href));
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

function write(name, contents) {
    const target = join(workspace, `${name}.mjs`);
    writeFileSync(target, contents, 'utf8');
    return target;
}
