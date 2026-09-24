import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// The Skill conformance panel runs against the real app.js block, not a copy of
// it: the source between the section markers is evaluated in a sandbox with the
// DOM helpers the SPA provides. What is asserted here is what a user sees.

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
const enSource = readFileSync(new URL('../../source/web/assets/locales/en.js', import.meta.url), 'utf8');

// The real translator and the real English catalog: a test that stubs them
// proves nothing about what a user reads.
const { createTranslator } = await import(new URL('../../source/web/assets/i18n.js', import.meta.url));
const { en } = await import(new URL('../../source/web/assets/locales/en.js', import.meta.url));
const tr = createTranslator('en');

function node(tag) {
    return {
        tag,
        className: '',
        title: '',
        hidden: false,
        children: [],
        _text: '',
        set textContent(value) { this._text = String(value); this.children = []; },
        get textContent() { return this._text; },
        appendChild(child) { this.children.push(child); return child; },
    };
}

function sandbox(overrides = {}) {
    const host = node('div');
    const context = vm.createContext({
        $: (id) => (id === 'cust-editor-conformance' ? host : null),
        el: (cls, tag = 'div') => { const n = node(tag); n.className = cls || ''; return n; },
        document: { createElement: (tag) => node(tag) },
        tr,
        ...overrides,
    });
    const start = source.indexOf('// ===== Skill conformance display =====');
    const end = source.indexOf('// ===== end Skill conformance display =====');
    assert.ok(start >= 0 && end > start, 'app.js must keep the Skill conformance section markers');
    vm.runInContext(source.slice(start, end), context);
    return { context, host };
}

function texts(root) {
    const out = [];
    const walk = (n) => {
        if (n.textContent) out.push(n.textContent);
        n.children.forEach(walk);
    };
    root.children.forEach(walk);
    return out;
}

const conformantSkill = {
    category: 'skill',
    name: 'pdf-processing',
    root: 'C:/skills',
    precedence: 'primary',
    conformant: true,
    metadata: {},
    warnings: [],
};

test('a Skill shows only the optional fields it actually declares', () => {
    const { context } = sandbox();
    assert.equal(context.custSkillMetaLines(conformantSkill).length, 0);

    const declared = Array.from(context.custSkillMetaLines({
        ...conformantSkill,
        metadata: { license: 'MIT', version: '1.0', entries: { author: 'example-org', team: 'docs' } },
    }));
    assert.deepEqual(declared.map((l) => l.field), ['license', 'version', 'entry']);
    assert.deepEqual(declared.map((l) => l.value), ['MIT', '1.0', 'docs']);
});

test('allowed-tools is shown with the note that it grants nothing', () => {
    const { context } = sandbox();
    const lines = context.custSkillMetaLines({
        ...conformantSkill,
        metadata: { allowedTools: 'Bash(rm:*) Read', allowedToolsAuthoritative: false },
    });
    assert.equal(lines.length, 1);
    assert.equal(lines[0].value, 'Bash(rm:*) Read');
    assert.equal(lines[0].note, en['skill.meta.allowedTools.note']);
    // The English copy has to say it outright, not imply it.
    assert.match(enSource, /'skill\.meta\.allowedTools\.note':[^\n]*grants no Permission/);
});

test('a diagnostic renders its localized text and falls back to the server message', () => {
    const { context } = sandbox();
    const lines = context.custSkillDiagnosticLines({
        ...conformantSkill,
        warnings: [
            { code: 'name-missing', severity: 'error', message: 'A Skill must declare a name.' },
            { code: 'a-code-no-catalog-knows', severity: 'warning', message: 'Server said this.' },
        ],
    });
    assert.deepEqual(lines.map((l) => l.text), [en['skill.warn.name-missing'], 'Server said this.']);
    assert.deepEqual(lines.map((l) => l.severity), ['error', 'warning']);
});

test('a diagnostic that carries detail passes the server message through', () => {
    const { context } = sandbox();
    const detail = "More than one Skill is called 'pdf-processing'.";
    const lines = context.custSkillDiagnosticLines({
        ...conformantSkill,
        warnings: [{ code: 'duplicate-name', severity: 'warning', message: detail }],
    });
    assert.equal(lines[0].text, detail, 'a {message} catalog entry must not swallow the specifics');
});

