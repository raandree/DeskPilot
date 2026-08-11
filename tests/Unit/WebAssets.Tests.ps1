#requires -Version 7.0

# Guards for the web/ assets that are bundled into the module and published to
# the PowerShell Gallery (see build.yaml CopyPaths). These tests read the SOURCE
# assets under source/web, which is exactly what ModuleBuilder copies.

Describe 'Web assets bundle' -Tag 'Unit' {
    BeforeAll {
        $script:webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
    }

    It 'has index.html at the web root' {
        Test-Path -LiteralPath (Join-Path $script:webRoot 'index.html') -PathType Leaf | Should -BeTrue
    }

    It 'has the core SPA files under assets/' {
        foreach ($name in 'app.js', 'attachments.js', 'auth.js', 'diff.js', 'markdown.js', 'questionnaire.js', 'speech.js', 'styles.css') {
            Test-Path -LiteralPath (Join-Path $script:webRoot 'assets' $name) -PathType Leaf | Should -BeTrue
        }
    }

    It 'sizes the files panel from a custom property so it can be dragged' {
        $html = Get-Content -LiteralPath (Join-Path $script:webRoot 'index.html') -Raw
        $css = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'styles.css') -Raw
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        $html | Should -Match 'id="explorer-resize"'
        $html | Should -Match 'role="separator"'
        # A hard-coded third column would make the drag handle do nothing.
        $css | Should -Match ([regex]::Escape('grid-template-columns: 280px 1fr var(--explorer-w'))
        $css | Should -Match ([regex]::Escape('.explorer-resize'))
        $js | Should -Match ([regex]::Escape("setProperty('--explorer-w'"))
        $js | Should -Match 'wireExplorerResize\(\)'
    }

    It 'links the Intercom setup guide, and opens every external link safely' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        $js | Should -Match ([regex]::Escape('const INTERCOM_GUIDE_URL'))
        $js | Should -Match ([regex]::Escape('docs/intercom-getting-started.md'))
        $js | Should -Match ([regex]::Escape('href="${INTERCOM_GUIDE_URL}"'))
        # target="_blank" without rel="noopener noreferrer" hands the opened page a
        # window.opener it can navigate away (reverse tabnabbing).
        foreach ($match in [regex]::Matches($js, '<a\s[^>]*target="_blank"[^>]*>')) {
            $match.Value | Should -Match 'rel="noopener noreferrer"'
        }
    }

    It 'renders every Intercom control it binds to' {
        # A handler bound to an id the template never renders fails silently: the
        # control is simply absent and nothing throws. That shipped once - the
        # pairing panel's container was missing, so "Link my phone" never appeared
        # while every API test still passed.
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        $bound = [regex]::Matches($js, "\`$\('(set-ic-[a-z-]+|set-intercom-[a-z-]+|btn-intercom|stab-intercom)'\)") |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique

        $bound.Count | Should -BeGreaterThan 5
        foreach ($id in $bound) {
            $rendered = $js.Contains("id=`"$id`"") -or
                (Get-Content -LiteralPath (Join-Path $script:webRoot 'index.html') -Raw).Contains("id=`"$id`"")
            $rendered | Should -BeTrue -Because "app.js binds `$('$id') but nothing renders that id"
        }
    }

    It 'lets both sides of a conversation be copied in one click' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $css = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'styles.css') -Raw

        # A user message used to offer edit-and-resend only.
        $js | Should -Match '(?s)function buildUserEl.{0,2000}copyMessageText\(m\.text\)'
        $js | Should -Match '(?s)function buildMessageActions.{0,600}copyMessageText\(text\)'
        # One helper, so the clipboard fallback exists on both paths.
        $js | Should -Match 'async function copyMessageText'
        $js | Should -Match ([regex]::Escape("document.execCommand('copy')"))
        # The actions are hover-revealed, so focus has to reveal them as well.
        $css | Should -Match ([regex]::Escape('.msg-user:focus-within .user-actions'))
    }

    It 'keeps destructive conversation actions out of one click' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        # The one-click button on a row archives; it used to delete outright.
        $js | Should -Match ([regex]::Escape("archive.onclick = (e) => { e.stopPropagation(); toggleArchive(c.id, !c.archived); };"))
        $js | Should -Not -Match ([regex]::Escape('del.onclick = (e) => { e.stopPropagation(); deleteConversation(c.id); };'))
        # Deleting is reachable from the actions menu and the right-click menu.
        $js | Should -Match ([regex]::Escape("mk('Delete…', () => deleteConversation(summary.id))"))
        $js | Should -Match ([regex]::Escape('item.oncontextmenu'))
        # And it always confirms, whoever calls it.
        $js | Should -Match '(?s)async function deleteConversation\(id\).{0,600}window\.confirm'
    }

    It 'offers a checkpoint on a prompt, and confirms before discarding anything' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $css = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'styles.css') -Raw

        # The divider is only meaningful where a snapshot was actually taken, so
        # it has to be gated on the message carrying one.
        $js | Should -Match ([regex]::Escape("m.role === 'user' && m.checkpoint && m.checkpoint.sha"))
        $js | Should -Match 'function buildCheckpointEl'
        $js | Should -Match ([regex]::Escape('Restore Checkpoint'))
        # The live bubble is built before the server has taken the snapshot, so
        # rendering only on thread rebuild leaves the turn you just ran without a
        # divider until you switch conversations and back.
        $js | Should -Match 'function syncCheckpointDividers'
        $js | Should -Match '(?s)async function refreshCurrentConversation.{0,400}syncCheckpointDividers\(\)'
        # Restoring throws away messages and rewrites files; it must never be one click.
        $js | Should -Match '(?s)async function restoreCheckpoint\(m\).{0,900}window\.confirm'
        # The discarded prompt goes back in the composer, or the user loses what they typed.
        $js | Should -Match '(?s)async function restoreCheckpoint\(m\).{0,2000}promptEl\.value = r\.prompt'
        $css | Should -Match ([regex]::Escape('.checkpoint-label'))
    }

    It 'shows the model''s thinking expanded, and keeps it in view while it streams' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        # "Show the model's thinking" that lands collapsed shows nothing.
        $js | Should -Match ([regex]::Escape('thinking.open = !!(state.settings && state.settings.showThinking)'))
        # The box only appears after the turn-start scroll, so it has to scroll for
        # itself or it unfolds below the fold and the turn reads as stalled.
        $js | Should -Match '(?s)function renderThinking\(wrap, text\) \{.{0,300}?scrollThread\(\);\s*\}'
        # Every live reasoning frame goes through that helper; an inline update
        # would silently lose the scroll again.
        $reasoning = [regex]::Matches($js, 'reasoning: \(d\) =>')
        $reasoning.Count | Should -BeGreaterThan 0
        [regex]::Matches($js, 'renderThinking\(wrap, think\)').Count | Should -Be $reasoning.Count
        $js | Should -Not -Match ([regex]::Escape(".thinking .disclosure-body').textContent = think"))
    }

    It 'follows a project or agent switched from the phone' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        # Intercom made this window stop being the only writer of Settings. Without
        # a re-read the composer keeps naming a project and an agent the next Turn
        # no longer uses.
        $js | Should -Match '(?s)async function refreshIntercom\(\).{0,1200}syncSettingsFromIntercom\(\)'
        $js | Should -Match 'async function syncSettingsFromIntercom'
        # Polling Settings when nothing can change them remotely is pure noise.
        $js | Should -Match ([regex]::Escape("state.intercom.status !== 'on'"))
        # Both chips read the selection, so both have to be repainted.
        $js | Should -Match '(?s)async function syncSettingsFromIntercom.{0,900}populateProjectSelect\(\);\s*updateAgentChip\(\);'
    }

    It 'follows a model switched from the phone' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        # A remote /model writes Settings and re-pins the bound Conversation, and
        # the composer select reads the pin - so a repaint from Settings alone
        # would leave the select naming the previous model.
        $js | Should -Match '(?s)async function syncSettingsFromIntercom.{0,900}before\.model !== fresh\.model'
        $js | Should -Match '(?s)if \(modelChanged\) \{\s*await refreshCurrentConversation\(\);\s*setModelSelect\('
    }

    It 'shows the model that is actually the default when none is pinned' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        # With no Settings model the browser preselects the first option, which is
        # whatever the Engine listed first - a "Default model" field contradicting
        # the model the Turn will actually run on.
        $js | Should -Match ([regex]::Escape('id === (s.model || state.defaultModel)'))
    }

    It 'parses a unified diff into rows with old and new line numbers' {
        $modulePath = Join-Path $script:webRoot 'assets' 'diff.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const {
    parseUnifiedDiff, newFileRows, splitRelPath, statusGlyph, statusLabel,
} = await import(pathToFileURL(process.argv[1]).href);

