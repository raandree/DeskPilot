import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
function definition(name, optional = false) {
    const start = source.indexOf(`function ${name}(`);
    if (start < 0 && optional) return '';
    assert.ok(start >= 0, `${name} must exist`);
    const opening = source.indexOf('{', start);
    let depth = 0;
    for (let index = opening; index < source.length; index++) {
        if (source[index] === '{') depth++;
        if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1);
    }
    throw new Error(`Unbalanced ${name}`);
}
const context = vm.createContext({
    t: (value) => value,
    el: (className, tag = 'div') => ({ className, tag, textContent: '', children: [], append(...items) { this.children.push(...items); } }),
    escapeHtml: (value) => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
    activityKind: () => ({ ico: '#', label: 'Ran', noun: 'commands' }),
    activityLine: () => 'Ran command',
});
vm.runInContext([
    definition('terminalExecutionRows', true),
    definition('terminalExecutionLabel', true),
    definition('approvalRow'), definition('approvalDetail'), definition('activityRowHtml'),
].join('\n'), context);
const flatten = (node) => [node.textContent, ...(node.children || []).map(flatten)].join(' ');
const policy = {
    mode: 'isolated', projectAccess: 'read-only', network: 'allow-list',
    allowedHosts: ['example.com'], environment: [{ name: 'DP_TOKEN', secret: true, value: 'must-not-render' }],
    timeoutSeconds: 120, cpuCount: 1, memoryMB: 1024, processLimit: 64, outputBytes: 1048576, tempMB: 128,
};

test('Terminal approval renders the boundary, every limit, and only environment names', () => {
    const rows = context.approvalDetail({ class: 'Terminal', summary: { command: 'npm install', workingDirectory: '/project', execution: policy } });
    const text = rows.map(flatten).join(' ');
    for (const value of ['Isolated', 'read-only', 'example.com', 'DP_TOKEN', 'secret', '120', '1024', '64', '1048576', '128']) {
        assert.ok(text.includes(value), `Approval must show ${value}`);
    }
    assert.ok(!text.includes('must-not-render'));
});

test('old Terminal approvals explicitly render Local', () => {
    const text = context.approvalDetail({ class: 'Terminal', summary: { command: 'npm install' } }).map(flatten).join(' ');
    assert.ok(text.includes('Local'));
});

test('command Activity renders its recorded mode, not current Settings', () => {
    const html = context.activityRowHtml({ kind: 'run', detail: 'git status', execution: policy }, false);
    assert.ok(html.includes('Isolated'));
    assert.ok(html.includes('read-only'));
});
