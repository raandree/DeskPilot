import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import { splitRelPath } from '../../source/web/assets/diff.js';
import { iconKey, iconSvg } from '../../source/web/assets/icons.js';

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
    const nodes = new Map(['thread', 'thread-jump', 'prompt', 'activity-hint', 'activity-status', 'btn-send', 'btn-dispatch'].map(id => [id, new Element()]));
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

test('a live thinking section keeps its newest line in view without scrolling from script', () => {
    // In Chromium a script scroll inside the thread cancels the reader's wheel
    // scroll of the thread, so pinning the live section on every token made the
    // thread impossible to scroll back down while reasoning streamed.
    const { context, wrap, boxes } = fixture();
    const trace = banner(1) + '\nthinking:\n' + 'A long line of reasoning.\n'.repeat(80);
    for (let end = 40; end <= trace.length; end += 40) context.renderThinking(wrap, trace.slice(0, end));
    context.renderThinking(wrap, trace);
    assert.equal(body(boxes()[0]), trace);
    assert.equal(boxes()[0].querySelector('.disclosure-body').scrollTop, 0);
});

const tool = (n, name, arg) => `18:13:0${n} \u2192 ${name}\n  path: ${arg}\n`;
const labels = boxes => boxes.map(box => box.querySelector('.thinking-label').textContent);

test('a finished thinking section is titled by what it was about, with its duration kept aside', () => {
    const { context, wrap, boxes } = fixture();
    // The Engine drops the newline after streamed reasoning, so a Tool call can
    // start on the same line as the last sentence.
    const first = banner(1) + '\nthinking:\nThe user wants me to compare the spec with the tests. Let me read them.' +
        tool(1, 'read_file', 'specs/ui.md') + '\n';
    const second = banner(2) + '\nthinking:\n**Comparing feedback themes**\n\nI am lining up each theme.\n\n';
    const third = banner(3) + tool(3, 'read_file', 'C:\\repo\\tests\\ui.test.mjs');
    context.renderThinking(wrap, first);
    context.renderThinking(wrap, first + second);
    context.renderThinking(wrap, first + second + third);
    assert.equal(boxes()[2].querySelector('.thinking-label').textContent, 'Thinking…');
    context.sealThinking(wrap);
    assert.deepEqual(labels(boxes()), [
        'The user wants me to compare the spec with the tests.',
        'Comparing feedback themes',
        'Read ui.test.mjs',
    ]);
    for (const box of boxes()) {
        assert.match(box.querySelector('.thinking-time').textContent, /^\d+s$/);
        assert.equal(box.querySelector('summary').title, box.querySelector('.thinking-label').textContent);
    }
    assert.ok(labels(boxes()).every(label => !/Thought for/.test(label)));
});

test('thinking titles fall back to the opening words, then to the Tools, and stay plain text', () => {
    const { context } = fixture();
    const title = text => context.summarizeThinking(text).title;
    assert.equal(title(banner(1) + '\nthinking:\nGood. Now I have the spec and the release notes. Next the tests.'),
        'Good. Now I have the spec and the release notes.');
    assert.equal(title('Unstructured older reasoning without any boundaries'), 'Unstructured older reasoning without any boundaries');
    assert.equal(title(banner(1) + '\nthinking:\n## Planning the `review`\nDetails follow.'), 'Planning the review');
    const long = title(banner(1) + '\nthinking:\n' + 'word '.repeat(120));
    assert.ok(long.length <= 161 && long.endsWith('\u2026'), long);
    assert.equal(title(banner(1) + tool(1, 'read_file', 'a.md') + tool(1, 'read_file', 'b.md') + tool(1, 'list_dir', 'notes')),
        'read_file \u00d72, list_dir');
    assert.equal(title(banner(1) + '18:13:01 \u2192 write_file\n  path: notes/a.md\n  content:\n    The user wants a note.\n    ' + banner(2) +
        '    18:13:02 \u2192 not_a_tool\n    \u2192 nor_this\n'), 'Wrote a.md');
    assert.equal(title(banner(1)), '');
    assert.equal(title('\nthinking:\n<img src=x onerror=alert(1)> is what the page contains.'),
        '<img src=x onerror=alert(1)> is what the page contains.');
});

