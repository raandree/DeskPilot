import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
const start = source.indexOf('function renderApproval(');
const end = source.indexOf('\nfunction renderUsage(', start);
assert.ok(start >= 0 && end > start);
function element(className = '') {
    const classes = new Set(className.split(/\s+/).filter(Boolean));
    return {
        children: [], dataset: {}, textContent: '',
        classList: { add: value => classes.add(value), remove: value => classes.delete(value), contains: value => classes.has(value) },
        append(...items) { this.children.push(...items); },
        appendChild(item) { this.children.push(item); },
        setAttribute() {}, focus() {}, querySelectorAll() { return []; },
    };
}
for (const kind of ['Terminal', 'FileWrite', 'Mcp']) {
    test(`${kind} approval makes the initially hidden prompt container visible`, () => {
        const node = element('user-prompts hidden');
        const context = vm.createContext({
            el: element, tr: key => key, APPROVAL_TITLES: {},
            approvalDetail: () => [element('approval-row')], scrollThread() {},
        });
        vm.runInContext(source.slice(start, end), context);
        context.renderApproval(node, { id: 'fixture', class: kind, summary: {}, allowedScopes: ['once'] }, 'conversation');
        assert.equal(node.children.length, 1);
        assert.equal(node.classList.contains('hidden'), false);
        assert.equal(node.children[0].dataset.approvalId, 'fixture');
    });
}

test('an invalid approval leaves the empty container hidden', () => {
    const node = element('user-prompts hidden');
    const context = vm.createContext({});
    vm.runInContext(source.slice(start, end), context);
    context.renderApproval(node, {}, 'conversation');
    assert.equal(node.children.length, 0);
    assert.equal(node.classList.contains('hidden'), true);
});