const diff = [
    'diff --git a/notes.txt b/notes.txt',
    'index 1111111..2222222 100644',
    '--- a/notes.txt',
    '+++ b/notes.txt',
    '@@ -1,3 +1,4 @@',
    ' keep me',
    '-old line',
    '+new line',
    '+extra line',
    ' tail',
].join('\n');

const parsed = parseUnifiedDiff(diff);
assert.equal(parsed.added, 2);
assert.equal(parsed.deleted, 1);

const meta = parsed.rows.filter((r) => r.type === 'meta');
assert.equal(meta.length, 4, 'the git file header stays as meta rows');

const hunk = parsed.rows.find((r) => r.type === 'hunk');
assert.equal(hunk.text, '@@ -1,3 +1,4 @@');

const body = parsed.rows.filter((r) => r.type !== 'meta' && r.type !== 'hunk');
assert.deepEqual(body.map((r) => [r.type, r.oldNo, r.newNo, r.text]), [
    ['ctx', 1, 1, 'keep me'],
    ['del', 2, null, 'old line'],
    ['add', null, 2, 'new line'],
    ['add', null, 3, 'extra line'],
    ['ctx', 3, 4, 'tail'],
]);

// A single-line hunk header has no comma-count; both forms must parse.
const short = parseUnifiedDiff('@@ -7 +9 @@\n-a\n+b');
assert.deepEqual(short.rows.filter((r) => r.type !== 'hunk').map((r) => [r.type, r.oldNo, r.newNo]), [
    ['del', 7, null],
    ['add', null, 9],
]);

