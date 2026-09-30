import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { ICON_NAMES, iconSvg } from '../../source/web/assets/icons.js';

const appJs = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
const activityAction = readFileSync(new URL('../../source/Private/ConvertTo-DpActivityAction.ps1', import.meta.url), 'utf8');

test('every icon is a 16px line drawing coloured by the text around it and hidden from assistive technology', () => {
    assert.ok(ICON_NAMES.length >= 15);
    assert.equal(new Set(ICON_NAMES).size, ICON_NAMES.length);
    for (const name of ICON_NAMES) {
        const svg = iconSvg(name);
        assert.match(svg, /^<svg [^>]*><\/?[a-z]/, name);
        assert.match(svg, /<\/svg>$/, name);
        for (const attribute of ['viewBox="0 0 16 16"', 'width="16"', 'height="16"', 'fill="none"', 'stroke="currentColor"', 'aria-hidden="true"', 'focusable="false"', `data-icon="${name}"`]) {
            assert.ok(svg.includes(attribute), `${name} lacks ${attribute}`);
        }
    }
});

test('icons are inert, self-contained markup that no theme or page can turn into a request or a script', () => {
    for (const name of ICON_NAMES) {
        const svg = iconSvg(name);
        const inner = svg.replace(/^<svg [^>]*>/, '').replace(/<\/svg>$/, '');
        for (const tag of inner.match(/<[^>]+>/g)) {
            assert.match(tag, /^<(path|circle|rect|line|polyline|ellipse) [^<>]*\/>$/, `${name} contains ${tag}`);
        }
        assert.doesNotMatch(svg, /<script|<foreignObject|<image|<use|<style|\son\w+=|href|url\(|javascript:|style=/i, name);
        assert.doesNotMatch(svg, /#[0-9a-f]{3,8}\b|rgb\(|hsl\(/i, `${name} must take its colour from the theme`);
    }
});

test('an unknown or inherited name draws the generic Tool icon instead of failing or injecting', () => {
    const generic = iconSvg('tool');
    for (const name of ['__proto__', 'constructor', 'toString', 'hasOwnProperty', '"><img src=x onerror=alert(1)>', '', undefined, null]) {
        assert.equal(iconSvg(name), generic, String(name));
    }
    assert.throws(() => { ICON_NAMES.push('x'); });
});

test('every Activity kind the Host Server reports has its own icon and label', () => {
    const hostKinds = new Set([...activityAction.matchAll(/kind = '([a-z]+)'/g)].map(match => match[1]));
    for (const kind of ['mcp', 'other', 'approval', 'dropped']) hostKinds.add(kind);
    assert.ok(hostKinds.has('browse') && hostKinds.has('read') && hostKinds.size >= 14, [...hostKinds].join(', '));
    const table = appJs.slice(appJs.indexOf('const ACTIVITY_KINDS = {'), appJs.indexOf('};', appJs.indexOf('const ACTIVITY_KINDS = {')));
    for (const kind of hostKinds) {
        const entry = table.match(new RegExp(`\\n\\s+${kind}: \\{ icon: '([a-z-]+)', label: '([^']*)'`));
        assert.ok(entry, `ACTIVITY_KINDS has no icon for '${kind}'`);
        assert.ok(ICON_NAMES.includes(entry[1]), `'${kind}' uses an undrawn icon '${entry[1]}'`);
        if (kind !== 'other') assert.notEqual(entry[1], 'tool', `'${kind}' deserves its own icon`);
        if (kind !== 'dropped') assert.ok(entry[2], `'${kind}' needs a verb`);
    }
    assert.doesNotMatch(table, /ico: /, 'emoji icons were replaced by drawn ones');
});

test('thinking sections name Tools with the same kind and field as the Host Server', () => {
    const host = new Map([...activityAction.matchAll(/^\s+(\w+)\s+= @\{ kind = '(\w+)'; field = '(\w*)' \}/gm)].map(match => [match[1], [match[2], match[3]]]));
    const mirror = new Map([...appJs.matchAll(/\['(\w+)', \['(\w+)', '(\w*)'\]\]/g)].map(match => [match[1], [match[2], match[3]]]));
    assert.ok(host.size >= 15, `parsed ${host.size} Host Server Tools`);
    assert.deepEqual([...mirror].sort(), [...host].sort());
});
