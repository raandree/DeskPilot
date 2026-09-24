import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
const start = source.indexOf('async function openCustEditor(');
const end = source.indexOf('\nfunction custLineCount(', start);
assert.ok(start >= 0 && end > start);
const definition = source.slice(start, end);
const item = (name) => ({ name, category: 'skill', path: `${name}/SKILL.md` });
function fixture() {
    const nodes = new Map();
    const pending = [];
    const context = vm.createContext({
        cust: { editor: null },
        $: (id) => {
            if (!nodes.has(id)) nodes.set(id, { textContent: '', value: '', readOnly: false, disabled: false, title: '', scrollTop: 0 });
            return nodes.get(id);
        },
        api: () => new Promise((resolve, reject) => pending.push({ resolve, reject })),
        renderCustConformance() {}, setCustViewMode() {}, showCustEditor() {},
        renderGutter() {}, syncGutterScroll() {}, formatBytes: (value) => String(value),
    });
    vm.runInContext(definition, context);
    return { context, nodes, pending };
}

test('closing a Customization before its content arrives cannot update a missing editor', async () => {
    const { context, nodes, pending } = fixture();
    const opened = context.openCustEditor(item('first'));
    context.cust.editor = null;
    pending[0].resolve({ text: 'stale', bytes: 5, truncated: false });
    await assert.doesNotReject(opened);
    assert.equal(nodes.get('cust-editor').value, '');
});

test('a late Customization response cannot overwrite a newer editor', async () => {
    const { context, nodes, pending } = fixture();
    const first = context.openCustEditor(item('first'));
    const second = context.openCustEditor(item('second'));
    pending[1].resolve({ text: 'current', bytes: 7, truncated: false });
    await second;
    pending[0].resolve({ text: 'stale', bytes: 5, truncated: true });
    await first;
    assert.equal(nodes.get('cust-editor').value, 'current');
    assert.equal(nodes.get('cust-editor').readOnly, false);
});

test('a stale Customization failure cannot replace the active editor status', async () => {
    const { context, nodes, pending } = fixture();
    const first = context.openCustEditor(item('first'));
    const second = context.openCustEditor(item('second'));
    pending[1].resolve({ text: 'current', bytes: 7, truncated: false });
    await second;
    pending[0].reject(new Error('old request failed'));
    await first;
    assert.equal(nodes.get('cust-editor-meta').textContent, '7');
    assert.equal(nodes.get('cust-editor').readOnly, false);
});

test('the empty loading buffer is not editable before authoritative content arrives', async () => {
    const { context, nodes, pending } = fixture();
    const opened = context.openCustEditor(item('first'));
    assert.equal(nodes.get('cust-editor').readOnly, true);
    pending[0].resolve({ text: 'loaded', bytes: 6, truncated: false });
    await opened;
    assert.equal(nodes.get('cust-editor').readOnly, false);
});