// An empty diff must not invent rows.
assert.deepEqual(parseUnifiedDiff('').rows, []);

// A brand new file is shown as all additions, numbered from one.
assert.deepEqual(newFileRows('a\nb\n'), [
    { type: 'add', oldNo: null, newNo: 1, text: 'a' },
    { type: 'add', oldNo: null, newNo: 2, text: 'b' },
]);

assert.deepEqual(splitRelPath('src/deep/file.ts'), { name: 'file.ts', dir: 'src/deep' });
assert.deepEqual(splitRelPath('root.md'), { name: 'root.md', dir: '' });
assert.deepEqual(splitRelPath('win\\style\\path.txt'), { name: 'path.txt', dir: 'win/style' });

assert.equal(statusGlyph('added'), 'A');
assert.equal(statusGlyph('untracked'), 'U');
assert.equal(statusGlyph('deleted'), 'D');
assert.equal(statusGlyph('conflicted'), '!');
assert.equal(statusGlyph('modified'), 'M');
assert.equal(statusGlyph('anything-else'), 'M');
assert.match(statusLabel('conflicted'), /conflict/i);
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'drops a file from the diff viewer once it no longer differs' {
        $modulePath = Join-Path $script:webRoot 'assets' 'diff.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { reconcileDiffFiles } = await import(pathToFileURL(process.argv[1]).href);

// The viewer opens with a snapshot of the change set; Keep, Undo and Save all
// move the working tree underneath it.
const a = { rel: 'a.txt', status: 'modified' };
const c = { rel: 'c.txt', status: 'added' };
const current = new Map([['a.txt', a], ['c.txt', c]]);
const lookup = (rel) => current.get(rel) || null;
const files = [{ rel: 'a.txt' }, { rel: 'b.txt' }, { rel: 'c.txt' }];

// The fresh record replaces the stale one: it carries the snapshot the diff is
// taken against, so keeping the old object would show the wrong comparison.
assert.deepEqual(
    reconcileDiffFiles([{ rel: 'a.txt', status: 'untracked', snapshotSha: 'old' }], 0, lookup),
    { files: [a], index: 0 });

// The selected file was undone -> land on the next survivor, not back at the top.
assert.deepEqual(reconcileDiffFiles(files, 1, lookup), { files: [a, c], index: 1 });

// The selection survives -> stay on it.
assert.deepEqual(reconcileDiffFiles(files, 2, lookup), { files: [a, c], index: 1 });

// Nothing left after the undone selection -> clamp to the last survivor.
assert.deepEqual(reconcileDiffFiles([{ rel: 'a.txt' }, { rel: 'b.txt' }], 1, lookup), { files: [a], index: 0 });

// Nothing survives -> an empty list, so the caller knows to close the viewer.
assert.deepEqual(reconcileDiffFiles([{ rel: 'b.txt' }], 0, lookup), { files: [], index: 0 });

// Junk in, no throw out.
assert.deepEqual(reconcileDiffFiles(null, 0, lookup), { files: [], index: 0 });
assert.deepEqual(reconcileDiffFiles([{ rel: '' }, null], 0, lookup), { files: [], index: 0 });
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'refreshes the open diff viewer after a keep or undo' {
        $js = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        # Without this the viewer keeps listing a file that has already been put
        # back, and offers a second undo for a change that no longer exists.
        $js | Should -Match 'reconcileDiffFiles'
        $js | Should -Match 'async function refreshDiffViewer\(\)'
        $js | Should -Match 'await refreshDiffViewer\(\)'
    }

    It 'extracts clipboard files without intercepting text-only paste data' {
        $modulePath = Join-Path $script:webRoot 'assets' 'attachments.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { getClipboardFiles, getImagePaths, wireClipboardAttachments } = await import(pathToFileURL(process.argv[1]).href);
const screenshot = { name: 'image.png', type: 'image/png' };
const documentFile = { name: 'brief.pdf', type: 'application/pdf' };

assert.deepEqual(getClipboardFiles({ files: [screenshot], items: [] }), [screenshot]);
assert.deepEqual(getClipboardFiles({
    files: [],
    items: [
        { kind: 'string', getAsFile: () => null },
        { kind: 'file', getAsFile: () => documentFile },
    ],
}), [documentFile]);
assert.deepEqual(getClipboardFiles({ files: [], items: [{ kind: 'string' }] }), []);
assert.deepEqual(getImagePaths([
    { path: 'C:/uploads/image.png', contentType: 'image/png' },
    { path: 'C:/uploads/brief.pdf', contentType: 'application/pdf' },
]), ['C:/uploads/image.png']);

let pasteHandler;
const uploaded = [];
const target = { addEventListener: (name, handler) => { if (name === 'paste') pasteHandler = handler; } };
wireClipboardAttachments(target, (files) => uploaded.push(...files));

let prevented = false;
pasteHandler({ clipboardData: { files: [screenshot] }, preventDefault: () => { prevented = true; } });
assert.equal(prevented, true);
assert.deepEqual(uploaded, [screenshot]);

prevented = false;
pasteHandler({ clipboardData: { files: [], items: [{ kind: 'string' }] }, preventDefault: () => { prevented = true; } });
assert.equal(prevented, false);
assert.deepEqual(uploaded, [screenshot]);
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'keeps the device code and link pinned while the sign-in poll runs' {
        $modulePath = Join-Path $script:webRoot 'assets' 'auth.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { parseAuthLine, createAuthProgress, applyAuthLine, AUTH_WAITING_STATUS } =
    await import(pathToFileURL(process.argv[1]).href);

assert.deepEqual(parseAuthLine('1. Open: https://github.com/login/device'),
    { kind: 'url', value: 'https://github.com/login/device' });
assert.deepEqual(parseAuthLine('2. Code: 5D02-A273'), { kind: 'code', value: '5D02-A273' });
assert.deepEqual(parseAuthLine('.'), { kind: 'progress', value: '' });
assert.deepEqual(parseAuthLine('. . .'), { kind: 'progress', value: '' });
assert.deepEqual(parseAuthLine('  '), { kind: 'progress', value: '' });
assert.deepEqual(parseAuthLine('Requesting device code from GitHub'),
    { kind: 'status', value: 'Requesting device code from GitHub' });

let progress = createAuthProgress();
for (const line of [
    'Requesting device code from GitHub',
    '1. Open: https://github.com/login/device',
    '2. Code: 5D02-A273',
    '(code copied to clipboard)',
    '.', '.', '.', '.',
]) {
    progress = applyAuthLine(progress, line);
}
assert.equal(progress.url, 'https://github.com/login/device');
assert.equal(progress.code, '5D02-A273');
assert.equal(progress.status, AUTH_WAITING_STATUS);

const later = applyAuthLine(progress, 'Exchanging the code for a token');
assert.equal(later.status, 'Exchanging the code for a token');
assert.equal(later.code, '5D02-A273');
assert.equal(later.url, 'https://github.com/login/device');
assert.equal(progress.status, AUTH_WAITING_STATUS, 'applyAuthLine must not mutate its input');
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'shows the selected Project folder leaf in the Project chip' {
        $appPath = Join-Path $script:webRoot 'assets' 'app.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(process.argv[1], 'utf8');
const start = source.indexOf('function projects()');
const end = source.indexOf('function buildProjectMenu()', start);
assert.notEqual(start, -1, 'Project helpers must be present');
assert.notEqual(end, -1, 'Project menu boundary must be present');

const label = {};
const button = {};
const context = {
    state: {
        settings: {
            projects: [{ id: 'p_ling', name: 'd:', path: 'D:\\ling' }],
            selectedProjectId: 'p_ling',
        },
    },
    $: (id) => id === 'project-chip-label' ? label : id === 'btn-project' ? button : null,
    syncExplorerAvailability: () => {},
};
vm.runInNewContext(source.slice(start, end) + '\nupdateProjectChip();', context);

assert.equal(label.textContent, 'ling');
assert.equal(label.title, 'ling');
assert.equal(button.title, 'ling');
'@

        $output = & node --input-type=module --eval $nodeScript $appPath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)

        $styles = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'styles.css') -Raw
        $styles | Should -Match '(?s)#btn-project\s*\{[^}]*width:\s*fit-content'
        $styles | Should -Match '(?s)#project-chip-label\s*\{[^}]*max-width:\s*150px[^}]*text-overflow:\s*ellipsis'
    }

    It 'renders Ask-User questions and submits answers while a Turn streams' {
        $app = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $styles = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'styles.css') -Raw

        $app | Should -Match 'question:\s*\(d\)\s*=>'
        $app | Should -Match '/question'
        $app | Should -Match 'userPrompts'
        $app | Should -Match 'questionnaire-options'
        $app | Should -Match 'questionnaire-option-check'
        $app | Should -Match 'questionnaire-progress'
        $app | Should -Match 'questionnaire-nav'
        $app | Should -Match 'questionnaire-close'
        $app | Should -Match 'serializeQuestionnaireAnswer'
        $app | Should -Match 'optionButton\.tabIndex'
        $app | Should -Match 'optionButton\.onkeydown'
        $styles | Should -Match '\.user-prompt-card'
        $styles | Should -Match '\.questionnaire-option\.selected'
        $styles | Should -Match '\.questionnaire-footer'
    }

    It 'supports Questionnaire wizard selection and answer serialization' {
        $modulePath = Join-Path $script:webRoot 'assets' 'questionnaire.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const {
    createQuestionnaireState,
    setQuestionnaireStep,
    toggleQuestionnaireOption,
    setQuestionnaireFreeText,
    isQuestionnaireStepComplete,
    isQuestionnaireComplete,
    getQuestionnaireOptionFocusIndex,
    serializeQuestionnaireAnswer,
} = await import(pathToFileURL(process.argv[1]).href);

