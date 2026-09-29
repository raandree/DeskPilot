import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import { splitRelPath } from '../../source/web/assets/diff.js';

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
        if (value.includes('<summary>')) {
            const summary = this.appendChild(new Element('', 'summary'));
            if (value.includes('thinking-label')) summary.appendChild(new Element('thinking-label', 'span'));
        }
        if (value.includes('class="disclosure-body"')) this.appendChild(new Element('disclosure-body'));
    }
    get innerHTML() { return this.html || ''; }
    appendChild(node) {
        node.parentElement = this;
        this.children.push(node);
        return node;
    }
    append(...nodes) { nodes.forEach(node => this.appendChild(node)); }
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
}

function fixture() {
    const nodes = new Map(['thread', 'activity-hint', 'activity-status', 'btn-send', 'btn-dispatch'].map(id => [id, new Element()]));
    const context = vm.createContext({
        el: (className, tag) => new Element(className, tag),
        $: id => nodes.get(id),
        document: { createElement: tag => new Element('', tag) },
        state: { streaming: true, settings: {} },
        asArray: value => Array.isArray(value) ? value : value == null ? [] : [value],
        escapeHtml: value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;'),
        renderMarkdown: value => value,
        splitRelPath, projectRelPath: () => null,
        hydrateCopies() {}, decorateArtifacts() {}, buildMessageActions() {}, renderSteps() {},
        renderTasks() {}, renderUsage() {}, renderChanges() {}, closeDispatchPopover() {},
        aiChanges: { undoable: true },
        buildChangeRow: () => new Element('changes-row', 'button'),
    });
    vm.runInContext([
        between('function buildAssistantEl(', 'function renderSteps('),
        between('const ACTIVITY_KINDS =', '// ===== Changes review'),
        between('function noteFileEdit(', 'function buildChangeRow('),
        between('const THREAD_STICK_PX =', '// ===== Sending a Turn'),
        between('function showInlineError(', '// After the first Turn'),
        between('function setStreamingUI(', '// ===== Dispatch'),
    ].join('\n'), context);
    const wrap = context.buildAssistantEl({ id: 'fixture' });
    nodes.get('thread').appendChild(wrap);
    return { context, wrap, nodes, boxes: () => wrap.querySelectorAll('.thinking') };
}

const banner = n => `18:13:0${n} \u2500\u2500 Iteration ${n} (chat) \u2500\u2500\n`;
const body = box => box.querySelector('.disclosure-body').textContent;

test('each Engine output starts a separate thinking section even without answer text', () => {
    const { context, wrap, boxes } = fixture();
    const first = banner(1) + '\nthinking:\nInspect the Project.\n';
    const second = banner(2) + '\nthinking:\nReview the findings.';
    context.renderThinking(wrap, first);
    const firstBox = boxes()[0];
    context.renderThinking(wrap, first + second);
    assert.equal(boxes().length, 2);
    assert.equal(body(firstBox), first);
    assert.equal(firstBox.dataset.sealed, '1');
    assert.equal(firstBox.open, false);
    assert.equal(body(boxes()[1]), second);
    assert.equal(boxes()[1].open, true);
    context.renderThinking(wrap, first + second + ' More detail.');
    assert.equal(boxes().length, 2);
    assert.equal(body(firstBox), first);
    assert.equal(body(boxes()[1]), second + ' More detail.');
});

test('coalesced and fragmented iteration frames preserve every character without one section per token', () => {
    const { context, wrap, boxes } = fixture();
    const first = '\n' + banner(1) + 'First output.\n';
    const second = banner(2) + 'Second output.\n';
    context.renderThinking(wrap, first + second.slice(0, 16));
    assert.equal(boxes().length, 1);
    context.renderThinking(wrap, first + second + banner(3) + 'Third');
    assert.equal(boxes().length, 3);
    context.renderThinking(wrap, first + second + banner(3) + 'Third output.');
    assert.equal(boxes().length, 3);
    assert.equal(boxes().map(body).join(''), first + second + banner(3) + 'Third output.');
});

test('indented Tool arguments and ordinary prose do not create thinking sections', () => {
    const { context, wrap, boxes } = fixture();
    const text = banner(1) + `  content:\n    ${banner(2)}Not an iteration boundary.\n<img src=x onerror=alert(1)>`;
    for (let end = 1; end <= text.length; end++) context.renderThinking(wrap, text.slice(0, end));
    assert.equal(boxes().length, 1);
    assert.equal(body(boxes()[0]), text);
    assert.equal(boxes()[0].querySelector('img'), null);
});

test('empty reasoning frames do not open blank thinking sections', () => {
    const { context, wrap, boxes } = fixture();
    context.renderThinking(wrap, '');
    assert.equal(boxes().length, 0);
    assert.equal(wrap._refs.flow.classList.contains('hidden'), true);
});

test('answer text remains between thinking runs and finalization preserves the live sections', () => {
    const { context, wrap, boxes } = fixture();
    context.renderThinking(wrap, banner(1) + 'First thought.');
    context.sealThinking(wrap);
    context.flushAnswerChunk(wrap, 'Here is the first finding.');
    const next = banner(2) + 'Second thought.\n';
    context.renderThinking(wrap, next + banner(3) + 'Third thought.');
    assert.equal(boxes().length, 3);
    assert.deepEqual(wrap._refs.flow.children.map(node => node.classes.has('thinking')), [true, false, true, true]);
    context.finalizeAssistant(wrap, { text: 'Final answer.', reasoning: 'Flat Engine result.' });
    assert.equal(boxes().length, 3);
    assert.ok(boxes().every(box => box.dataset.sealed === '1' && !box.open));
    assert.equal(wrap._refs.content.innerHTML, 'Final answer.');
    assert.equal(body(boxes()[1]), next);
});

