import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

let child = {};
try { child = await import('../../source/web/assets/child.js'); } catch (error) {
    if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
}

test('child consent freezes explicit estimated mode and selected files', () => {
    assert.equal(typeof child.childStartRequest, 'function');
    const request = child.childStartRequest({ prompt: 'Inspect input.', paths: 'input.txt\nnotes/todo.md', consent: true, writable: false });
    assert.equal(request.profile, 'single-child-v3');
    assert.equal(request.budgetMode, 'provider-estimate');
    assert.equal(request.projectAccess, 'read-only');
    assert.deepEqual(request.selectedPaths, ['input.txt', 'notes/todo.md']);
    assert.equal(Object.hasOwn(request, 'history'), false);
});

test('child consent refuses blank selection, traversal, and missing consent', () => {
    assert.equal(typeof child.childStartRequest, 'function');
    for (const value of [{ paths: '' }, { paths: '../secret' }, { paths: 'C:/secret' }, { consent: false }]) {
        assert.throws(() => child.childStartRequest({ prompt: 'Inspect.', paths: 'input.txt', consent: true, ...value }));
    }
});

test('unknown child Usage stays unknown rather than zero or a guaranteed charge', () => {
    assert.equal(typeof child.childUsageText, 'function');
    const text = child.childUsageText({ UsageKnown: false, ReservedTokens: 132, ReservedCostUSD: 0.25, KnownUsage: { PromptTokens: 20 } });
    assert.match(text, /unknown/i);
    assert.match(text, /132/);
    assert.match(text, /estimated/i);
    assert.doesNotMatch(text, /maximum charge|guaranteed/i);
});

test('proposal text is decoded as data without applying it or creating HTML', () => {
    assert.equal(typeof child.childProposalText, 'function');
    const text = '<img src="https://untrusted.example">';
    assert.equal(child.childProposalText({ size: text.length, contentBase64: Buffer.from(text).toString('base64') }), text);
    assert.throws(() => child.childProposalText({ size: 999999999, contentBase64: '' }));
});

test('an admitted child task opens its recovered record without an ordinary rerun action', () => {
    const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
    const definition = source.slice(source.indexOf('function buildUserEl('), source.indexOf('function buildAssistantEl('));
    const node = (className, tag = 'div') => ({ className, tag, dataset: {}, children: [], appendChild(item) { this.children.push(item); }, setAttribute() {} });
    let opened;
    const context = vm.createContext({
        el: node, asArray: (value) => value || [], t: (key) => key,
        buildCopyButton: () => node('copy', 'button'), copyMessageText() {},
        childPanel: { open: (id) => { opened = id; } },
    });
    vm.runInContext(definition, context);
    const rendered = context.buildUserEl({ id: 'message', text: 'Admitted private task.', childRunId: 'child-id' });
    const flatten = (item) => [item, ...item.children.flatMap(flatten)];
    const controls = flatten(rendered).filter((item) => item.tag === 'button');
    const view = controls.find((item) => item.textContent === 'composer.child.view');
    assert.ok(view, 'An interrupted child must remain reachable from its user Message');
    view.onclick();
    assert.equal(opened, 'child-id');
    assert.equal(controls.some((item) => item.title === 'Edit & resend'), false);
});