test('advice does not count as a problem', () => {
    const { context } = sandbox();
    assert.equal(context.custSkillSummary(conformantSkill).tone, 'ok');
    assert.equal(context.custSkillSummary(conformantSkill).text, en['skill.conformance.ok']);
    assert.equal(
        context.custSkillSummary({ ...conformantSkill, warnings: [{ code: 'description-terse', severity: 'info' }] }).tone,
        'ok',
    );
    const bad = context.custSkillSummary({
        ...conformantSkill,
        warnings: [
            { code: 'name-missing', severity: 'error' },
            { code: 'name-invalid', severity: 'warning' },
            { code: 'description-terse', severity: 'info' },
        ],
    });
    assert.equal(bad.tone, 'warn');
    assert.equal(bad.text, en['skill.conformance.problems.other'].replace('{count}', '2'));
    const one = context.custSkillSummary({ ...conformantSkill, warnings: [{ code: 'name-invalid', severity: 'warning' }] });
    assert.equal(one.text, en['skill.conformance.problems.one'].replace('{count}', '1'), 'the count is pluralized through the translator');
});

test('a Skill DeskPilot could not certify never reads as conformant', () => {
    const { context } = sandbox();
    // Findings past the display budget still decide the verdict, so the summary
    // must not fall back to "follows the format" when nothing is listed.
    const unverified = context.custSkillSummary({ ...conformantSkill, conformant: false, warnings: [] });
    assert.equal(unverified.tone, 'warn');
    assert.equal(unverified.text, en['skill.conformance.unverified']);
    // Advice alone leaves a conformant Skill conformant.
    const advised = context.custSkillSummary({
        ...conformantSkill,
        conformant: true,
        warnings: [{ code: 'description-terse', severity: 'info' }],
    });
    assert.equal(advised.text, en['skill.conformance.ok']);
});

test('a shadowed copy says where it came from and who wins', () => {
    const { context } = sandbox();
    assert.equal(context.custSkillPrecedenceLine(conformantSkill), tr('skill.precedence.primary', { root: 'C:/skills' }));
    const shadowed = context.custSkillPrecedenceLine({ ...conformantSkill, precedence: 'shadowed' });
    assert.equal(shadowed, tr('skill.precedence.shadowed', { root: 'C:/skills' }));
    assert.ok(shadowed.includes('C:/skills'), 'the reader is told which copy this is');
    assert.equal(context.custSkillPrecedenceLine({ category: 'agent' }), null);
    assert.equal(context.custSkillFlagText({ ...conformantSkill, precedence: 'shadowed' }), en['skill.precedence.shadowedShort']);
    assert.equal(context.custSkillFlagText({ category: 'agent', name: 'x' }), '');
});

test('the panel renders Skill metadata as text and hides for other categories', () => {
    const { context, host } = sandbox();
    context.renderCustConformance({
        ...conformantSkill,
        metadata: { license: 'MIT' },
        warnings: [{ code: 'name-invalid', severity: 'warning', message: 'bad name' }],
    });
    assert.equal(host.hidden, false);
    const rendered = texts(host);
    assert.ok(rendered.includes(en['skill.conformance.problems.one'].replace('{count}', '1')));
    assert.ok(rendered.includes('MIT'));
    assert.ok(rendered.includes(en['skill.warn.name-invalid']));

    context.renderCustConformance({ category: 'agent', name: 'legal' });
    assert.equal(host.hidden, true);
    assert.deepEqual(host.children, [], 'the panel must not keep the previous Skill on screen');
});

test('hostile metadata stays text and is never parsed as markup', () => {
    const { context, host } = sandbox();
    const payload = '<img src=x onerror=alert(1)>';
    context.renderCustConformance({
        ...conformantSkill,
        metadata: { license: payload, entries: { note: payload } },
        warnings: [{ code: 'unknown-code', severity: 'warning', message: payload }],
    });
    const rendered = texts(host);
    assert.ok(rendered.includes(payload), 'the value is written verbatim as text');
    const block = source.slice(
        source.indexOf('// ===== Skill conformance display ====='),
        source.indexOf('// ===== end Skill conformance display ====='),
    );
    assert.ok(!block.includes('innerHTML'), 'the conformance panel must never build markup from a Skill');
});
