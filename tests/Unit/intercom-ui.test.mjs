import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');

function between(start, end) {
    const first = source.indexOf(start);
    const last = source.indexOf(end, first);
    assert.ok(first >= 0 && last > first, `Missing source boundaries: ${start}, ${end}`);
    return source.slice(first, last);
}

// The real renderer and its two helpers, run against a stub status box.
function renderPanel(intercom) {
    const box = { innerHTML: '' };
    const context = vm.createContext({
        $: (id) => (id === 'set-intercom-status' ? box : null),
        state: { intercom, intercomStale: false },
    });
    vm.runInContext(
        between('const escapeHtml = ', 'function toast(') + '\n' +
        between('const asArray = ', '\n') + '\n' +
        between('function renderIntercomPanel() {', '\n// The dismissible "update available" banner.') + '\n' +
        'renderIntercomPanel();',
        context);
    return box.innerHTML;
}

function controls(failSave = false) {
    const input = { checked: false, disabled: false };
    const requests = [];
    const notices = [];
    const state = { intercom: { requireGroupMention: false } };
    const context = vm.createContext({
        $: () => input,
        state,
        api: async (method, path, patch) => {
            requests.push({ method, path, patch });
            if (failSave) throw new Error('Save failed');
            return { ...state.intercom, ...patch };
        },
        updateIntercomChip() {},
        renderIntercomPanel() {},
        refreshIntercom() {},
        toast: (message) => notices.push(message),
    });
    const saveStart = source.indexOf('    const saveIntercom = async (patch) => {');
    const saveEnd = source.indexOf('    const icNumber =', saveStart);
    const changeStart = source.indexOf("    $('set-ic-mention').onchange =");
    const changeEnd = source.indexOf("    $('set-ic-chat').onchange =", changeStart);
    assert.ok(saveStart >= 0 && saveEnd > saveStart, 'The Intercom save handler must exist');
    assert.ok(changeStart >= 0 && changeEnd > changeStart, 'The group mention control must have a change handler');
    vm.runInContext(source.slice(saveStart, saveEnd) + source.slice(changeStart, changeEnd), context);
    return { input, requests, notices, state };
}

test('group mention checkbox renders the saved setting', () => {
    const label = source.match(/<label><input type="checkbox" id="set-ic-mention"[^\n]*<\/label>/)?.[0];
    assert.ok(label, 'Intercom must expose a group mention checkbox');
    for (const required of [false, true]) {
        const html = vm.runInNewContext('`' + label + '`', { ic: { requireGroupMention: required } });
        assert.equal(html.includes('checked'), required);
        assert.match(html, /Require a bot mention in groups/);
    }
});

for (const required of [false, true]) {
    test(`group mention checkbox saves ${required} through Intercom`, async () => {
        const { input, requests, state } = controls();
        state.intercom.requireGroupMention = !required;
        input.checked = required;

        const saving = input.onchange({ target: input });
        assert.equal(input.disabled, true);
        await saving;

        assert.equal(requests.length, 1);
        assert.equal(requests[0].method, 'PUT');
        assert.equal(requests[0].path, '/api/intercom');
        assert.equal(requests[0].patch.requireGroupMention, required);
        assert.equal(Object.keys(requests[0].patch).length, 1);
        assert.equal(state.intercom.requireGroupMention, required);
        assert.equal(input.checked, required);
        assert.equal(input.disabled, false);
    });

    test(`failed group mention save restores ${!required}`, async () => {
        const { input, state, notices } = controls(true);
        state.intercom.requireGroupMention = !required;
        input.checked = required;

        await input.onchange({ target: input });

        assert.equal(state.intercom.requireGroupMention, !required);
        assert.equal(input.checked, !required);
        assert.equal(input.disabled, false);
        assert.deepEqual(notices, ['Save failed']);
    });
}

test('a folded audit line says how many group Messages it stands for', () => {
    const sinceUtc = '2026-10-02T10:00:00.000Z';
    const html = renderPanel({
        status: 'on',
        counters: { received: 38 },
        log: [
            { utc: '2026-10-02T10:01:00.000Z', direction: 'in', kind: 'prompt', detail: 'ship it', chatId: '111', from: 'Mo', accepted: true },
            {
                utc: '2026-10-02T10:05:00.000Z', direction: 'in', kind: 'unaddressed',
                detail: 'Group Message did not mention this Intercom.', chatId: '-1004455397827', from: '',
                accepted: false, messageCount: 37, sinceUtc,
            },
        ],
    });

    assert.match(html, /intercom-kind tiny">unaddressed</);
    assert.ok(html.includes(`×37 since ${new Date(sinceUtc).toLocaleTimeString()}`), html);
    assert.equal(html.split('×').length - 1, 1, 'Only the folded line carries a count');
});

test('a single un-addressed Message carries no count', () => {
    const html = renderPanel({
        status: 'on',
        log: [{
            utc: '2026-10-02T10:05:00.000Z', direction: 'in', kind: 'unaddressed',
            detail: 'Group Message did not mention this Intercom.', chatId: '-1004455397827', from: '',
            accepted: false, messageCount: 1, sinceUtc: '2026-10-02T10:05:00.000Z',
        }],
    });

    assert.match(html, /Group Message did not mention this Intercom\./);
    assert.ok(!html.includes('×'), html);
});