test('a thinking section the reader opened stays open when the next section arrives', () => {
    const { context, wrap, boxes } = fixture();
    const first = banner(1) + 'First thought.\n';
    context.renderThinking(wrap, first);
    boxes()[0].querySelector('summary').listeners.click();
    context.renderThinking(wrap, first + banner(2) + 'Second thought.');
    assert.equal(boxes().length, 2);
    assert.equal(boxes()[0].open, true);
    assert.equal(boxes()[0].dataset.sealed, '1');
    context.showInlineError(wrap, 'Turn stopped.');
    assert.equal(boxes()[1].open, false);
    assert.equal(boxes()[1].dataset.sealed, '1');
});

test('stored traces retain iteration sections while legacy prose remains readable', () => {
    const { context, wrap, boxes } = fixture();
    const text = banner(1) + 'First.\n' + banner(2) + 'Second.';
    context.finalizeAssistant(wrap, { reasoning: text, stopped: true });
    assert.equal(boxes().length, 2);
    assert.equal(boxes().map(body).join(''), text);
    assert.ok(boxes().every(box => !box.open && box.dataset.sealed === '1'));
    const legacy = context.buildAssistantEl({ id: 'legacy' });
    context.finalizeAssistant(legacy, { text: 'Answer.', reasoning: 'Unstructured older reasoning.' });
    assert.equal(legacy.querySelectorAll('.thinking').length, 1);
    assert.equal(body(legacy.querySelector('.thinking')), 'Unstructured older reasoning.');
});

test('Activity starts collapsed and retains an explicit expansion during live updates', () => {
    const { context, wrap } = fixture();
    context.noteActivity(wrap, { kind: 'read', detail: 'first.md' });
    assert.equal(wrap._refs.activity.open, false);
    assert.equal(wrap._refs.activity.classList.contains('hidden'), false);
    wrap._refs.activity.open = true;
    context.noteActivity(wrap, { kind: 'read', detail: 'second.md' });
    assert.equal(wrap._refs.activity.open, true);
    assert.match(wrap._refs.activity.innerHTML, /2 actions/);
    context.renderActivity(wrap._refs.activity, null);
    assert.equal(wrap._refs.activity.open, false);
    assert.match(wrap._refs.activity.innerHTML, /2 actions/);
});

test('live file edits and completed Changes use the same collapsed disclosure', () => {
    const { context, wrap } = fixture();
    const node = wrap._refs.changes;
    context.noteFileEdit(wrap, 'notes/first.md');
    assert.equal(node.tagName, 'DETAILS');
    assert.equal(node.open, false);
    assert.equal(node.children[0].tagName, 'SUMMARY');
    node.open = true;
    context.noteFileEdit(wrap, 'notes/second.md');
    context.noteFileEdit(wrap, 'notes/first.md');
    assert.equal(node.open, true);
    assert.match(node.children[0].innerHTML, /2 files/);
    context.sealLiveEdits(node);
    assert.match(node.children[0].innerHTML, /2 files edited/);
    node.open = false;
    context.paintChangesCard(node, [{ rel: 'notes/first.md', added: 2, deleted: 1 }]);
    assert.equal(node.open, false);
    assert.equal(node.children[0].tagName, 'SUMMARY');
    assert.match(node.children[0].innerHTML, /1 file changed/);
    assert.equal(node.querySelectorAll('button').length, 3, 'Keep, Undo, and the Diff viewer remain available');
});

test('work summaries precede the latest thinking and answer, without hiding approvals', () => {
    const { wrap } = fixture();
    const r = wrap._refs;
    for (const panel of [r.tasks, r.changes, r.activity]) {
        assert.ok(wrap.children.indexOf(panel) < wrap.children.indexOf(r.flow));
    }
    assert.ok(wrap.children.indexOf(r.flow) < wrap.children.indexOf(r.content));
    assert.ok(wrap.children.indexOf(r.content) < wrap.children.indexOf(r.userPrompts));
});

test('the composer never repeats thinking or Tool details and hides its fallback when thinking is visible', () => {
    const { context, wrap, nodes } = fixture();
    const hint = nodes.get('activity-hint');
    context.setStreamingUI(true);
    assert.equal(hint.classList.contains('hidden'), false, 'There is progress feedback before reasoning arrives');
    assert.doesNotMatch(hint.innerHTML, /activity-status/);
    context.noteActivity(wrap, { kind: 'read', detail: 'private-notes.md' });
    assert.doesNotMatch(hint.innerHTML, /private-notes/);
    context.renderThinking(wrap, banner(1) + 'The full update belongs in the thinking section.');
    assert.equal(hint.classList.contains('hidden'), true);
    context.setStreamingUI(false);
    assert.equal(hint.classList.contains('hidden'), true);
});

test('new thinking follows the bottom but does not pull a reader away from earlier output', () => {
    const { context, wrap, nodes } = fixture();
    const thread = nodes.get('thread');
    vm.runInContext('threadFollow = false;', context);
    context.renderThinking(wrap, banner(1) + 'First.');
    assert.equal(thread.scrollTop, 0);
    vm.runInContext('threadFollow = true;', context);
    context.renderThinking(wrap, banner(1) + 'First.\n' + banner(2) + 'Second.');
    assert.equal(thread.scrollTop, thread.scrollHeight);
});