const wizard = createQuestionnaireState({
    id: 'q_1',
    structured: true,
    title: 'Practice profile',
    questions: [
        {
            header: 'Model', question: 'How should you work?', multiSelect: false,
            allowFreeformInput: false,
            options: [{ label: 'Independent', description: '' }, { label: 'Employed', description: '' }],
        },
        {
            header: 'Learning', question: 'Who should you learn from?', multiSelect: true,
            allowFreeformInput: true,
            options: [{ label: 'Mentors', description: '' }, { label: 'Peers', description: '' }],
        },
        {
            header: 'Location', question: 'Where?', multiSelect: false,
            allowFreeformInput: true, options: [],
        },
    ],
});

assert.equal(getQuestionnaireOptionFocusIndex(0, 'ArrowDown', 3), 1);
assert.equal(getQuestionnaireOptionFocusIndex(2, 'ArrowDown', 3), 0);
assert.equal(getQuestionnaireOptionFocusIndex(0, 'ArrowUp', 3), 2);
assert.equal(getQuestionnaireOptionFocusIndex(1, 'Home', 3), 0);
assert.equal(getQuestionnaireOptionFocusIndex(1, 'End', 3), 2);
assert.equal(getQuestionnaireOptionFocusIndex(1, 'Tab', 3), 1);

