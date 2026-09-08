import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');

function themeControls(saved = {}, dark = false) {
    const values = new Map(Object.entries(saved));
    const attributes = new Map();
    const controls = {
        'btn-theme': { setAttribute: (name, value) => attributes.set(name, value) },
        'set-theme': {},
        'set-color-theme': {},
    };
    const root = { dataset: {}, style: {} };
    const media = {
        matches: dark,
        addEventListener: (name, listener) => { media.onchange = listener; },
    };
    const context = vm.createContext({
        $: (id) => controls[id],
        document: { documentElement: root },
        localStorage: {
            getItem: (key) => values.get(key) ?? null,
            setItem: (key, value) => values.set(key, value),
        },
        window: { matchMedia: () => media },
    });
    const preferencesStart = source.indexOf('// ===== Theme =====');
    const preferencesEnd = source.indexOf('// Which keystroke', preferencesStart);
    const applyStart = source.indexOf('function applyTheme()');
    const applyEnd = source.indexOf('// ===== Init =====', applyStart);
    assert.ok(preferencesStart >= 0 && preferencesEnd > preferencesStart);
    assert.ok(applyStart >= 0 && applyEnd > applyStart);
    vm.runInContext(source.slice(preferencesStart, preferencesEnd) + source.slice(applyStart, applyEnd), context);
    return { context, root, controls, attributes, values, media };
}

test('existing light and dark preferences retain the DeskPilot theme', () => {
    for (const mode of ['light', 'dark', 'system']) {
        const { context, root, values } = themeControls({ ad_theme: mode });
        context.applyTheme();
        assert.equal(root.dataset.theme, mode);
        assert.equal(root.dataset.colorTheme, 'deskpilot');
        assert.equal(values.get('ad_theme'), mode);
    }
});

for (const colorTheme of ['terminal-amber', 'terminal-green']) {
    for (const mode of ['light', 'dark', 'system']) {
        test(`${colorTheme} applies independently of ${mode} mode`, () => {
            const { context, root, values } = themeControls({ ad_theme: mode, ad_color_theme: colorTheme });
            context.applyTheme();
            assert.equal(root.dataset.theme, mode);
            assert.equal(root.dataset.colorTheme, colorTheme);
            assert.equal(values.get('ad_theme'), mode);
        });
    }

    test(`${colorTheme} survives the top-bar mode toggle and reload`, () => {
        const { context, root, values, controls, attributes } = themeControls({
            ad_theme: 'dark', ad_color_theme: colorTheme,
        });
        context.applyTheme();
        context.toggleTheme();
        assert.equal(root.dataset.theme, 'light');
        assert.equal(root.dataset.colorTheme, colorTheme);
        assert.equal(values.get('ad_theme'), 'light');
        assert.equal(values.get('ad_color_theme'), colorTheme);
        assert.equal(controls['set-theme'].value, 'light');
        assert.equal(attributes.get('aria-label'), 'Switch to dark mode');

        const reloaded = themeControls(Object.fromEntries(values));
        reloaded.context.applyTheme();
        assert.equal(reloaded.root.dataset.theme, 'light');
        assert.equal(reloaded.root.dataset.colorTheme, colorTheme);
    });

    test(`${colorTheme} follows a system appearance change without losing the preference`, () => {
        const { context, root, values, media, attributes } = themeControls({
            ad_theme: 'system', ad_color_theme: colorTheme,
        });
        context.applyTheme();
        media.matches = true;
        media.onchange();
        assert.equal(context.effectiveTheme(), 'dark');
        assert.equal(root.dataset.theme, 'system');
        assert.equal(root.dataset.colorTheme, colorTheme);
        assert.equal(values.get('ad_theme'), 'system');
        assert.equal(attributes.get('aria-label'), 'Switch to light mode');
    });
}

test('unknown stored theme choices fall back to DeskPilot and system appearance', () => {
    const { context, root } = themeControls({ ad_theme: 'obsolete', ad_color_theme: 'unknown' }, true);
    context.applyTheme();
    assert.equal(root.dataset.colorTheme, 'deskpilot');
    assert.equal(root.dataset.theme, 'system');
    assert.equal(context.effectiveTheme(), 'dark');
});

test('Settings offers labelled theme and mode selectors with the saved choices', () => {
    for (const colorTheme of ['deskpilot', 'terminal-amber', 'terminal-green']) {
        const { context } = themeControls({ ad_theme: 'dark', ad_color_theme: colorTheme });
        context.tr = (key) => key;
        for (const [id, selected, options] of [
            ['set-color-theme', colorTheme, ['deskpilot', 'terminal-amber', 'terminal-green']],
            ['set-theme', 'dark', ['system', 'light', 'dark']],
        ]) {
            const template = source.match(new RegExp(`<select id="${id}">[\\s\\S]*?</select>`))?.[0];
            assert.ok(template, `Settings must render ${id}`);
            assert.match(source, new RegExp(`<label for="${id}"`));
            const html = vm.runInContext('`' + template + '`', context);
            const rendered = [...html.matchAll(/<option value="([^"]+)"([^>]*)>/g)];
            assert.deepEqual(rendered.map((option) => option[1]), options);
            assert.deepEqual(rendered.filter((option) => /\bselected\b/.test(option[2])).map((option) => option[1]), [selected]);
        }
    }
});

for (const colorTheme of ['deskpilot', 'terminal-amber', 'terminal-green']) {
    test(`Settings applies ${colorTheme} immediately without saving Host Server Settings`, () => {
        const { context, controls, root, values } = themeControls({
            ad_theme: 'dark', ad_color_theme: 'terminal-green',
        });
        const handler = source.split('\n').find((line) => line.includes("$('set-color-theme').onchange ="));
        assert.ok(handler, 'The theme selector must have a change handler');
        vm.runInContext(handler, context);
        controls['set-color-theme'].value = colorTheme;
        controls['set-color-theme'].onchange({ target: controls['set-color-theme'] });
        assert.equal(values.get('ad_color_theme'), colorTheme);
        assert.equal(values.get('ad_theme'), 'dark');
        assert.equal(root.dataset.colorTheme, colorTheme);
        assert.equal(root.dataset.theme, 'dark');
    });
}