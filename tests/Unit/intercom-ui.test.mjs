import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');

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