toggleQuestionnaireOption(wizard, 0, 'Independent');
toggleQuestionnaireOption(wizard, 0, 'Employed');
assert.deepEqual(wizard.questions[0].selectedOptions, ['Employed'], 'single-select replaces the prior answer');

setQuestionnaireStep(wizard, 1);
toggleQuestionnaireOption(wizard, 1, 'Mentors');
toggleQuestionnaireOption(wizard, 1, 'Peers');
setQuestionnaireFreeText(wizard, 1, 'Kinesiologists with their own practice');
assert.deepEqual(wizard.questions[1].selectedOptions, ['Mentors', 'Peers']);

setQuestionnaireStep(wizard, 2);
assert.equal(isQuestionnaireStepComplete(wizard, 2), false);
setQuestionnaireFreeText(wizard, 2, 'Munich, within 30 km');
assert.equal(isQuestionnaireComplete(wizard), true);

const answer = JSON.parse(serializeQuestionnaireAnswer(wizard));
assert.deepEqual(answer.answers[0].selectedOptions, ['Employed']);
assert.deepEqual(answer.answers[1].selectedOptions, ['Mentors', 'Peers']);
assert.equal(answer.answers[1].freeText, 'Kinesiologists with their own practice');
assert.equal(answer.answers[2].freeText, 'Munich, within 30 km');