const iconOf = holder => holder && holder.dataset.icon;
const emoji = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u2318]/u;

test('a live thinking section shows the thought icon, and a finished one shows what it did', () => {
    const { context, wrap, boxes } = fixture();
    const sections = [
        banner(1) + '\nthinking:\nComparing the spec with the tests.\n' + tool(1, 'read_file', 'specs/ui.md'),
        banner(2) + tool(2, 'read_file', 'C:\\repo\\tests\\ui.test.mjs'),
        banner(3) + '18:13:03 \u2192 run_command\n  cwd: C:\\repo\n  command: git status --short\n',
        banner(4) + tool(4, 'read_file', 'a.md') + tool(4, 'read_file', 'b.md'),
        banner(5) + tool(5, 'read_file', 'a.md') + tool(5, 'list_directory', 'notes'),
        banner(6) + '18:13:06 \u2192 mcp_docs_search\n  query: pester mocks\n',
        banner(7) + '18:13:07 \u2192 fetch_url\n  url: https://docs.github.com/en/copilot\n',
        banner(8) + '18:13:08 \u2192 constructor\n  path: __proto__\n',
    ];
    let text = '';
    for (const section of sections) {
        text += section;
        context.renderThinking(wrap, text);
        const live = boxes().at(-1);
        assert.equal(iconOf(live.querySelector('.thinking-icon')), 'thinking');
        assert.equal(live.querySelector('summary').children.indexOf(live.querySelector('.thinking-icon')), 0);
    }
    context.sealThinking(wrap);
    assert.deepEqual(boxes().map(box => [iconOf(box.querySelector('.thinking-icon')), box.querySelector('.thinking-label').textContent]), [
        ['thinking', 'Comparing the spec with the tests.'],
        ['file', 'Read ui.test.mjs'],
        ['terminal', 'Ran git status --short'],
        ['file', 'Read 2 files'],
        ['tool', 'read_file, list_directory'],
        ['plug', 'mcp_docs_search \u00b7 pester mocks'],
        ['globe', 'Fetched docs.github.com'],
        ['tool', 'constructor \u00b7 __proto__'],
    ]);
    for (const box of boxes()) assert.match(box.querySelector('.thinking-icon').innerHTML, /^<svg /);
});

test('Activity rows, groups and the panel line use drawn icons for each kind instead of emoji', () => {
    const { context, wrap } = fixture();
    context.noteActivity(wrap, { kind: 'read', detail: 'notes/a.md' });
    context.noteActivity(wrap, { kind: 'read', detail: 'notes/b.md' });
    context.noteActivity(wrap, { kind: 'run', detail: 'git status' });
    context.noteActivity(wrap, { kind: 'browse', detail: 'https://example.com/' });
    context.noteActivity(wrap, { kind: 'mcp', tool: 'mcp_docs_search' });
    const node = wrap._refs.activity;
    for (const icon of ['activity', 'file', 'terminal', 'browser', 'plug']) assert.match(node.innerHTML, new RegExp(`data-icon="${icon}"`));
    assert.doesNotMatch(node.innerHTML, emoji);
    assert.match(node.innerHTML, /Browsed <span class="path">https:\/\/example\.com\/<\/span>/);
    assert.match(node.innerHTML, /<summary><span class="ico" data-icon="file">/, 'a run of reads folds under the file icon');
    assert.equal(node.classList.contains('is-live'), true);
    context.renderActivity(node, null);
    assert.equal(node.classList.contains('is-live'), false);
    assert.match(node.innerHTML, /^<summary><span class="ico" data-icon="activity">/);
});

test('Messages stored before the ordered Activity keep their rows, now with drawn icons', () => {
    const { context, wrap } = fixture();
    context.renderActivity(wrap._refs.activity, {
        filesRead: ['a.md'], filesWritten: ['b.md'], commandsRun: ['git log'], pagesFetched: ['https://x.test'], questionsAsked: ['Which one?'],
    });
    const html = wrap._refs.activity.innerHTML;
    for (const icon of ['activity', 'file', 'edit', 'terminal', 'globe', 'question']) assert.match(html, new RegExp(`data-icon="${icon}"`));
    assert.doesNotMatch(html, emoji);
});

