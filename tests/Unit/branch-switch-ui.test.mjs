import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// The Git bar picker and the Branch Wizard rows run against the real app.js
// functions, sliced out between stable markers and evaluated with the minimal
// DOM surface they touch. What is asserted is what a user can click.

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');

function slice(startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.ok(start >= 0 && end > start, `app.js must keep '${startMarker}' before '${endMarker}'`);
    return source.slice(start, end);
}

function node(tag) {
    const n = {
        tag,
        className: '',
        title: '',
        value: '',
        disabled: false,
        selected: false,
        children: [],
        attributes: {},
        _html: '',
        _text: '',
        set innerHTML(value) { this._html = String(value); this.children = []; },
        get innerHTML() { return this._html; },
        set textContent(value) { this._text = String(value); this.children = []; },
        get textContent() { return this._text; },
        appendChild(child) { this.children.push(child); return child; },
        append(...nodes) { this.children.push(...nodes); },
        setAttribute(name, value) { this.attributes[name] = String(value); },
        classList: { add() {}, remove() {} },
    };
    return n;
}

function sandbox({ response = null, failure = null } = {}) {
    const bar = node('div');
    const calls = [];
    const toasts = [];
    const busyLabels = [];
    const redraws = [];
    const branchWiz = { step: 'home', busyLabel: '', defaultBranch: 'main' };
    const context = vm.createContext({
        $: (id) => (id === 'git-bar' ? bar : null),
        el: (cls, tag = 'div') => { const n = node(tag); n.className = cls || ''; return n; },
        document: { createElement: (tag) => node(tag) },
        escapeHtml: (s) => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
        api: async (method, path, body) => {
            calls.push(JSON.stringify([method, path, body]));
            if (failure) throw new Error(failure);
            return response;
        },
        toast: (message) => toasts.push(message),
        refreshExplorer: () => redraws.push('explorer'),
        refreshGitBar: () => redraws.push('git-bar'),
        renderBranchWizard: () => { if (branchWiz.step === 'busy') busyLabels.push(branchWiz.busyLabel); },
        branchWizLoad: async () => {},
        openBranchWizard: () => {},
        branchWiz,
    });
    vm.runInContext([
        slice('function gitLegendText(def)', '// The changed files, listed directly under the Git bar.'),
        slice('async function switchBranch(', '// ===== Branch Wizard ====='),
        slice('function branchWizBtn(', 'function renderBranchHome('),
        slice('function buildBranchRow(', 'function renderBranchCreate('),
    ].join('\n'), context);
    return { context, bar, calls, toasts, busyLabels, redraws };
}

const serverOnly = {
    name: 'origin/ai/fy26-report', display: 'origin/ai/fy26-report', shortName: 'ai/fy26-report',
    isRemote: true, isCurrent: false, isDefault: false, hasLocal: false, merged: false,
};
const mainBranch = {
    name: 'main', display: 'main', isRemote: false, isCurrent: true, isDefault: true, hasLocal: true, merged: true,
};

function actionLabels(row) {
    const acts = row.children.find((c) => c.className === 'branch-row-acts');
    return acts.children.map((b) => b.textContent);
}

function flush() {
    return new Promise((resolve) => setImmediate(resolve));
}

test('a server-only Branch row offers Switch', () => {
    const { context } = sandbox();
    const row = context.buildBranchRow(serverOnly, 'main');
    assert.deepEqual(actionLabels(row), ['Switch']);
});

test('the current Branch row still offers no Switch', () => {
    const { context } = sandbox();
    const row = context.buildBranchRow({ ...mainBranch, isDefault: false, name: 'draft', display: 'draft' }, 'main');
    assert.ok(!actionLabels(row).includes('Switch'));
});

test('Switch on a server-only row asks for that Branch and names the local Branch it switched to', async () => {
    const { context, calls, toasts, busyLabels } = sandbox({ response: { branch: 'ai/fy26-report', detached: false } });
    const row = context.buildBranchRow(serverOnly, 'main');
    const acts = row.children.find((c) => c.className === 'branch-row-acts');
    await acts.children.find((b) => b.textContent === 'Switch').onclick();
    assert.deepEqual(calls, [JSON.stringify(['POST', '/api/git/checkout', { branch: 'origin/ai/fy26-report' }])]);
    assert.equal(busyLabels.length, 1);
    assert.match(busyLabels[0], /server/);
    assert.deepEqual(toasts, ['Switched to ai/fy26-report.']);
});

test('the Git bar picker lets a server-only Branch be chosen', async () => {
    const { context, bar, calls, toasts } = sandbox({ response: { branch: 'ai/fy26-report', detached: false } });
    context.renderGitBar(
        { gitAvailable: true, isRepo: true, branch: 'main', detached: false },
        { defaultBranch: 'main', branches: [mainBranch, serverOnly] },
        false,
    );
    const select = bar.children.find((c) => c.tag === 'select');
    const option = select.children.find((o) => o.textContent.includes('origin/ai/fy26-report'));
    assert.equal(option.disabled, false);
    assert.equal(option.value, 'origin/ai/fy26-report');

    select.value = option.value;
    select.onchange();
    await flush();
    assert.deepEqual(calls, [JSON.stringify(['POST', '/api/git/checkout', { branch: 'origin/ai/fy26-report' }])]);
    assert.deepEqual(toasts, ['Getting origin/ai/fy26-report from the server…', 'Switched to ai/fy26-report.']);
});

test('a server-only Branch the Host Server refuses is explained and the Git bar redrawn', async () => {
    const { context, bar, toasts, redraws } = sandbox({ failure: "'ai/fy26-report' no longer exists on the server." });
    context.renderGitBar(
        { gitAvailable: true, isRepo: true, branch: 'main', detached: false },
        { defaultBranch: 'main', branches: [mainBranch, serverOnly] },
        false,
    );
    const select = bar.children.find((c) => c.tag === 'select');
    select.value = 'origin/ai/fy26-report';
    select.onchange();
    await flush();
    assert.equal(toasts.at(-1), "'ai/fy26-report' no longer exists on the server.");
    assert.deepEqual(redraws, ['git-bar']);
});