const plain = createQuestionnaireState({
    id: 'q_2', structured: false, question: 'Which city?', questions: [],
});
setQuestionnaireFreeText(plain, 0, 'Berlin');
assert.equal(serializeQuestionnaireAnswer(plain), 'Berlin');
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'renders a CRLF Markdown file instead of spinning forever' {
        $modulePath = Join-Path $script:webRoot 'assets' 'markdown.js'
        $scriptPath = Join-Path $TestDrive 'markdown-crlf.mjs'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { renderMarkdown } = await import(pathToFileURL(process.argv[2]).href);

// A Windows-authored file is CRLF end to end. A stray \r defeats the
// $-anchored heading pattern, which left the paragraph gatherer with a line it
// refused to consume and no way to advance - an infinite loop that froze the
// browser tab on the file viewer's first heading.
const html = renderMarkdown('# Title\r\n\r\nText **bold**\r\n\r\n- one\r\n- two\r\n\r\n```ps\r\ncode\r\n```\r\n');

assert.match(html, /<h1>Title<\/h1>/);
assert.match(html, /<p>Text <strong>bold<\/strong><\/p>/);
assert.match(html, /<ul><li>one<\/li><li>two<\/li><\/ul>/);
assert.match(html, /<code>code<\/code>/);
assert.equal(/\r/.test(html), false, 'no carriage return may leak into the HTML');
assert.equal(html.includes('<p></p>'), false, 'an empty paragraph means a line was consumed by nothing');
'@
        Set-Content -LiteralPath $scriptPath -Value $nodeScript -Encoding utf8

        # Run out of process under a hard timeout: the regression guarded here
        # is a non-terminating loop, which would otherwise hang the whole run.
        $outPath = Join-Path $TestDrive 'markdown-crlf.out'
        $errPath = Join-Path $TestDrive 'markdown-crlf.err'
        $proc = Start-Process -FilePath 'node' -ArgumentList $scriptPath, $modulePath -PassThru -NoNewWindow -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $finished = $proc.WaitForExit(30000)
        if (-not $finished) { $proc.Kill($true) }
        $output = @(Get-Content -LiteralPath $outPath -ErrorAction SilentlyContinue) +
            @(Get-Content -LiteralPath $errPath -ErrorAction SilentlyContinue)

        $finished | Should -BeTrue -Because 'renderMarkdown must terminate on CRLF input'
        $proc.ExitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'switches to an immediate stopping state and renders stopped Turn Usage' {
        $app = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw

        $app | Should -Match 'stopRequested:\s*false'
        $app | Should -Match 'function\s+setStoppingUI\s*\('
        $app | Should -Match 'stopping:\s*\(d\)\s*=>'
        $app | Should -Match 'stopped:\s*\(m\)\s*=>'
        $app | Should -Match 'estimateScope'
        ([regex]::Matches($app, 'let\s+turnStopped\s*=\s*false;')).Count | Should -Be 2
        ([regex]::Matches($app, 'turnStopped\s*=\s*true;')).Count | Should -Be 4
        ([regex]::Matches($app, 'renderScheduled\s*=\s*false;\s*if\s*\(state\.stopRequested\s*\|\|\s*turnStopped\)\s*return;')).Count |
            Should -Be 2
    }

    It 'speaks and listens in the chosen language, not just the browser''s' {
        $appPath = Join-Path $script:webRoot 'assets' 'app.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(process.argv[1], 'utf8');
const start = source.indexOf('// ===== Voice: language =====');
const end = source.indexOf('// ===== Voice: dictation', start);
assert.notEqual(start, -1, 'Voice language helpers must be present');
assert.notEqual(end, -1, 'Voice dictation boundary must be present');

const store = new Map();
const voices = [{ lang: 'en-US', name: 'English' }, { lang: 'de-DE', name: 'Deutsch' }];
const context = {
    localStorage: {
        getItem: (k) => (store.has(k) ? store.get(k) : null),
        setItem: (k, v) => store.set(k, String(v)),
    },
    navigator: { language: 'en-GB' },
    window: { speechSynthesis: { getVoices: () => voices } },
};
vm.runInNewContext(source.slice(start, end) + '\nglobalThis.VOICE_LANGS = VOICE_LANGS;', context);

// Unset means "follow the browser", which is what shipped before the setting.
assert.equal(context.voiceLangPref(), 'auto');
assert.equal(context.voiceLang(), 'en-GB');

// German is offered, and overrides the browser language once chosen.
assert.ok(context.VOICE_LANGS.some((l) => l.id === 'de-DE'), 'German must be selectable');
store.set('ad_voicelang', 'de-DE');
assert.equal(context.voiceLangPref(), 'de-DE');
assert.equal(context.voiceLang(), 'de-DE');

// A stale or hand-edited value must not break speech outright.
store.set('ad_voicelang', 'not-a-language');
assert.equal(context.voiceLangPref(), 'auto');
'@

        $output = & node --input-type=module --eval $nodeScript $appPath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)

        $app = Get-Content -LiteralPath $appPath -Raw
        # Both speech APIs used to be hard-wired to navigator.language, so a German
        # speaker on an English browser got an English recogniser and reader.
        $app | Should -Match ([regex]::Escape('rec.lang = voiceLang();'))
        $app | Should -Match ([regex]::Escape('u.lang = lang;'))
        $app | Should -Not -Match 'rec\.lang = navigator\.language'
        $app | Should -Not -Match 'u\.lang = navigator\.language'
        # And the choice has to be reachable and persisted, or it cannot be made.
        $app | Should -Match 'id="set-voicelang"'
        $app | Should -Match ([regex]::Escape("localStorage.setItem('ad_voicelang'"))
    }

    It 'picks a modern voice and reads a year as a year' {
        $modulePath = Join-Path $script:webRoot 'assets' 'speech.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { numbersToSpeech, pickVoice } = await import(pathToFileURL(process.argv[1]).href);

// Windows lists its 2010-era SAPI "... Desktop" voices first, so taking the first
// language match is exactly what made read-aloud sound a decade old.
const voices = [
    { name: 'Microsoft Hedda Desktop - German (Germany)', lang: 'de-DE', localService: true },
    { name: 'Microsoft Katja - German (Germany)', lang: 'de-DE', localService: true },
    { name: 'Microsoft Katja Online (Natural) - German (Germany)', lang: 'de-DE', localService: false },
    { name: 'Microsoft David Desktop - English (United States)', lang: 'en-US', localService: true },
    { name: 'Microsoft Sonia Online (Natural) - English (United Kingdom)', lang: 'en-GB', localService: false },
];

assert.equal(pickVoice(voices, 'de-DE').name, 'Microsoft Katja Online (Natural) - German (Germany)');
// A modern voice beats an old one, but never a language the user did not ask for.
assert.equal(pickVoice(voices, 'de-AT').name, 'Microsoft Katja Online (Natural) - German (Germany)');
assert.equal(pickVoice(voices, 'en-US').name, 'Microsoft David Desktop - English (United States)');
assert.equal(pickVoice(voices, 'fr-FR'), null);
assert.equal(pickVoice([], 'de-DE'), null);

// A saved choice wins, but only while it still speaks the chosen language.
assert.equal(pickVoice(voices, 'de-DE', 'Microsoft Katja - German (Germany)').name, 'Microsoft Katja - German (Germany)');
assert.equal(pickVoice(voices, 'en-US', 'Microsoft Katja - German (Germany)').name, 'Microsoft David Desktop - English (United States)');

// Engines read a bare 1945 as "one thousand nine hundred forty-five".
assert.equal(numbersToSpeech('It was signed in 1945.', 'en-US'), 'It was signed in nineteen forty-five.');
assert.equal(numbersToSpeech('from 1905 to 1900', 'en-US'), 'from nineteen oh five to nineteen hundred');
assert.equal(numbersToSpeech('shipped in 2020, planned since 2005', 'en-GB'), 'shipped in twenty twenty, planned since two thousand five');
assert.equal(numbersToSpeech('Es war im Jahr 1945.', 'de-DE'), 'Es war im Jahr neunzehnhundertfünfundvierzig.');
assert.equal(numbersToSpeech('seit 2020 und ab 2001', 'de-DE'), 'seit zweitausendzwanzig und ab zweitausendeins');

// Only a year cue makes a number a year: a port, a count and an out-of-range
// number all have to survive untouched.
assert.equal(numbersToSpeech('listening on 8080', 'en-US'), 'listening on 8080');
assert.equal(numbersToSpeech('ran 1945 tests', 'en-US'), 'ran 1945 tests');
assert.equal(numbersToSpeech('in 3000 ports', 'en-US'), 'in 3000 ports');
assert.equal(numbersToSpeech('in 19450 ms', 'en-US'), 'in 19450 ms');
// A language we cannot spell out is left alone rather than mangled.
assert.equal(numbersToSpeech('en 1945', 'fr-FR'), 'en 1945');
assert.equal(numbersToSpeech('', 'en-US'), '');
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)

        $app = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $app | Should -Match 'import \{[^}]*numbersToSpeech[^}]*\} from ''\./speech\.js'';'
        $app | Should -Match 'id="set-voice"'
        $app | Should -Match ([regex]::Escape("localStorage.setItem('ad_voicename'"))
        # The voice list arrives late in Chrome, so the picker has to refill itself.
        $app | Should -Match ([regex]::Escape('onvoiceschanged'))
    }

    It 'reads a Message as prose, not as Markdown punctuation' {
        $modulePath = Join-Path $script:webRoot 'assets' 'markdown.js'
        $nodeScript = @'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const { markdownToSpeech } = await import(pathToFileURL(process.argv[1]).href);

const spoken = markdownToSpeech([
    '## Setup steps',
    '',
    'Run **build.ps1** with the *test* task, see [the docs](https://example.com/a).',
    '',
    '- first step',
    '- second step',
    '',
    '1. numbered step',
    '',
    '| Task | State |',
    '| --- | --- |',
    '| build | green |',
    '',
    '---',
    '',
    '> a quoted note',
    '',
    '```powershell',
    './build.ps1 -Tasks test',
    '```',
    '',
    'Inline `Get-ChildItem` stays readable.',
].join('\n'));

// None of this is language. Spoken, it is "hash hash", "star star", "vertical bar".
for (const syntax of ['#', '*', '|', '---', '>', '`', '](', 'https://']) {
    assert.ok(!spoken.includes(syntax), `still speaks ${syntax}: ${spoken}`);
}

// The prose, including every label the syntax was wrapped around, survives.
for (const kept of ['Setup steps', 'build.ps1', 'test', 'the docs', 'first step', 'second step',
    'numbered step', 'Task', 'green', 'a quoted note', 'Get-ChildItem']) {
    assert.ok(spoken.includes(kept), `lost ${kept}: ${spoken}`);
}

// A heading, a list item and a table row are sentences to the ear; without a
// full stop the reader runs each one into the next.
assert.match(spoken, /Setup steps\./);
assert.match(spoken, /first step\./);
assert.match(spoken, /Task, State\./);

// Code is announced, never spelled out.
assert.ok(spoken.includes('Code block.'));
assert.ok(!spoken.includes('-Tasks'));

// Prose with no Markdown in it comes back unchanged.
assert.equal(markdownToSpeech('Just a sentence.'), 'Just a sentence.');
assert.equal(markdownToSpeech(''), '');
'@

        $output = & node --input-type=module --eval $nodeScript $modulePath 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)

        # Read aloud used to strip code fences only, so every heading, bullet and
        # table pipe was spoken out.
        $app = Get-Content -LiteralPath (Join-Path $script:webRoot 'assets' 'app.js') -Raw
        $app | Should -Match 'import \{[^}]*markdownToSpeech[^}]*\} from ''\./markdown\.js'';'
        $app | Should -Match '(?s)function speakText\([^)]*\).{0,400}markdownToSpeech\(text\)'
    }
}

