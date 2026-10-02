import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import { splitRelPath } from '../../source/web/assets/diff.js';
import { ICON_NAMES, iconKey, iconSvg } from '../../source/web/assets/icons.js';

const source = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
function between(start, end) {
    const first = source.indexOf(start);
    const last = source.indexOf(end, first);
    assert.ok(first >= 0 && last > first, `Missing source boundaries: ${start}, ${end}`);
    return source.slice(first, last);
}

class Element {
    constructor(className = '', tag = 'div') {
        this.tagName = tag.toUpperCase();
        this.classes = new Set(className.split(/\s+/).filter(Boolean));
        this.classList = {
            add: (...values) => values.forEach(value => this.classes.add(value)),
            remove: (...values) => values.forEach(value => this.classes.delete(value)),
            contains: value => this.classes.has(value),
            toggle: (value, on = !this.classes.has(value)) => on ? this.classes.add(value) : this.classes.delete(value),
        };
        this.children = [];
        this.dataset = {};
        this.listeners = {};
        this.open = false;
        this.scrollTop = 0;
        this.scrollHeight = 1000;
        this.clientHeight = 300;
        this.textContent = '';
    }
    set innerHTML(value) {
        this.html = value;
        this.children = [];
        if (value.includes('<summary>')) this.appendChild(new Element('', 'summary'));
        if (value.includes('class="disclosure-body"')) this.appendChild(new Element('disclosure-body'));
    }
    get innerHTML() { return this.html || ''; }
    appendChild(node) {
        node.parentElement = this;
        this.children.push(node);
        return node;
    }
    append(...nodes) { nodes.forEach(node => this.appendChild(typeof node === 'string' ? Object.assign(new Element('', '#text'), { textContent: node }) : node)); }
    prepend(node) { node.parentElement = this; this.children.unshift(node); }
    replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
    setAttribute(name, value) { this[name] = value; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    scrollTo({ top }) { this.scrollTop = top; }
    matches(selector) {
        if (selector.includes(':last-child') && this.parentElement.children.at(-1) !== this) return false;
        if (selector.includes(':not([data-sealed="1"])') && this.dataset.sealed === '1') return false;
        const simple = selector.split(':')[0];
        return simple.startsWith('.') ? this.classes.has(simple.slice(1)) : this.tagName.toLowerCase() === simple;
    }
    querySelectorAll(selector) {
        return this.children.flatMap(node => [
            ...(node.matches(selector) ? [node] : []), ...node.querySelectorAll(selector),
        ]);
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    // Everything a reader could see: text set through the DOM, never parsed.
    get allText() { return [this.textContent, ...this.children.map(child => child.allText)].join(' '); }
}

function fixture() {
    const nodes = new Map(['thread', 'thread-jump', 'prompt', 'activity-hint', 'activity-status', 'btn-send', 'btn-dispatch'].map(id => [id, new Element()]));
    const edits = [];
    const context = vm.createContext({
        el: (className, tag) => new Element(className, tag),
        $: id => nodes.get(id),
        document: { createElement: tag => new Element('', tag) },
        state: { streaming: true, settings: {} },
        asArray: value => Array.isArray(value) ? value : value == null ? [] : [value],
        escapeHtml: value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;'),
        renderMarkdown: value => value,
        splitRelPath, projectRelPath: () => null, iconKey, iconSvg,
        terminalExecutionLabel: () => 'Local', openDiffViewer() {},
        hydrateCopies() {}, decorateArtifacts() {}, buildMessageActions() {}, renderSteps() {},
        renderUsage() {}, renderChanges() {}, closeDispatchPopover() {},
        aiChanges: { undoable: true },
        buildChangeRow: () => new Element('changes-row', 'button'),
    });
    vm.runInContext([
        between('function buildAssistantEl(', 'function renderSteps('),
        between('// ===== Activity (what the Turn touched', '// ===== Changes review'),
        between('function noteFileEdit(', 'function buildChangeRow('),
        between('function renderTasks(', 'function renderUserPrompt('),
        between('const THREAD_STICK_PX =', '// ===== Sending a Turn'),
        between('function showInlineError(', '// After the first Turn'),
        between('function setStreamingUI(', '// ===== Dispatch'),
    ].join('\n'), context);
    const wrap = context.buildAssistantEl({ id: 'fixture' });
    nodes.get('thread').appendChild(wrap);
    const realNoteFileEdit = context.noteFileEdit;
    context.noteFileEdit = (w, path) => { edits.push(path); realNoteFileEdit(w, path); };
    return { context, wrap, edits, cards: () => wrap._refs.agents.querySelectorAll('.agent-run') };
}

const started = (extra = {}) => ({
    id: 'a_0123456789abcdef', tool: 'run_subagent', kind: 'agent', detail: 'general-purpose', phase: 'started',
    status: 'running', description: 'docs audit', input: 'Audit every example in docs/.', actions: [], ...extra,
});
const finished = (extra = {}) => ({
    id: 'a_0123456789abcdef', tool: 'run_subagent', kind: 'agent', detail: 'general-purpose', phase: 'finished',
    status: 'completed', output: 'Two examples are stale.', reason: '', durationMs: 12400, iterations: 5, toolCalls: 3, costUSD: 0.0042, ...extra,
});
const part = (card, name) => card.querySelector(`.${name}`);

test('a Subagent run sits with the work summaries, ahead of the thinking and the answer', () => {
    const { wrap } = fixture();
    const r = wrap._refs;
    assert.ok(r.agents, 'the message has a place for Subagent runs');
    assert.ok(wrap.children.indexOf(r.activity) < wrap.children.indexOf(r.agents));
    assert.ok(wrap.children.indexOf(r.agents) < wrap.children.indexOf(r.flow));
    assert.equal(r.agents.classList.contains('hidden'), true, 'no empty panel before a run starts');
});

test('a started Subagent opens a running card with its task, and its Tool calls nest inside it', () => {
    const { context, wrap, edits, cards } = fixture();
    context.noteActivity(wrap, started());
    assert.equal(cards().length, 1);
    const card = cards()[0];
    assert.equal(card.tagName, 'DETAILS');
    assert.equal(card.dataset.status, 'running');
    assert.equal(card.open, true, 'a running card shows what it was asked to do');
    assert.match(part(card, 'agent-run-title').allText, /Running agent/);
    assert.match(part(card, 'agent-run-name').textContent, /^general-purpose$/);
    assert.equal(part(card, 'agent-run-label').textContent, 'docs audit');
    assert.equal(part(card, 'agent-run-input').textContent, 'Audit every example in docs/.');
    assert.equal(wrap._refs.agents.classList.contains('hidden'), false);

    context.noteActivity(wrap, { kind: 'write', tool: 'write_file', detail: 'docs/a.md', parentId: 'a_0123456789abcdef' });
    context.noteActivity(wrap, { kind: 'read', tool: 'read_file', detail: 'docs/b.md', parentId: 'a_0123456789abcdef' });
    const tools = part(cards()[0], 'agent-run-tools');
    assert.match(tools.innerHTML, /docs\/a\.md/);
    assert.match(tools.innerHTML, /docs\/b\.md/);
    assert.deepEqual(edits, ['docs/a.md'], 'a Subagent write is a change to review too');

    const panel = wrap._refs.activity;
    assert.equal(panel._liveActions.length, 1, 'the Subagent\'s Tool calls are not top-level actions');
    assert.match(panel.innerHTML, /Working — 1 action/);
    assert.match(panel.innerHTML, /Ran agent/);
});

test('a finished Subagent shows its report and folds unless the reader opened it', () => {
    const { context, wrap, cards } = fixture();
    context.noteActivity(wrap, started());
    context.noteActivity(wrap, finished());
    assert.equal(cards().length, 1, 'the finish completes the same card');
    const card = cards()[0];
    assert.equal(card.dataset.status, 'completed');
    assert.equal(card.open, false);
    assert.match(part(card, 'agent-run-title').allText, /Agent .*completed/);
    assert.equal(part(card, 'agent-run-output').textContent, 'Two examples are stale.');
    assert.equal(part(card, 'agent-run-input').textContent, 'Audit every example in docs/.', 'the task is kept beside the report');
    assert.match(part(card, 'agent-run-meta').textContent, /12s/);
    assert.match(part(card, 'agent-run-meta').textContent, /3 tool calls/);
    assert.match(part(card, 'agent-run-meta').textContent, /\$0\.0042/);

    const kept = fixture();
    kept.context.noteActivity(kept.wrap, started());
    kept.cards()[0].dataset.touched = '1';
    kept.context.noteActivity(kept.wrap, finished());
    assert.equal(kept.cards()[0].open, true);
});

test('a run that did not complete says why instead of showing a report: <status>', () => {
    for (const [status, words] of [['refused', /was refused/], ['failed', /failed/], ['cancelled', /was cancelled/], ['stopped', /was stopped/]]) {
        const { context, wrap, cards } = fixture();
        context.noteActivity(wrap, started());
        context.noteActivity(wrap, finished({ status, output: '', reason: 'The task is too long.', costUSD: null }));
        const card = cards()[0];
        assert.equal(card.dataset.status, status);
        assert.match(part(card, 'agent-run-title').allText, words, status);
        assert.equal(part(card, 'agent-run-reason').textContent, 'The task is too long.');
        assert.equal(part(card, 'agent-run-output'), null);
        assert.doesNotMatch(part(card, 'agent-run-meta').textContent, /\$/, 'an unknown cost is not shown as a price');
    }
});

test('Model text in a Subagent run is shown as text, never parsed as markup', () => {
    const { context, wrap, cards } = fixture();
    const hostile = '<img src=x onerror="alert(1)">';
    context.noteActivity(wrap, started({ detail: hostile, description: hostile, input: hostile }));
    context.noteActivity(wrap, finished({ detail: hostile, output: hostile }));
    const card = cards()[0];
    for (const name of ['agent-run-name', 'agent-run-label', 'agent-run-input', 'agent-run-output']) {
        assert.equal(part(card, name).textContent, hostile, name);
        assert.equal(part(card, name).innerHTML, '', `${name} never receives markup`);
    }
    assert.doesNotMatch(wrap._refs.activity.innerHTML, /<img/);
});

test('a stored Message rebuilds its Subagent runs, with their Tool calls, from its Activity', () => {
    const { context, wrap, cards } = fixture();
    const run = { ...started(), ...finished(), actions: [{ kind: 'read', tool: 'read_file', detail: 'docs/c.md', parentId: 'a_0123456789abcdef' }] };
    context.finalizeAssistant(wrap, { text: 'Done.', activity: { actions: [run, { kind: 'read', tool: 'read_file', detail: 'README.md' }] } });
    assert.equal(cards().length, 1);
    const card = cards()[0];
    assert.equal(card.dataset.status, 'completed');
    assert.equal(card.open, false);
    assert.match(part(card, 'agent-run-tools').innerHTML, /docs\/c\.md/);
    assert.equal(part(card, 'agent-run-output').textContent, 'Two examples are stale.');
    assert.match(wrap._refs.activity.innerHTML, /Activity — 2 actions/);
});

test('consecutive runs fold as "Ran 2 agents", not by repeating the single-run verb', () => {
    const { context, wrap } = fixture();
    context.noteActivity(wrap, started());
    context.noteActivity(wrap, finished());
    context.noteActivity(wrap, started({ id: 'a_fedcba9876543210', detail: 'reviewer' }));
    assert.match(wrap._refs.activity.innerHTML, /Ran 2 agents/);
    assert.doesNotMatch(wrap._refs.activity.innerHTML, /Ran agent 2/);
});

test('a thinking section that only dispatched a Subagent is titled by it', () => {
    const { context } = fixture();
    const section = '10:00:01 \u2192 run_subagent\n  agent: reviewer\n  prompt: Review the diff.\n';
    const { title, icon } = context.summarizeThinking(section);
    assert.equal(title, 'Ran agent reviewer');
    assert.equal(icon, 'agent');
});

test('the Subagent icon is a drawn icon, and the Permission says what it costs', () => {
    assert.ok(ICON_NAMES.includes('agent'));
    assert.notEqual(iconSvg('agent'), iconSvg('tool'));
    const permissions = between('const PERMISSIONS = [', '];');
    assert.match(permissions, /key: 'subagents', name: 'Subagents'/);
    assert.match(permissions, /same permissions/);
    assert.match(permissions, /Model calls/);
});

test('the Subagents Permission says so when the Engine cannot run Subagents', async () => {
    const definitions = between('const PERMISSIONS = [', '];') + '];\n' + between('function buildPermList(', '// ===== Projects =====');
    for (const supported of [false, true]) {
        const context = vm.createContext({
            el: (className, tag) => new Element(className, tag),
            document: { createElement: tag => new Element('', tag) },
            state: { streaming: false, settings: { permissions: { subagents: true } } },
            api: async (method, path) => (path === '/api/health' ? { subagentsSupported: supported } : {}),
            terminalExecutionLabel: () => 'Local', toast() {}, updatePermDot() {},
        });
        vm.runInContext(definitions, context);
        const container = new Element();
        context.buildPermList(container);
        await new Promise(resolve => setImmediate(resolve));
        const row = container.children.find(child => child.querySelector('.perm-meta').innerHTML.includes('Subagents'));
        assert.ok(row, 'the Subagents row is listed');
        const note = row.querySelector('.perm-support');
        assert.ok(note, 'the row has a place for the Engine note');
        if (supported) assert.equal(note.textContent, '');
        else assert.match(note.textContent, /cannot run Subagents/);
    }
});