test('the live-edit, Changes and Tasks lines carry icons that say what they hold', () => {
    const { context, wrap } = fixture();
    context.noteFileEdit(wrap, 'notes/a.md');
    assert.match(wrap._refs.changes.children[0].innerHTML, /^<span class="ico" data-icon="edit">/);
    context.paintChangesCard(wrap._refs.changes, [{ rel: 'notes/a.md', added: 1, deleted: 0 }]);
    assert.match(wrap._refs.changes.children[0].innerHTML, /^<span class="ico" data-icon="diff">/);
    context.renderTasks(wrap._refs.tasks, [{ id: 1, title: 'Read <b>notes</b>', status: 'completed' }, { id: 2, title: 'Summarise', status: 'in-progress' }]);
    assert.match(wrap._refs.tasks.innerHTML, /data-icon="checklist"[\s\S]*Tasks — 1\/2/);
    assert.doesNotMatch(wrap._refs.tasks.innerHTML, /<b>/);
});

test('stored thinking sections are titled by content and carry no invented duration', () => {
    const { context, wrap, boxes } = fixture();
    const text = banner(1) + '\nthinking:\nChecking the June release notes for repeats.\n' + banner(2) + tool(2, 'read_file', 'notes/june.md');
    context.finalizeAssistant(wrap, { reasoning: text, stopped: true });
    assert.deepEqual(labels(boxes()), ['Checking the June release notes for repeats.', 'Read june.md']);
    assert.ok(boxes().every(box => box.querySelector('.thinking-time').textContent === ''));
    const legacy = context.buildAssistantEl({ id: 'legacy' });
    context.finalizeAssistant(legacy, { text: 'Answer.', reasoning: 'Unstructured older reasoning.' });
    assert.equal(legacy.querySelector('.thinking-label').textContent, 'Unstructured older reasoning.');
});

test('an upward wheel stops following at once and the jump control returns to the newest output', () => {
    const { context, wrap, nodes } = fixture();
    const thread = nodes.get('thread');
    const jump = nodes.get('thread-jump');
    context.wireThreadFollow();
    thread.scrollTop = 700;
    thread.listeners.scroll();
    // One wheel notch is inside the stick distance, and the next token must not
    // drag the reader straight back down.
    thread.listeners.wheel({ deltaY: -40 });
    thread.scrollTop = 660;
    thread.listeners.scroll();
    context.renderThinking(wrap, banner(1) + 'First.');
    assert.equal(thread.scrollTop, 660);
    thread.scrollTop = 200;
    thread.listeners.scroll();
    context.renderThinking(wrap, banner(1) + 'First. More.');
    assert.equal(thread.scrollTop, 200);
    assert.equal(jump.classList.contains('hidden'), false);
    jump.listeners.click();
    assert.equal(thread.scrollTop, thread.scrollHeight);
    assert.equal(jump.classList.contains('hidden'), true);
    context.renderThinking(wrap, banner(1) + 'First. More. Still following.');
    assert.equal(thread.scrollTop, thread.scrollHeight);
    // Wheeling down to the bottom resumes following as well.
    thread.listeners.wheel({ deltaY: -40 });
    thread.scrollTop = 300;
    thread.listeners.scroll();
    thread.scrollTop = 700;
    thread.listeners.scroll();
    thread.scrollHeight = 1200;
    context.renderThinking(wrap, banner(1) + 'First. More. Still following. Again.');
    assert.equal(thread.scrollTop, 1200);
});

test('an upward wheel with nothing above it does not stop following', () => {
    const { context, wrap, nodes } = fixture();
    const thread = nodes.get('thread');
    context.wireThreadFollow();
    thread.scrollHeight = 300;
    thread.listeners.wheel({ deltaY: -40 });
    thread.scrollHeight = 1000;
    context.renderThinking(wrap, banner(1) + 'The Turn has only just started.');
    assert.equal(thread.scrollTop, 1000);
});