Describe 'Web asset reference casing' -Tag 'Unit' {
    # Linux install paths are case-sensitive. An href/src/srcset/url() that
    # disagrees with the on-disk filename works on Windows/macOS but 404s on a
    # Gallery install running on Linux. Assert every LOCAL, relative asset
    # reference in the HTML/CSS resolves with EXACT case. (Inter-module ESM
    # imports are validated separately by the app.js ESM check.)
    BeforeAll {
        $script:webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
    }

    It 'references every local asset with its exact on-disk case' {
        $textFiles = Get-ChildItem -LiteralPath $script:webRoot -Recurse -File |
            Where-Object { $_.Extension -in '.html', '.css' }

        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $textFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $found = [System.Collections.Generic.List[string]]::new()

            foreach ($m in [regex]::Matches($content, '(?:href|src)\s*=\s*"([^"]+)"|(?:href|src)\s*=\s*''([^'']+)''')) {
                $found.Add($(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }))
            }
            foreach ($m in [regex]::Matches($content, 'srcset\s*=\s*"([^"]+)"|srcset\s*=\s*''([^'']+)''')) {
                $set = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                foreach ($cand in ($set -split ',')) {
                    $url = ($cand.Trim() -split '\s+')[0]
                    if ($url) { $found.Add($url) }
                }
            }
            foreach ($m in [regex]::Matches($content, 'url\(\s*''?"?([^''")]+)''?"?\s*\)')) {
                $found.Add($m.Groups[1].Value)
            }

            foreach ($ref in $found) {
                $clean = ($ref -split '[?#]')[0].Trim()
                if ([string]::IsNullOrWhiteSpace($clean)) { continue }
                if ($clean -match '^(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|//|/|#|data:)') { continue }

                $target = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $clean))
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                    $problems.Add("$($file.Name): references missing asset '$clean'")
                    continue
                }
                $dir = [System.IO.Path]::GetDirectoryName($target)
                $leaf = [System.IO.Path]::GetFileName($target)
                if (-not (Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -ceq $leaf })) {
                    $problems.Add("$($file.Name): case mismatch on '$clean' (would 404 on Linux)")
                }
            }
        }

        $problems | Should -BeNullOrEmpty
    }
}

Describe 'Web assets contain no secrets' -Tag 'Unit' {
    # web/ ships to the public Gallery (world-readable and permanent). Guard
    # against accidentally bundling a token, key, or absolute local path.
    BeforeAll {
        $script:webRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'web' | Convert-Path
    }

    It 'has no embedded secret or absolute local path in any bundled file' {
        $files = Get-ChildItem -LiteralPath $script:webRoot -Recurse -File |
            Where-Object { $_.Extension -in '.html', '.css', '.js', '.json', '.svg' }

        $patterns = @(
            'ghp_[A-Za-z0-9]{20,}'
            'gho_[A-Za-z0-9]{20,}'
            'github_pat_[A-Za-z0-9_]{20,}'
            'xox[baprs]-[A-Za-z0-9-]{10,}'
            'AKIA[0-9A-Z]{16}'
            '-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----'
            '[A-Za-z]:\\Users\\[^\\/:*?"<>|\r\n]+'
        )

        $hits = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $files) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if ([string]::IsNullOrEmpty($content)) { continue }
            foreach ($pattern in $patterns) {
                if ($content -match $pattern) {
                    $hits.Add("$($file.Name): matched /$pattern/")
                }
            }
        }

        $hits | Should -BeNullOrEmpty
    }
}
