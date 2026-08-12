import { getImagePaths, wireClipboardAttachments } from './attachments.js';
import { AUTH_WAITING_STATUS, applyAuthLine, createAuthProgress } from './auth.js';
import {
    newFileRows,
    parseUnifiedDiff,
    reconcileDiffFiles,
    splitRelPath,
    statusGlyph,
    statusLabel,
} from './diff.js';
import { markdownToSpeech, renderMarkdown } from './markdown.js';
import {
    createQuestionnaireState,
    getQuestionnaireOptionFocusIndex,
    isQuestionnaireComplete,
    isQuestionnaireStepComplete,
    serializeQuestionnaireAnswer,
    setQuestionnaireFreeText,
    setQuestionnaireStep,
    toggleQuestionnaireOption,
} from './questionnaire.js';
import { numbersToSpeech, pickVoice } from './speech.js';

// ===== Session token =====
const token =
    new URLSearchParams(location.search).get('t') ||
    sessionStorage.getItem('ad_token') ||
    '';
if (token) sessionStorage.setItem('ad_token', token);

// ===== Tiny helpers =====
const $ = (id) => document.getElementById(id);
const el = (cls, tag = 'div') => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    return n;
};
const escapeHtml = (s) =>
    (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function toast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.remove('hidden');
    clearTimeout(toast._t);
    toast._t = setTimeout(() => t.classList.add('hidden'), 2600);
}

async function api(method, path, body) {
    const res = await fetch(path, {
        method,
        headers: { 'Content-Type': 'application/json', 'X-DeskPilot-Token': token },
        body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    if (res.status === 204) return null;
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { /* not json */ }
    if (!res.ok) {
        // Enrich the thrown error so callers can react to specific conditions
        // (notably a 401 auth_required, which drives the re-sign-in overlay).
        const err = new Error((data && data.error && data.error.message) || res.statusText);
        err.status = res.status;
        err.code = data && data.error && data.error.code;
        err.reauth = !!(data && data.error && data.error.reauth);
        throw err;
    }
    return data;
}

async function streamPost(path, body, handlers) {
    const res = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-DeskPilot-Token': token },
        body: JSON.stringify(body),
    });
    const ctype = res.headers.get('content-type') || '';
    if (!res.ok && ctype.includes('application/json')) {
        const e = await res.json().catch(() => null);
        throw new Error((e && e.error && e.error.message) || 'HTTP ' + res.status);
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let idx;
        while ((idx = buf.indexOf('\n\n')) >= 0) {
            const raw = buf.slice(0, idx);
            buf = buf.slice(idx + 2);
            if (!raw || raw.startsWith(':')) continue;
            let event = 'message';
            let data = '';
            for (const line of raw.split('\n')) {
                if (line.startsWith('event:')) event = line.slice(6).trim();
                else if (line.startsWith('data:')) data += line.slice(5).trim();
            }
            let parsed = null;
            if (data) { try { parsed = JSON.parse(data); } catch { /* ignore */ } }
            if (handlers[event]) handlers[event](parsed);
        }
    }
}

// ===== State =====
const state = {
    conversations: [],
    current: null,
    settings: null,
    models: [],
    defaultModel: null,
    authForce: false,
    streaming: false,
    stopRequested: false,
    pendingAttachments: [],
    agents: [],
    usageRange: 14,
    // Latest cached update status from GET /api/update (or null before the first
    // fetch). Drives the update banner and the Settings "Updates" panel.
    update: null,
    // Latest cached Intercom status from GET /api/intercom. Drives the topbar
    // chip and the Settings "Intercom" panel. intercomStale is set when the poll
    // fails, so the panel can say it is out of date rather than keep painting the
    // last good response as if it were live.
    intercom: null,
    intercomStale: false,
    // Latest /api/intercom/turn payload: what a Turn started from the phone is
    // producing right now. Polled rather than streamed - a remote Turn has no
    // browser request to stream over, and a long-lived SSE channel would hold
    // the Host Server's single accept thread.
    remoteTurn: null,
    remoteTurnWasActive: false,
    // Last conversation-store revision the sidebar was rendered from. Intercom
    // can create, archive, unarchive and delete conversations, and the Host
    // Server cannot push - so the window compares this and reloads.
    conversationsRevision: null,
    updateDismissed: false,
    restartDismissed: false,
    // Conversation organisation: archived items are hidden unless showArchived is
    // on; searchResults (when non-null) replaces the list with server search hits.
    showArchived: false,
    searchResults: null,
    searchQuery: '',
    promptHistory: [],
    historyIndex: -1,
    historyDraft: '',
    explorerPath: '',
    // Folders the user has expanded in the explorer (absolute paths). Tracked so a
    // refresh — including an automatic one — keeps the tree exactly as they left it.
    explorerExpanded: new Set(),
    // Pending-dispatch queue: messages typed while a Turn is streaming and held
    // back until it finishes. Each item is { kind, text, prompt }: `kind` is
    // 'queue' or 'steer', `text` is what the user actually typed (rendered in
    // the thread), `prompt` is what the server gets — equal to `text` for
    // queue and prefixed with a steering preamble for steer. Transient by
    // design: never persisted, never sent over the wire as a list.
    dispatchQueue: [],
    // Resolves the moment the current SSE stream ends (any reason). Used by
    // Stop-and-Send and queue-flush to await the running Turn deterministically.
    streamEndPromise: null,
    streamEndResolve: null,
};

const PERMISSIONS = [
    { key: 'browsing', name: 'Browsing', note: 'Read web pages you don’t control.', powerful: false },
    { key: 'file', name: 'Files', note: 'Read and write files as you.', powerful: true },
    { key: 'terminal', name: 'Terminal', note: 'Run commands as you.', powerful: true },
    { key: 'askUser', name: 'Ask you', note: 'Pause to ask a question.', powerful: false },
    { key: 'userTools', name: 'Your tools', note: 'Call tools you registered.', powerful: false },
];

// Fixed palette for the optional Conversation colour label. These names must
// match the backend allow-list in Invoke-DpRouteHandler (patchConversation).
const CONV_COLORS = [
    { name: 'red', hex: '#ef4444' },
    { name: 'amber', hex: '#f59e0b' },
    { name: 'green', hex: '#22c55e' },
    { name: 'teal', hex: '#14b8a6' },
    { name: 'blue', hex: '#3b82f6' },
    { name: 'purple', hex: '#a855f7' },
];
function convColorHex(name) {
    const c = CONV_COLORS.find((x) => x.name === name);
    return c ? c.hex : 'transparent';
}

// ===== Theme =====
function effectiveTheme() {
    const t = localStorage.getItem('ad_theme') || 'system';
    if (t === 'system') {
        return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
    }
    return t;
}

// Which keystroke sends a prompt. A per-machine input preference, so it lives in
// localStorage beside the theme rather than in Settings - the Host Server gains
// nothing from knowing it, and it shapes no Turn. Ctrl+Enter is the default: a
// stray Enter mid-thought should not send a half-written instruction to an agent
// that can change files and run commands.
function sendKeyMode() {
    return localStorage.getItem('ad_sendkey') === 'enter' ? 'enter' : 'ctrl-enter';
}

// True when this keystroke means "send" under the current preference. Shift+Enter
// always means a newline, in both modes.
function isSendKey(e) {
    if (e.key !== 'Enter' || e.shiftKey) return false;
    const withModifier = e.ctrlKey || e.metaKey;
    return sendKeyMode() === 'enter' ? !withModifier : withModifier;
}

function applySendKeyHint() {
    const promptEl = $('prompt');
    if (!promptEl) return;
    promptEl.placeholder = sendKeyMode() === 'enter'
        ? 'Message DeskPilot\u2026  (Enter to send, Shift+Enter for a new line)'
        : 'Message DeskPilot\u2026  (Ctrl+Enter to send, Enter for a new line)';
}

function applyTheme() {
    const t = localStorage.getItem('ad_theme') || 'system';
    document.documentElement.dataset.theme = t;
    updateThemeToggle();
}

function updateThemeToggle() {
    const btn = $('btn-theme');
    if (!btn) return;
    const dark = effectiveTheme() === 'dark';
    btn.textContent = dark ? '☀' : '☾';
    const label = dark ? 'Switch to light mode' : 'Switch to dark mode';
    btn.title = label;
    btn.setAttribute('aria-label', label);
}

function toggleTheme() {
    const next = effectiveTheme() === 'dark' ? 'light' : 'dark';
    localStorage.setItem('ad_theme', next);
    applyTheme();
    const sel = $('set-theme');
    if (sel) sel.value = next;
}

// Keep the toggle icon honest when the OS theme flips while set to "system".
if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
        if ((localStorage.getItem('ad_theme') || 'system') === 'system') updateThemeToggle();
    });
}

// ===== Init =====
async function init() {
    applyTheme();
    applySendKeyHint();
    wireGlobal();
    renderExamples();
    let health = null;
    try { health = await api('GET', '/api/health'); } catch { /* offline */ }
    if (!health) { showBanner('Cannot reach the DeskPilot Host Server. Is it still running?'); return; }
    setAppVersion(health.version);
    if (health.engineError) showBanner('Engine not loaded: ' + health.engineError);
    try { await loadSettings(); } catch { /* defaults */ }
    if (health.authenticated) await enterApp();
    else showAuth();
}

async function enterApp() {
    hideAuth();
    await loadModels();
    await loadAgents();
    wireAgentsAutoRefresh();
    await loadConversations();
    await refreshUsage();
    refreshUpdateStatus();
    wireUpdateAutoRefresh();
    refreshIntercom();
    wireIntercomAutoRefresh();
    // Deep link: /?c=<id> opens that Conversation directly (used by "Open in new
    // window"), else fall back to the most recent, else a fresh Conversation.
    const deepId = new URLSearchParams(location.search).get('c');
    if (deepId && state.conversations.some((c) => c.id === deepId)) await selectConversation(deepId);
    else if (state.conversations.length) await selectConversation(state.conversations[0].id);
    else await newConversation();
}

// ===== Loaders =====
async function loadSettings() {
    state.settings = await api('GET', '/api/settings');
    updatePermDot();
    populateProjectSelect();
    syncExplorerAvailability();
}
async function loadModels() {
    try {
        const data = await api('GET', '/api/models');
        state.models = data.models || [];
        state.defaultModel = data.default || (state.models[0] && state.models[0].id);
    } catch (e) {
        state.models = [];
        // An expired or missing sign-in surfaces as a 401 auth_required here; the
        // token file still exists, so the app was entered normally and the model
        // dropdown would otherwise dead-end at "(sign in to load models)". Surface
        // the re-sign-in overlay so there is an obvious next step.
        if (e && (e.reauth || e.status === 401)) promptReauth();
    }
    populateModelSelect();
}
async function loadConversations() {
    const data = await api('GET', '/api/conversations');
    state.conversations = data.conversations || [];
    renderConversationList();
}
async function refreshUsage() {
    try {
        const u = await api('GET', '/api/usage');
        state.usage = u;
        const sessionCredits = (u.session && u.session.credits) || 0;
        const lifetimeCredits = (u.lifetime && u.lifetime.credits) || 0;
        $('usage-session-credits').textContent = formatCredits(sessionCredits);
        $('usage-alltime-credits').textContent = formatCredits(lifetimeCredits);
        if (!$('usage-popover').classList.contains('hidden')) populateUsagePopover(u);
    } catch { /* ignore */ }
}

function formatCredits(n) {
    return (n || 0).toLocaleString(undefined, { maximumFractionDigits: 2 });
}

// Warn once when this session's estimated cost crosses the configured budget.
function maybeWarnBudget() {
    const budget = (state.settings && Number(state.settings.costBudgetUSD)) || 0;
    if (budget <= 0) return;
    const spent = (state.usage && state.usage.session && Number(state.usage.session.costUSD)) || 0;
    if (spent >= budget && !state._budgetWarned) {
        state._budgetWarned = true;
        toast(`Heads up: this session has spent about $${spent.toFixed(2)}, over your $${budget.toFixed(2)} warning.`);
    }
}

function usageRows(block) {
    const rows = [
        ['Credits', formatCredits(block.credits), true],
        ['Cost', '$' + (block.costUSD || 0).toFixed(4), false],
        ['Tokens', (block.totalTokens || 0).toLocaleString(), false],
        ['Tokens in', (block.promptTokens || 0).toLocaleString(), false],
        ['Tokens out', (block.completionTokens || 0).toLocaleString(), false],
        ['Turns', (block.turns || 0).toLocaleString(), false],
    ];
    // Turns whose model has no published rate contribute nothing to the money
    // figures, so those figures are a floor, not the answer. Say so rather than
    // letting a confident number under-report what was spent.
    const unpriced = Number(block.unpricedTurns) || 0;
    if (unpriced > 0) rows.push(['Not priced', unpriced.toLocaleString() + ' turn' + (unpriced === 1 ? '' : 's'), false]);
    return rows;
}

// Render the top Models of this session (by tokens) into the usage popover. The
// per-Model breakdown is already tracked server-side; this only surfaces it.
function renderTopModels(u) {
    const host = $('usage-topmodels');
    const wrap = $('usage-topmodels-block');
    if (!host || !wrap) return;
    const models = (u && u.byModel || [])
        .filter((m) => m && (Number(m.totalTokens) > 0 || Number(m.turns) > 0))
        .sort((a, b) => Number(b.totalTokens) - Number(a.totalTokens))
        .slice(0, 5);
    if (models.length === 0) { wrap.classList.add('hidden'); host.innerHTML = ''; return; }
    wrap.classList.remove('hidden');
    host.innerHTML = '';
    for (const m of models) {
        const row = el('usage-model-row');
        const name = el('usage-model-name', 'span'); name.textContent = m.model;
        const meta = el('usage-model-meta muted tiny', 'span');
        const unpriced = Number(m.unpricedTurns) || 0;
        meta.textContent = (Number(m.totalTokens) || 0).toLocaleString() + ' tok · ' +
            (unpriced > 0 && !Number(m.credits) ? 'no rate' : formatCredits(m.credits) + ' cr');
        if (unpriced > 0) meta.title = unpriced + ' turn(s) on this model have no published rate, so their cost is not counted.';
        row.append(name, meta);
        host.appendChild(row);
    }
}

function populateUsagePopover(u) {
    const fill = (nodeId, block) => {
        const node = $(nodeId);
        node.innerHTML = '';
        for (const [label, value, lead] of usageRows(block)) {
            const k = el('k', 'span'); k.textContent = label;
            const v = el('v' + (lead ? ' lead' : ''), 'span'); v.textContent = value;
            node.append(k, v);
        }
    };
    fill('usage-session', u.session || {});
    fill('usage-lifetime', u.lifetime || {});
    const since = u.lifetime && u.lifetime.sinceUtc;
    $('usage-since').textContent = since ? '· since ' + new Date(since).toLocaleDateString() : '';
    renderTopModels(u);
    renderUsageChart(u);
}

// Inline SVG bar chart of credits spent per day over the selected window. No
// charting library — keeps the UI build-free.
function renderUsageChart(u) {
    const host = $('usage-chart');
    if (!host) return;
    const range = state.usageRange || 14;
    const daily = (u && u.daily) || [];
    const byDate = new Map(daily.map((d) => [d.date, d]));

    // Build a continuous series for the last `range` days (UTC), oldest → newest,
    // filling gaps with zero so the axis is contiguous.
    const days = [];
    const today = new Date();
    for (let i = range - 1; i >= 0; i--) {
        const dt = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - i));
        const key = dt.toISOString().slice(0, 10);
        const entry = byDate.get(key);
        days.push({ key, date: dt, credits: entry ? entry.credits : 0 });
    }

    const max = Math.max(...days.map((d) => d.credits), 0);
    const total = days.reduce((s, d) => s + d.credits, 0);
    if (total <= 0) {
        host.innerHTML = '<div class="usage-chart-empty muted tiny">No usage in the last ' + range + ' days.</div>';
        return;
    }

    const W = 252, H = 84, pad = 2;
    const n = days.length;
    const slot = W / n;
    const barW = Math.max(2, slot - 3);
    const scale = (c) => (max > 0 ? (c / max) * (H - 16) : 0);

    let bars = '';
    for (let i = 0; i < n; i++) {
        const d = days[i];
        const h = scale(d.credits);
        const x = i * slot + (slot - barW) / 2;
        const y = H - 14 - h;
        const label = d.date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
        bars += `<rect class="bar" x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${barW.toFixed(1)}" height="${Math.max(0, h).toFixed(1)}" rx="1.5"><title>${label}: ${formatCredits(d.credits)} cr</title></rect>`;
    }
    // First, mid and last date ticks.
    const tick = (i) => `<text class="tick" x="${(i * slot + slot / 2).toFixed(1)}" y="${H - 2}" text-anchor="middle">${days[i].date.toLocaleDateString(undefined, { month: 'numeric', day: 'numeric' })}</text>`;
    const ticks = [tick(0), tick(Math.floor(n / 2)), tick(n - 1)].join('');

    host.innerHTML =
        `<svg viewBox="0 0 ${W} ${H}" width="100%" height="${H}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Credits per day">` +
        `<g>${bars}</g><g>${ticks}</g></svg>` +
        `<div class="usage-chart-foot muted tiny">${formatCredits(total)} cr over ${range} days</div>`;
}

function setUsageRange(range) {
    state.usageRange = range;
    document.querySelectorAll('.range-btn').forEach((b) => b.classList.toggle('active', Number(b.dataset.range) === range));
    if (state.usage) renderUsageChart(state.usage);
}

async function resetLifetime() {
    if (!window.confirm('Reset the all-time credit counter to zero? This cannot be undone.')) return;
    try {
        const u = await api('POST', '/api/usage/reset', { scope: 'lifetime' });
        state.usage = u;
        populateUsagePopover(u);
        toast('All-time counter reset.');
    } catch (e) { toast(e.message); }
}

// ===== Conversations =====
function remoteWorkingOn() {
    const r = state.remoteTurn;
    return r && r.active ? r.conversationId : null;
}

function renderConversationList() {
    if (state.searchResults) { renderSearchResults(); return; }
    const list = $('conversation-list');
    list.innerHTML = '';
    const visible = state.conversations.filter((c) => state.showArchived || !c.archived);
    for (const c of visible) {
        const item = el('conv-item');
        if (c.archived) item.classList.add('archived');
        if (c.unread) item.classList.add('unread');
        if (state.current && c.id === state.current.id) item.classList.add('active');
        item.tabIndex = 0;
        item.onkeydown = (e) => handleConvItemKey(e, c);
        if (c.color) {
            const dot = el('conv-color-dot');
            dot.style.background = convColorHex(c.color);
            dot.title = c.color;
            item.appendChild(dot);
        }
        const name = el('conv-name');
        name.textContent = (c.pinned ? '📌 ' : '') + (c.title || 'New conversation');
        item.appendChild(name);
        if (remoteWorkingOn() === c.id) {
            const working = el('conv-working');
            working.textContent = '📻';
            working.title = 'Working on a request from your phone';
            item.appendChild(working);
        }
        if (c.unread) {
            const unreadDot = el('conv-unread-dot');
            unreadDot.title = 'Unread';
            item.appendChild(unreadDot);
        }
        const menu = el('conv-menu-btn', 'button');
        menu.textContent = '⋯';
        menu.title = 'Conversation actions';
        menu.setAttribute('aria-label', 'Conversation actions');
        menu.onclick = (e) => { e.stopPropagation(); openConvMenu(c, menu); };
        // The one-click button archives. Deleting is irreversible, so it lives in
        // the actions menu behind a confirmation rather than a hair's breadth
        // from the row you were only trying to tidy away.
        const archive = el('conv-archive', 'button');
        archive.textContent = c.archived ? '↩' : '✕';
        archive.title = c.archived ? 'Unarchive' : 'Archive';
        archive.setAttribute('aria-label', archive.title);
        archive.onclick = (e) => { e.stopPropagation(); toggleArchive(c.id, !c.archived); };
        item.append(menu, archive);
        item.onclick = () => selectConversation(c.id);
        item.oncontextmenu = (e) => { e.preventDefault(); openConvMenu(c, item); };
        list.appendChild(item);
    }
    updateArchivedToggle();
    updateMarkAllReadButton();
}

function updateArchivedToggle() {
    const btn = $('btn-show-archived');
    if (!btn) return;
    if (state.searchResults) { btn.classList.add('hidden'); return; }
    const archivedCount = state.conversations.filter((c) => c.archived).length;
    if (archivedCount === 0 && !state.showArchived) { btn.classList.add('hidden'); return; }
    btn.classList.remove('hidden');
    btn.textContent = state.showArchived ? 'Hide archived' : `Show ${archivedCount} archived`;
}

// Show a "Mark N as read" control only when unread Conversations exist.
function updateMarkAllReadButton() {
    const btn = $('btn-mark-all-read');
    if (!btn) return;
    const count = state.conversations.filter((c) => c.unread).length;
    if (count === 0) { btn.classList.add('hidden'); return; }
    btn.classList.remove('hidden');
    btn.textContent = 'Mark ' + count + ' as read';
}

function renderSearchResults() {
    const list = $('conversation-list');
    list.innerHTML = '';
    const results = state.searchResults || [];
    if (results.length === 0) {
        const empty = el('cust-empty');
        empty.textContent = 'No conversations match.';
        list.appendChild(empty);
        updateArchivedToggle();
        updateMarkAllReadButton();
        return;
    }
    for (const r of results) {
        const item = el('conv-item conv-search-item');
        if (r.unread) item.classList.add('unread');
        if (state.current && r.id === state.current.id) item.classList.add('active');
        if (r.color) item.style.borderLeft = '3px solid ' + convColorHex(r.color);
        const name = el('conv-name');
        name.textContent = (r.pinned ? '📌 ' : '') + (r.title || 'New conversation');
        item.appendChild(name);
        if (r.snippet) {
            const snip = el('conv-snippet muted tiny');
            snip.textContent = r.snippet;
            item.appendChild(snip);
        }
        item.onclick = () => selectConversation(r.id);
        list.appendChild(item);
    }
    updateArchivedToggle();
    updateMarkAllReadButton();
}

// Debounced server-side search across titles and message text.
function runConversationSearch(q) {
    const query = (q || '').trim();
    state.searchQuery = query;
    clearTimeout(runConversationSearch._t);
    if (!query) { state.searchResults = null; renderConversationList(); return; }
    runConversationSearch._t = setTimeout(async () => {
        try {
            const data = await api('GET', '/api/conversations/search?q=' + encodeURIComponent(query));
            if (state.searchQuery !== query) return; // a newer query won
            state.searchResults = data.results || [];
            renderSearchResults();
        } catch (e) { toast(e.message); }
    }, 180);
}

// Per-conversation action menu, grouped into Open / Organise / Manage sections.
// Deletion is deliberately NOT in this menu — it stays on the hover ✕ so the
// delete flow is unchanged.
function openConvMenu(summary, anchor) {
    closeConvMenu();
    const menu = el('popover popover-menu conv-action-menu', 'div');
    menu.setAttribute('role', 'menu');
    const mk = (label, fn) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'menu-item';
        b.setAttribute('role', 'menuitem');
        b.textContent = label;
        b.onclick = (e) => { e.stopPropagation(); closeConvMenu(); fn(); };
        return b;
    };
    menu.append(
        mk('Open in new window', () => openConversationInNewWindow(summary.id)),
        mk('Duplicate', () => duplicateConversation(summary.id)),
        el('menu-divider'),
        mk(summary.pinned ? 'Unpin' : 'Pin to top', () => togglePin(summary.id, !summary.pinned)),
        mk(summary.unread ? 'Mark as read' : 'Mark as unread', () => toggleUnread(summary.id, !summary.unread)),
        mk(summary.archived ? 'Unarchive' : 'Archive', () => toggleArchive(summary.id, !summary.archived)),
        buildConvColorRow(summary),
        el('menu-divider'),
        mk('Rename…', () => renameConversation(summary.id)),
        mk('Copy transcript', () => copyTranscript(summary.id)),
        mk('Export as Markdown', () => exportConversation(summary.id)),
        mk('Details', () => showConversationDetails(summary, anchor)),
        mk('Session info', () => openSessionInfo(anchor, summary.id)),
        el('menu-divider'),
        mk('Delete…', () => deleteConversation(summary.id)),
    );
    document.body.appendChild(menu);
    positionConvPopover(menu, anchor);
    state._convMenu = menu;
    setTimeout(() => document.addEventListener('click', closeConvMenu, { once: true }), 0);
}

// Position a fixed popover just below an anchor, clamped to the viewport.
function positionConvPopover(pop, anchor) {
    const rect = anchor.getBoundingClientRect();
    pop.style.position = 'fixed';
    pop.style.transform = 'none';
    pop.style.top = (rect.bottom + 4) + 'px';
    pop.style.left = Math.max(8, Math.min(rect.left, window.innerWidth - (pop.offsetWidth || 180) - 8)) + 'px';
}

// A row of colour swatches (plus a "no colour" option) for tagging a Conversation.
function buildConvColorRow(summary) {
    const row = el('menu-color-row');
    const none = el('color-swatch color-none' + (summary.color ? '' : ' selected'), 'button');
    none.type = 'button';
    none.title = 'No colour';
    none.setAttribute('aria-label', 'No colour');
    none.onclick = (e) => { e.stopPropagation(); closeConvMenu(); setConversationColor(summary.id, ''); };
    row.appendChild(none);
    for (const col of CONV_COLORS) {
        const sw = el('color-swatch' + (summary.color === col.name ? ' selected' : ''), 'button');
        sw.type = 'button';
        sw.style.background = col.hex;
        sw.title = col.name;
        sw.setAttribute('aria-label', col.name);
        sw.onclick = (e) => { e.stopPropagation(); closeConvMenu(); setConversationColor(summary.id, col.name); };
        row.appendChild(sw);
    }
    return row;
}

function closeConvMenu() {
    if (state._convMenu) { state._convMenu.remove(); state._convMenu = null; }
}

function patchConvLocal(id, patch) {
    const inList = state.conversations.find((c) => c.id === id);
    if (inList) Object.assign(inList, patch);
    if (state.searchResults) {
        const inSearch = state.searchResults.find((c) => c.id === id);
        if (inSearch) Object.assign(inSearch, patch);
    }
}

async function togglePin(id, pinned) {
    try {
        await api('PATCH', '/api/conversations/' + id, { pinned });
        await loadConversations();
        if (state.searchResults) renderSearchResults();
        toast(pinned ? 'Pinned.' : 'Unpinned.');
    } catch (e) { toast(e.message); }
}

async function toggleArchive(id, archived) {
    try {
        await api('PATCH', '/api/conversations/' + id, { archived });
        patchConvLocal(id, { archived });
        renderConversationList();
        toast(archived ? 'Archived.' : 'Unarchived.');
    } catch (e) { toast(e.message); }
}

async function renameConversation(id) {
    const cur = state.conversations.find((c) => c.id === id);
    const next = window.prompt('Rename conversation:', (cur && cur.title) || '');
    if (next === null) return;
    const title = next.trim();
    if (!title) return;
    try {
        await api('PATCH', '/api/conversations/' + id, { title });
        patchConvLocal(id, { title });
        if (state.current && state.current.id === id) { state.current.title = title; $('conv-title').value = title; }
        renderConversationList();
    } catch (e) { toast(e.message); }
}

// Open a Conversation in a separate browser window/tab via a deep link.
function openConversationInNewWindow(id) {
    const url = new URL(location.href);
    url.hash = '';
    url.searchParams.set('c', id);
    if (token) url.searchParams.set('t', token);
    window.open(url.toString(), '_blank', 'noopener');
}

// Duplicate a Conversation (server copies title + messages + history) and open it.
async function duplicateConversation(id) {
    try {
        const summary = await api('POST', '/api/conversations/' + id + '/duplicate');
        await loadConversations();
        await selectConversation(summary.id);
        toast('Duplicated.');
    } catch (e) { toast(e.message); }
}

// Toggle a Conversation's unread flag.
async function toggleUnread(id, unread) {
    try {
        await api('PATCH', '/api/conversations/' + id, { unread });
        patchConvLocal(id, { unread });
        renderConversationList();
        if (state.searchResults) renderSearchResults();
    } catch (e) { toast(e.message); }
}

// Clear the unread flag on every Conversation in one request.
async function markAllConversationsRead() {
    try {
        await api('POST', '/api/conversations/read-all');
        for (const c of state.conversations) c.unread = false;
        if (state.searchResults) for (const r of state.searchResults) r.unread = false;
        renderConversationList();
        if (state.searchResults) renderSearchResults();
        toast('All marked read.');
    } catch (e) { toast(e.message); }
}

// Set (or clear, when color is falsy) a Conversation's colour label.
async function setConversationColor(id, color) {
    try {
        await api('PATCH', '/api/conversations/' + id, { color });
        patchConvLocal(id, { color: color || null });
        renderConversationList();
        if (state.searchResults) renderSearchResults();
    } catch (e) { toast(e.message); }
}

// Keyboard shortcuts on a focused Conversation row: Enter opens, F2 renames,
// Delete archives (reversible — it never deletes the Conversation).
function handleConvItemKey(e, c) {
    if (e.key === 'Enter') { e.preventDefault(); selectConversation(c.id); }
    else if (e.key === 'F2') { e.preventDefault(); renameConversation(c.id); }
    else if (e.key === 'Delete') { e.preventDefault(); toggleArchive(c.id, !c.archived); }
}

// Format an ISO timestamp for the details popover; falls back to the raw string.
function fmtConvDate(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    return isNaN(d.getTime()) ? String(iso) : d.toLocaleString();
}

// Sum the per-Message Usage (cost, credits, tokens) across a Conversation, and
// count the Turns the Engine had no rate for - those add nothing to the money,
// so the sums are a floor whenever unpriced is non-zero.
function sumConversationUsage(messages) {
    let costUSD = 0, credits = 0, totalTokens = 0, unpriced = 0;
    for (const m of asArray(messages)) {
        const u = m.usage || {};
        costUSD += Number(u.costUSD) || 0;
        credits += Number(u.credits) || 0;
        totalTokens += Number(u.totalTokens) || 0;
        if (u.priced === false) unpriced += 1;
    }
    return { costUSD, credits, totalTokens, unpriced };
}

// "$0.0000" is a lie when the model had no rate; "at least $x" is not.
function formatCostFloor(costUSD, unpriced) {
    return (unpriced > 0 ? '\u2265 $' : '$') + (Number(costUSD) || 0).toFixed(4);
}

// A small read-only popover with a Conversation's metadata, including the
// accumulated Usage (cost / credits / tokens) summed across its Messages.
async function showConversationDetails(summary, anchor) {
    closeConvMenu();
    const pop = el('popover conv-action-menu conv-details-pop', 'div');
    const valEls = {};
    const rows = [
        ['Title', summary.title || 'New conversation'],
        ['Messages', String(summary.messageCount != null ? summary.messageCount : '—')],
        ['Model', summary.model || 'Default'],
        ['Colour', summary.color || 'None'],
        ['Cost', '…'],
        ['Credits', '…'],
        ['Tokens', '…'],
        ['Created', fmtConvDate(summary.createdUtc)],
        ['Updated', fmtConvDate(summary.updatedUtc)],
    ];
    for (const [k, v] of rows) {
        const row = el('detail-row');
        const key = el('detail-key'); key.textContent = k;
        const val = el('detail-val'); val.textContent = v; val.title = v;
        row.append(key, val);
        pop.appendChild(row);
        valEls[k] = val;
    }
    document.body.appendChild(pop);
    positionConvPopover(pop, anchor);
    state._convMenu = pop;
    setTimeout(() => document.addEventListener('click', closeConvMenu, { once: true }), 0);
    // Accumulated Usage needs the full Message list, so fetch it and fill in.
    const setVal = (k, text) => { if (valEls[k]) { valEls[k].textContent = text; valEls[k].title = text; } };
    try {
        const conv = await api('GET', '/api/conversations/' + summary.id);
        const u = sumConversationUsage(conv.messages);
        setVal('Cost', formatCostFloor(u.costUSD, u.unpriced));
        setVal('Credits', formatCredits(u.credits) + (u.unpriced ? '+' : ''));
        setVal('Tokens', u.totalTokens.toLocaleString());
    } catch {
        setVal('Cost', '—'); setVal('Credits', '—'); setVal('Tokens', '—');
    }
}

// ===== Session info: cost + context window + compaction =====

// Rough token estimate for display only (~4 chars per token, the common GPT
// heuristic). Used to split the measured context into estimated components.
function estimateTokens(text) {
    return Math.ceil((String(text || '').length) / 4);
}

// Compact a token count for the meter and breakdown (e.g. 128000 -> "128K").
function fmtTokens(n) {
    n = Number(n) || 0;
    if (n >= 1000) {
        const k = n / 1000;
        return k.toLocaleString(undefined, { maximumFractionDigits: k >= 100 ? 0 : 1 }) + 'K';
    }
    return String(n);
}

// The effective Model capability entry for a Conversation: its own pinned Model,
// else the Settings default, else the Engine default. Returns null when unknown.
function effectiveContextModel(conv) {
    const id = (conv && conv.model) || (state.settings && state.settings.model) || state.defaultModel;
    if (!id) return null;
    return (state.models || []).find((m) => m.id === id) || null;
}

// Compute Session Info for a Conversation: accumulated cost/credits/turns, plus
// the context-window occupancy of the LAST Turn (its per-round-trip prompt size,
// derived from the Engine's summed promptTokens / iterations) against the Model's
// context window, and an estimated split of that context into conversation
// Messages vs system/tool overhead.
function computeSessionInfo(conv) {
    conv = conv || state.current;
    const messages = (conv && conv.messages) || [];
    const usage = sumConversationUsage(messages);
    const assistants = messages.filter((m) => m.role === 'assistant');
    // The Engine's usage.promptTokens is the SUM of input tokens across every
    // tool-calling round-trip in a Turn (each round-trip is billed, so summing is
    // right for cost). The context window only ever holds ONE prompt at a time, so
    // the occupancy is a single round-trip — approximated as the per-iteration
    // average (exact when the Turn made one round-trip, usage.iterations === 1).
    // Using the raw sum over-reports many-fold: a 9-round-trip Turn would read as
    // ~9x the window. The last non-zero Turn is the current occupancy.
    let measured = 0;
    for (const m of assistants) {
        const u = m.usage || {};
        const p = Number(u.promptTokens);
        if (p) measured = Math.round(p / Math.max(1, Number(u.iterations) || 1));
    }
    const model = effectiveContextModel(conv);
    const maxTokens = (model && Number(model.maxContextWindowTokens)) || 0;
    const maxOutput = (model && Number(model.maxOutputTokens)) || 0;
    let rawMessagesEst = 0;
    for (const m of messages) rawMessagesEst += estimateTokens(m.text);
    // Everything the Engine counted beyond the visible message text — system
    // prompt, tool schemas, tool results — is shown as one honest aggregate.
    let messagesEst = rawMessagesEst, overheadEst = 0;
    if (measured > 0) {
        messagesEst = Math.min(rawMessagesEst, measured);
        overheadEst = Math.max(0, measured - messagesEst);
    }
    const pct = (maxTokens > 0 && measured > 0) ? Math.min(100, (measured / maxTokens) * 100) : 0;
    return {
        id: conv && conv.id,
        modelId: (model && model.id) || (conv && conv.model) || (state.settings && state.settings.model) || state.defaultModel || 'Default',
        credits: usage.credits, cost: usage.costUSD, unpriced: usage.unpriced, turns: assistants.length,
        measured, maxTokens, maxOutput, pct, messagesEst, overheadEst,
        compactedUtc: conv && conv.compactedUtc,
    };
}

// Update (or hide) the glanceable context-window pill in the top bar.
function renderContextMeter() {
    const btn = $('btn-context');
    if (!btn) return;
    const info = computeSessionInfo();
    if (!state.current || info.measured <= 0 || info.maxTokens <= 0) {
        btn.classList.add('hidden');
        return;
    }
    const pct = Math.round(info.pct);
    btn.classList.remove('hidden');
    btn.dataset.level = pct >= 90 ? 'high' : (pct >= 70 ? 'mid' : 'low');
    btn.innerHTML = '';
    const track = el('ctx-meter-track', 'span');
    const fill = el('ctx-meter-fill', 'span');
    fill.style.width = pct + '%';
    track.appendChild(fill);
    const label = el('ctx-meter-label', 'span');
    label.textContent = pct + '%';
    btn.append(track, label);
    btn.title = `Context: ${info.measured.toLocaleString()} / ${info.maxTokens.toLocaleString()} tokens (${pct}%). Click for session info.`;
}

// One estimated/measured breakdown row (label, a mini-bar, and a token figure).
function buildBreakdownRow(label, tokens, max, isEst) {
    const row = el('bd-row');
    const k = el('bd-k', 'span'); k.textContent = label;
    const bar = el('bd-bar', 'span');
    const fill = el('bd-fill', 'span');
    fill.style.width = (max > 0 ? Math.min(100, (tokens / max) * 100) : 0).toFixed(1) + '%';
    bar.appendChild(fill);
    const v = el('bd-v', 'span'); v.textContent = (isEst ? '~' : '') + fmtTokens(tokens);
    row.append(k, bar, v);
    return row;
}

// Build the Session Info popover contents for a Conversation via DOM (never
// innerHTML for user-authored text), the way showConversationDetails does.
function fillSessionPopover(conv) {
    const pop = $('session-popover');
    const info = computeSessionInfo(conv);
    pop.innerHTML = '';

    const head = el('', 'h3'); head.textContent = 'Session info';
    pop.appendChild(head);

    const model = el('session-model muted tiny');
    model.textContent = info.modelId + (info.maxTokens ? ' · ' + fmtTokens(info.maxTokens) + ' context' : '');
    pop.appendChild(model);

    const costRow = el('session-row session-cost');
    const ck = el('session-k', 'span'); ck.textContent = 'Session cost';
    const cv = el('session-v', 'span'); cv.textContent = '⚡ ' + formatCredits(info.credits) + (info.unpriced ? '+' : '') + ' credits';
    costRow.append(ck, cv);
    pop.appendChild(costRow);

    const costSub = el('session-sub muted tiny');
    costSub.textContent = formatCostFloor(info.cost, info.unpriced) + ' · ' + info.turns + ' turn' + (info.turns === 1 ? '' : 's');
    pop.appendChild(costSub);

    if (info.unpriced) {
        const warn = el('session-sub muted tiny');
        warn.textContent = info.unpriced + ' turn' + (info.unpriced === 1 ? '' : 's') +
            ' could not be priced — there is no published rate for that model, so its cost is missing from the total.';
        pop.appendChild(warn);
    }

    const block = el('session-block');
    const bh = el('session-block-head'); bh.textContent = 'Context window';
    block.appendChild(bh);
    const hasContext = info.measured > 0 && info.maxTokens > 0;
    if (hasContext) {
        const barPct = Math.round(info.pct);
        const bar = el('ctx-bar');
        bar.dataset.level = barPct >= 90 ? 'high' : (barPct >= 70 ? 'mid' : 'low');
        const used = el('ctx-bar-used', 'span'); used.style.width = barPct + '%';
        const reservedPct = info.maxOutput > 0 ? Math.max(0, Math.min(100 - barPct, (info.maxOutput / info.maxTokens) * 100)) : 0;
        const reserved = el('ctx-bar-reserved', 'span'); reserved.style.width = reservedPct.toFixed(1) + '%';
        bar.append(used, reserved);
        block.appendChild(bar);

        const sub = el('session-sub muted tiny');
        sub.textContent = info.measured.toLocaleString() + ' / ' + info.maxTokens.toLocaleString() + ' tokens · ' + barPct + '% (last turn)';
        block.appendChild(sub);

        const bd = el('session-breakdown');
        bd.appendChild(buildBreakdownRow('Messages', info.messagesEst, info.maxTokens, true));
        bd.appendChild(buildBreakdownRow('System + tools', info.overheadEst, info.maxTokens, true));
        if (info.maxOutput > 0) bd.appendChild(buildBreakdownRow('Reserved for response', info.maxOutput, info.maxTokens, false));
        block.appendChild(bd);

        const hint = el('session-hint muted tiny');
        hint.textContent = 'Breakdown is estimated; the total is measured at the last turn.';
        block.appendChild(hint);
    } else {
        const none = el('muted tiny');
        none.textContent = 'No turns yet — send a message to measure context use.';
        block.appendChild(none);
    }
    pop.appendChild(block);

    if (info.compactedUtc) {
        const comp = el('session-compacted muted tiny');
        comp.textContent = 'Compacted ' + fmtConvDate(info.compactedUtc);
        pop.appendChild(comp);
    }

    // Surface the auto-compaction policy so an automatic compaction is never a
    // surprise (the manual button below still works regardless).
    const sset = state.settings || {};
    if (sset.autoCompaction) {
        const auto = el('session-auto muted tiny');
        const atPct = Math.round((Number(sset.compactionThreshold) || 0.8) * 100);
        auto.textContent = 'Auto-compaction is on (at ' + atPct + '% full).';
        pop.appendChild(auto);
    }

    const btn = el('btn btn-small session-compact-btn', 'button');
    btn.id = 'btn-compact';
    btn.type = 'button';
    btn.textContent = 'Compact conversation';
    if (!hasContext) btn.disabled = true;
    btn.onclick = (e) => { e.stopPropagation(); compactConversation(info.id); };
    pop.appendChild(btn);

    const foot = el('session-hint muted tiny');
    foot.textContent = 'Compacting summarises earlier turns to free the context window. Your visible messages stay intact.';
    pop.appendChild(foot);
}

// Open (or toggle) the Session Info popover. From the top-bar pill it shows the
// open Conversation; from a list row's menu it shows that row (fetched if needed).
async function openSessionInfo(anchor, convId) {
    const pop = $('session-popover');
    if (!pop) return;
    if (!pop.classList.contains('hidden')) { pop.classList.add('hidden'); return; }
    let conv = state.current;
    const targetId = convId || (state.current && state.current.id);
    if (!targetId) { toast('Open a conversation first.'); return; }
    if (convId && (!state.current || state.current.id !== convId)) {
        try { conv = await api('GET', '/api/conversations/' + convId); } catch { conv = null; }
    }
    fillSessionPopover(conv);
    pop.classList.remove('hidden');
    if (anchor) positionConvPopover(pop, anchor);
}

function closeSessionInfo() {
    const pop = $('session-popover');
    if (pop) pop.classList.add('hidden');
}

// Compact a Conversation's replayed context (summarise earlier Turns). The
// visible transcript is preserved; only the Engine -History shrinks, so the next
// Turn sends fewer tokens.
async function compactConversation(id) {
    if (!id) return;
    if (!window.confirm('Compact this conversation? Earlier turns are summarised to free up the context window. Your visible messages are kept.')) return;
    try {
        const r = await api('POST', '/api/conversations/' + id + '/compact');
        const freed = (r && Number(r.estimatedFreed)) || 0;
        toast(freed > 0 ? `Compacted — freed about ${fmtTokens(freed)} tokens of context.` : 'Conversation compacted.');
        closeSessionInfo();
        if (state.current && state.current.id === id) {
            await refreshCurrentConversation();
            renderContextMeter();
        }
        await loadConversations();
    } catch (e) {
        toast((e && e.message) || 'Could not compact the conversation.');
    }
}

// Build a Markdown transcript of a Conversation.
function buildTranscript(conv) {
    const lines = [];
    lines.push('# ' + (conv.title || 'Conversation'));
    lines.push('');
    if (conv.createdUtc) lines.push('_Created ' + conv.createdUtc + '_');
    lines.push('');
    for (const m of asArray(conv.messages)) {
        const who = m.role === 'user' ? 'You' : 'DeskPilot';
        lines.push('## ' + who);
        lines.push('');
        lines.push((m.text || '').trim() || '_(no text)_');
        lines.push('');
        const u = m.usage || {};
        const bits = [];
        if (u.totalTokens) bits.push(u.totalTokens.toLocaleString() + ' tokens');
        if (u.costUSD) bits.push('$' + Number(u.costUSD).toFixed(4));
        if (u.credits) bits.push(u.credits + ' credits');
        if (m.model) bits.push(m.model);
        if (bits.length) { lines.push('> ' + bits.join(' · ')); lines.push(''); }
    }
    return lines.join('\n');
}

// Copy a Conversation's Markdown transcript to the clipboard.
async function copyTranscript(id) {
    let conv;
    try { conv = await api('GET', '/api/conversations/' + id); }
    catch (e) { toast(e.message); return; }
    const text = buildTranscript(conv);
    try {
        await navigator.clipboard.writeText(text);
        toast('Transcript copied.');
    } catch {
        const ta = document.createElement('textarea');
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        let ok = false;
        try { ok = document.execCommand('copy'); } catch { ok = false; }
        ta.remove();
        toast(ok ? 'Transcript copied.' : 'Could not copy transcript.');
    }
}

// Copy a Message to the clipboard. The Clipboard API needs a secure context,
// which loopback is - but a denied permission or an older browser still lands
// here, so the textarea fallback keeps a one-click action from doing nothing.
async function copyMessageText(text, label) {
    const value = (text || '').toString();
    const done = label || 'Copied message.';
    try {
        await navigator.clipboard.writeText(value);
        toast(done);
        return;
    } catch { /* fall through */ }
    const ta = document.createElement('textarea');
    ta.value = value;
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    ta.remove();
    toast(ok ? done : 'Could not copy.');
}

// Build a Markdown transcript of a Conversation and download it.
async function exportConversation(id) {
    let conv;
    try { conv = await api('GET', '/api/conversations/' + id); }
    catch (e) { toast(e.message); return; }
    const blob = new Blob([buildTranscript(conv)], { type: 'text/markdown' });
    const safe = (conv.title || 'conversation').replace(/[^\w.-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'conversation';
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = safe + '.md';
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 0);
    toast('Exported ' + a.download);
}

async function newConversation() {
    const model = (state.settings && state.settings.model) || state.defaultModel || null;
    const summary = await api('POST', '/api/conversations', { model });
    state.conversations.unshift(summary);
    await selectConversation(summary.id);
    $('prompt').focus();
}

// Return to the home screen: drop the open Conversation and show the empty
// state. The next message the user sends starts a fresh Conversation.
function goHome() {
    if (state.streaming) { toast('Finish the current turn first.'); return; }
    state.current = null;
    $('conv-title').value = '';
    renderConversationList();
    renderThread();
    renderContextMeter();
    closeSidebar();
    $('prompt').focus();
}

async function selectConversation(id) {
    try {
        state.current = await api('GET', '/api/conversations/' + id);
    }
    catch (e) {
        // The row can outlive the Conversation: Intercom may have deleted it
        // since the sidebar was drawn. Clicking it used to do nothing at all.
        if (e && e.status === 404) {
            toast('That conversation no longer exists.');
            await syncConversationsFromServer();
            return;
        }
        throw e;
    }
    $('conv-title').value = state.current.title || '';
    setModelSelect(state.current.model || state.defaultModel);
    seedPromptHistory(state.current.messages);
    // Opening a Conversation clears its unread flag (best-effort; never blocks).
    const openedSummary = state.conversations.find((c) => c.id === id);
    if (openedSummary && openedSummary.unread) {
        openedSummary.unread = false;
        if (state.searchResults) { const r = state.searchResults.find((x) => x.id === id); if (r) r.unread = false; }
        api('PATCH', '/api/conversations/' + id, { unread: false }).catch(() => {});
    }
    renderConversationList();
    renderThread();
    renderContextMeter();
    closeSidebar();
}

async function deleteConversation(id) {
    // Deleting a Conversation cannot be undone, and archiving is what people
    // usually mean, so the confirmation names both.
    const summary = state.conversations.find((c) => c.id === id);
    const title = (summary && summary.title) || 'this conversation';
    if (!window.confirm(`Delete “${title}” permanently?\n\nThis cannot be undone. Archive it instead if you only want it out of the way.`)) return;
    await api('DELETE', '/api/conversations/' + id);
    state.conversations = state.conversations.filter((c) => c.id !== id);
    if (state.current && state.current.id === id) {
        state.current = null;
        if (state.conversations.length) await selectConversation(state.conversations[0].id);
        else await newConversation();
    } else {
        renderConversationList();
    }
}

// ===== Thread rendering =====
function renderThread() {
    const thread = $('thread');
    thread.innerHTML = '';
    if (!state.current || !state.current.messages || state.current.messages.length === 0) {
        thread.appendChild(buildEmptyState());
        return;
    }
    for (const m of state.current.messages) {
        if (m.role === 'user' && m.checkpoint && m.checkpoint.sha) thread.appendChild(buildCheckpointEl(m));
        thread.appendChild(m.role === 'user' ? buildUserEl(m) : finalizeAssistant(buildAssistantEl(m), m));
    }
    markLastAssistant();
    scrollThread();
}

// Show the Regenerate affordance only on the last assistant message (the only
// one the backend can re-run, since regenerate replays the last user prompt).
function markLastAssistant() {
    const thread = $('thread');
    thread.querySelectorAll('.msg-assistant.is-last').forEach((n) => n.classList.remove('is-last'));
    const all = thread.querySelectorAll('.msg-assistant');
    if (all.length) all[all.length - 1].classList.add('is-last');
}
function buildEmptyState() {
    const wrap = el('empty-state');
    wrap.innerHTML = `<span class="brand-mark-img brand-mark-img-xl" aria-hidden="true"></span>
    <h2>How can I help?</h2>
    <p class="muted">Ask a question, or give the agent a task. It can read and write files, run commands, and browse — with the permissions you allow.</p>
    <div class="examples" id="examples"></div>`;
    setTimeout(renderExamples, 0);
    return wrap;
}

// The marker above a prompt: everything from here on can be undone in one go.
// DeskPilot already snapshots the project before every turn, so a checkpoint is
// that snapshot made reachable from the transcript.
function buildCheckpointEl(m) {
    const wrap = el('checkpoint');
    const label = el('checkpoint-label', 'button');
    label.type = 'button';
    label.title = 'Go back to how things were just before this message';
    // Inline SVG rather than a glyph: the branch characters in Unicode have
    // patchy font coverage and fall back to a tofu box on some Windows installs.
    label.innerHTML = '<svg class="checkpoint-ico" viewBox="0 0 16 16" width="12" height="12" aria-hidden="true" focusable="false">' +
        '<path fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" ' +
        'd="M4.5 4.2v7.6M4.5 7.4h4a3 3 0 0 0 3-3v-.6"/>' +
        '<circle cx="4.5" cy="2.8" r="1.4" fill="currentColor"/>' +
        '<circle cx="4.5" cy="13.2" r="1.4" fill="currentColor"/>' +
        '<circle cx="11.5" cy="2.8" r="1.4" fill="currentColor"/>' +
        '</svg> Restore Checkpoint';
    label.onclick = () => restoreCheckpoint(m);
    wrap.appendChild(label);
    return wrap;
}

async function restoreCheckpoint(m) {
    if (state.streaming) { toast('Finish the current turn first.'); return; }
    if (!state.current) return;
    const when = m.checkpoint && m.checkpoint.createdUtc ? new Date(m.checkpoint.createdUtc).toLocaleTimeString() : '';
    const confirmed = window.confirm(
        `Go back to before this message${when ? ' (' + when + ')' : ''}?\n\n` +
        'This removes it and everything after it from the conversation, and puts back any files DeskPilot changed since. ' +
        'Your own edits to other files are left alone. This cannot be undone.');
    if (!confirmed) return;
    try {
        const r = await api('POST', '/api/conversations/' + state.current.id + '/checkpoint', { messageId: m.id });
        await selectConversation(state.current.id);
        const promptEl = $('prompt');
        if (promptEl && r.prompt) {
            promptEl.value = r.prompt;
            autoGrow(promptEl);
            setSendEnabled(true);
            promptEl.focus();
        }
        await refreshExplorer({ silent: true }).catch(() => {});
        const touched = (r.restored || []).length + (r.removed || []).length;
        toast(touched ? `Restored checkpoint — ${touched} file${touched === 1 ? '' : 's'} put back.` : 'Restored checkpoint.');
    } catch (e) { toast((e && e.message) || 'Could not restore that checkpoint.'); }
}

function buildUserEl(m) {
    const wrap = el('msg msg-user');
    if (m && m.id) wrap.dataset.id = m.id;
    const bubble = el('bubble');
    bubble.textContent = m.text;
    wrap.appendChild(bubble);
    if (m.dispatch === 'steered') {
        const badge = el('steered-badge');
        badge.textContent = 'Steered mid-turn';
        wrap.appendChild(badge);
    } else if (m.dispatch === 'queued') {
        const badge = el('steered-badge');
        badge.textContent = 'Sent from queue';
        wrap.appendChild(badge);
    }
    // Edit & resend, and copy (only meaningful for a persisted message with text).
    if (m && m.id && m.text) {
        const actions = el('user-actions');
        const copy = el('msg-action-btn', 'button');
        copy.type = 'button';
        copy.title = 'Copy message';
        copy.setAttribute('aria-label', 'Copy message');
        copy.textContent = '⧉';
        copy.onclick = () => copyMessageText(m.text);
        actions.appendChild(copy);
        const edit = el('msg-action-btn', 'button');
        edit.type = 'button';
        edit.title = 'Edit & resend';
        edit.setAttribute('aria-label', 'Edit and resend');
        edit.textContent = '✎';
        edit.onclick = () => startEditMessage(wrap, m);
        actions.appendChild(edit);
        wrap.appendChild(actions);
    }
    return wrap;
}

function buildAssistantEl(m) {
    const wrap = el('msg msg-assistant');
    wrap.dataset.id = m.id;
    const role = el('role');
    role.innerHTML = '<span class="brand-mark-img brand-mark-img-sm" aria-hidden="true"></span> DeskPilot';
    const actions = el('msg-actions');
    role.appendChild(actions);
    const thinking = el('disclosure thinking hidden', 'details');
    thinking.innerHTML = '<summary>Thinking</summary><div class="disclosure-body"></div>';
    // Asking to see the model's thinking means seeing it, not finding a box to open.
    thinking.open = !!(state.settings && state.settings.showThinking);
    // What the model said between its tool calls. Deliberately NOT gated on the
    // thinking setting: this is answer text the model chose to emit, not a trace.
    const steps = el('disclosure steps hidden', 'details');
    steps.innerHTML = '<summary>Steps</summary><div class="disclosure-body"></div>';
    const content = el('content');
    const tasks = el('tasks-panel hidden');
    const userPrompts = el('user-prompts hidden');
    userPrompts.setAttribute('aria-live', 'polite');
    const changes = el('changes-card hidden');
    const activity = el('disclosure activity hidden', 'details');
    const usage = el('usage-foot hidden');
    wrap.append(role, thinking, steps, content, tasks, userPrompts, changes, activity, usage);
    wrap._refs = { content, thinking, steps, tasks, userPrompts, changes, activity, usage, actions };
    return wrap;
}

function finalizeAssistant(wrap, m, opts) {
    const r = wrap._refs;
    if (m.stopped) {
        showInlineError(wrap, m.stopReason || 'Turn stopped.');
    } else {
        r.content.innerHTML = renderMarkdown(m.text || '');
        hydrateCopies(r.content);
        decorateArtifacts(r.content);
    }
    if (r.actions) buildMessageActions(r.actions, m, opts && opts.isLast);
    if (m.reasoning) {
        wrap.querySelector('.thinking').classList.remove('hidden');
        wrap.querySelector('.thinking .disclosure-body').textContent = m.reasoning;
    }
    renderSteps(r.steps, m.narration);
    renderTasks(r.tasks, m.tasks);
    renderActivity(r.activity, m.activity);
    renderChanges(r.changes, m);
    renderUsage(r.usage, m);
    return wrap;
}

// What the model said between its tool calls. It streams into the answer body
// live, and finalizeAssistant then replaces that body with the final answer -
// so without this the whole account of how the Turn was worked is destroyed at
// the moment it completes.
function renderSteps(node, narration) {
    if (!node) return;
    const blocks = asArray(narration).filter((b) => b && b.text);
    if (!blocks.length) { node.classList.add('hidden'); return; }
    node.classList.remove('hidden');
    const summary = node.querySelector('summary');
    if (summary) summary.textContent = blocks.length === 1 ? '1 step' : `${blocks.length} steps`;
    const body = node.querySelector('.disclosure-body');
    body.innerHTML = blocks
        .map((b) => `<div class="step-block">${renderMarkdown(String(b.text))}</div>`)
        .join('');
    hydrateCopies(body);
}

// ===== Activity (what the Turn touched, while it happens and afterwards) =====
// One row per tool call, in the order the agent made them. Consecutive rows of
// one kind fold into a group ("Read 6 files"), which is open while the Turn runs
// — the point is to see the files go by — and closed once it ends, leaving the
// whole panel as the single line the reader can open again.
const ACTIVITY_KINDS = {
    read: { ico: '📄', label: 'Read', noun: 'files' },
    list: { ico: '📁', label: 'Listed', noun: 'folders' },
    write: { ico: '✏️', label: 'Wrote', noun: 'files' },
    create: { ico: '📂', label: 'Created', noun: 'folders' },
    run: { ico: '⌘', label: 'Ran', noun: 'commands' },
    fetch: { ico: '🌐', label: 'Fetched', noun: 'pages' },
    search: { ico: '🔎', label: 'Searched', noun: 'searches' },
    ask: { ico: '❓', label: 'Asked', noun: 'questions' },
    load: { ico: '📘', label: 'Loaded', noun: 'files' },
    other: { ico: '•', label: 'Used', noun: 'tools' },
    dropped: { ico: '…', label: '', noun: '' },
};

const activityKind = (kind) => ACTIVITY_KINDS[kind] || ACTIVITY_KINDS.other;

// What an action says on one line. An unknown tool is named, because "Used" on
// its own says nothing; a known one that could not be read keeps its verb.
function activityLine(action) {
    if (!action) return '';
    const kind = activityKind(action.kind);
    const detail = String(action.detail || '');
    if (action.kind === 'dropped') return detail;
    if (detail) return `${kind.label} ${detail}`;
    if (action.kind === 'other' && action.tool) return `${kind.label} ${action.tool}`;
    return kind.label;
}

// Consecutive runs of one kind, the way the reader experienced them: six reads in
// a row are one moment of the Turn, and six reads spread across it are six.
function groupActivity(actions) {
    const groups = [];
    for (const a of actions) {
        const last = groups[groups.length - 1];
        if (last && last.kind === a.kind && a.kind !== 'dropped') last.items.push(a);
        else groups.push({ kind: a.kind, items: [a] });
    }
    return groups;
}

function activityRowHtml(action, showDiff) {
    const kind = activityKind(action.kind);
    const detail = String(action.detail || '');
    if (action.kind === 'dropped') {
        return `<div class="activity-item muted tiny"><span class="ico">${kind.ico}</span><span>${escapeHtml(detail)}</span></div>`;
    }
    const diffBtn = (showDiff && action.kind === 'write' && detail)
        ? `<button class="git-diff-btn" data-path="${escapeHtml(detail)}" title="Show what changed (Git diff)">diff</button>`
        : '';
    const body = detail
        ? `${escapeHtml(kind.label)} <span class="path">${escapeHtml(detail)}</span>`
        : escapeHtml(activityLine(action));
    return `<div class="activity-item"><span class="ico">${kind.ico}</span><span>${body}</span>${diffBtn}</div>`;
}

function paintActivity(node, actions, opts) {
    const live = !!(opts && opts.live);
    const gitOn = !!(state.settings && state.settings.workspaceFolder);
    const groups = groupActivity(actions);
    const body = groups.map((g) => {
        const kind = activityKind(g.kind);
        if (g.items.length === 1) return activityRowHtml(g.items[0], gitOn);
        return `<details class="activity-group"${live ? ' open' : ''}>` +
            `<summary><span class="ico">${kind.ico}</span>${escapeHtml(kind.label)} ${g.items.length} ${escapeHtml(kind.noun)}</summary>` +
            `<div class="activity-sub">${g.items.map((a) => activityRowHtml(a, gitOn)).join('')}</div>` +
            '</details>';
    }).join('');
    node.classList.remove('hidden');
    // Open it when the first action arrives, and leave it alone after that: a
    // reader who folds it away mid-Turn should not have to keep folding it. The
    // end of the Turn is what closes it again.
    if (!live) node.open = false;
    else if (actions.length <= 1) node.open = true;
    const n = actions.filter((a) => a.kind !== 'dropped').length;
    node.innerHTML =
        `<summary>${live ? 'Working' : 'Activity'} — ${n} action${n === 1 ? '' : 's'}</summary>` +
        `<div class="disclosure-body"><div class="activity-list">${body}</div></div>`;
    wireActivityDiffButtons(node);
}

function wireActivityDiffButtons(node) {
    const paths = [...new Set([...node.querySelectorAll('.git-diff-btn')].map((b) => b.dataset.path))];
    node.querySelectorAll('.git-diff-btn').forEach((btn) => {
        btn.onclick = (e) => { e.preventDefault(); openDiffViewer(paths.map((p) => ({ rel: p })), btn.dataset.path); };
    });
}

// One tool call, announced before the Engine runs it. This is the whole point of
// the panel: with the Thinking pane off, it was the only thing that ever said
// which files the agent was touching, and it said nothing until the Turn ended.
function noteActivity(wrap, action) {
    const node = wrap && wrap._refs && wrap._refs.activity;
    if (!node || !action || !action.kind) return;
    const live = node._liveActions || (node._liveActions = []);
    live.push(action);
    paintActivity(node, live, { live: true });
    // A write is also a change to review, which the Changes card takes over at the
    // end of the Turn.
    if (action.kind === 'write' && action.detail) noteFileEdit(wrap, action.detail);
    setActivityStatus(activityLine(action));
    followThread();
}

function renderActivity(node, activity) {
    if (!node) return;
    const ordered = asArray(activity && activity.actions).filter((a) => a && a.kind);
    // A stopped or budget-exhausted Turn never receives an Engine result, so what
    // streamed live is the only account there is; it must not be blanked.
    const live = node._liveActions || [];
    if (ordered.length || live.length) {
        paintActivity(node, ordered.length ? ordered : live, { live: false });
        return;
    }
    if (!activity) { node.classList.add('hidden'); return; }
    // Messages written before the Turn kept an ordered account: the Engine's
    // unordered sets are all they have.
    const groups = [
        ['filesRead', '📄', 'Read'],
        ['filesWritten', '✏️', 'Wrote'],
        ['commandsRun', '⌘', 'Ran'],
        ['pagesFetched', '🌐', 'Fetched'],
        ['questionsAsked', '❓', 'Asked'],
    ];
    const gitOn = !!(state.settings && state.settings.workspaceFolder);
    const written = asArray(activity.filesWritten).map(String);
    const items = [];
    for (const [key, ico, label] of groups) {
        for (const v of asArray(activity[key])) {
            const path = String(v);
            const isWritten = key === 'filesWritten';
            const diffBtn = (isWritten && gitOn)
                ? `<button class="git-diff-btn" data-path="${escapeHtml(path)}" title="Show what changed (Git diff)">diff</button>`
                : '';
            items.push(`<div class="activity-item"><span class="ico">${ico}</span><span>${label} <span class="path">${escapeHtml(path)}</span></span>${diffBtn}</div>`);
        }
    }
    const toolCount = asArray(activity.toolCalls).length;
    if (items.length === 0 && toolCount === 0) { node.classList.add('hidden'); return; }
    node.classList.remove('hidden');
    const n = items.length || toolCount;
    node.innerHTML =
        `<summary>Activity — ${n} action${n === 1 ? '' : 's'}</summary>` +
        `<div class="disclosure-body"><div class="activity-list">${items.join('') || '<span class="muted tiny">' + toolCount + ' tool call(s)</span>'}</div></div>`;
    node.querySelectorAll('.git-diff-btn').forEach((btn) => {
        btn.onclick = (e) => { e.preventDefault(); openDiffViewer(written.map((p) => ({ rel: p })), btn.dataset.path); };
    });
}

// ===== Changes review (what this Turn wrote, with per-file counts) =====
// Mirrors the review a developer gets in an IDE: a "N files changed +A −D"
// header, one row per file, click to see the diff, then Keep (commit) or Undo.
// Painted after the Turn finalizes because it needs a Git read per Turn, and
// only for the newest Turn: an older card would describe a working tree that
// has since moved on, and would cost one Git read per message on every render.
// While the Turn runs the same element carries the live edit rows below, which
// this card supersedes as soon as the change set can be measured.
async function renderChanges(node, m) {
    if (!node) return;
    const written = asArray(m && m.activity && m.activity.filesWritten).map(String);
    if (!written.length || !(state.settings && state.settings.workspaceFolder)) { sealLiveEdits(node); return; }

    // Driven by the pending set, not by Git: the card is the review of what this
    // Turn changed, and it disappears once the user keeps or undoes those files —
    // exactly the files, whatever else has happened in the repository since.
    await loadAiChanges(false);
    const wanted = new Set(written.map((p) => turnRelPath(p)).filter(Boolean));
    const files = aiChanges.list.filter((f) => f && f.status !== 'unchanged' && wanted.has(String(f.rel).toLowerCase()));
    if (!files.length) { sealLiveEdits(node); return; }

    paintChangesCard(node, files);
}

// ===== Live edits (the files a Turn is writing, while it writes them) =====
// The Engine announces a write before it performs it, so a row here states the
// agent's intent and carries no counts — measuring one would mean a Git read per
// write on the thread that keeps the stream alive. The Changes card replaces the
// whole thing at the end of the Turn, when the pending change set can be
// compared with the pre-Turn snapshot.
function noteFileEdit(wrap, path) {
    const node = wrap && wrap._refs && wrap._refs.changes;
    if (!node || !path) return;
    const key = turnRelPath(path);
    if (!key) return;
    const edits = node._liveEdits || (node._liveEdits = new Map());
    if (edits.has(key)) return;
    edits.set(key, turnDisplayPath(path));
    paintLiveEdits(node, edits, true);
}

function paintLiveEdits(node, edits, editing) {
    node.classList.remove('hidden');
    node.classList.add('changes-live');
    node.innerHTML = '';
    const n = edits.size;
    const head = el('changes-head');
    head.innerHTML = `<span class="changes-count">${editing ? 'Editing ' : ''}${n} file${n === 1 ? '' : 's'}${editing ? '\u2026' : ' edited'}</span>`;
    node.appendChild(head);
    const list = el('changes-list');
    for (const rel of edits.values()) {
        const parts = splitRelPath(rel);
        const row = el('changes-row changes-row-live');
        row.title = rel;
        // A neutral glyph, not a status letter: whether this ends up a new file or
        // an edit is not known until the write has happened.
        row.innerHTML =
            '<span class="changes-badge">\u270E</span>' +
            `<span class="changes-name">${escapeHtml(parts.name)}</span>` +
            `<span class="changes-dir muted tiny">${escapeHtml(parts.dir)}</span>`;
        list.appendChild(row);
    }
    node.appendChild(list);
}

// A Turn can end with nothing reviewable — no Project, no Git repository, or
// files the user has already put back — and that must not erase the record of
// what it wrote. Keep the live rows in that case, without the "still going"
// wording; a message rebuilt from history has none, so it clears as before.
function sealLiveEdits(node) {
    const edits = node._liveEdits;
    if (edits && edits.size) { paintLiveEdits(node, edits, false); return; }
    node.classList.add('hidden');
    node.innerHTML = '';
}

// A Turn reports absolute or Project-relative paths; show them the way the
// Changes list does, relative to the Project.
function turnDisplayPath(p) {
    const rel = projectRelPath(p);
    if (rel != null) return rel;
    return String(p || '').replace(/\\/g, '/').replace(/^\.\//, '');
}

// The pending set is keyed by lowercased Project-relative paths.
function turnRelPath(p) {
    return turnDisplayPath(p).toLowerCase();
}

function paintChangesCard(node, files) {
    const totals = files.reduce((acc, f) => ({ a: acc.a + Number(f.added || 0), d: acc.d + Number(f.deleted || 0) }), { a: 0, d: 0 });
    node.classList.remove('hidden');
    node.classList.remove('changes-live');
    node.innerHTML = '';

    const head = el('changes-head');
    head.innerHTML =
        `<span class="changes-count">${files.length} file${files.length === 1 ? '' : 's'} changed</span>` +
        `<span class="changes-stat changes-add">+${escapeHtml(String(totals.a))}</span>` +
        `<span class="changes-stat changes-del">\u2212${escapeHtml(String(totals.d))}</span>`;
    const actions = el('changes-acts');
    const paths = files.map((f) => f.rel);
    const keep = document.createElement('button');
    keep.className = 'btn btn-small btn-primary';
    keep.type = 'button';
    keep.textContent = 'Keep';
    keep.title = 'Accept these changes and stop tracking them as unreviewed';
    keep.onclick = (e) => { e.preventDefault(); keepAiChanges(paths, keep); };
    const undo = document.createElement('button');
    undo.className = 'btn btn-small';
    undo.type = 'button';
    undo.textContent = 'Undo';
    undo.title = 'Put these files back the way they were before DeskPilot changed them';
    undo.disabled = !aiChanges.undoable;
    undo.onclick = (e) => { e.preventDefault(); undoAiChanges(paths, undo); };
    actions.append(keep, undo);
    head.appendChild(actions);
    node.appendChild(head);

    const list = el('changes-list');
    for (const f of files) list.appendChild(buildChangeRow(f, files));
    node.appendChild(list);
}

function buildChangeRow(f, files) {
    const parts = splitRelPath(f.rel);
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'changes-row';
    row.title = statusLabel(f.status) + ' — click to see what changed';
    row.innerHTML =
        `<span class="changes-badge st-${escapeHtml(f.status || 'modified')}">${escapeHtml(statusGlyph(f.status))}</span>` +
        `<span class="changes-name">${escapeHtml(parts.name)}</span>` +
        `<span class="changes-dir muted tiny">${escapeHtml(parts.dir)}</span>` +
        (f.binary
            ? '<span class="changes-stat muted tiny">binary</span>'
            : `<span class="changes-stat changes-add">${f.added ? '+' + escapeHtml(String(f.added)) : ''}</span>` +
              `<span class="changes-stat changes-del">${f.deleted ? '\u2212' + escapeHtml(String(f.deleted)) : ''}</span>`);
    row.onclick = (e) => { e.preventDefault(); openDiffViewer(files, f.rel); };
    return row;
}

// Undo file changes through Git alone: revert tracked files to the last commit
// and delete files that are untracked. Used by the diff viewer for a file that
// is not (or no longer) a pending DeskPilot change.
async function undoTurnFiles(paths, btn, node) {
    const list = asArray(paths).map(String);
    if (list.length === 0) return;
    const msg = 'Undo these file changes?\n\n' +
        'Tracked files are reverted to the last Git commit, and untracked files are deleted. ' +
        'Anything you have not committed will be lost.\n\nFiles:\n' + list.map((p) => '• ' + p).join('\n');
    if (!window.confirm(msg)) return;
    if (btn) { btn.disabled = true; btn.textContent = 'Undoing…'; }
    try {
        const r = await api('POST', '/api/git/restore', { paths: list });
        const parts = [];
        if (r.restored && r.restored.length) parts.push(r.restored.length + ' reverted');
        if (r.removed && r.removed.length) parts.push(r.removed.length + ' removed');
        if (r.skipped && r.skipped.length) parts.push(r.skipped.length + ' skipped');
        toast(parts.length ? 'Undo: ' + parts.join(', ') + '.' : 'Nothing to undo.');
        if (node) { node.classList.add('hidden'); node.innerHTML = ''; }
        gitChanges.at = 0;
        aiChanges.at = 0;
        await refreshExplorer();
        await refreshDiffViewer();
    } catch (e) { toast(e.message); }
    finally { if (btn) { btn.disabled = false; btn.textContent = 'Undo'; } }
}

// ===== Diff viewer =====
// One modal for "show me what changed in this file", with the file list beside
// it so a reviewer can walk a whole change set without reopening anything.
const diffView = { files: [], index: 0 };
const DIFF_DISCARD_LIST_LIMIT = 10;

// "Discard all" over everything the viewer is showing: tracked files go back to
// the last save, files that were never saved are deleted. It throws away work in
// files the reviewer may never have opened, and an unsaved file has no second
// copy anywhere, so it always confirms and names what it is about to take.
async function discardAllDiffFiles(btn) {
    const paths = diffView.files.map((f) => String((f && f.rel) || '')).filter(Boolean);
    if (!paths.length) { toast('Nothing to discard.'); return; }
    const shown = paths.slice(0, DIFF_DISCARD_LIST_LIMIT).map((p) => '\u2022 ' + p).join('\n');
    const rest = paths.length - DIFF_DISCARD_LIST_LIMIT;
    const confirmed = window.confirm(
        `Discard the changes in ${paths.length} file${paths.length === 1 ? '' : 's'}?\n\n` +
        'Each file goes back to the way it was at the last save, and a file that was never saved is deleted. ' +
        'This cannot be undone.\n\n' + shown + (rest > 0 ? `\n\u2026and ${rest} more` : ''));
    if (!confirmed) return;
    const label = btn ? btn.textContent : '';
    if (btn) { btn.disabled = true; btn.textContent = 'Discarding\u2026'; }
    try {
        const r = await api('POST', '/api/git/restore', { paths });
        const bits = [];
        if (r.restored && r.restored.length) bits.push(r.restored.length + ' put back');
        if (r.removed && r.removed.length) bits.push(r.removed.length + ' removed');
        if (r.skipped && r.skipped.length) bits.push(r.skipped.length + ' skipped');
        toast(bits.length ? 'Discarded: ' + bits.join(', ') + '.' : 'Nothing to discard.');
        await afterChangeDecision();
    } catch (e) { toast(e.message); }
    finally { if (btn) { btn.disabled = false; btn.textContent = label; } }
}

function openDiffViewer(files, selectRel) {
    const list = asArray(files)
        .map((f) => (typeof f === 'string' ? { rel: f } : f))
        .filter((f) => f && f.rel && !f.directory);
    if (!list.length) { toast('Nothing to show.'); return; }
    diffView.files = list;
    const idx = list.findIndex((f) => f.rel === selectRel);
    diffView.index = idx >= 0 ? idx : 0;
    $('diff-backdrop').classList.remove('hidden');
    $('diff-modal').classList.remove('hidden');
    renderDiffFileList();
    loadDiffFile();
}

function closeDiffViewer() {
    $('diff-backdrop').classList.add('hidden');
    $('diff-modal').classList.add('hidden');
}

function diffViewerIsOpen() {
    return !$('diff-modal').classList.contains('hidden');
}

// What the change sets currently hold for a path, or null when nothing differs
// any more. The pending set wins: its record carries the pre-Turn snapshot the
// viewer diffs against.
function changeRecordFor(rel) {
    const key = String(rel || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
    if (!key) return null;
    const pending = aiChanges.files.get(key);
    if (pending && pending.status !== 'unchanged') return pending;
    return gitChangeList().find((f) => String(f.rel).replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase() === key) || null;
}

// Keep and Undo change the working tree under an open viewer. Re-derive its list
// from the refreshed change sets so an undone file stops being listed (and stops
// offering a second undo), and close the viewer when nothing is left to review.
// Callers must refresh the change sets first.
async function refreshDiffViewer() {
    if (!diffViewerIsOpen()) return;
    const next = reconcileDiffFiles(diffView.files, diffView.index, changeRecordFor);
    if (!next.files.length) { closeDiffViewer(); return; }
    diffView.files = next.files;
    diffView.index = next.index;
    renderDiffFileList();
    await loadDiffFile();
}

function renderDiffFileList() {
    const wrap = $('diff-files');
    if (!wrap) return;
    wrap.innerHTML = '';
    wrap.classList.toggle('hidden', diffView.files.length < 2);
    if (diffView.files.length < 2) return;
    diffView.files.forEach((f, i) => {
        const parts = splitRelPath(f.rel);
        const row = document.createElement('button');
        row.type = 'button';
        row.className = 'diff-file' + (i === diffView.index ? ' active' : '');
        row.title = f.rel;
        row.innerHTML =
            `<span class="changes-badge st-${escapeHtml(f.status || 'modified')}">${escapeHtml(statusGlyph(f.status))}</span>` +
            `<span class="diff-file-name">${escapeHtml(parts.name)}</span>` +
            `<span class="diff-file-dir muted tiny">${escapeHtml(parts.dir)}</span>`;
        row.onclick = () => { diffView.index = i; renderDiffFileList(); loadDiffFile(); };
        wrap.appendChild(row);
    });
}

function diffStep(delta) {
    if (diffView.files.length < 2) return;
    diffView.index = (diffView.index + delta + diffView.files.length) % diffView.files.length;
    renderDiffFileList();
    loadDiffFile();
}

async function loadDiffFile() {
    const current = diffView.files[diffView.index];
    if (!current) return;
    const body = $('diff-body');
    const title = $('diff-title');
    const stat = $('diff-stat');
    const foot = $('diff-foot');
    title.textContent = current.rel;
    title.title = current.rel;
    stat.textContent = '';
    body.innerHTML = '<div class="muted tiny diff-msg">Loading…</div>';
    foot.innerHTML = '';

    let data;
    // A pending DeskPilot change is diffed against the snapshot taken before the
    // Turn, so the viewer shows what the agent did rather than everything that
    // differs from the last commit.
    const base = current.snapshotSha || (aiChangeFor(current.rel) || {}).snapshotSha || '';
    const query = '/api/git/diff?path=' + encodeURIComponent(current.rel) + (base ? '&base=' + encodeURIComponent(base) : '');
    try { data = await api('GET', query); }
    catch (e) { body.innerHTML = `<div class="merge-error">⚠ ${escapeHtml(e.message)}</div>`; return; }
    if (data.error) { body.innerHTML = `<div class="merge-error">⚠ ${escapeHtml(data.error)}</div>`; return; }

    let rows = [];
    let added = 0;
    let deleted = 0;
    if (data.untracked) {
        if (data.binary) {
            body.innerHTML = '<div class="muted tiny diff-msg">New binary file — there is no text to compare.</div>';
        } else {
            rows = newFileRows(data.content);
            added = rows.length;
        }
    } else if (!data.diff || !data.diff.trim()) {
        body.innerHTML = '<div class="muted tiny diff-msg">No changes against the last commit.</div>';
    } else {
        const parsed = parseUnifiedDiff(data.diff);
        rows = parsed.rows;
        added = parsed.added;
        deleted = parsed.deleted;
    }

    if (rows.length) {
        stat.innerHTML = `<span class="changes-add">+${added}</span> <span class="changes-del">\u2212${deleted}</span>`;
        body.innerHTML = '';
        body.appendChild(buildDiffTable(rows));
    }

    const undoBtn = document.createElement('button');
    undoBtn.className = 'btn';
    undoBtn.type = 'button';
    undoBtn.textContent = 'Undo this file';
    // A pending DeskPilot change goes back to its pre-Turn snapshot; anything else
    // can only go back to the last commit.
    const pendingHere = aiChangeFor(current.rel);
    undoBtn.onclick = () => (pendingHere && pendingHere.undoable
        ? undoAiChanges([current.rel], undoBtn)
        : undoTurnFiles([current.rel], undoBtn));
    const closeBtn = document.createElement('button');
    closeBtn.className = 'btn btn-primary';
    closeBtn.type = 'button';
    closeBtn.textContent = 'Close';
    closeBtn.onclick = () => closeDiffViewer();
    // Reviewing a whole change set file by file and undoing each one is the slow
    // path; this is the one that ends it. Offered only over more than one file,
    // because over a single file it is the same act as "Undo this file", and kept
    // at the far end of the footer so it is nowhere near Close.
    if (diffView.files.length > 1) {
        const discardBtn = document.createElement('button');
        discardBtn.className = 'btn btn-danger diff-discard-all';
        discardBtn.type = 'button';
        discardBtn.textContent = 'Discard all changes\u2026';
        discardBtn.title = 'Put every file listed here back the way it was at the last save';
        discardBtn.onclick = () => discardAllDiffFiles(discardBtn);
        foot.appendChild(discardBtn);
    }
    foot.append(undoBtn, closeBtn);
}

function buildDiffTable(rows) {
    const table = el('diff-table');
    for (const r of rows) {
        const line = el('diff-row diff-' + r.type);
        const oldNo = el('diff-gutter', 'span');
        oldNo.textContent = r.oldNo == null ? '' : String(r.oldNo);
        const newNo = el('diff-gutter', 'span');
        newNo.textContent = r.newNo == null ? '' : String(r.newNo);
        const sign = el('diff-sign', 'span');
        sign.textContent = r.type === 'add' ? '+' : r.type === 'del' ? '\u2212' : '';
        const text = el('diff-text', 'span');
        text.textContent = r.text === '' ? '\u200b' : r.text;
        line.append(oldNo, newNo, sign, text);
        table.appendChild(line);
    }
    return table;
}

// Renders the in-Turn Task List as a compact, always-visible checklist. The full
// list is sent on every update (idempotent replace), so this paints from scratch
// each time. Hidden when the list is empty.
function renderTasks(node, tasks) {
    if (!node) return;
    const list = asArray(tasks);
    if (list.length === 0) { node.classList.add('hidden'); node.innerHTML = ''; return; }
    const total = list.length;
    const completed = list.filter((t) => t && t.status === 'completed').length;
    const glyph = (s) => (s === 'completed' ? '✓' : s === 'in-progress' ? '◐' : '○');
    const rows = list
        .map((t) => {
            const s = (t && t.status) || 'not-started';
            const title = escapeHtml(String((t && t.title) || ''));
            return `<div class="task-item task-${s}"><span class="task-glyph">${glyph(s)}</span><span class="task-title">${title}</span></div>`;
        })
        .join('');
    node.classList.remove('hidden');
    node.innerHTML = `<div class="tasks-head">Tasks — ${completed}/${total}</div><div class="task-list">${rows}</div>`;
}

function renderUserPrompt(node, request, conversationId) {
    if (!node || !request || !request.id) return;
    const requestId = String(request.id);
    if (Array.from(node.children).some((child) => child.dataset.questionId === requestId)) return;

    const wizard = createQuestionnaireState(request);
    if (wizard.questions.length === 0) return;

    const card = el('user-prompt-card questionnaire-card');
    card.dataset.questionId = requestId;
    const head = el('questionnaire-head');
    const title = el('questionnaire-title');
    title.textContent = wizard.title;
    const headActions = el('questionnaire-head-actions');
    const collapse = el('questionnaire-icon questionnaire-collapse', 'button');
    collapse.type = 'button';
    collapse.title = 'Collapse Questionnaire';
    collapse.setAttribute('aria-label', 'Collapse Questionnaire');
    collapse.textContent = '⌃';
    const close = el('questionnaire-icon questionnaire-close', 'button');
    close.type = 'button';
    close.title = 'Stop this Turn';
    close.setAttribute('aria-label', 'Stop this Turn');
    close.textContent = '×';
    headActions.append(collapse, close);
    head.append(title, headActions);

    const body = el('questionnaire-body');
    const footer = el('questionnaire-footer');
    const status = el('user-prompt-status');
    card.append(head, body, footer, status);
    node.classList.remove('hidden');
    node.appendChild(card);
    scrollThread();

    const renderAnswered = () => {
        body.innerHTML = '';
        const summary = el('questionnaire-summary');
        for (const question of wizard.questions) {
            const row = el('questionnaire-summary-row');
            const key = el('questionnaire-summary-key');
            key.textContent = question.header;
            const value = el('questionnaire-summary-value');
            value.textContent = [...question.selectedOptions, question.freeText.trim()]
                .filter(Boolean)
                .join(', ');
            row.append(key, value);
            summary.appendChild(row);
        }
        body.appendChild(summary);
        footer.innerHTML = '';
        collapse.remove();
        close.remove();
        status.textContent = 'Answered';
        card.classList.add('answered');
    };

    const submitAnswers = async () => {
        if (!isQuestionnaireComplete(wizard)) {
            const missingIndex = wizard.questions.findIndex((_, index) =>
                !isQuestionnaireStepComplete(wizard, index));
            setQuestionnaireStep(wizard, missingIndex);
            renderStep();
            status.textContent = 'Answer this question to continue.';
            return;
        }
        const answer = serializeQuestionnaireAnswer(wizard);
        card.querySelectorAll('button, input').forEach((control) => { control.disabled = true; });
        status.textContent = 'Sending…';
        status.classList.remove('error-text');
        try {
            await api('POST', `/api/conversations/${encodeURIComponent(conversationId)}/question`, {
                questionId: requestId,
                answer,
            });
            renderAnswered();
        } catch (error) {
            card.querySelectorAll('button, input').forEach((control) => { control.disabled = false; });
            status.textContent = error.message || String(error);
            status.classList.add('error-text');
        }
    };

    const renderStep = () => {
        body.innerHTML = '';
        footer.innerHTML = '';
        status.textContent = '';
        status.classList.remove('error-text');

        const questionIndex = wizard.currentIndex;
        const question = wizard.questions[questionIndex];
        const stepHeader = el('questionnaire-step-header');
        stepHeader.textContent = question.header;
        const questionText = el('questionnaire-question');
        questionText.textContent = question.question;
        body.append(stepHeader, questionText);

        if (question.options.length > 0) {
            const options = el('questionnaire-options');
            options.setAttribute('role', question.multiSelect ? 'group' : 'radiogroup');
            question.options.forEach((option, optionIndex) => {
                const selected = question.selectedOptions.includes(option.label);
                const optionButton = el('questionnaire-option' + (selected ? ' selected' : ''), 'button');
                optionButton.type = 'button';
                optionButton.dataset.label = option.label;
                optionButton.dataset.optionIndex = String(optionIndex);
                optionButton.tabIndex = optionIndex === question.optionFocusIndex ? 0 : -1;
                optionButton.setAttribute('role', question.multiSelect ? 'checkbox' : 'radio');
                optionButton.setAttribute('aria-checked', String(selected));

                const number = el('questionnaire-option-number');
                number.textContent = String(optionIndex + 1);
                const check = el('questionnaire-option-check');
                check.textContent = selected ? '✓' : '';
                const copy = el('questionnaire-option-copy');
                const optionLabel = el('questionnaire-option-label');
                optionLabel.textContent = option.label;
                copy.appendChild(optionLabel);
                if (option.description) {
                    const description = el('questionnaire-option-description');
                    description.textContent = option.description;
                    copy.appendChild(description);
                }
                optionButton.append(number, check, copy);
                optionButton.onclick = () => {
                    question.optionFocusIndex = optionIndex;
                    toggleQuestionnaireOption(wizard, questionIndex, option.label);
                    renderStep();
                    const selectedOption = body.querySelector(`[data-option-index="${optionIndex}"]`);
                    if (selectedOption) selectedOption.focus();
                };
                optionButton.onkeydown = (event) => {
                    const nextIndex = getQuestionnaireOptionFocusIndex(
                        question.optionFocusIndex,
                        event.key,
                        question.options.length
                    );
                    if (nextIndex === question.optionFocusIndex &&
                        !['Home', 'End'].includes(event.key)) return;
                    event.preventDefault();
                    question.optionFocusIndex = nextIndex;
                    if (!question.multiSelect) {
                        toggleQuestionnaireOption(
                            wizard,
                            questionIndex,
                            question.options[nextIndex].label
                        );
                    }
                    renderStep();
                    const nextOption = body.querySelector(`[data-option-index="${nextIndex}"]`);
                    if (nextOption) nextOption.focus();
                };
                options.appendChild(optionButton);
            });
            body.appendChild(options);
        }

        let freeTextInput = null;
        if (question.allowFreeformInput) {
            freeTextInput = el('questionnaire-free-text', 'input');
            freeTextInput.type = 'text';
            freeTextInput.value = question.freeText;
            freeTextInput.placeholder = question.options.length > 0 ? 'Custom answer' : 'Enter your answer';
            freeTextInput.setAttribute('aria-label', `Answer for ${question.header}`);
            body.appendChild(freeTextInput);
        }

        const nav = el('questionnaire-nav');
        const previous = el('questionnaire-nav-button', 'button');
        previous.type = 'button';
        previous.textContent = '‹';
        previous.title = 'Previous question';
        previous.setAttribute('aria-label', 'Previous question');
        previous.disabled = questionIndex === 0;
        previous.onclick = () => {
            setQuestionnaireStep(wizard, questionIndex - 1);
            renderStep();
        };
        const next = el('questionnaire-nav-button', 'button');
        next.type = 'button';
        next.textContent = '›';
        next.title = 'Next question';
        next.setAttribute('aria-label', 'Next question');
        next.hidden = questionIndex === wizard.questions.length - 1;
        next.onclick = () => {
            if (!isQuestionnaireStepComplete(wizard, questionIndex)) return;
            setQuestionnaireStep(wizard, questionIndex + 1);
            renderStep();
        };
        nav.append(previous, next);

        const progress = el('questionnaire-progress');
        progress.textContent = `${questionIndex + 1} / ${wizard.questions.length}`;
        const submit = el('btn btn-primary questionnaire-submit', 'button');
        submit.type = 'button';
        submit.textContent = wizard.questions.length === 1 ? 'Answer' : 'Submit answers';
        submit.hidden = questionIndex !== wizard.questions.length - 1;
        submit.onclick = submitAnswers;

        const updateControls = () => {
            next.disabled = !isQuestionnaireStepComplete(wizard, questionIndex);
            submit.disabled = !isQuestionnaireComplete(wizard);
        };
        if (freeTextInput) {
            freeTextInput.oninput = () => {
                setQuestionnaireFreeText(wizard, questionIndex, freeTextInput.value);
                updateControls();
            };
            freeTextInput.onkeydown = (event) => {
                if (event.key !== 'Enter') return;
                event.preventDefault();
                if (!isQuestionnaireStepComplete(wizard, questionIndex)) return;
                if (questionIndex === wizard.questions.length - 1) submitAnswers();
                else {
                    setQuestionnaireStep(wizard, questionIndex + 1);
                    renderStep();
                }
            };
        }

        footer.append(nav, progress, submit);
        updateControls();
        scrollThread();
        const firstFocusable = body.querySelector('.questionnaire-option.selected, .questionnaire-option, .questionnaire-free-text');
        if (firstFocusable) firstFocusable.focus();
    };

    collapse.onclick = () => {
        const collapsed = card.classList.toggle('collapsed');
        collapse.textContent = collapsed ? '⌄' : '⌃';
        collapse.title = collapsed ? 'Expand Questionnaire' : 'Collapse Questionnaire';
        collapse.setAttribute('aria-label', collapse.title);
    };
    close.onclick = () => stopTurn();
    renderStep();
}

function renderUsage(node, m) {
    const u = m.usage || {};
    const bits = [];
    if (u.totalTokens) bits.push(`${u.estimated ? '~' : ''}${u.totalTokens.toLocaleString()} ${u.estimated ? 'input ' : ''}tokens`);
    // priced === false means the Engine has no rate for this model, not that the
    // Turn was free. Printing $0.0000 there would be a confident wrong number.
    if (u.priced === false) {
        bits.push('cost unknown \u2014 no published rate for this model');
    }
    else {
        if (u.costUSD) bits.push(`${u.estimated ? '~' : ''}$${u.costUSD.toFixed(4)}`);
        if (u.credits) bits.push(`${u.estimated ? '~' : ''}${u.credits} credits${u.estimateScope === 'input-only' ? ' (input estimate)' : ''}`);
        if (u.estimated && !u.totalTokens && !u.costUSD && !u.credits) bits.push('Usage estimate unavailable');
    }
    if (m.model) bits.push(escapeHtml(m.model));
    if (m.durationMs) bits.push(`${(m.durationMs / 1000).toFixed(1)}s`);
    if (!bits.length) { node.classList.add('hidden'); return; }
    node.classList.remove('hidden');
    node.innerHTML = bits.map((b) => `<span>${b}</span>`).join('');
}

function hydrateCopies(container) {
    container.querySelectorAll('pre .copy-btn').forEach((btn) => {
        btn.onclick = () => {
            const code = btn.parentElement.querySelector('code');
            navigator.clipboard.writeText(code ? code.textContent : '').then(() => {
                btn.textContent = 'Copied';
                setTimeout(() => (btn.textContent = 'Copy'), 1200);
            });
        };
    });
}

const asArray = (v) => (Array.isArray(v) ? v : v == null ? [] : [v]);

// Follow the newest output only while the reader has not scrolled away from the
// bottom - scrolling up mid-Turn is how the Thinking box gets read, and pinning
// the thread on every token drags the reader back down mid-line. Distance alone
// cannot decide this: `.thread` scrolls smoothly, so during an in-flight
// programmatic scroll `scrollTop` lags behind the newest token and a distance
// test would read that lag as "the reader scrolled away" and kill auto-follow
// for the rest of the Turn. Every programmatic scroll here moves *down*, so an
// upward move is the reader's: that is what stops the following, and arriving
// back at the bottom is what resumes it.
const THREAD_STICK_PX = 120;
let threadFollow = true;
let threadLastTop = 0;

function wireThreadFollow() {
    const t = $('thread');
    if (!t) return;
    t.addEventListener('scroll', () => {
        const top = t.scrollTop;
        const atBottom = t.scrollHeight - top - t.clientHeight <= THREAD_STICK_PX;
        if (top < threadLastTop - 1) threadFollow = atBottom;
        else if (atBottom) threadFollow = true;
        threadLastTop = top;
    }, { passive: true });
}

function scrollThread() {
    const t = $('thread');
    t.scrollTop = t.scrollHeight;
    threadFollow = true;
}

function followThread() {
    if (threadFollow) scrollThread();
}

// Put a reasoning delta in a message's Thinking box and follow it down. The box
// only appears after the turn-start scroll, so without this it unfolds below the
// fold and a long think looks like a stalled turn. The box is height-bounded and
// scrolls itself, so the thread scroll alone would still leave the newest line
// out of sight.
function renderThinking(wrap, text) {
    const box = wrap.querySelector('.thinking');
    box.classList.remove('hidden');
    const body = box.querySelector('.disclosure-body');
    body.textContent = text;
    body.scrollTop = body.scrollHeight;
    setActivityStatus(lastTraceLine(text));
    followThread();
}

// The Thinking box sits above the answer inside its message, so a long answer
// pushes it out of the viewport and the only thing still moving is the spinner —
// which cannot tell "still working" from "hung". Mirror the newest trace line
// next to that spinner, where the composer keeps it visible whatever the thread
// does, and let a click jump back to the box it came from.
function setActivityStatus(line) {
    const hint = $('activity-hint');
    const status = $('activity-status');
    if (!hint || !status || !line || hint.classList.contains('hidden')) return;
    status.textContent = line;
    status.title = line;
    status.disabled = false;
    hint.classList.add('has-trace');
}

// Only the tail can hold the newest line, and a laid-out trace runs to thousands
// of lines, so never scan the whole thing once per streamed frame.
function lastTraceLine(text) {
    if (!text) return '';
    const tail = text.length > 600 ? text.slice(-600) : text;
    const lines = tail.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i].trim();
        if (line) return line;
    }
    return '';
}

// Jump from the status line to the box it mirrors, unfolding it if the user (or
// the "Show the model's thinking" setting) left it closed. Clicking it means
// "let me read this", so it also stops the following outright: the scroll below
// is smooth, and the next streamed frame would otherwise win the race and pull
// the thread straight back to the bottom. With Thinking off there is no such box
// and the line is mirroring the Activity panel, so open that instead.
function revealThinking() {
    const thread = $('thread');
    const thinking = thread.querySelectorAll('.msg-assistant .thinking:not(.hidden)');
    const activity = thread.querySelectorAll('.msg-assistant .activity:not(.hidden)');
    const box = thinking[thinking.length - 1] || activity[activity.length - 1];
    if (!box) return;
    threadFollow = false;
    box.open = true;
    box.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

// ===== Sending a Turn =====
async function send() {
    if (voice.listening) stopDictation();
    // While streaming, the Send button is the dispatch chevron's parent — clicking
    // it should not silently stop. Plain clicks here mean "open the dispatch menu"
    // when the user has typed something to send next; otherwise it just stops.
    if (state.streaming) {
        const promptEl = $('prompt');
        if (promptEl.value.trim()) {
            openDispatchPopover();
        } else {
            stopTurn();
        }
        return;
    }
    const promptEl = $('prompt');
    const userPrompt = promptEl.value.trim();
    if (!userPrompt && !state.pendingAttachments.length) return;
    if (!state.current) await newConversation();

    recordPrompt(userPrompt);

    let prompt = userPrompt;
    let images = [];
    if (state.pendingAttachments.length) {
        const count = state.pendingAttachments.length;
        const hasWorkspace = !!(state.settings && state.settings.workspaceFolder);
        images = getImagePaths(state.pendingAttachments);
        // With a Project active the agent's working directory is the Workspace
        // Folder, so relative names suffice; with no Project the uploads live
        // elsewhere, so name their absolute paths instead.
        const note = hasWorkspace
            ? `I attached ${count} file(s) in the Workspace Folder: ${state.pendingAttachments.map(f => f.savedAs).join(', ')}. Read them with your file tool when relevant.`
            : `I attached ${count} file(s) at these paths: ${state.pendingAttachments.map(f => f.path).join(', ')}. Read them with your file tool when relevant.`;
        prompt = prompt ? `${note}\n\n${prompt}` : note;
        state.pendingAttachments = [];
        renderAttachments();
    }

    promptEl.value = '';
    autoGrow(promptEl);
    await _runTurn({ prompt, displayText: prompt, images });
}

// Core Turn runner. `prompt` is what the server sees; `displayText` is what the
// user bubble shows; `dispatch` (optional) is 'queued' or 'steered' and renders
// a small badge below the bubble so the user sees how the message was sent.
async function _runTurn({ prompt, displayText, dispatch, images = [] }) {
    const promptEl = $('prompt');
    setSendEnabled(false);

    // optimistic user message
    const empty = $('thread').querySelector('.empty-state');
    if (empty) $('thread').innerHTML = '';
    const userEl = buildUserEl({ text: displayText, dispatch });
    $('thread').appendChild(userEl);

    const wrap = buildAssistantEl({ id: 'pending' });
    wrap._refs.content.classList.add('stream-caret');
    $('thread').appendChild(wrap);
    markLastAssistant();
    scrollThread();

    state.streaming = true;
    state.stopRequested = false;
    state.streamEndPromise = new Promise((resolve) => { state.streamEndResolve = resolve; });
    setStreamingUI(true);
    let raw = '';
    let think = '';
    let turnCompleted = false;
    let turnStopped = false;
    const conversationId = state.current.id;
    // Render the live answer as Markdown, but coalesce to one paint per frame so a
    // fast token stream doesn't re-parse the whole message on every delta.
    let renderScheduled = false;
    const renderLive = () => {
        renderScheduled = false;
        if (state.stopRequested || turnStopped) return;
        wrap._refs.content.innerHTML = renderMarkdown(raw);
        followThread();
    };

    try {
        const messageBody = { prompt };
        if (images.length) messageBody.images = images;
        await streamPost('/api/conversations/' + conversationId + '/messages', messageBody, {
            start: (d) => { if (d && d.messageId) wrap.dataset.id = d.messageId; if (d && d.userMessageId) userEl.dataset.id = d.userMessageId; },
            delta: (d) => {
                if (state.stopRequested) return;
                raw += (d && d.text) || '';
                if (!renderScheduled) {
                    renderScheduled = true;
                    requestAnimationFrame(renderLive);
                }
            },
            reasoning: (d) => {
                if (state.stopRequested) return;
                think += (d && d.text) || '';
                renderThinking(wrap, think);
            },
            tasks: (d) => { if (!state.stopRequested && d && d.tasks) renderTasks(wrap._refs.tasks, d.tasks); },
            activity: (d) => { if (!state.stopRequested && d) noteActivity(wrap, d); },
            question: (d) => { if (!state.stopRequested) renderUserPrompt(wrap._refs.userPrompts, d, conversationId); },
            stopping: (d) => {
                turnStopped = true;
                state.stopRequested = true;
                setStoppingUI();
                wrap._refs.content.classList.remove('stream-caret');
                showInlineError(wrap, (d && d.message) || 'Turn stopped.');
            },
            stopped: (m) => {
                turnStopped = true;
                wrap._refs.content.classList.remove('stream-caret');
                finalizeAssistant(wrap, m, { isLast: true });
                markLastAssistant();
                followThread();
            },
            done: (m) => {
                turnCompleted = true;
                wrap._refs.content.classList.remove('stream-caret');
                finalizeAssistant(wrap, m, { isLast: true });
                markLastAssistant();
                followThread();
            },
            error: (d) => {
                wrap._refs.content.classList.remove('stream-caret');
                showInlineError(wrap, (d && d.message) || 'Something went wrong.');
            },
        });
    } catch (e) {
        wrap._refs.content.classList.remove('stream-caret');
        showInlineError(wrap, e.message || String(e));
    } finally {
        state.streaming = false;
        state.stopRequested = false;
        setStreamingUI(false);
        const resolveEnd = state.streamEndResolve;
        state.streamEndPromise = null;
        state.streamEndResolve = null;
        if (resolveEnd) resolveEnd();
        await loadConversations();
        if (state.current) {
            const s = state.conversations.find((c) => c.id === state.current.id);
            if (s) $('conv-title').value = s.title;
        }
        await refreshCurrentConversation();
        await refreshUsage();
        maybeWarnBudget();
        if (explorerOpen()) refreshExplorer();
        promptEl.focus();
        if (turnCompleted) {
            // These follow-ups belong only to a successfully completed Turn. A
            // Stop must not trigger fresh Model calls or additional credit spend.
            await maybeAutoTitle();
            await maybeAutoCompact();
            await maybeLearnMemory();
        }
        // Drain one queued/steered message, if any. We only fire the next one;
        // its own finally will drain the one after it (chained, never racing).
        flushDispatchQueue();
    }
}

function showInlineError(wrap, message) {
    const refs = wrap._refs;
    refs.content.innerHTML = '';
    const err = el('bubble');
    err.textContent = '⚠ ' + message;
    wrap.classList.add('msg-error');
    refs.content.appendChild(err);
}

// After the first Turn of a new Conversation, ask the server to replace the
// placeholder/truncated title with a concise AI summary, the way GitHub Copilot
// auto-names a new chat. Best-effort and gated to the first exchange; the server
// makes the final call and skips a manually renamed (title-locked) Conversation.
async function maybeAutoTitle() {
    if (!state.current) return;
    const id = state.current.id;
    const summary = state.conversations.find((c) => c.id === id);
    if (!summary || summary.messageCount > 2) return;
    try {
        const r = await api('POST', '/api/conversations/' + id + '/title', {});
        if (r && r.title) {
            patchConvLocal(id, { title: r.title });
            if (state.current && state.current.id === id) {
                state.current.title = r.title;
                const input = $('conv-title');
                if (input) input.value = r.title;
            }
            renderConversationList();
        }
    } catch { /* best-effort: keep the fallback title */ }
}

// After a Turn, if auto-compaction is enabled and the last Turn filled the Model
// context window to at least the configured threshold, ask the server to compact
// the replayed history — the same summarise-and-keep-tail the manual Compact
// action performs. Best-effort and self-limiting: the visible transcript is never
// touched, a "too_short" reply is a silent no-op, and because the measured
// occupancy only drops after the NEXT real Turn this fires at most once per Turn
// (no loop). Every firing is announced with a toast, so nothing is hidden.
async function maybeAutoCompact() {
    const s = state.settings || {};
    if (!s.autoCompaction) return;
    if (!state.current || state.autoCompacting) return;
    const info = computeSessionInfo();
    if (!info || info.maxTokens <= 0 || info.measured <= 0) return;
    const threshold = Math.min(0.95, Math.max(0.5, Number(s.compactionThreshold) || 0.8));
    if (info.pct < threshold * 100) return;
    const id = state.current.id;
    state.autoCompacting = true;
    try {
        const r = await api('POST', '/api/conversations/' + id + '/compact');
        const freed = (r && Number(r.estimatedFreed)) || 0;
        toast(freed > 0
            ? `Auto-compacted to free context — freed about ${fmtTokens(freed)} tokens.`
            : 'Auto-compacted to free context.');
        if (state.current && state.current.id === id) {
            await refreshCurrentConversation();
            renderContextMeter();
        }
        await loadConversations();
    } catch (e) {
        // "too_short" (not enough history yet) is an expected no-op, not an error;
        // stay silent so a single large Turn near the limit never spams the user.
        if (!(e && (e.code === 'too_short' || e.status === 400))) {
            // Any other failure is quietly ignored: auto-compaction is best-effort
            // and must never interrupt the user's flow. The context meter still
            // shows the true occupancy, and manual Compact remains available.
        }
    } finally {
        state.autoCompacting = false;
    }
}

// After some turns, ask the server to fold durable facts from the conversation
// into the agent's persistent Memory. Throttled by assistant-turn count (not every
// turn) to keep the cost honest, best-effort, and announced with a toast only when
// something actually changed. Mirrors maybeAutoTitle / maybeAutoCompact. The manual
// "Update from this conversation" button in Settings covers the off / short-chat
// cases.
async function maybeLearnMemory() {
    const s = state.settings || {};
    if (!s.memoryLearning) return;
    if (!state.current || state.learningMemory) return;
    const assistantTurns = ((state.current.messages) || []).filter((m) => m.role === 'assistant').length;
    const EVERY = 5;
    // Nothing to learn from a very short chat; then only every EVERY-th turn.
    if (assistantTurns < EVERY || assistantTurns % EVERY !== 0) return;
    const id = state.current.id;
    state.learningMemory = true;
    try {
        const r = await api('POST', '/api/memory/learn', { conversationId: id });
        if (r && r.changed) toast('Updated what I remember about you.');
    } catch (e) {
        // Best-effort: a busy Turn (409) or a short conversation (400) is a silent
        // no-op; learning must never interrupt the user's flow.
        void e;
    } finally {
        state.learningMemory = false;
    }
}

async function stopTurn() {
    if (!state.current || !state.streaming || state.stopRequested) return;
    state.stopRequested = true;
    setStoppingUI();
    toast('Stopping…');
    try {
        await api('POST', '/api/conversations/' + state.current.id + '/stop');
    } catch (error) {
        state.stopRequested = false;
        setStreamingUI(true);
        toast(error.message || 'Could not stop the Turn.');
    }
}

function setStoppingUI() {
    const btn = $('btn-send');
    btn.textContent = 'Stopping…';
    btn.classList.add('stop');
    btn.disabled = true;
    const dispatchBtn = $('btn-dispatch');
    if (dispatchBtn) dispatchBtn.classList.add('hidden');
    const hint = $('activity-hint');
    hint.classList.add('hidden');
    document.querySelectorAll('.stream-caret').forEach((node) => node.classList.remove('stream-caret'));
}

function setStreamingUI(on) {
    const btn = $('btn-send');
    btn.textContent = on ? 'Stop' : 'Send';
    btn.classList.toggle('stop', on);
    btn.disabled = false;
    const dispatchBtn = $('btn-dispatch');
    if (dispatchBtn) {
        dispatchBtn.classList.toggle('hidden', !on);
        if (!on) closeDispatchPopover();
    }
    const hint = $('activity-hint');
    if (on) {
        hint.classList.remove('hidden');
        hint.classList.remove('has-trace');
        hint.innerHTML = '<span class="spinner"></span>' +
            '<button type="button" id="activity-status" class="activity-status" disabled>Working…</button>';
        $('activity-status').onclick = revealThinking;
    } else {
        hint.classList.add('hidden');
    }
}

// ===== Dispatch (Stop and Send / Add to Queue / Steer with Message) =====
// Dispatch is a pure client-side UX layer on top of the existing single-Turn
// API. The server has no concept of mid-Turn injection, so:
//   - Stop and Send  → POST /stop, await SSE close, send the new prompt as a
//                       fresh Turn.
//   - Add to Queue   → buffer the prompt; flush after the current Turn ends.
//   - Steer with Msg → like queue, but the prompt sent to the server is
//                       prefixed with a steering preamble so the model knows
//                       the user wrote it while a previous Turn was running.
const STEER_PREAMBLE = '[Steering note — the user sent this while a previous turn was running. Treat it as a course-correction or addendum to the previous turn.]';

function openDispatchPopover() {
    if (!state.streaming) return;
    const pop = $('dispatch-popover');
    const btn = $('btn-dispatch');
    if (!pop || !btn) return;
    pop.classList.remove('hidden');
    btn.setAttribute('aria-expanded', 'true');
}

function closeDispatchPopover() {
    const pop = $('dispatch-popover');
    const btn = $('btn-dispatch');
    if (!pop) return;
    pop.classList.add('hidden');
    if (btn) btn.setAttribute('aria-expanded', 'false');
}

function toggleDispatchPopover() {
    const pop = $('dispatch-popover');
    if (!pop) return;
    if (pop.classList.contains('hidden')) openDispatchPopover();
    else closeDispatchPopover();
}

function readComposerPrompt() {
    const promptEl = $('prompt');
    return { promptEl, text: promptEl.value.trim() };
}

function consumeComposer() {
    const promptEl = $('prompt');
    promptEl.value = '';
    autoGrow(promptEl);
}

function dispatchEnqueue(kind) {
    // kind: 'queue' | 'steer'
    const { text } = readComposerPrompt();
    if (!text) return false;
    const prompt = kind === 'steer' ? `${STEER_PREAMBLE}\n\n${text}` : text;
    state.dispatchQueue.push({ kind, text, prompt });
    consumeComposer();
    closeDispatchPopover();
    renderDispatchQueue();
    return true;
}

async function dispatchStopAndSend() {
    const { text } = readComposerPrompt();
    if (!text) return;
    closeDispatchPopover();
    const ended = state.streamEndPromise;
    if (state.streaming) {
        await stopTurn();
        if (ended) await ended;
    }
    // The textarea still holds the user's prompt; let send() pick it up just
    // like a normal Send. send() runs _runTurn which will also drain any
    // queue entries that accumulated while we were stopping.
    await send();
}

function flushDispatchQueue() {
    if (state.streaming) return;
    if (!state.dispatchQueue.length) return;
    const next = state.dispatchQueue.shift();
    renderDispatchQueue();
    const dispatchTag = next.kind === 'steer' ? 'steered' : 'queued';
    // Fire-and-forget: _runTurn is async, but we don't await it here because
    // the surrounding finally block has already returned.
    _runTurn({ prompt: next.prompt, displayText: next.text, dispatch: dispatchTag });
}

function renderDispatchQueue() {
    const row = $('dispatch-queue');
    if (!row) return;
    row.innerHTML = '';
    if (!state.dispatchQueue.length) {
        row.classList.add('hidden');
        return;
    }
    row.classList.remove('hidden');
    state.dispatchQueue.forEach((item, idx) => {
        const chip = el('dispatch-chip');
        const kind = el('dispatch-chip-kind');
        kind.textContent = item.kind === 'steer' ? '↑ Steer' : '+ Queue';
        const txt = el('dispatch-chip-text');
        txt.textContent = item.text;
        const x = document.createElement('button');
        x.type = 'button';
        x.className = 'dispatch-chip-x';
        x.setAttribute('aria-label', 'Discard pending message');
        x.textContent = '×';
        x.addEventListener('click', () => {
            state.dispatchQueue.splice(idx, 1);
            renderDispatchQueue();
        });
        chip.append(kind, txt, x);
        row.appendChild(chip);
    });
}

// ===== Models =====
function populateModelSelect() {
    const sel = $('model-select');
    sel.innerHTML = '';
    if (!state.models.length) {
        const o = document.createElement('option');
        o.value = '';
        o.textContent = state.defaultModel || '(sign in to load models)';
        sel.appendChild(o);
        return;
    }
    for (const m of state.models) {
        const o = document.createElement('option');
        o.value = m.id;
        o.textContent = m.id;
        sel.appendChild(o);
    }
}
function setModelSelect(id) {
    const sel = $('model-select');
    if (id && [...sel.options].some((o) => o.value === id)) sel.value = id;
}

// ===== Permissions =====
function updatePermDot() {
    const p = (state.settings && state.settings.permissions) || {};
    $('perm-dot').classList.toggle('warn', !!p.terminal);
}
function buildPermList(container) {
    container.innerHTML = '';
    const p = (state.settings && state.settings.permissions) || {};
    for (const def of PERMISSIONS) {
        const row = el('perm-row' + (def.powerful ? ' powerful' : ''));
        const meta = el('perm-meta');
        meta.innerHTML = `<div class="perm-name">${def.name}</div><div class="muted tiny">${def.note}</div>`;
        const sw = el('switch', 'label');
        const input = document.createElement('input');
        input.type = 'checkbox';
        input.checked = !!p[def.key];
        input.onchange = async () => {
            try {
                state.settings = await api('PUT', '/api/settings', { permissions: { [def.key]: input.checked } });
                updatePermDot();
            } catch (e) { toast(e.message); input.checked = !input.checked; }
        };
        const slider = el('slider', 'span');
        sw.append(input, slider);
        row.append(meta, sw);
        container.appendChild(row);
    }
}

// ===== Projects =====
const shortPath = (p) => (p.length > 28 ? '…' + p.slice(-27) : p);

function projects() { return (state.settings && state.settings.projects) || []; }
function newProjectId() { return 'p_' + Math.random().toString(36).slice(2, 12); }
function leafName(path) { return path.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || 'Project'; }

function populateProjectSelect() {
    updateProjectChip();
    if (!$('project-popover').classList.contains('hidden')) buildProjectMenu();
}

function updateProjectChip() {
    const label = $('project-chip-label');
    if (!label) return;
    const list = projects();
    const selectedId = (state.settings && state.settings.selectedProjectId) || '';
    const selected = list.find((p) => p.id === selectedId);
    const displayName = selected ? leafName(selected.path) : 'No project';
    label.textContent = displayName;
    label.title = selected ? displayName : '';
    const button = $('btn-project');
    if (button) button.title = selected ? displayName : 'Project — the working folder for new prompts';
    syncExplorerAvailability();
}

function buildProjectMenu() {
    const menu = $('project-menu');
    if (!menu) return;
    const list = projects();
    const selectedId = (state.settings && state.settings.selectedProjectId) || '';
    menu.innerHTML = '';

    if (!list.length) {
        const empty = el('menu-empty muted tiny');
        empty.textContent = 'No projects yet.';
        menu.appendChild(empty);
    }
    for (const p of list) {
        const isSel = p.id === selectedId;
        const item = document.createElement('button');
        item.className = 'menu-item' + (isSel ? ' selected' : '');
        item.setAttribute('role', 'menuitemradio');
        item.setAttribute('aria-checked', isSel ? 'true' : 'false');
        item.title = p.path;
        item.innerHTML = `<span class="check">${isSel ? '✓' : ''}</span><span class="menu-text"><span class="menu-name">${escapeHtml(p.name)}</span><span class="menu-sub muted tiny">${escapeHtml(shortPath(p.path))}</span></span>`;
        item.onclick = () => selectProject(p.id);
        menu.appendChild(item);
    }

    const divider = el('menu-divider');
    menu.appendChild(divider);

    if (selectedId) {
        const close = document.createElement('button');
        close.className = 'menu-item';
        close.setAttribute('role', 'menuitem');
        close.innerHTML = '<span class="check">✕</span><span class="menu-text">Close project</span>';
        close.onclick = () => closeProject();
        menu.appendChild(close);
    }

    const add = document.createElement('button');
    add.className = 'menu-item add';
    add.setAttribute('role', 'menuitem');
    add.innerHTML = '<span class="check">＋</span><span class="menu-text">New project…</span>';
    add.onclick = () => { closeProjectMenu(); newProject(); };
    menu.appendChild(add);
}

function openProjectMenu() {
    buildProjectMenu();
    const pop = $('project-popover');
    const btn = $('btn-project');
    const rect = btn.getBoundingClientRect();
    // Anchor the menu to the button; override the centered .popover defaults.
    pop.style.transform = 'none';
    pop.style.bottom = (window.innerHeight - rect.top + 8) + 'px';
    pop.classList.remove('hidden');
    // Clamp horizontally so the menu stays on screen.
    const width = pop.offsetWidth;
    const left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
    pop.style.left = left + 'px';
    btn.setAttribute('aria-expanded', 'true');
}

function closeProjectMenu() {
    $('project-popover').classList.add('hidden');
    const btn = $('btn-project');
    if (btn) btn.setAttribute('aria-expanded', 'false');
}

function toggleProjectMenu() {
    if ($('project-popover').classList.contains('hidden')) openProjectMenu();
    else closeProjectMenu();
}

async function selectProject(value) {
    closeProjectMenu();
    const current = (state.settings && state.settings.selectedProjectId) || '';
    if ((value || '') === current) return;
    try {
        state.settings = await api('PUT', '/api/settings', { selectedProjectId: value || null });
        updateProjectChip();
    } catch (e) { toast(e.message); updateProjectChip(); }
}

// Close (deselect) the active Project. It stays registered, but no Workspace
// Folder is active until a Project is selected again.
function closeProject() {
    return selectProject(null);
}

async function newProject() {
    const sel = projects().find((p) => p.id === (state.settings && state.settings.selectedProjectId));
    const picked = await pickFolder({ title: 'New project folder', start: sel ? sel.path : '', requireName: true });
    if (!picked || !picked.path) { updateProjectChip(); return; }
    await registerProject(picked);
    updateProjectChip();
}

async function registerProject(picked) {
    const name = (picked.name || leafName(picked.path)).trim();
    const normPath = (p) => p.replace(/[\\/]+$/, '').toLowerCase();
    const existing = projects();
    if (existing.some((p) => p.name.trim().toLowerCase() === name.toLowerCase())) {
        toast(`A project named “${name}” already exists.`);
        return false;
    }
    if (existing.some((p) => normPath(p.path) === normPath(picked.path))) {
        toast('That folder is already registered as a project.');
        return false;
    }
    const id = newProjectId();
    try {
        state.settings = await api('PUT', '/api/settings', { projects: existing.concat([{ id, name, path: picked.path }]), selectedProjectId: id });
        toast('Project registered.');
        return true;
    } catch (e) { toast(e.message); return false; }
}

// ===== Folder picker =====
let folderResolve = null;
let folderCurrent = { path: '', parent: null, drives: [], home: '' };

function pickFolder(opts = {}) {
    return new Promise((resolve) => {
        folderResolve = resolve;
        $('folder-title').textContent = opts.title || 'Choose a folder';
        const nameEl = $('folder-name');
        const wantsName = opts.requireName !== false;
        nameEl.classList.toggle('hidden', !wantsName);
        nameEl.value = '';
        delete nameEl.dataset.touched;
        $('folder-backdrop').classList.remove('hidden');
        $('folder-modal').classList.remove('hidden');
        folderNavigate(opts.start || '');
    });
}

function closeFolderPicker(result) {
    $('folder-backdrop').classList.add('hidden');
    $('folder-modal').classList.add('hidden');
    const r = folderResolve;
    folderResolve = null;
    if (r) r(result || null);
}

async function folderNavigate(path) {
    let data;
    try { data = await api('GET', '/api/fs/list?path=' + encodeURIComponent(path || '')); }
    catch (e) { toast(e.message); return; }
    folderCurrent = data;
    $('folder-path').value = data.path || '';
    $('folder-up').disabled = !data.parent;
    const nameEl = $('folder-name');
    if (!nameEl.dataset.touched) {
        const leaf = data.name && data.name !== data.path ? data.name : leafName(data.path || '');
        nameEl.value = leaf;
    }
    renderFolderDrives(data.drives, data.path);
    renderFolderList(data.entries, data.error);
}

function renderFolderDrives(drives, current) {
    const wrap = $('folder-drives');
    wrap.innerHTML = '';
    const cur = (current || '').toUpperCase();
    for (const d of (drives || [])) {
        const b = el('drive-btn' + (cur.startsWith(d.toUpperCase()) ? ' active' : ''), 'button');
        b.textContent = d.replace(/\\$/, '');
        b.title = d;
        b.onclick = () => folderNavigate(d);
        wrap.appendChild(b);
    }
}

function renderFolderList(entries, error) {
    const list = $('folder-list');
    list.innerHTML = '';
    if (error) {
        const e = el('folder-error muted tiny');
        e.textContent = '⚠ ' + error;
        list.appendChild(e);
        return;
    }
    if (!entries || !entries.length) {
        const e = el('folder-empty muted tiny');
        e.textContent = 'No sub-folders here. Use this folder, or create one.';
        list.appendChild(e);
        return;
    }
    for (const ent of entries) {
        const item = el('folder-item', 'button');
        item.title = ent.path;
        item.innerHTML = `<span class="folder-ico">📁</span><span class="folder-itemname"></span><span class="folder-into">›</span>`;
        item.querySelector('.folder-itemname').textContent = ent.name;
        item.onclick = () => folderNavigate(ent.path);
        list.appendChild(item);
    }
}

async function folderMkdir() {
    const parent = $('folder-path').value.trim() || folderCurrent.path;
    if (!parent) { toast('Choose a parent folder first.'); return; }
    const name = (window.prompt('New folder name:', '') || '').trim();
    if (!name) return;
    try {
        const data = await api('POST', '/api/fs/mkdir', { parent, name });
        folderCurrent = data;
        $('folder-path').value = data.path || '';
        $('folder-up').disabled = !data.parent;
        const nameEl = $('folder-name');
        if (!nameEl.dataset.touched) nameEl.value = data.name || name;
        renderFolderDrives(data.drives, data.path);
        renderFolderList(data.entries, data.error);
        toast('Folder created.');
    } catch (e) { toast(e.message); }
}

function folderConfirm() {
    const path = $('folder-path').value.trim();
    if (!path) { toast('Choose a folder.'); return; }
    const nameEl = $('folder-name');
    const wantsName = !nameEl.classList.contains('hidden');
    const name = wantsName ? (nameEl.value.trim() || leafName(path)) : '';
    closeFolderPicker({ path, name });
}

async function projectAction(patch) {
    try {
        state.settings = await api('PUT', '/api/settings', patch);
        renderProjectsManager();
        populateProjectSelect();
    } catch (e) { toast(e.message); }
}

function renderProjectsManager() {
    const container = $('set-projects');
    if (!container) return;
    const list = projects();
    const selectedId = (state.settings && state.settings.selectedProjectId) || '';
    if (!list.length) {
        container.innerHTML = '<div class="muted tiny">No projects yet. Add one below.</div>';
        return;
    }
    container.innerHTML = '';
    for (const p of list) {
        const isSel = p.id === selectedId;
        const row = el('project-row' + (isSel ? ' selected' : ''));
        const meta = el('project-meta');
        meta.innerHTML = `<div class="project-name">${escapeHtml(p.name)}${isSel ? ' <span class="project-badge">selected</span>' : ''}</div><div class="muted tiny path">${escapeHtml(p.path)}</div>`;
        // Remote control is opted into per project, never inherited: this is the
        // boundary that decides whether a message from a phone may act at all.
        const remote = document.createElement('label');
        remote.className = 'project-remote tiny';
        remote.title = 'Let Intercom run instructions in this project from your phone';
        const remoteBox = document.createElement('input');
        remoteBox.type = 'checkbox';
        remoteBox.checked = p.intercom === true;
        remoteBox.onchange = () => {
            const next = projects().map((x) => (x.id === p.id ? Object.assign({}, x, { intercom: remoteBox.checked }) : x));
            projectAction({ projects: next });
        };
        remote.append(remoteBox, document.createTextNode(' allow phone control'));
        meta.appendChild(remote);
        const actions = el('project-actions');
        if (!isSel) {
            const use = document.createElement('button');
            use.className = 'btn btn-small';
            use.textContent = 'Use';
            use.onclick = () => projectAction({ selectedProjectId: p.id });
            actions.appendChild(use);
        } else {
            const close = document.createElement('button');
            close.className = 'btn btn-small';
            close.textContent = 'Close';
            close.title = 'Deselect this project (keeps it registered)';
            close.onclick = () => projectAction({ selectedProjectId: null });
            actions.appendChild(close);
        }
        const rm = document.createElement('button');
        rm.className = 'btn btn-small btn-danger';
        rm.textContent = 'Remove';
        rm.onclick = () => {
            if (!window.confirm(`Remove project “${p.name}”? This only unregisters it; the folder stays on disk.`)) return;
            projectAction({ projects: projects().filter((x) => x.id !== p.id) });
        };
        actions.appendChild(rm);
        row.append(meta, actions);
        container.appendChild(row);
    }
}

// ===== Agents =====
async function loadAgents() {
    try {
        const data = await api('GET', '/api/agents');
        state.agents = data.agents || [];
    } catch {
        // Keep the previous list on a transient failure (e.g. a poll landing
        // mid-turn) so an auto-refresh never flickers the menu to empty.
        if (!Array.isArray(state.agents)) state.agents = [];
    }
    updateAgentChip();
}

function selectedAgentId() { return (state.settings && state.settings.selectedAgent) || ''; }

function updateAgentChip() {
    const label = $('agent-chip-label');
    if (!label) return;
    const sel = state.agents.find((a) => a.id === selectedAgentId());
    label.textContent = sel ? sel.name : 'No agent';
    label.title = sel ? (sel.description || sel.name) : '';
    if (!$('agent-popover').classList.contains('hidden')) buildAgentMenu();
}

function buildAgentMenu() {
    const menu = $('agent-menu');
    if (!menu) return;
    const selId = selectedAgentId();
    menu.innerHTML = '';

    const none = document.createElement('button');
    none.className = 'menu-item' + (selId ? '' : ' selected');
    none.setAttribute('role', 'menuitemradio');
    none.setAttribute('aria-checked', selId ? 'false' : 'true');
    none.innerHTML = `<span class="check">${selId ? '' : '✓'}</span><span class="menu-text"><span class="menu-name">No agent</span><span class="menu-sub muted tiny">Plain assistant</span></span>`;
    none.onclick = () => selectAgent('');
    menu.appendChild(none);

    if (!state.agents.length) {
        const empty = el('menu-empty muted tiny');
        empty.textContent = state.settings && state.settings.agentsRoot
            ? 'No agents found in the Agents folder.'
            : 'Set an Agents folder in Settings.';
        menu.appendChild(empty);
    } else {
        menu.appendChild(el('menu-divider'));
        for (const a of state.agents) {
            const isSel = a.id === selId;
            const item = document.createElement('button');
            item.className = 'menu-item' + (isSel ? ' selected' : '');
            item.setAttribute('role', 'menuitemradio');
            item.setAttribute('aria-checked', isSel ? 'true' : 'false');
            item.title = a.description || a.name;
            const sub = a.description ? shortText(a.description, 64) : a.id;
            item.innerHTML = `<span class="check">${isSel ? '✓' : ''}</span><span class="menu-text"><span class="menu-name">${escapeHtml(a.name)}</span><span class="menu-sub muted tiny">${escapeHtml(sub)}</span></span>`;
            item.onclick = () => selectAgent(a.id);
            menu.appendChild(item);
        }
    }

    // Always offer the CopilotAtelier setup: it is how a user populates the
    // ~/.copilot folders that feed this very menu. Not a one-click action — it
    // opens a consent modal explaining what the setup script changes first.
    menu.appendChild(el('menu-divider'));
    const atelier = document.createElement('button');
    atelier.className = 'menu-item menu-item-action';
    atelier.setAttribute('role', 'menuitem');
    atelier.innerHTML = '<span class="check">🎨</span><span class="menu-text"><span class="menu-name">Set up CopilotAtelier…</span><span class="menu-sub muted tiny">Download &amp; register agents, skills, instructions, prompts</span></span>';
    atelier.onclick = () => { closeAgentMenu(); openAtelierSetup(); };
    menu.appendChild(atelier);
}

function openAgentMenu() {
    buildAgentMenu();
    const pop = $('agent-popover');
    const btn = $('btn-agent');
    const rect = btn.getBoundingClientRect();
    pop.style.transform = 'none';
    pop.style.bottom = (window.innerHeight - rect.top + 8) + 'px';
    pop.classList.remove('hidden');
    const width = pop.offsetWidth;
    pop.style.left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8)) + 'px';
    btn.setAttribute('aria-expanded', 'true');
}

function closeAgentMenu() {
    $('agent-popover').classList.add('hidden');
    const btn = $('btn-agent');
    if (btn) btn.setAttribute('aria-expanded', 'false');
}

function toggleAgentMenu() {
    if ($('agent-popover').classList.contains('hidden')) openAgentMenu();
    else closeAgentMenu();
}

async function selectAgent(id) {
    closeAgentMenu();
    if ((id || '') === selectedAgentId()) return;
    try {
        state.settings = await api('PUT', '/api/settings', { selectedAgent: id || null });
        updateAgentChip();
    } catch (e) { toast(e.message); updateAgentChip(); }
}

// ===== CopilotAtelier setup =====
// An opt-in flow reached from the Agent menu. It downloads the CopilotAtelier
// repository and runs its Setup-CopilotSettings.ps1, which links the well-known
// ~/.copilot/{agents,instructions,skills,prompts} folders to a synced copy so
// this agent picker (and the Customizations surface) fill with real content.
// Because it downloads and runs code that changes the machine, the user must
// confirm explicitly first — the menu item only ever opens the consent modal.
const ATELIER_REPO_URL = 'https://github.com/raandree/CopilotAtelier';

function openAtelierSetup() {
    renderAtelierConsent();
    $('atelier-modal').classList.remove('hidden');
    $('atelier-backdrop').classList.remove('hidden');
}

function closeAtelierSetup() {
    $('atelier-modal').classList.add('hidden');
    $('atelier-backdrop').classList.add('hidden');
}

// Step 1 — the consent screen. It spells out exactly what the setup script does
// before anything is downloaded or run, so the user gives informed permission.
function renderAtelierConsent() {
    const body = $('atelier-body');
    const foot = $('atelier-foot');
    body.innerHTML =
        '<p>CopilotAtelier is a curated set of Copilot <strong>agents, skills, instructions and prompt files</strong>. ' +
        'Setting it up fills this Agent menu (and the Customizations view) with ready-to-use personas.</p>' +
        '<p>DeskPilot will download the repository from ' +
        `<a href="${ATELIER_REPO_URL}" target="_blank" rel="noopener noreferrer">${escapeHtml(ATELIER_REPO_URL)}</a> ` +
        'and run its <code>Setup-CopilotSettings.ps1</code> script <strong>with your user privileges</strong>. That script:</p>' +
        '<ul class="atelier-changes">' +
        '<li>Links <code>~/.copilot/{agents,instructions,skills,prompts}</code> to a synced copy (OneDrive when present, otherwise your home folder) using NTFS junctions.</li>' +
        '<li>Updates VS Code <code>settings.json</code> and <code>keybindings.json</code> — a timestamped backup is made first.</li>' +
        '<li>Sets the <code>COPILOT_ALLOW_ALL</code> user environment variable to <code>1</code>.</li>' +
        '</ul>' +
        '<p class="muted tiny">A PowerShell window opens so you can watch it run and answer any prompts (for example, replacing an existing non-empty <code>~/.copilot</code> folder). Windows only.</p>';
    foot.innerHTML =
        '<button class="btn" id="atelier-cancel" type="button">Cancel</button>' +
        '<button class="btn btn-primary" id="atelier-run" type="button">Download &amp; run setup</button>';
    $('atelier-cancel').onclick = () => closeAtelierSetup();
    $('atelier-run').onclick = () => runAtelierSetup();
}

// Step 2 — run it. POSTs to the consent-gated backend route and reports the
// outcome. New agents appear in the menu on their own (the list auto-refreshes),
// so there is no manual refresh button.
async function runAtelierSetup() {
    const body = $('atelier-body');
    const foot = $('atelier-foot');
    body.innerHTML = '<div class="atelier-busy"><span class="merge-spinner"></span> Downloading CopilotAtelier and starting the setup…</div>';
    foot.innerHTML = '';
    let data;
    try {
        data = await api('POST', '/api/atelier/setup');
    } catch (e) {
        body.innerHTML = `<div class="merge-error">⚠ ${escapeHtml(e.message)}</div>`;
        foot.innerHTML =
            '<button class="btn" id="atelier-cancel" type="button">Close</button>' +
            '<button class="btn btn-primary" id="atelier-retry" type="button">Try again</button>';
        $('atelier-cancel').onclick = () => closeAtelierSetup();
        $('atelier-retry').onclick = () => renderAtelierConsent();
        return;
    }
    const where = data.sourcePath
        ? `<p class="muted tiny">Files: <span class="path">${escapeHtml(data.sourcePath)}</span></p>`
        : '';
    if (data.launched) {
        body.innerHTML =
            '<div class="merge-ok">✓ Setup started.</div>' +
            '<p>A PowerShell window opened and is running the setup. Follow any prompts there. ' +
            'When it finishes, your new agents appear in the Agent menu automatically — no restart needed.</p>' + where;
    } else {
        body.innerHTML =
            '<div class="merge-ok">✓ Downloaded.</div>' +
            `<p>${escapeHtml(data.message || 'Run Setup-CopilotSettings.ps1 from the downloaded folder to finish.')}</p>` + where;
    }
    foot.innerHTML = '<button class="btn btn-primary" id="atelier-cancel" type="button">Close</button>';
    $('atelier-cancel').onclick = () => closeAtelierSetup();
}

const shortText = (s, n) => (s && s.length > n ? s.slice(0, n - 1).trim() + '…' : (s || ''));

// ===== Project file explorer =====
function selectedProject() {
    return projects().find((p) => p.id === ((state.settings && state.settings.selectedProjectId) || ''));
}

// When no project is selected the panel is collapsed AND not expandable.
function syncExplorerAvailability() {
    const wf = (state.settings && state.settings.workspaceFolder) || '';
    const has = !!wf;
    const btn = $('btn-files');
    if (btn) btn.disabled = !has;
    if (!has) {
        const ex = $('explorer');
        if (ex && !ex.classList.contains('collapsed')) collapseExplorer();
        if (btn) btn.setAttribute('aria-expanded', 'false');
        state.explorerPath = '';
        state.explorerExpanded.clear();
        return;
    }
    // Project switched while the explorer is open -> reload its tree + git bar
    // (drop the previous project's expanded folders, whose paths point elsewhere).
    if (explorerOpen() && state.explorerPath !== wf) { state.explorerExpanded.clear(); refreshExplorer(); }
}

function explorerOpen() { return !$('explorer').classList.contains('collapsed'); }

function collapseExplorer() {
    $('explorer').classList.add('collapsed');
    document.querySelector('.app').classList.remove('with-explorer');
    const btn = $('btn-files');
    if (btn) btn.setAttribute('aria-expanded', 'false');
}

function expandExplorer() {
    if (!(state.settings && state.settings.workspaceFolder)) { toast('Select a project first.'); return; }
    $('explorer').classList.remove('collapsed');
    document.querySelector('.app').classList.add('with-explorer');
    const btn = $('btn-files');
    if (btn) btn.setAttribute('aria-expanded', 'true');
    refreshExplorer();
}

function toggleExplorer() {
    if (explorerOpen()) collapseExplorer();
    else expandExplorer();
}

// ===== Explorer width =====
// The explorer is a grid column, so resizing it is one custom property. The
// chosen width lives in localStorage beside the theme: it is a per-machine
// display preference the Host Server has no reason to know about.
const EXPLORER_WIDTH_KEY = 'ad_explorer_w';
const EXPLORER_WIDTH_DEFAULT = 320;
const EXPLORER_WIDTH_MIN = 200;
// What the user last asked for, before clamping. Kept separate so shrinking the
// window and widening it again restores their width instead of the clamp.
let explorerWidthWanted = EXPLORER_WIDTH_DEFAULT;

function explorerWidthMax() {
    return Math.max(EXPLORER_WIDTH_MIN, Math.round(window.innerWidth * 0.6));
}

function clampExplorerWidth(px) {
    const n = Number(px);
    if (!Number.isFinite(n)) return EXPLORER_WIDTH_DEFAULT;
    return Math.min(explorerWidthMax(), Math.max(EXPLORER_WIDTH_MIN, Math.round(n)));
}

function applyExplorerWidth(px, opts) {
    const remember = !(opts && opts.transient);
    if (remember) {
        const asked = Number(px);
        // Never below the minimum, but deliberately not capped to the viewport:
        // that cap is a display clamp, not what the user asked for.
        if (Number.isFinite(asked)) explorerWidthWanted = Math.max(EXPLORER_WIDTH_MIN, Math.round(asked));
    }
    const width = clampExplorerWidth(px);
    document.documentElement.style.setProperty('--explorer-w', width + 'px');
    const handle = $('explorer-resize');
    if (handle) {
        handle.setAttribute('aria-valuenow', String(width));
        handle.setAttribute('aria-valuemin', String(EXPLORER_WIDTH_MIN));
        handle.setAttribute('aria-valuemax', String(explorerWidthMax()));
    }
    if (opts && opts.persist) localStorage.setItem(EXPLORER_WIDTH_KEY, String(width));
    return width;
}

function wireExplorerResize() {
    applyExplorerWidth(localStorage.getItem(EXPLORER_WIDTH_KEY) || EXPLORER_WIDTH_DEFAULT);
    const handle = $('explorer-resize');
    if (!handle) return;
    let startX = 0;
    let startWidth = EXPLORER_WIDTH_DEFAULT;

    handle.addEventListener('pointerdown', (e) => {
        if (e.button !== 0) return;
        e.preventDefault();
        startX = e.clientX;
        startWidth = $('explorer').getBoundingClientRect().width;
        handle.classList.add('is-dragging');
        handle.setPointerCapture(e.pointerId);
        document.body.classList.add('is-resizing');
    });

    handle.addEventListener('pointermove', (e) => {
        if (!handle.hasPointerCapture(e.pointerId)) return;
        // The panel is on the right edge, so dragging left widens it.
        applyExplorerWidth(startWidth + (startX - e.clientX));
    });

    const endDrag = (e) => {
        if (!handle.hasPointerCapture(e.pointerId)) return;
        handle.releasePointerCapture(e.pointerId);
        handle.classList.remove('is-dragging');
        document.body.classList.remove('is-resizing');
        applyExplorerWidth(explorerWidthWanted, { persist: true });
    };
    handle.addEventListener('pointerup', endDrag);
    handle.addEventListener('pointercancel', endDrag);
    handle.addEventListener('dblclick', () => applyExplorerWidth(EXPLORER_WIDTH_DEFAULT, { persist: true }));

    handle.addEventListener('keydown', (e) => {
        const step = e.shiftKey ? 40 : 10;
        if (e.key === 'ArrowLeft') { e.preventDefault(); applyExplorerWidth(explorerWidthWanted + step, { persist: true }); }
        else if (e.key === 'ArrowRight') { e.preventDefault(); applyExplorerWidth(explorerWidthWanted - step, { persist: true }); }
        else if (e.key === 'Home') { e.preventDefault(); applyExplorerWidth(EXPLORER_WIDTH_DEFAULT, { persist: true }); }
    });

    // A narrower window can leave the chosen width past the new maximum; re-clamp
    // for display without forgetting what the user asked for.
    window.addEventListener('resize', () => applyExplorerWidth(explorerWidthWanted, { transient: true }));
}

// Sequence + busy guards so overlapping refreshes (a poll, a focus event, a
// post-Turn refresh) never swap a stale tree into the DOM or stack background work.
let _explorerSeq = 0;
let _explorerBusy = false;

async function refreshExplorer(opts) {
    const silent = !!(opts && opts.silent);
    const proj = selectedProject();
    const tree = $('explorer-tree');
    $('explorer-title').textContent = proj ? proj.name : 'Files';
    state.explorerPath = proj ? proj.path : '';
    if (!proj) { tree.innerHTML = ''; state.explorerExpanded.clear(); $('git-bar').classList.add('hidden'); return; }
    // Don't stack background refreshes; an explicit (non-silent) refresh still runs.
    if (silent && _explorerBusy) return;
    _explorerBusy = true;
    const seq = ++_explorerSeq;
    // Awaited, not fired: the Git bar's refresh is what loads the change set, and
    // the tree paints a Git status per row, so it has to be in hand first.
    await refreshGitBar(silent);
    // A silent refresh keeps the current tree visible while it rebuilds (no flicker);
    // an explicit one shows a loading hint.
    if (!silent) tree.innerHTML = '<div class="muted tiny explorer-msg">Loading…</div>';
    let rootNode = null;
    try { rootNode = await buildTreeLevel('', 0); }
    finally { if (seq === _explorerSeq) _explorerBusy = false; }
    // Superseded by a newer refresh, or the explorer was closed while we built.
    if (seq !== _explorerSeq || !explorerOpen()) return;
    const prevScroll = tree.scrollTop;
    tree.innerHTML = '';
    if (rootNode) tree.appendChild(rootNode);
    tree.scrollTop = prevScroll;
}

// Keep the explorer in step with on-disk changes without a manual refresh:
// silently (no flicker, expanded folders + scroll preserved) when the window/tab
// regains focus or becomes visible, and on a gentle interval while it is open and
// visible. Skips while the user is interacting inside the explorer so a poll never
// yanks the tree or an open branch dropdown out from under them.
let _explorerAutoWired = false;
function wireExplorerAutoRefresh() {
    if (_explorerAutoWired) return;
    _explorerAutoWired = true;
    const tick = () => {
        // Skip while a Turn is streaming: the Host Server handles requests on a single
        // thread and services this poll inline in its streaming loop, so a directory +
        // git scan here would stall token delivery. The turn's finally refreshes the
        // explorer once when streaming ends.
        if (state.streaming) return;
        if (!explorerOpen() || document.visibilityState !== 'visible') return;
        const active = document.activeElement;
        if (active && $('explorer').contains(active)) return;
        refreshExplorer({ silent: true });
    };
    window.addEventListener('focus', tick);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') tick(); });
    setInterval(tick, 5000);
}

// Auto-refresh the Agent list so agents added after startup (for example by the
// CopilotAtelier setup, which runs in a separate console) appear without a
// restart. Polling fits the single-threaded, no-persistent-SSE Host Server
// better than a server-side folder watcher, and a focus/visibility refresh
// catches the common case of returning to the tab after running the setup.
let _agentsAutoWired = false;
function wireAgentsAutoRefresh() {
    if (_agentsAutoWired) return;
    _agentsAutoWired = true;
    const tick = () => {
        if (state.streaming) return;
        if (document.visibilityState !== 'visible') return;
        // Don't rebuild the menu out from under the user while it is open.
        if (!$('agent-popover').classList.contains('hidden')) return;
        loadAgents();
    };
    window.addEventListener('focus', tick);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') tick(); });
    setInterval(tick, 15000);
}

// ===== Updates =====
let _updateAutoWired = false;

// Poll the Host Server's cached Gallery-update status and re-render the surfaces.
// The server runs the actual (throttled) Gallery check in the background; the SPA
// only reflects it, so this is a cheap local request.
async function refreshUpdateStatus() {
    try { state.update = await api('GET', '/api/update'); }
    catch { return; }
    renderUpdateBanner();
    renderUpdatePanel();
}

function wireUpdateAutoRefresh() {
    if (_updateAutoWired) return;
    _updateAutoWired = true;
    const tick = () => {
        if (document.visibilityState !== 'visible') return;
        refreshUpdateStatus();
    };
    window.addEventListener('focus', tick);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') tick(); });
    setInterval(tick, 60000);
}

// ===== Intercom =====
let _intercomAutoWired = false;

// The setup guide. Intercom is the one feature where reading first genuinely
// matters - a message from a phone can drive the agent - so the Settings panel
// links straight to it rather than just telling the user it exists.
const INTERCOM_GUIDE_URL = 'https://github.com/raandree/DeskPilot/blob/main/docs/intercom-getting-started.md';

// Reflect the Host Server's Intercom state. The server owns the poll loop and
// the transport; the SPA only reports what it finds, so this stays a cheap
// local request.
async function refreshIntercom() {
    try {
        state.intercom = await api('GET', '/api/intercom');
        state.intercomStale = false;
    }
    catch {
        // A dead Host Server used to leave this panel frozen on its last good
        // response - counters, status and all - so a stopped DeskPilot looked
        // exactly like a running one with an old error.
        state.intercomStale = true;
        updateIntercomChip();
        renderIntercomPanel();
        return;
    }
    updateIntercomChip();
    renderIntercomPanel();
    renderIntercomPairing();
    syncSettingsFromIntercom();
}

// Intercom can change the Project, the Agent and the Model from the phone, so
// this window is no longer the only writer of Settings. Without a re-read the
// composer would keep naming a project, an agent and a model the next Turn no
// longer uses - two surfaces disagreeing about the same fact, which is worse
// than either being empty.
// Only the selection matters here, so an unchanged read costs one cheap local
// request and no re-render.
async function syncSettingsFromIntercom() {
    if (!state.intercom || state.intercom.status !== 'on') return;
    if (state.streaming) return;
    let fresh;
    try { fresh = await api('GET', '/api/settings'); } catch { return; }
    const before = state.settings || {};
    const projectsChanged = JSON.stringify(before.projects || []) !== JSON.stringify(fresh.projects || []);
    const modelChanged = before.model !== fresh.model;
    if (before.selectedProjectId === fresh.selectedProjectId
        && before.selectedAgent === fresh.selectedAgent
        && !modelChanged
        && !projectsChanged) return;
    state.settings = fresh;
    populateProjectSelect();
    updateAgentChip();
    // A remote model switch also re-pins the bound Conversation, and that pin is
    // what the composer select shows - so the Conversation has to be re-read, not
    // just repainted from Settings.
    if (modelChanged) {
        await refreshCurrentConversation();
        setModelSelect((state.current && state.current.model) || fresh.model || state.defaultModel);
    }
}

function wireIntercomAutoRefresh() {
    if (_intercomAutoWired) return;
    _intercomAutoWired = true;
    const tick = () => {
        if (document.visibilityState !== 'visible') return;
        refreshIntercom();
    };
    window.addEventListener('focus', tick);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') tick(); });
    setInterval(tick, 20000);
    // While a pairing window is open the user is staring at the panel waiting for
    // their own message to appear, so poll fast enough to feel immediate.
    setInterval(() => {
        if (document.visibilityState !== 'visible') return;
        if (!state.intercom || !state.intercom.pairing || !state.intercom.pairing.active) return;
        refreshIntercom();
    }, 2000);
    setInterval(pollRemoteTurn, 3000);
}

// Follow a Turn the phone started. There is no SSE stream for it - the Host
// Server accepts on one thread, so a persistent event channel would hold the
// only thread it has - and the request that drives a normal Turn does not exist
// here. Polling a cheap local route is what fits the architecture.
// Re-read the Conversation list after something other than this window changed
// it, and make sure the open Conversation still exists.
async function syncConversationsFromServer() {
    await loadConversations();
    const openId = state.current && state.current.id;
    if (openId && !state.conversations.some((c) => c.id === openId)) {
        state.current = null;
        if (state.conversations.length) await selectConversation(state.conversations[0].id);
        else await newConversation();
        return;
    }
    if (!openId && state.conversations.length) await selectConversation(state.conversations[0].id);
}

async function pollRemoteTurn() {
    if (document.visibilityState !== 'visible') return;
    // Our own Turn owns the thread while it streams; never paint over it.
    if (state.streaming) return;
    let data;
    try { data = await api('GET', '/api/intercom/turn'); }
    catch { return; }

    const wasActive = state.remoteTurnWasActive;
    state.remoteTurn = data;
    state.remoteTurnWasActive = !!data.active;

    if (data.active || wasActive) renderConversationList();
    renderRemoteLive();

    // Intercom can create, archive, unarchive and delete conversations. Without
    // this the sidebar kept showing a deleted one, and clicking it did nothing.
    const revision = data.conversationsRevision;
    if (typeof revision === 'number' && state.conversationsRevision !== null && revision !== state.conversationsRevision) {
        state.conversationsRevision = revision;
        try { await syncConversationsFromServer(); } catch { /* a transient failure just leaves the list as it was */ }
    }
    else if (typeof revision === 'number') {
        state.conversationsRevision = revision;
    }

    if (wasActive && !data.active) {
        // The live view was an approximation; the recorded Message is the truth,
        // and it carries the activity, usage and task list the buffer never had.
        try {
            await loadConversations();
            if (state.current && data.conversationId && state.current.id === data.conversationId) {
                await selectConversation(data.conversationId);
            }
        } catch { /* a transient failure just leaves the list as it was */ }
    }
}

// The live bubble: the prompt that arrived from the phone, plus the answer as it
// is written. Replaced by the real Message once the Turn ends.
function renderRemoteLive() {
    const thread = $('thread');
    if (!thread) return;
    const data = state.remoteTurn;
    const show = data && data.active && !state.streaming &&
        state.current && data.conversationId && state.current.id === data.conversationId;

    let node = document.getElementById('remote-live');
    if (!show) { if (node) node.remove(); return; }

    if (!node) {
        node = el('remote-live');
        node.id = 'remote-live';
        const promptWrap = el('msg msg-user');
        const bubble = el('bubble');
        bubble.textContent = data.prompt || '';
        const badge = el('steered-badge');
        badge.textContent = '📻 From your phone';
        promptWrap.append(bubble, badge);
        const answer = buildAssistantEl({ id: 'remote-live-msg' });
        answer.classList.add('is-remote');
        node.append(promptWrap, answer);
        node._refs = answer._refs;
        thread.appendChild(node);
        const emptyState = thread.querySelector('.empty-state');
        if (emptyState) emptyState.remove();
        scrollThread();
    }

    const refs = node._refs;
    refs.content.innerHTML = renderMarkdown(data.text || '') ||
        '<span class="muted tiny">Working…</span>';
    if (data.reasoning) renderThinking(node, data.reasoning);
    followThread();
}

// Start or stop the pairing window. Without this the setup is impossible to
// finish: Intercom will not listen until it knows which chat is yours, so the
// bot cannot answer even /start, and there is no way to learn the id from it.
async function setIntercomPairing(stop) {
    try {
        state.intercom = await api('POST', '/api/intercom/pair', { stop: !!stop });
        updateIntercomChip();
        renderIntercomPanel();
        renderIntercomPairing();
    } catch (e) { toast((e && e.message) || 'Could not start linking.'); }
}

function renderIntercomPairing() {
    const box = $('set-ic-pairing');
    if (!box) return;
    const i = state.intercom;
    if (!i) { box.innerHTML = '<span class="muted tiny">Checking…</span>'; return; }

    if (i.chatId) {
        box.innerHTML = `<div class="intercom-state ok">Linked to chat ${escapeHtml(i.chatId)}</div>` +
            '<div class="muted tiny">Only this chat can reach DeskPilot. To link a different phone, clear the box below and link again.</div>';
        return;
    }

    if (!i.tokenConfigured) {
        box.innerHTML = '<span class="muted tiny">Save your bot token first, then come back here.</span>';
        return;
    }

    const pairing = i.pairing || {};
    if (!pairing.active) {
        box.innerHTML = '<div class="intercom-state warn">Not linked yet</div>' +
            '<div class="muted tiny">DeskPilot ignores every message until you tell it which chat is yours — that is why your bot has not replied.</div>' +
            '<div class="backup-row"><button class="btn btn-small btn-primary" id="ic-pair-start" type="button">Link my phone</button></div>';
        $('ic-pair-start').onclick = () => setIntercomPairing(false);
        return;
    }

    const candidates = asArray(pairing.candidates);
    const rows = ['<div class="intercom-state warn">Listening… open Telegram and send your bot any message.</div>'];
    if (pairing.expiresUtc) {
        rows.push(`<div class="muted tiny">This stops on its own at ${new Date(pairing.expiresUtc).toLocaleTimeString()}.</div>`);
    }
    if (!candidates.length) {
        rows.push('<div class="muted tiny">Nothing yet. Any message will do — even “hello”.</div>');
    } else {
        rows.push('<div class="muted tiny">Messages arrived. Pick the one that is you:</div>');
        for (const c of candidates) {
            rows.push(
                `<div class="intercom-candidate"><button class="btn btn-small btn-primary" data-chat="${escapeHtml(c.chatId)}" type="button">This is me</button>` +
                `<span class="tiny"><strong>${escapeHtml(c.fromName || 'Unknown')}</strong> <span class="muted">(${escapeHtml(c.chatId)})</span>` +
                `${c.preview ? ' — “' + escapeHtml(c.preview) + '”' : ''}</span></div>`);
        }
    }
    rows.push('<div class="backup-row"><button class="btn btn-small" id="ic-pair-stop" type="button">Cancel</button></div>');
    box.innerHTML = rows.join('');

    for (const btn of box.querySelectorAll('button[data-chat]')) {
        btn.onclick = async () => {
            const chatId = btn.dataset.chat;
            try {
                state.intercom = await api('PUT', '/api/intercom', { chatId });
                const field = $('set-ic-chat');
                if (field) field.value = chatId;
                updateIntercomChip();
                renderIntercomPanel();
                renderIntercomPairing();
                toast('Phone linked. Your bot will answer from now on.');
            } catch (e) { toast((e && e.message) || 'Could not link that chat.'); }
        };
    }
    $('ic-pair-stop').onclick = () => setIntercomPairing(true);
}

// The topbar chip. It is hidden entirely while Intercom is off, so a feature
// nobody uses adds no chrome; once on, it says in one glance whether the phone
// link is healthy.
function updateIntercomChip() {
    const chip = $('btn-intercom');
    if (!chip) return;
    const i = state.intercom;
    if (!i || !i.enabled) { chip.classList.add('hidden'); return; }
    chip.classList.remove('hidden');
    if (state.intercomStale) {
        chip.classList.remove('ok', 'warn');
        chip.classList.add('bad');
        chip.innerHTML = '<span aria-hidden="true">📻</span> <span>DeskPilot not responding</span>';
        chip.title = 'The DeskPilot window has stopped. Restart it and reload this page.';
        return;
    }
    const map = {
        on: { icon: '📻', label: 'Intercom on', cls: 'ok' },
        error: { icon: '📻', label: 'Intercom problem', cls: 'bad' },
        'needs-token': { icon: '📻', label: 'Intercom needs a token', cls: 'warn' },
        'needs-chat': { icon: '📻', label: 'Intercom: link your phone', cls: 'warn' },
        pairing: { icon: '📻', label: 'Intercom: waiting for your message', cls: 'warn' },
        starting: { icon: '📻', label: 'Intercom starting…', cls: 'warn' },
    };
    const s = map[i.status] || map.starting;
    chip.classList.remove('ok', 'warn', 'bad');
    chip.classList.add(s.cls);
    const waiting = i.questionPending ? ' · waiting for your answer' : '';
    chip.innerHTML = `<span aria-hidden="true">${s.icon}</span> <span>${escapeHtml(s.label)}</span>`;
    chip.title = `${s.label}${waiting}` + (i.lastError ? ` — ${i.lastError}` : '');
    chip.onclick = () => { openSettings(); const tab = $('stab-intercom'); if (tab) tab.click(); };
}

// The Settings panel body. Only the live parts are re-rendered here; the inputs
// are built once by openSettings so typing is never interrupted by a poll.
function renderIntercomPanel() {
    const box = $('set-intercom-status');
    if (!box) return;
    const i = state.intercom;
    if (!i) { box.innerHTML = '<span class="muted tiny">Checking…</span>'; return; }

    if (state.intercomStale) {
        box.innerHTML = '<div class="intercom-state bad">DeskPilot is not responding</div>' +
            '<div class="intercom-err tiny">This page cannot reach DeskPilot, so everything below is out of date — including any error. ' +
            'Restart DeskPilot, then reload this page.</div>';
        return;
    }

    const label = {
        off: 'Off',
        on: 'On — connected',
        error: 'Problem',
        'needs-token': 'Needs a bot token',
        'needs-chat': 'Not linked to a phone yet',
        pairing: 'Waiting for a message from your phone',
        starting: 'Starting…',
    }[i.status] || i.status;
    const cls = i.status === 'on' ? 'ok' : (i.status === 'error' ? 'bad' : 'warn');

    const rows = [`<div class="intercom-state ${cls}">${escapeHtml(label)}</div>`];
    if (i.lastError) rows.push(`<div class="intercom-err tiny">${escapeHtml(i.lastError)}</div>`);
    if (i.enabled && !i.projectAllowed && i.projectReason) {
        rows.push(`<div class="intercom-err tiny">${escapeHtml(i.projectReason)}</div>`);
    }
    const c = i.counters || {};
    rows.push(
        `<div class="intercom-counts tiny">Received ${c.received || 0} · accepted ${c.accepted || 0} · ` +
        `<strong>rejected ${c.rejected || 0}</strong> · sent ${c.sent || 0} · dropped ${c.dropped || 0} · errors ${c.errors || 0}</div>`);
    if (i.nextCheckInUtc) {
        rows.push(`<div class="muted tiny">Next check-in by ${new Date(i.nextCheckInUtc).toLocaleTimeString()}</div>`);
    }

    const log = asArray(i.log).slice(-12).reverse();
    if (log.length) {
        const items = log.map((e) => {
            const when = new Date(e.utc).toLocaleTimeString();
            const arrow = e.direction === 'in' ? '←' : (e.direction === 'out' ? '→' : '·');
            return `<div class="intercom-log-row${e.accepted ? '' : ' rejected'}">` +
                `<span class="tiny muted">${escapeHtml(when)}</span> <span class="intercom-arrow">${arrow}</span> ` +
                `<span class="intercom-kind tiny">${escapeHtml(e.kind)}</span> <span class="tiny">${escapeHtml(e.detail || '')}</span></div>`;
        }).join('');
        rows.push(`<div class="intercom-log">${items}</div>`);
    }
    box.innerHTML = rows.join('');
}

// The dismissible "update available" banner. Once installed it flips to a
// "restart to apply" message that cannot be dismissed (the update only takes
// effect on the next launch), so the user always sees the next step. The banner
// text is the consent disclosure: it names what "Update now" will install.
function renderUpdateBanner() {
    const el = $('update-notice');
    if (!el) return;
    const u = state.update;
    if (!u) { el.classList.add('hidden'); return; }
    if (u.installResult && u.installResult.restartRequired) {
        if (state.restartDismissed) { el.classList.add('hidden'); return; }
        const ver = u.targetVersion ? escapeHtml(String(u.targetVersion)) : 'the latest version';
        const engineNote = u.installResult.engineReloaded ? ' The Engine reloaded and is active now.' : '';
        el.innerHTML =
            `<span class="update-msg">DeskPilot was updated to ${ver}.${engineNote} Restart DeskPilot to finish applying the update.</span>` +
            '<span class="update-actions">' +
            '<button type="button" class="btn btn-small" id="update-restart">Restart DeskPilot</button>' +
            '<button type="button" class="btn btn-small btn-ghost" id="update-restart-later">Later</button>' +
            '</span>';
        el.classList.remove('hidden');
        $('update-restart').onclick = () => restartDeskPilot();
        $('update-restart-later').onclick = () => { state.restartDismissed = true; el.classList.add('hidden'); };
        return;
    }
    if (!u.updateAvailable || state.updateDismissed) { el.classList.add('hidden'); return; }
    const kind = u.targetIsPrerelease ? ' preview' : '';
    const ver = escapeHtml(String(u.targetVersion || ''));
    el.innerHTML =
        `<span class="update-msg">DeskPilot ${ver}${kind} is available. Updating installs the newest DeskPilot and ShellPilot from the PowerShell Gallery and needs a restart.</span>` +
        '<span class="update-actions">' +
        '<button type="button" class="btn btn-small" id="update-now">Update now</button>' +
        '<button type="button" class="btn btn-small btn-ghost" id="update-dismiss">Dismiss</button>' +
        '</span>';
    el.classList.remove('hidden');
    $('update-now').onclick = () => installUpdate();
    $('update-dismiss').onclick = () => { state.updateDismissed = true; el.classList.add('hidden'); };
    if (u.installing) { $('update-now').disabled = true; $('update-now').textContent = 'Updating…'; }
}

// POST the consent-gated install. The request blocks until the Gallery install
// finishes (the single-threaded server is briefly busy), so show progress and
// then the restart prompt.
async function installUpdate() {
    const btn = $('update-now');
    if (btn) { btn.disabled = true; btn.textContent = 'Updating…'; }
    if (state.update) { state.update.installing = true; }
    renderUpdatePanel();
    toast('Updating DeskPilot and ShellPilot…');
    try {
        const r = await api('POST', '/api/update/install');
        state.update = await api('GET', '/api/update');
        renderUpdateBanner();
        renderUpdatePanel();
        toast((r && r.message) || 'Update installed. Restart DeskPilot to apply.');
    } catch (e) {
        if (state.update) { state.update.installing = false; }
        renderUpdateBanner();
        renderUpdatePanel();
        toast((e && e.message) || 'Update failed.');
    }
}

// Relaunch DeskPilot so the installed update takes effect. The current process
// exits after spawning a fresh instance, so this tab loses its connection and a
// new window opens - hence the explicit "you can close this tab" message.
async function restartDeskPilot() {
    const btn = $('update-restart');
    if (btn) { btn.disabled = true; btn.textContent = 'Restarting…'; }
    try {
        const r = await api('POST', '/api/update/restart');
        const el = $('update-notice');
        if (el) {
            el.innerHTML = `<span class="update-msg">${escapeHtml((r && r.message) || 'DeskPilot is restarting. A new window will open; you can close this tab.')}</span>`;
            el.classList.remove('hidden');
        }
        toast('Restarting DeskPilot…');
    } catch (e) {
        if (btn) { btn.disabled = false; btn.textContent = 'Restart DeskPilot'; }
        toast((e && e.message) || 'Could not restart DeskPilot.');
    }
}

// The manual "Check for updates" button: trigger a server-side Gallery check,
// then poll the cached status until the check clears.
async function checkForUpdates() {
    const btn = $('update-check');
    if (btn) { btn.disabled = true; btn.textContent = 'Checking…'; }
    try { await api('POST', '/api/update/check'); } catch { /* fail-silent */ }
    for (let i = 0; i < 12; i++) {
        await new Promise((r) => setTimeout(r, 1500));
        try { state.update = await api('GET', '/api/update'); } catch { break; }
        renderUpdateBanner();
        renderUpdatePanel();
        if (!state.update || !state.update.checking) break;
    }
    if (btn) { btn.disabled = false; btn.textContent = 'Check for updates'; }
}

// Reflect update status in the Settings -> Engine & data "Updates" panel (present
// in the DOM only while the drawer is open, so this is a no-op otherwise).
function renderUpdatePanel() {
    const status = $('set-update-status');
    if (!status) return;
    const u = state.update;
    const now = $('set-update-now');
    if (!u) { status.textContent = 'Checking…'; return; }
    if (u.installResult && u.installResult.restartRequired) {
        status.textContent = `Updated to ${u.targetVersion || 'the latest version'} — restart DeskPilot to apply.`;
    } else if (u.installing) {
        status.textContent = 'Installing update…';
    } else if (u.checking) {
        status.textContent = 'Checking the PowerShell Gallery…';
    } else if (u.updateAvailable) {
        const kind = u.targetIsPrerelease ? ' (preview)' : '';
        status.textContent = `Update available: ${u.targetVersion}${kind} (installed ${u.currentVersion}).`;
    } else {
        status.textContent = `Up to date (installed ${u.currentVersion || '—'}).`;
    }
    if (now) now.classList.toggle('hidden', !(u.updateAvailable && !(u.installResult && u.installResult.restartRequired)));
}

// ===== Git bar (in the explorer) =====
async function refreshGitBar(silent) {
    const bar = $('git-bar');
    if (!bar) return;
    if (!(state.settings && state.settings.workspaceFolder)) {
        bar.classList.add('hidden');
        resetGitChanges();
        resetAiChanges();
        renderChangesPanel();
        return;
    }
    bar.classList.remove('hidden');
    // On a silent (auto) refresh, keep the current bar visible while we re-check
    // so it doesn't flash "Checking Git…" every few seconds.
    if (!silent) bar.innerHTML = '<span class="muted tiny">Checking Git…</span>';
    let status;
    try { status = await api('GET', '/api/git/status'); }
    catch (e) { bar.innerHTML = `<span class="git-warn">Git: ${escapeHtml(e.message)}</span>`; return; }
    // The richer branch list (local + remote-only, each with a merged-into-default
    // flag) powers the badges and the Merge entry. A local-only comparison keeps
    // this fast; the Merge Wizard re-fetches from the remote for accuracy.
    let branchData = null;
    if (status && status.isRepo) {
        try { branchData = await api('GET', '/api/git/branches'); } catch { /* fall back to status */ }
    }
    renderGitBar(status, branchData, silent);
    if (status && status.isRepo) {
        await Promise.all([loadGitChanges(!silent), loadAiChanges(!silent)]);
    }
    else {
        resetGitChanges();
        await loadAiChanges(!silent);
    }
    renderChangesPanel();
}

function gitLegendText(def) {
    const where = def ? `'${def}'` : 'the default branch';
    return `\u2713 = already merged into ${where}  \u00b7  \u2757 = not yet merged  \u00b7  (remote) = exists only on the server`;
}

function gitBranchBadge(b) {
    if (b.merged === true) return '\u2713 ';
    if (b.merged === false) return '\u2757 ';
    return '\u2022 ';
}

function branchTitle(b, def) {
    const where = def ? `'${def}'` : 'the default branch';
    let s;
    if (b.merged === true) s = `Already merged into ${where}.`;
    else if (b.merged === false) s = `Not yet merged into ${where}.`;
    else s = 'Merge status unknown.';
    if (b.isRemote) s += ' Remote-only branch (exists on the server only).';
    return s;
}

function renderGitBar(status, branchData, silent) {
    const bar = $('git-bar');
    if (!bar) return;
    bar.innerHTML = '';

    if (!status || status.gitAvailable === false) {
        bar.innerHTML = '<span class="git-muted muted tiny">Git is not installed.</span>';
        return;
    }

    if (!status.isRepo) {
        const warn = el('git-warn');
        warn.innerHTML = '<span class="git-ico">⚠</span> Not a Git repository';
        const btn = document.createElement('button');
        btn.className = 'btn btn-small git-init-btn';
        btn.textContent = 'git init';
        btn.onclick = () => gitInit();
        bar.append(warn, btn);
        return;
    }

    const info = el('git-info');
    info.innerHTML = '<span class="git-ico git-ok">✔</span> Git';
    const label = el('git-branch-label muted tiny');
    label.textContent = status.detached ? 'detached at' : 'branch';

    const def = (branchData && branchData.defaultBranch) || '';
    const entries = (branchData && branchData.branches && branchData.branches.length) ? branchData.branches : null;

    const select = document.createElement('select');
    select.className = 'git-branch-select';
    select.title = entries ? gitLegendText(def) : 'Switch branch';

    // A detached HEAD isn't in the branch list; show it as a disabled current option.
    if (status.detached) {
        const o = document.createElement('option');
        o.value = ''; o.textContent = status.branch + ' (detached)'; o.selected = true; o.disabled = true;
        select.appendChild(o);
    }

    if (entries) {
        for (const b of entries) {
            const o = document.createElement('option');
            // Remote-only branches can't be checked out directly here.
            o.value = b.isRemote ? '' : b.name;
            if (b.isRemote) o.disabled = true;
            o.textContent = gitBranchBadge(b) + b.display + (b.isDefault ? '  (main)' : '') + (b.isRemote ? '  (remote)' : '');
            o.title = branchTitle(b, def);
            if (!status.detached && b.isCurrent) o.selected = true;
            select.appendChild(o);
        }
    } else {
        const branches = status.branches && status.branches.length ? status.branches : [status.branch];
        for (const b of branches) {
            const o = document.createElement('option');
            o.value = b; o.textContent = b;
            if (!status.detached && b === status.branch) o.selected = true;
            select.appendChild(o);
        }
    }
    select.onchange = () => { if (select.value) switchBranch(select.value); };

    bar.append(info, label, select);

    // A small, reliably-hoverable legend explaining the badges.
    if (entries) {
        const legend = el('git-legend', 'span');
        legend.textContent = '\u24d8'; // circled i
        legend.title = gitLegendText(def);
        legend.setAttribute('aria-label', gitLegendText(def));
        bar.append(legend);
    }

    // The Branch Wizard is the single entry point for everything a non-expert
    // needs to do with branches: create, switch, delete, merge and sync.
    const branchBtn = document.createElement('button');
    branchBtn.className = 'btn btn-small git-branch-btn';
    branchBtn.textContent = 'Branches…';
    branchBtn.title = 'Create, switch, delete, merge and sync branches';
    branchBtn.onclick = () => openBranchWizard();
    bar.append(branchBtn);
}

// The changed files, listed directly under the Git bar. A count alone is too
// easy to miss, and the Activity panel is collapsed by default — this is the
// surface that says "the agent touched these files" without being asked. Two
// sections, because they answer different questions: what DeskPilot changed and
// you have not reviewed yet, and what is simply uncommitted in Git.
function renderChangesPanel() {
    const panel = $('git-changes');
    if (!panel) return;
    panel.innerHTML = '';

    const pending = aiChanges.list.filter((f) => f && f.rel && f.status !== 'unchanged');
    const gitFiles = gitChangeList();
    if (!pending.length && !(gitChanges.has && gitFiles.length)) { panel.classList.add('hidden'); return; }
    panel.classList.remove('hidden');

    if (pending.length) {
        panel.appendChild(buildChangesSection({
            cls: 'is-ai',
            title: `DeskPilot changed ${aiChanges.fileCount} file${aiChanges.fileCount === 1 ? '' : 's'}`,
            hint: 'Not reviewed yet — keep them or put them back.',
            added: aiChanges.added,
            deleted: aiChanges.deleted,
            files: pending,
            actions: [
                { label: 'Keep all', cls: 'btn-primary', title: 'Accept these changes and stop tracking them', run: (b) => keepAiChanges(null, b) },
                { label: 'Undo all', cls: '', title: 'Put every file back the way it was before DeskPilot changed it', run: (b) => undoAiChanges(null, b), disabled: !aiChanges.undoable },
            ],
        }));
    }

    if (gitChanges.has && gitFiles.length) {
        panel.appendChild(buildChangesSection({
            cls: 'is-git',
            title: `${gitChanges.fileCount} uncommitted file${gitChanges.fileCount === 1 ? '' : 's'}`,
            hint: pending.length ? 'Everything not yet saved as a commit, including the above.' : '',
            added: gitChanges.added,
            deleted: gitChanges.deleted,
            files: gitFiles,
            actions: [
                { label: 'Review', cls: '', title: 'Open the diff viewer over every changed file', run: () => openRepoChanges() },
                { label: 'Save all\u2026', cls: 'btn-primary', title: 'Record every changed file in this project\u2019s history, in one save', run: () => openSaveWizard() },
            ],
        }));
    }
}

function buildChangesSection(opts) {
    const section = el('git-changes-section ' + (opts.cls || ''));

    const head = el('git-changes-head');
    const title = el('git-changes-title');
    title.textContent = opts.title;
    const add = el('changes-stat changes-add', 'span');
    add.textContent = '+' + opts.added;
    const del = el('changes-stat changes-del', 'span');
    del.textContent = '\u2212' + opts.deleted;
    head.append(title, add, del);
    const acts = el('git-changes-acts');
    for (const a of (opts.actions || [])) {
        const b = document.createElement('button');
        b.className = 'btn btn-small ' + (a.cls || '');
        b.type = 'button';
        b.textContent = a.label;
        if (a.title) b.title = a.title;
        if (a.disabled) b.disabled = true;
        b.onclick = () => a.run(b);
        acts.appendChild(b);
    }
    head.appendChild(acts);
    section.appendChild(head);

    if (opts.hint) {
        const hint = el('git-changes-hint muted tiny');
        hint.textContent = opts.hint;
        section.appendChild(hint);
    }

    const list = el('git-changes-list');
    const shown = opts.files.slice(0, CHANGES_PANEL_LIMIT);
    for (const f of shown) list.appendChild(buildChangeRow(f, opts.files));
    section.appendChild(list);

    if (opts.files.length > shown.length) {
        const more = document.createElement('button');
        more.className = 'git-changes-more muted tiny';
        more.type = 'button';
        more.textContent = `…and ${opts.files.length - shown.length} more`;
        more.onclick = () => openDiffViewer(opts.files, opts.files[0].rel);
        section.appendChild(more);
    }
    return section;
}

// One shared read of "what changed" drives both the Git bar's count and the file
// explorer's highlighting, so the badge and the tree can never disagree. The
// explorer re-renders every few seconds and the Host Server handles requests on
// one thread, so the reading is cached and concurrent callers share one request.
const gitChanges = {
    has: false, fileCount: 0, added: 0, deleted: 0, at: 0,
    list: [],           // the API's file records, in order
    files: new Map(),   // project-relative (lowercased) -> status
    dirs: new Map(),    // ancestor folder -> number of changed files beneath it
    newDirs: [],        // untracked folders; everything inside inherits the status
};
const GIT_CHANGE_MAX_AGE_MS = 20000;
const CHANGES_PANEL_LIMIT = 12;
const SAVE_LIST_LIMIT = 40;
let _gitChangesInflight = null;

// Only real files can be diffed; a folder record (Git reports one for an
// untracked directory) is kept for colouring the tree but never listed as
// something to open.
function gitChangeList() {
    return gitChanges.list.filter((f) => f && f.rel && !f.directory);
}

function resetGitChanges() {
    gitChanges.has = false;
    gitChanges.fileCount = 0;
    gitChanges.added = 0;
    gitChanges.deleted = 0;
    gitChanges.list = [];
    gitChanges.files.clear();
    gitChanges.dirs.clear();
    gitChanges.newDirs = [];
}

function applyGitChanges(data) {
    resetGitChanges();
    if (!data || data.error || !data.files) return;
    gitChanges.has = true;
    gitChanges.fileCount = Number(data.fileCount || data.files.length);
    gitChanges.added = Number(data.totalAdded || 0);
    gitChanges.deleted = Number(data.totalDeleted || 0);
    gitChanges.list = data.files.filter((f) => f && f.rel);
    for (const f of data.files) {
        const rel = String((f && f.rel) || '').replace(/\\/g, '/').replace(/\/+$/, '');
        if (!rel) continue;
        const key = rel.toLowerCase();
        const status = (f && f.status) || 'modified';
        gitChanges.files.set(key, status);
        if (f && f.directory) gitChanges.newDirs.push({ key, status });
        // Count the change against every ancestor, so a collapsed folder still
        // shows that something inside it changed.
        const parts = key.split('/');
        for (let i = 1; i < parts.length; i++) {
            const dir = parts.slice(0, i).join('/');
            gitChanges.dirs.set(dir, (gitChanges.dirs.get(dir) || 0) + 1);
        }
    }
}

async function fetchGitChanges() {
    if (!(state.settings && state.settings.workspaceFolder)) { resetGitChanges(); return gitChanges; }
    let data;
    try { data = await api('GET', '/api/git/changes'); } catch { return gitChanges; }
    gitChanges.at = Date.now();
    applyGitChanges(data);
    return gitChanges;
}

async function loadGitChanges(force) {
    const fresh = gitChanges.at && (Date.now() - gitChanges.at) < GIT_CHANGE_MAX_AGE_MS;
    if (!force && fresh) return gitChanges;
    if (_gitChangesInflight) return _gitChangesInflight;
    _gitChangesInflight = fetchGitChanges();
    try { return await _gitChangesInflight; }
    finally { _gitChangesInflight = null; }
}

// Absolute path -> path relative to the selected Project, or null when outside.
function projectRelPath(absPath) {
    const root = String(state.explorerPath || '').replace(/\\/g, '/').replace(/\/+$/, '');
    if (!root) return null;
    const p = String(absPath || '').replace(/\\/g, '/').replace(/\/+$/, '');
    if (p.length <= root.length + 1) return null;
    if (p.slice(0, root.length).toLowerCase() !== root.toLowerCase()) return null;
    if (p[root.length] !== '/') return null;
    return p.slice(root.length + 1);
}

// The Git status to paint on an explorer row: the file's own status, the status
// it inherits from an untracked folder above it, or 'contains' for a folder with
// changes somewhere beneath.
function gitStatusFor(absPath, isDir) {
    if (!gitChanges.has) return null;
    const rel = projectRelPath(absPath);
    if (rel == null) return null;
    const key = rel.toLowerCase();
    const own = gitChanges.files.get(key);
    if (own) return own;
    for (const d of gitChanges.newDirs) {
        if (key.startsWith(d.key + '/')) return d.status;
    }
    if (isDir && gitChanges.dirs.has(key)) return 'contains';
    return null;
}

// Opens the diff viewer over every uncommitted file in the repository.
async function openRepoChanges() {
    await loadGitChanges(true);
    renderChangesPanel();
    const files = gitChangeList();
    if (!files.length) { toast('Nothing has changed since the last save.'); return; }
    openDiffViewer(files, files[0].rel);
}

// ===== Pending DeskPilot changes =====
// The layer above Git: files the agent wrote that the user has not yet kept or
// undone. Each carries the snapshot taken before the Turn, so "undo" means "back
// to how it was before DeskPilot touched it" — not "back to the last commit",
// which would also throw away the user's own work.
const aiChanges = { has: false, fileCount: 0, added: 0, deleted: 0, undoable: false, at: 0, list: [], files: new Map() };
let _aiChangesInflight = null;

function resetAiChanges() {
    aiChanges.has = false;
    aiChanges.fileCount = 0;
    aiChanges.added = 0;
    aiChanges.deleted = 0;
    aiChanges.undoable = false;
    aiChanges.list = [];
    aiChanges.files.clear();
}

async function fetchAiChanges() {
    if (!(state.settings && state.settings.workspaceFolder)) { resetAiChanges(); return aiChanges; }
    let data;
    try { data = await api('GET', '/api/changes'); } catch { return aiChanges; }
    aiChanges.at = Date.now();
    resetAiChanges();
    if (!data || data.error || !data.files) return aiChanges;
    aiChanges.has = true;
    aiChanges.undoable = !!data.undoable;
    aiChanges.list = data.files.filter((f) => f && f.rel);
    aiChanges.fileCount = aiChanges.list.filter((f) => f.status !== 'unchanged').length;
    aiChanges.added = Number(data.totalAdded || 0);
    aiChanges.deleted = Number(data.totalDeleted || 0);
    for (const f of aiChanges.list) aiChanges.files.set(String(f.rel).replace(/\\/g, '/').toLowerCase(), f);
    return aiChanges;
}

async function loadAiChanges(force) {
    const fresh = aiChanges.at && (Date.now() - aiChanges.at) < GIT_CHANGE_MAX_AGE_MS;
    if (!force && fresh) return aiChanges;
    if (_aiChangesInflight) return _aiChangesInflight;
    _aiChangesInflight = fetchAiChanges();
    try { return await _aiChangesInflight; }
    finally { _aiChangesInflight = null; }
}

function aiChangeFor(absPath) {
    if (!aiChanges.has) return null;
    const rel = projectRelPath(absPath);
    if (rel == null) return null;
    return aiChanges.files.get(rel.toLowerCase()) || null;
}

// Keep = accept and stop tracking. It deliberately does NOT commit: committing is
// a separate decision the Save action owns, and conflating them would make
// "keep" irreversible.
async function keepAiChanges(paths, btn) {
    const list = paths ? asArray(paths).map(String) : null;
    if (btn) { btn.disabled = true; btn.textContent = 'Keeping…'; }
    try {
        const body = list ? { paths: list } : {};
        const r = await api('POST', '/api/changes/keep', body);
        toast(r.kept ? `Kept ${r.kept} file${r.kept === 1 ? '' : 's'}.` : 'Nothing to keep.');
        await afterChangeDecision();
    } catch (e) { toast(e.message); }
    finally { if (btn) { btn.disabled = false; btn.textContent = 'Keep all'; } }
}

async function undoAiChanges(paths, btn) {
    const list = paths ? asArray(paths).map(String) : null;
    const what = list ? `${list.length} file${list.length === 1 ? '' : 's'}` : 'every file DeskPilot changed';
    if (!window.confirm(`Put ${what} back the way it was before DeskPilot changed it?\n\nYour own edits from before that point are kept; files DeskPilot created are deleted.`)) return;
    if (btn) { btn.disabled = true; btn.textContent = 'Undoing…'; }
    try {
        const body = list ? { paths: list } : {};
        const r = await api('POST', '/api/changes/undo', body);
        const bits = [];
        if (r.restored && r.restored.length) bits.push(r.restored.length + ' put back');
        if (r.removed && r.removed.length) bits.push(r.removed.length + ' removed');
        if (r.skipped && r.skipped.length) bits.push(r.skipped.length + ' skipped');
        toast(bits.length ? 'Undo: ' + bits.join(', ') + '.' : 'Nothing to undo.');
        await afterChangeDecision();
    } catch (e) { toast(e.message); }
    finally { if (btn) { btn.disabled = false; btn.textContent = 'Undo all'; } }
}

async function afterChangeDecision() {
    aiChanges.at = 0;
    gitChanges.at = 0;
    await refreshExplorer();
    renderThread();
    await refreshDiffViewer();
}

// ===== Save (one commit over every uncommitted file) =====
// "Save" is what DeskPilot calls a commit. Keeping and undoing operate on the
// pending set; nothing else made an agent's work durable, and `git add` +
// `git commit` is exactly the step a non-expert cannot reach. So this is one
// action over the whole Project: see what will be saved, describe it in a
// sentence, save it all at once.
const saveWiz = { busy: false, error: '', loaded: false, message: '', files: [], fileCount: 0, added: 0, deleted: 0 };

async function openSaveWizard() {
    if (!(state.settings && state.settings.workspaceFolder)) { toast('Select a project first.'); return; }
    saveWiz.busy = false;
    saveWiz.error = '';
    saveWiz.loaded = false;
    saveWiz.message = '';
    saveWiz.files = [];
    saveWiz.fileCount = 0;
    saveWiz.added = 0;
    saveWiz.deleted = 0;
    $('save-backdrop').classList.remove('hidden');
    $('save-modal').classList.remove('hidden');
    renderSaveWizard();
    await loadSaveWizard();
}

function closeSaveWizard() {
    // Never lose a half-typed message to a stray click while the commit runs.
    if (saveWiz.busy) return;
    $('save-backdrop').classList.add('hidden');
    $('save-modal').classList.add('hidden');
}

function saveWizIsOpen() {
    return !$('save-modal').classList.contains('hidden');
}

async function loadSaveWizard() {
    await loadGitChanges(true);
    saveWiz.loaded = true;
    saveWiz.files = gitChangeList();
    saveWiz.fileCount = gitChanges.fileCount;
    saveWiz.added = gitChanges.added;
    saveWiz.deleted = gitChanges.deleted;
    saveWiz.message = suggestSaveMessage(saveWiz.files, saveWiz.fileCount);
    renderChangesPanel();
    if (saveWizIsOpen()) renderSaveWizard();
}

// A message is required, and "what do I write here?" is the step that stops the
// target user. Prefill something honest and editable rather than an empty box.
function suggestSaveMessage(files, count) {
    const n = Number(count || files.length || 0);
    if (n === 0) return '';
    if (n === 1 && files.length) {
        const f = files[0];
        const name = splitRelPath(f.rel).name;
        if (f.status === 'untracked' || f.status === 'added') return 'Add ' + name;
        if (f.status === 'deleted') return 'Delete ' + name;
        if (f.status === 'renamed') return 'Rename ' + name;
        return 'Update ' + name;
    }
    return 'Update ' + n + ' files';
}

function renderSaveWizard() {
    const body = $('save-body');
    const foot = $('save-foot');
    if (!body || !foot) return;
    body.innerHTML = '';
    foot.innerHTML = '';

    if (saveWiz.busy) {
        body.innerHTML = '<div class="merge-busy"><span class="merge-spinner"></span> Saving…</div>';
        return;
    }

    if (saveWiz.error) {
        const err = el('merge-error');
        err.textContent = '⚠ ' + saveWiz.error;
        body.appendChild(err);
    }

    if (!saveWiz.loaded) {
        const loading = el('muted tiny merge-msg');
        loading.textContent = 'Looking at what changed…';
        body.appendChild(loading);
        foot.appendChild(branchWizBtn('Close', '', closeSaveWizard));
        return;
    }

    const intro = el('merge-msg');
    intro.textContent = 'Saving records every changed file in this project\u2019s history, all in one entry. ' +
        'Nothing is sent anywhere \u2014 use Branches \u2192 Send to server for that.';
    body.appendChild(intro);

    if (!gitChanges.has) {
        const none = el('muted tiny merge-msg');
        none.textContent = 'Nothing can be saved here \u2014 this project is not a Git repository, or Git is not available.';
        body.appendChild(none);
        foot.appendChild(branchWizBtn('Close', '', closeSaveWizard));
        return;
    }

    if (!saveWiz.fileCount) {
        const none = el('muted tiny merge-msg');
        none.textContent = 'Nothing has changed since the last save.';
        body.appendChild(none);
        foot.appendChild(branchWizBtn('Close', '', closeSaveWizard));
        return;
    }

    const head = el('save-summary');
    head.innerHTML =
        `<span class="save-count">${saveWiz.fileCount} file${saveWiz.fileCount === 1 ? '' : 's'} will be saved</span>` +
        `<span class="changes-stat changes-add">+${escapeHtml(String(saveWiz.added))}</span>` +
        `<span class="changes-stat changes-del">\u2212${escapeHtml(String(saveWiz.deleted))}</span>`;
    body.appendChild(head);

    const list = el('save-list');
    const shown = saveWiz.files.slice(0, SAVE_LIST_LIMIT);
    for (const f of shown) list.appendChild(buildSaveRow(f));
    body.appendChild(list);
    if (saveWiz.fileCount > shown.length) {
        const more = el('muted tiny');
        more.textContent = `\u2026and ${saveWiz.fileCount - shown.length} more.`;
        body.appendChild(more);
    }

    const field = el('branch-field');
    const label = document.createElement('label');
    label.setAttribute('for', 'save-message');
    label.textContent = 'Describe what you changed';
    const row = el('save-message-row');
    const input = document.createElement('input');
    input.id = 'save-message';
    input.className = 'branch-input';
    input.type = 'text';
    input.autocomplete = 'off';
    input.value = saveWiz.message;
    input.placeholder = 'e.g. Update the quarterly report';
    input.oninput = () => { saveWiz.message = input.value; };
    input.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); runSave(); } };
    const suggest = document.createElement('button');
    suggest.id = 'save-suggest';
    suggest.className = 'icon-btn save-suggest';
    suggest.type = 'button';
    suggest.textContent = '\u2728';
    suggest.title = 'Let DeskPilot read the changes and describe them for you';
    suggest.setAttribute('aria-label', 'Suggest a description');
    suggest.onclick = () => suggestSaveMessageFromModel();
    row.append(input, suggest);
    const hint = el('muted tiny', 'p');
    hint.textContent = 'A short sentence so you can recognise this save later \u2014 or use \u2728 to have DeskPilot write it.';
    field.append(label, row, hint);
    body.appendChild(field);

    foot.appendChild(branchWizBtn('Cancel', '', closeSaveWizard));
    foot.appendChild(branchWizBtn('Review changes\u2026', '', () => { closeSaveWizard(); openRepoChanges(); }));
    foot.appendChild(branchWizBtn('Save all changes', 'btn-primary', () => runSave()));
    setTimeout(() => { const box = $('save-message'); if (box) { box.focus(); box.select(); } }, 0);
}

// The description is where the target user stalls, so the sparkle asks the Model
// to read the change set and write it. Explicit click only: it costs a Turn.
async function suggestSaveMessageFromModel() {
    const btn = $('save-suggest');
    const box = $('save-message');
    if (!btn || !box) return;
    const label = btn.textContent;
    btn.disabled = true;
    btn.textContent = '\u22ef';
    btn.title = 'Reading your changes…';
    try {
        const r = await api('POST', '/api/git/commit/message', {});
        if (r && r.message) {
            saveWiz.message = r.message;
            box.value = r.message;
            box.focus();
            box.select();
        }
    } catch (e) { toast(e.message); }
    finally {
        btn.disabled = false;
        btn.textContent = label;
        btn.title = 'Let DeskPilot read the changes and describe them for you';
    }
}

function buildSaveRow(f) {
    const parts = splitRelPath(f.rel);
    const row = el('save-row');
    row.title = statusLabel(f.status) + ' \u2014 ' + f.rel;
    row.innerHTML =
        `<span class="changes-badge st-${escapeHtml(f.status || 'modified')}">${escapeHtml(statusGlyph(f.status))}</span>` +
        `<span class="changes-name">${escapeHtml(parts.name)}</span>` +
        `<span class="changes-dir muted tiny">${escapeHtml(parts.dir)}</span>` +
        (f.binary
            ? '<span class="changes-stat muted tiny">binary</span>'
            : `<span class="changes-stat changes-add">${f.added ? '+' + escapeHtml(String(f.added)) : ''}</span>` +
              `<span class="changes-stat changes-del">${f.deleted ? '\u2212' + escapeHtml(String(f.deleted)) : ''}</span>`);
    return row;
}

async function runSave() {
    const message = String(saveWiz.message || '').trim();
    if (!message) { saveWiz.error = 'Write a short description first.'; renderSaveWizard(); return; }
    saveWiz.busy = true;
    saveWiz.error = '';
    renderSaveWizard();
    let result = null;
    try { result = await api('POST', '/api/git/commit', { message }); }
    catch (e) { saveWiz.error = e.message; }
    saveWiz.busy = false;
    if (saveWiz.error) { renderSaveWizard(); return; }

    if (result && result.nothingToCommit) {
        saveWiz.error = 'Nothing had changed, so nothing was saved.';
        await loadSaveWizard();
        return;
    }
    const n = (result && result.files && result.files.length) || 0;
    const where = result && result.shortSha ? ' as ' + result.shortSha : '';
    toast(`Saved ${n} file${n === 1 ? '' : 's'}${where}.`);
    closeSaveWizard();
    await afterChangeDecision();
}

async function gitInit() {
    try {
        await api('POST', '/api/git/init');
        toast('Initialized a Git repository.');
        refreshExplorer();
    } catch (e) { toast(e.message); }
}

async function switchBranch(branch) {
    try {
        await api('POST', '/api/git/checkout', { branch });
        toast('Switched to ' + branch + '.');
        refreshExplorer();
    } catch (e) { toast(e.message); refreshGitBar(); }
}

// ===== Branch Wizard =====
// One guided place for everything a non-expert does with branches: see where
// they are, create a branch, switch, delete, merge, and sync with the server.
// Git vocabulary is translated at the surface ("get"/"send" rather than
// pull/push) while the underlying operations stay ordinary git.
const branchWiz = {
    step: 'home', branches: null, defaultBranch: '', sync: null,
    busyLabel: '', target: '', conflict: null, deleteTarget: null, error: '',
};

function openBranchWizard() {
    branchWiz.step = 'home';
    branchWiz.branches = null;
    branchWiz.defaultBranch = '';
    branchWiz.sync = null;
    branchWiz.conflict = null;
    branchWiz.deleteTarget = null;
    branchWiz.error = '';
    $('branch-backdrop').classList.remove('hidden');
    $('branch-modal').classList.remove('hidden');
    renderBranchWizard();
    branchWizLoad();
}

function closeBranchWizard() {
    $('branch-backdrop').classList.add('hidden');
    $('branch-modal').classList.add('hidden');
    refreshGitBar();
}

async function branchWizLoad() {
    try {
        const [branches, sync] = await Promise.all([
            api('GET', '/api/git/branches?fetch=1'),
            api('GET', '/api/git/sync/status'),
        ]);
        branchWiz.branches = branches.branches || [];
        branchWiz.defaultBranch = branches.defaultBranch || '';
        branchWiz.sync = sync;
        // A conflict left behind by a merge or a sync is the most urgent thing
        // in the repository; surface it before anything else.
        if (sync && sync.inMerge && (sync.conflictFiles || []).length && branchWiz.step === 'home') {
            branchWizGoConflict();
            return;
        }
    } catch (e) {
        branchWiz.error = e.message;
        branchWiz.branches = branchWiz.branches || [];
    }
    renderBranchWizard();
}

function renderBranchWizard() {
    const body = $('branch-body');
    const foot = $('branch-foot');
    const title = $('branch-title');
    if (!body || !foot) return;
    body.innerHTML = '';
    foot.innerHTML = '';
    switch (branchWiz.step) {
        case 'home': renderBranchHome(body, foot, title); break;
        case 'create': renderBranchCreate(body, foot, title); break;
        case 'delete': renderBranchDelete(body, foot, title); break;
        case 'conflict': renderBranchConflict(body, foot, title); break;
        case 'busy':
            title.textContent = 'Working';
            body.innerHTML = `<div class="merge-busy"><span class="merge-spinner"></span> ${escapeHtml(branchWiz.busyLabel)}</div>`;
            break;
        default: body.textContent = '';
    }
}

function branchWizBtn(label, cls, onclick, disabled) {
    const b = document.createElement('button');
    b.className = 'btn ' + (cls || '');
    b.type = 'button';
    b.textContent = label;
    if (disabled) b.disabled = true;
    if (onclick) b.onclick = onclick;
    return b;
}

function renderBranchHome(body, foot, title) {
    title.textContent = 'Branches';
    if (branchWiz.error) {
        const err = el('merge-error');
        err.textContent = '⚠ ' + branchWiz.error;
        body.appendChild(err);
    }
    if (!branchWiz.branches) {
        const loading = el('muted tiny merge-msg');
        loading.textContent = 'Loading branches…';
        body.appendChild(loading);
        foot.appendChild(branchWizBtn('Close', '', closeBranchWizard));
        return;
    }

    body.appendChild(buildSyncPanel());

    const def = branchWiz.defaultBranch || '';
    const intro = el('branch-intro muted tiny');
    intro.textContent = 'A branch is a separate line of work. Changes on one branch do not affect another until you merge them.';
    body.appendChild(intro);

    const list = el('branch-list');
    for (const b of branchWiz.branches) list.appendChild(buildBranchRow(b, def));
    if (!branchWiz.branches.length) {
        const empty = el('muted tiny merge-msg');
        empty.textContent = 'No branches yet.';
        list.appendChild(empty);
    }
    body.appendChild(list);

    const legend = el('branch-legend muted tiny');
    legend.textContent = gitLegendText(def);
    body.appendChild(legend);

    foot.appendChild(branchWizBtn('Close', '', closeBranchWizard));
    foot.appendChild(branchWizBtn('New branch…', '', () => { branchWiz.step = 'create'; renderBranchWizard(); }));
    foot.appendChild(branchWizBtn('Merge a branch…', 'btn-primary', () => { closeBranchWizard(); openMergeWizard(); }));
}

function buildSyncPanel() {
    const s = branchWiz.sync || {};
    const panel = el('branch-sync');
    const where = el('branch-sync-where');
    where.innerHTML = s.detached
        ? '<strong>Not on a branch</strong> <span class="muted tiny">(detached) — switch to a branch to work normally.</span>'
        : `You are on <strong>${escapeHtml(s.branch || '—')}</strong>`;
    panel.appendChild(where);

    const state_ = el('branch-sync-state muted tiny');
    if (!s.hasRemote) {
        state_.textContent = 'This project has no server (remote), so there is nothing to sync with.';
    } else if (!s.hasUpstream) {
        state_.textContent = s.ahead
            ? `${s.ahead} save${s.ahead === 1 ? '' : 's'} on this branch have never been sent to the server.`
            : 'This branch is not on the server yet.';
    } else {
        const bits = [];
        if (s.ahead) bits.push(`${s.ahead} to send`);
        if (s.behind) bits.push(`${s.behind} to get`);
        state_.textContent = bits.length ? bits.join(' · ') + ` (server: ${s.upstream})` : `Up to date with ${s.upstream}.`;
    }
    panel.appendChild(state_);

    if (s.dirty) {
        const dirty = el('branch-sync-dirty muted tiny');
        dirty.textContent = `${s.changeCount} unsaved change${s.changeCount === 1 ? '' : 's'} in your files. Save them to put them in this branch\u2019s history, or review them first.`;
        panel.appendChild(dirty);
    }

    const acts = el('branch-sync-acts');
    if (s.hasRemote) {
        acts.appendChild(branchWizBtn('Sync', 'btn-small btn-primary', () => branchWizSync('sync'), !!s.detached));
        acts.appendChild(branchWizBtn('Get from server', 'btn-small', () => branchWizSync('pull'), !!s.detached));
        acts.appendChild(branchWizBtn('Send to server', 'btn-small', () => branchWizSync('push'), !!s.detached));
    }
    if (s.dirty) {
        acts.appendChild(branchWizBtn('Save all changes…', 'btn-small', () => { closeBranchWizard(); openSaveWizard(); }));
        acts.appendChild(branchWizBtn('Review changes…', 'btn-small', () => { closeBranchWizard(); openRepoChanges(); }));
    }
    if (acts.children.length) panel.appendChild(acts);
    return panel;
}

function buildBranchRow(b, def) {
    const row = el('branch-row');
    const badgeCls = b.merged === true ? 'is-merged' : (b.merged === false ? 'is-unmerged' : 'is-unknown');
    const badgeCh = b.merged === true ? '\u2713' : (b.merged === false ? '\u2757' : '\u2022');
    row.innerHTML =
        `<span class="merge-badge ${badgeCls}" title="${escapeHtml(branchTitle(b, def))}">${badgeCh}</span>` +
        `<span class="branch-name">${escapeHtml(b.display)}</span>` +
        (b.isCurrent ? '<span class="merge-tag muted tiny">current</span>' : '') +
        (b.isDefault ? '<span class="merge-tag muted tiny">main</span>' : '') +
        (b.isRemote ? '<span class="merge-tag muted tiny">server only</span>' : '');
    const acts = el('branch-row-acts');
    if (!b.isCurrent && !b.isRemote) {
        acts.appendChild(branchWizBtn('Switch', 'btn-small', () => branchWizSwitch(b.name)));
    }
    if (!b.isDefault && !b.isRemote) {
        acts.appendChild(branchWizBtn('Delete', 'btn-small', () => {
            branchWiz.deleteTarget = b;
            branchWiz.step = 'delete';
            renderBranchWizard();
        }, !!b.isCurrent && !branchWiz.defaultBranch));
    }
    row.appendChild(acts);
    return row;
}

async function branchWizSwitch(name) {
    branchWiz.busyLabel = 'Switching branch…';
    branchWiz.step = 'busy';
    renderBranchWizard();
    try {
        await api('POST', '/api/git/checkout', { branch: name });
        toast('Switched to ' + name + '.');
        refreshExplorer();
    } catch (e) { toast(e.message); }
    branchWiz.step = 'home';
    await branchWizLoad();
}

function renderBranchCreate(body, foot, title) {
    title.textContent = 'New branch';
    const def = branchWiz.defaultBranch || 'main';
    const current = (branchWiz.sync && branchWiz.sync.branch) || def;
    const intro = el('merge-msg');
    intro.innerHTML = 'A new branch starts as a copy of an existing one. Work on it freely — nothing changes on the other branch until you merge.';
    body.appendChild(intro);

    const field = el('branch-field');
    field.innerHTML =
        '<label for="branch-new-name">Name</label>' +
        '<input id="branch-new-name" class="branch-input" type="text" autocomplete="off" spellcheck="false" placeholder="e.g. draft-report" />' +
        '<p class="muted tiny">Letters, digits, dashes and slashes. No spaces.</p>';
    body.appendChild(field);

    const from = el('branch-field');
    const options = [];
    const names = new Set();
    for (const b of (branchWiz.branches || [])) {
        if (b.isRemote || names.has(b.name)) continue;
        names.add(b.name);
        options.push(`<option value="${escapeHtml(b.name)}"${b.name === current ? ' selected' : ''}>${escapeHtml(b.name)}${b.isDefault ? ' (main)' : ''}${b.isCurrent ? ' — where you are now' : ''}</option>`);
    }
    from.innerHTML =
        '<label for="branch-new-from">Start from</label>' +
        `<select id="branch-new-from" class="branch-input">${options.join('')}</select>`;
    body.appendChild(from);

    const opt = el('merge-clean-opt', 'label');
    opt.innerHTML = '<input type="checkbox" id="branch-new-switch" checked> Switch to the new branch right away';
    body.appendChild(opt);

    foot.appendChild(branchWizBtn('Back', '', () => { branchWiz.step = 'home'; renderBranchWizard(); }));
    foot.appendChild(branchWizBtn('Create', 'btn-primary', branchWizCreate));
    setTimeout(() => { const input = $('branch-new-name'); if (input) input.focus(); }, 0);
}

async function branchWizCreate() {
    const name = ($('branch-new-name') ? $('branch-new-name').value : '').trim();
    const from = $('branch-new-from') ? $('branch-new-from').value : '';
    const checkout = $('branch-new-switch') ? $('branch-new-switch').checked : true;
    if (!name) { toast('Give the branch a name.'); return; }
    branchWiz.busyLabel = 'Creating the branch…';
    branchWiz.step = 'busy';
    renderBranchWizard();
    try {
        const r = await api('POST', '/api/git/branch/create', { name, from, checkout });
        // The branch can be created while the switch fails (for example when an
        // uncommitted change would be overwritten); say so rather than claiming
        // an unqualified success.
        if (r.error) toast(r.error);
        else toast(r.checkedOut ? `Created ${r.name} and switched to it.` : `Created ${r.name}.`);
        refreshExplorer();
    } catch (e) {
        toast(e.message);
        branchWiz.step = 'create';
        renderBranchWizard();
        return;
    }
    branchWiz.step = 'home';
    await branchWizLoad();
}

function renderBranchDelete(body, foot, title) {
    title.textContent = 'Delete branch';
    const b = branchWiz.deleteTarget || {};
    const def = escapeHtml(branchWiz.defaultBranch || 'main');
    const name = escapeHtml(b.display || b.name);
    const warn = el(b.merged === true ? 'merge-msg' : 'merge-precond');
    warn.innerHTML = b.merged === true
        ? `<strong>${name}</strong> is already merged into <strong>${def}</strong>, so deleting it loses nothing.`
        : b.merged === false
            ? `<strong>${name}</strong> has commits that are <strong>not</strong> in ${def}. Deleting it throws that work away.`
            : `DeskPilot could not tell whether <strong>${name}</strong> is merged into ${def}. It will try the safe delete first and ask again if Git objects.`;
    body.appendChild(warn);

    if (branchWiz.sync && branchWiz.sync.hasRemote) {
        const opt = el('merge-clean-opt', 'label');
        opt.innerHTML = '<input type="checkbox" id="branch-del-remote"> Also delete it on the server <span class="muted tiny">(affects everyone using this repository)</span>';
        body.appendChild(opt);
    }

    foot.appendChild(branchWizBtn('Back', '', () => { branchWiz.step = 'home'; renderBranchWizard(); }));
    foot.appendChild(branchWizBtn('Delete', 'btn-primary', () => branchWizDelete(false)));
}

// Always attempt the safe delete first. Git's own refusal of an unmerged branch
// — surfaced as 409 — is the only trustworthy signal, so the force is offered
// there rather than guessed from a merged flag that can be unknown.
async function branchWizDelete(force) {
    const b = branchWiz.deleteTarget || {};
    const remote = $('branch-del-remote') ? $('branch-del-remote').checked : false;
    if (remote && !window.confirm(`Also delete ${b.name} on the server? Everyone using this repository loses that branch.`)) return;
    branchWiz.busyLabel = 'Deleting the branch…';
    branchWiz.step = 'busy';
    renderBranchWizard();
    try {
        const r = await api('POST', '/api/git/branch/delete', { name: b.name, force: !!force, deleteRemote: remote });
        const bits = [];
        if (r.deleted) bits.push('deleted locally');
        if (r.remoteDeleted) bits.push('deleted on the server');
        if (r.remoteError) bits.push('server delete failed: ' + r.remoteError);
        toast(bits.length ? b.name + ' — ' + bits.join(', ') + '.' : 'Nothing to delete.');
        refreshExplorer();
    } catch (e) {
        if (e.status === 409 && !force) {
            branchWiz.step = 'delete';
            renderBranchWizard();
            if (window.confirm(e.message + '\n\nDelete it anyway and lose those commits?')) {
                await branchWizDelete(true);
            }
            return;
        }
        toast(e.message);
    }
    branchWiz.step = 'home';
    await branchWizLoad();
}

async function branchWizSync(action) {
    const labels = { sync: 'Syncing with the server…', pull: 'Getting the server\u2019s changes…', push: 'Sending your changes…' };
    branchWiz.busyLabel = labels[action] || 'Working…';
    branchWiz.step = 'busy';
    renderBranchWizard();
    let r;
    try { r = await api('POST', '/api/git/sync', { action, autostash: false }); }
    catch (e) { toast(e.message); branchWiz.step = 'home'; await branchWizLoad(); return; }

    if (r.status === 'blocked' && (r.reasons || []).includes('dirty')) {
        branchWiz.step = 'home';
        renderBranchWizard();
        if (window.confirm('You have unsaved changes.\n\nDeskPilot can set them aside, sync, and put them back. Continue?')) {
            branchWiz.busyLabel = branchWiz.busyLabel || 'Syncing…';
            branchWiz.step = 'busy';
            renderBranchWizard();
            try { r = await api('POST', '/api/git/sync', { action, autostash: true }); }
            catch (e) { toast(e.message); branchWiz.step = 'home'; await branchWizLoad(); return; }
        } else {
            await branchWizLoad();
            return;
        }
    }

    if (r.status === 'conflict') {
        branchWiz.target = r.upstream || 'the server';
        branchWizGoConflict();
        return;
    }
    if (r.status === 'blocked' || r.status === 'error') {
        toast(r.error || 'The sync could not run.');
        branchWiz.step = 'home';
        await branchWizLoad();
        return;
    }
    const bits = [];
    if (r.pulled) bits.push(r.fastForward ? 'got the server\u2019s changes' : 'merged the server\u2019s changes');
    if (r.published) bits.push('published this branch');
    else if (r.pushed) bits.push('sent your changes');
    if (r.stashPopConflict) bits.push('your set-aside changes need attention');
    toast(bits.length ? 'Sync: ' + bits.join(', ') + '.' : 'Already up to date.');
    refreshExplorer();
    branchWiz.step = 'home';
    await branchWizLoad();
}

// A conflict is where a non-expert gets stuck, so DeskPilot prepares the exact
// prompt that gets the agent to fix it. Nothing is sent until the user says so.
async function branchWizGoConflict() {
    branchWiz.step = 'busy';
    branchWiz.busyLabel = 'Preparing a fix…';
    renderBranchWizard();
    try {
        branchWiz.conflict = await api('GET', '/api/git/conflict/prompt?branch=' + encodeURIComponent(branchWiz.target || ''));
    } catch (e) {
        toast(e.message);
        branchWiz.step = 'home';
        await branchWizLoad();
        return;
    }
    branchWiz.step = 'conflict';
    renderBranchWizard();
}

function renderBranchConflict(body, foot, title) {
    title.textContent = 'Conflicting changes';
    const c = branchWiz.conflict || {};
    const files = c.files || [];
    const intro = el('merge-precond');
    intro.innerHTML =
        `<strong>The same lines were changed in two places</strong>, so Git cannot decide on its own. ` +
        `${files.length} file${files.length === 1 ? '' : 's'} need${files.length === 1 ? 's' : ''} a decision.`;
    body.appendChild(intro);

    const list = el('merge-file-list', 'ul');
    for (const f of files) {
        const li = document.createElement('li');
        li.textContent = f;
        list.appendChild(li);
    }
    body.appendChild(list);

    const hint = el('muted tiny merge-msg');
    hint.textContent = 'DeskPilot has written a prompt that asks the agent to resolve these conflicts. Review it, edit it if you like, then send it.';
    body.appendChild(hint);

    const box = document.createElement('textarea');
    box.id = 'branch-conflict-prompt';
    box.className = 'branch-prompt';
    box.rows = 10;
    box.spellcheck = false;
    box.value = c.prompt || '';
    body.appendChild(box);

    foot.appendChild(branchWizBtn('Copy', '', () => {
        const text = ($('branch-conflict-prompt') || {}).value || '';
        navigator.clipboard.writeText(text).then(() => toast('Prompt copied.'), () => toast('Could not copy.'));
    }));
    foot.appendChild(branchWizBtn('Abort the merge', '', branchWizAbortMerge));
    foot.appendChild(branchWizBtn('Ask DeskPilot to fix it', 'btn-primary', branchWizSendConflictPrompt));
}

function branchWizSendConflictPrompt() {
    const text = ($('branch-conflict-prompt') || {}).value || '';
    if (!text.trim()) { toast('The prompt is empty.'); return; }
    closeBranchWizard();
    const promptEl = $('prompt');
    promptEl.value = text;
    autoGrow(promptEl);
    setSendEnabled(true);
    promptEl.focus();
    send();
}

async function branchWizAbortMerge() {
    if (!window.confirm('Abort the merge and put the files back the way they were before it started?')) return;
    branchWiz.busyLabel = 'Aborting the merge…';
    branchWiz.step = 'busy';
    renderBranchWizard();
    try { await api('POST', '/api/git/merge/abort', {}); toast('Merge aborted.'); }
    catch (e) { toast(e.message); }
    refreshExplorer();
    branchWiz.step = 'home';
    branchWiz.conflict = null;
    await branchWizLoad();
}

// ===== Merge Wizard =====
// A step machine that walks a non-expert through merging a branch into the
// default branch: choose -> preview -> merge -> (conflict -> AI plan) -> result
// -> cleanup -> done. Each step re-renders the modal body + foot.
const merge = {
    step: '', branch: '', branches: [], defaultBranch: '',
    preview: null, autofix: false, result: null, plan: null,
    binaryChoices: {}, applyResult: null, preMergeSha: '',
};

function openMergeWizard(branch) {
    merge.step = 'choose';
    merge.branch = branch || '';
    merge.branches = []; merge.defaultBranch = '';
    merge.preview = null; merge.autofix = false; merge.result = null;
    merge.plan = null; merge.binaryChoices = {}; merge.applyResult = null;
    merge.preMergeSha = '';
    $('merge-backdrop').classList.remove('hidden');
    $('merge-modal').classList.remove('hidden');
    renderMerge();
    if (merge.branch) mergeGoPreview(merge.branch);
    else mergeLoadBranches();
}

function closeMergeWizard() {
    if (merge.step === 'conflict' || merge.step === 'plan') {
        if (!window.confirm('A merge is in progress with unresolved conflicts. Leave it open in the repository? You can choose “Abort the merge” instead to undo it cleanly.')) return;
    }
    $('merge-backdrop').classList.add('hidden');
    $('merge-modal').classList.add('hidden');
}

function mergeBtnEl(label, cls, onclick, disabled) {
    const b = document.createElement('button');
    b.className = 'btn ' + (cls || '');
    b.textContent = label;
    if (disabled) b.disabled = true;
    if (onclick) b.onclick = onclick;
    return b;
}

function renderMerge() {
    const body = $('merge-body');
    const foot = $('merge-foot');
    const title = $('merge-title');
    if (!body || !foot) return;
    body.innerHTML = ''; foot.innerHTML = '';
    switch (merge.step) {
        case 'choose': renderMergeChoose(body, foot, title); break;
        case 'preview': renderMergePreview(body, foot, title); break;
        case 'merging': renderMergeBusy(body, foot, title, 'Merging…'); break;
        case 'blocked': renderMergeBlocked(body, foot, title); break;
        case 'conflict': renderMergeConflict(body, foot, title); break;
        case 'planning': renderMergeBusy(body, foot, title, 'Asking the AI for a merge plan…'); break;
        case 'plan': renderMergePlan(body, foot, title); break;
        case 'applying': renderMergeBusy(body, foot, title, 'Completing the merge…'); break;
        case 'result': renderMergeResult(body, foot, title); break;
        case 'cleanup': renderMergeCleanup(body, foot, title); break;
        case 'done': renderMergeDone(body, foot, title); break;
        default: body.textContent = '';
    }
}

function renderMergeBusy(body, foot, title, label) {
    title.textContent = label.replace(/…$/, '');
    body.innerHTML = `<div class="merge-busy"><span class="merge-spinner"></span> ${escapeHtml(label)}</div>`;
}

async function mergeLoadBranches() {
    try {
        // Fetch from the remote so merged status is accurate when choosing.
        const data = await api('GET', '/api/git/branches?fetch=1');
        merge.branches = data.branches || [];
        merge.defaultBranch = data.defaultBranch || '';
    } catch (e) { toast(e.message); merge.branches = []; }
    if (merge.step === 'choose') renderMerge();
}

function renderMergeChoose(body, foot, title) {
    title.textContent = 'Merge a branch';
    if (!merge.branches.length && !merge.defaultBranch) {
        body.innerHTML = '<div class="muted tiny merge-msg">Loading branches…</div>';
        foot.appendChild(mergeBtnEl('Close', '', closeMergeWizard));
        return;
    }
    const def = merge.defaultBranch || 'main';
    const candidates = merge.branches.filter((b) => !b.isDefault && b.name !== def);
    if (!candidates.length) {
        body.innerHTML = `<div class="merge-msg">There are no other branches to merge into <strong>${escapeHtml(def)}</strong>.</div>`;
        foot.appendChild(mergeBtnEl('Close', '', closeMergeWizard));
        return;
    }
    const intro = el('merge-intro');
    intro.innerHTML = `Choose a branch to merge into <strong>${escapeHtml(def)}</strong>:`;
    body.appendChild(intro);
    const list = el('merge-branch-list');
    for (const b of candidates) {
        const badgeCls = b.merged === true ? 'is-merged' : (b.merged === false ? 'is-unmerged' : 'is-unknown');
        const badgeCh = b.merged === true ? '\u2713' : (b.merged === false ? '\u2757' : '\u2022');
        const row = document.createElement('button');
        row.className = 'merge-branch-row';
        row.innerHTML =
            `<span class="merge-badge ${badgeCls}" title="${escapeHtml(branchTitle(b, def))}">${badgeCh}</span>` +
            `<span class="merge-branch-name">${escapeHtml(b.display)}</span>` +
            (b.isCurrent ? '<span class="merge-tag muted tiny">current</span>' : '') +
            (b.isRemote ? '<span class="merge-tag muted tiny">remote</span>' : '') +
            (b.merged === true ? '<span class="merge-tag muted tiny">merged</span>' : '');
        row.onclick = () => mergeGoPreview(b.name);
        list.appendChild(row);
    }
    body.appendChild(list);
    foot.appendChild(mergeBtnEl('Close', '', closeMergeWizard));
}

async function mergeGoPreview(branch) {
    merge.branch = branch;
    merge.step = 'preview';
    merge.preview = null;
    renderMerge();
    try { merge.preview = await api('GET', '/api/git/merge/preview?branch=' + encodeURIComponent(branch)); }
    catch (e) { merge.preview = { error: e.message }; }
    if (merge.preview && merge.preview.defaultBranch) merge.defaultBranch = merge.preview.defaultBranch;
    renderMerge();
}

function renderMergePreview(body, foot, title) {
    title.textContent = 'Review the merge';
    const p = merge.preview;
    if (!p) {
        body.innerHTML = '<div class="muted tiny merge-msg">Loading preview…</div>';
        foot.appendChild(mergeBtnEl('Cancel', '', () => mergeBackToChoose()));
        return;
    }
    if (p.error) {
        body.innerHTML = `<div class="merge-error">⚠ ${escapeHtml(p.error)}</div>`;
        foot.appendChild(mergeBtnEl('Back', '', () => mergeBackToChoose()));
        return;
    }
    const def = p.defaultBranch || merge.defaultBranch || 'main';
    if (p.alreadyMerged) {
        body.innerHTML = `<div class="merge-ok">\u2713 <strong>${escapeHtml(merge.branch)}</strong> is already merged into <strong>${escapeHtml(def)}</strong>. There is nothing to merge — you can clean it up.</div>`;
        foot.appendChild(mergeBtnEl('Cancel', '', closeMergeWizard));
        foot.appendChild(mergeBtnEl('Clean up the branch', 'btn-primary', () => mergeGoCleanup()));
        return;
    }
    const head = el('merge-summary');
    head.innerHTML =
        `Merging <strong>${escapeHtml(merge.branch)}</strong> → <strong>${escapeHtml(def)}</strong> &nbsp;·&nbsp; ` +
        `${p.commitCount} commit${p.commitCount === 1 ? '' : 's'}${p.truncated ? '+' : ''} &nbsp;·&nbsp; ` +
        (p.fastForward ? 'fast-forward' : 'creates a merge commit');
    body.appendChild(head);

    if (p.dirty || p.behind) {
        const warn = el('merge-precond');
        let msg = '<strong>Before merging:</strong><ul>';
        if (p.dirty) msg += '<li>You have uncommitted changes in your working folder.</li>';
        if (p.behind) msg += `<li><strong>${escapeHtml(def)}</strong> is ${p.behindCount} commit${p.behindCount === 1 ? '' : 's'} behind the server.</li>`;
        msg += '</ul>';
        warn.innerHTML = msg;
        const lbl = el('merge-autofix', 'label');
        lbl.innerHTML = `<input type="checkbox" id="merge-autofix-cb"> Fix this for me (stash my changes${p.behind ? ', update ' + escapeHtml(def) + ' from the server' : ''}, then merge)`;
        warn.appendChild(lbl);
        body.appendChild(warn);
    }

    const list = el('merge-commits');
    for (const c of (p.commits || [])) {
        const row = el('merge-commit');
        row.innerHTML = `<span class="merge-sha">${escapeHtml(c.shortSha)}</span><span class="merge-cmsg">${escapeHtml(c.subject)}</span><span class="muted tiny">${escapeHtml(c.author)}</span>`;
        list.appendChild(row);
    }
    if (p.truncated) { const m = el('muted tiny'); m.textContent = '…and more.'; list.appendChild(m); }
    body.appendChild(list);

    foot.appendChild(mergeBtnEl('Cancel', '', closeMergeWizard));
    foot.appendChild(mergeBtnEl('Merge', 'btn-primary', () => {
        const cb = $('merge-autofix-cb');
        merge.autofix = !!(cb && cb.checked);
        if ((p.dirty || p.behind) && !merge.autofix) { toast('Tick “Fix this for me”, or commit your changes first.'); return; }
        mergeDoMerge();
    }));
}

function mergeBackToChoose() {
    merge.step = 'choose';
    renderMerge();
    if (!merge.branches.length) mergeLoadBranches();
}

async function mergeDoMerge() {
    merge.step = 'merging';
    renderMerge();
    let r;
    try { r = await api('POST', '/api/git/merge', { branch: merge.branch, autofix: merge.autofix }); }
    catch (e) { toast(e.message); merge.step = 'preview'; renderMerge(); return; }
    merge.result = r;
    if (r.preMergeSha) merge.preMergeSha = r.preMergeSha;
    if (r.status === 'success' || r.status === 'already-merged') merge.step = 'result';
    else if (r.status === 'conflict') merge.step = 'conflict';
    else if (r.status === 'blocked') merge.step = 'blocked';
    else { toast(r.error || 'Merge failed.'); merge.step = 'preview'; }
    renderMerge();
    if (merge.step === 'result') refreshExplorer();
}

function renderMergeBlocked(body, foot, title) {
    title.textContent = 'Action needed';
    const r = merge.result || {};
    const reasons = r.reasons || [];
    let msg = '<div class="merge-precond"><strong>The merge can’t run yet:</strong><ul>';
    if (reasons.includes('dirty')) msg += '<li>You have uncommitted changes.</li>';
    if (reasons.includes('behind')) msg += `<li><strong>${escapeHtml(r.defaultBranch || 'main')}</strong> is behind the server.</li>`;
    if (reasons.includes('pull-diverged')) msg += '<li>Your branch and the server have diverged; resolve that first.</li>';
    if (reasons.includes('conflict-with-local-changes')) msg += '<li>The merge conflicts <em>and</em> you have uncommitted changes. Commit or discard them, then merge again.</li>';
    msg += '</ul></div>';
    if (r.error) msg += `<div class="muted tiny">${escapeHtml(r.error)}</div>`;
    body.innerHTML = msg;
    foot.appendChild(mergeBtnEl('Cancel', '', closeMergeWizard));
    if (reasons.includes('dirty') || reasons.includes('behind')) {
        foot.appendChild(mergeBtnEl('Fix it for me & merge', 'btn-primary', () => { merge.autofix = true; mergeDoMerge(); }));
    } else {
        foot.appendChild(mergeBtnEl('Back', '', () => mergeGoPreview(merge.branch)));
    }
}

function renderMergeConflict(body, foot, title) {
    title.textContent = 'Merge conflicts';
    const files = (merge.result && merge.result.conflictFiles) || [];
    let msg = `<div class="merge-msg">The merge has conflicts in ${files.length} file${files.length === 1 ? '' : 's'}. DeskPilot can ask the AI to propose a fix, which you’ll review before anything is saved.</div><ul class="merge-file-list">`;
    for (const f of files) msg += `<li>${escapeHtml(f)}</li>`;
    msg += '</ul>';
    body.innerHTML = msg;
    foot.appendChild(mergeBtnEl('Abort the merge', '', mergeAbort));
    foot.appendChild(mergeBtnEl('Ask the AI for a fix', 'btn-primary', mergeAskAI));
}

async function mergeAskAI() {
    merge.step = 'planning';
    renderMerge();
    let r;
    try { r = await api('POST', '/api/git/merge/plan', { branch: merge.branch }); }
    catch (e) { toast(e.message); merge.step = 'conflict'; renderMerge(); return; }
    merge.plan = r;
    merge.binaryChoices = {};
    for (const bf of (r.binaryFiles || [])) merge.binaryChoices[bf.rel] = 'theirs';
    merge.step = 'plan';
    renderMerge();
}

function renderMergePlan(body, foot, title) {
    title.textContent = 'Review the AI’s merge plan';
    const plan = merge.plan || {};
    const res = (plan.plan && plan.plan.resolutions) || [];
    const planErr = plan.plan && plan.plan.error;
    const binary = plan.binaryFiles || [];

    if (planErr && !res.length && !binary.length) {
        body.innerHTML = `<div class="merge-error">⚠ ${escapeHtml(planErr)}</div>`;
        foot.appendChild(mergeBtnEl('Abort the merge', '', mergeAbort));
        foot.appendChild(mergeBtnEl('Try again', '', mergeAskAI));
        return;
    }
    if (plan.plan && plan.plan.notes) {
        const n = el('merge-plan-notes');
        n.textContent = '\u201c' + plan.plan.notes + '\u201d';
        body.appendChild(n);
    }
    for (const r of res) {
        const det = document.createElement('details');
        det.className = 'merge-res';
        const sum = document.createElement('summary');
        sum.innerHTML = `<span class="merge-res-path">${escapeHtml(r.path)}</span> <span class="muted tiny">resolved — click to preview</span>`;
        det.appendChild(sum);
        const pre = el('merge-res-body', 'pre');
        pre.textContent = r.content;
        det.appendChild(pre);
        body.appendChild(det);
    }
    if (binary.length) {
        const bh = el('merge-binary');
        bh.innerHTML = '<strong>Binary files</strong> — the AI can’t merge these. Pick which version to keep:';
        body.appendChild(bh);
        binary.forEach((bf, i) => {
            const cur = merge.binaryChoices[bf.rel] || 'theirs';
            const row = el('merge-binary-row');
            row.innerHTML =
                `<span class="merge-bin-path">${escapeHtml(bf.rel)}</span>` +
                `<label><input type="radio" name="merge-bin-${i}" value="ours" ${cur === 'ours' ? 'checked' : ''}> keep ${escapeHtml(merge.defaultBranch || 'main')} (ours)</label>` +
                `<label><input type="radio" name="merge-bin-${i}" value="theirs" ${cur === 'theirs' ? 'checked' : ''}> keep ${escapeHtml(merge.branch)} (theirs)</label>`;
            row.querySelectorAll('input[type=radio]').forEach((inp) => { inp.onchange = () => { merge.binaryChoices[bf.rel] = inp.value; }; });
            body.appendChild(row);
        });
    }
    if (!res.length && !binary.length) {
        body.innerHTML = '<div class="merge-error">⚠ The AI returned no resolutions. You can abort the merge.</div>';
        foot.appendChild(mergeBtnEl('Abort the merge', '', mergeAbort));
        foot.appendChild(mergeBtnEl('Try again', '', mergeAskAI));
        return;
    }
    foot.appendChild(mergeBtnEl('Abort the merge', '', mergeAbort));
    foot.appendChild(mergeBtnEl('Apply & complete the merge', 'btn-primary', mergeApply));
}

async function mergeApply() {
    const plan = merge.plan || {};
    const resolutions = (plan.plan && plan.plan.resolutions) || [];
    const binaryChoices = Object.keys(merge.binaryChoices).map((k) => ({ path: k, choice: merge.binaryChoices[k] }));
    merge.step = 'applying';
    renderMerge();
    let r;
    try { r = await api('POST', '/api/git/merge/apply', { resolutions, binaryChoices, popStash: !!(merge.result && merge.result.stashed) }); }
    catch (e) { toast(e.message); merge.step = 'plan'; renderMerge(); return; }
    merge.applyResult = r;
    merge.result = merge.result || {};
    if (r.mergedSha) { merge.result.mergedSha = r.mergedSha; merge.result.status = 'success'; merge.result.fastForward = false; }
    merge.step = 'result';
    renderMerge();
    refreshExplorer();
}

async function mergeAbort() {
    try { await api('POST', '/api/git/merge/abort', { popStash: !!(merge.result && merge.result.stashed) }); toast('Merge aborted.'); }
    catch (e) { toast(e.message); }
    $('merge-backdrop').classList.add('hidden');
    $('merge-modal').classList.add('hidden');
    refreshExplorer();
}

function renderMergeResult(body, foot, title) {
    title.textContent = 'Merged';
    const r = merge.result || {};
    const def = r.defaultBranch || merge.defaultBranch || 'main';
    const how = r.fastForward ? 'fast-forward' : 'merge commit';
    body.innerHTML =
        `<div class="merge-ok">\u2713 Merged <strong>${escapeHtml(merge.branch)}</strong> into <strong>${escapeHtml(def)}</strong>` +
        (r.mergedSha ? ` (${escapeHtml(String(r.mergedSha).slice(0, 7))}, ${how})` : '') + '.</div>' +
        (r.stashPopConflict ? '<div class="merge-precond">Your stashed changes could not be re-applied cleanly; resolve them in your editor.</div>' : '') +
        '<div class="muted tiny merge-msg">Clean up the branch now, or undo this merge.</div>';
    foot.appendChild(mergeBtnEl('Undo this merge', '', mergeUndo, !merge.preMergeSha));
    foot.appendChild(mergeBtnEl('Skip cleanup', '', () => { closeMergeWizard(); refreshExplorer(); }));
    foot.appendChild(mergeBtnEl('Clean up the branch', 'btn-primary', () => mergeGoCleanup()));
}

function mergeGoCleanup() { merge.step = 'cleanup'; renderMerge(); }

function renderMergeCleanup(body, foot, title) {
    title.textContent = 'Clean up the branch';
    const def = merge.defaultBranch || 'main';
    body.innerHTML =
        `<div class="merge-msg">The local branch <strong>${escapeHtml(merge.branch)}</strong> will be deleted (it’s merged into ${escapeHtml(def)}).</div>` +
        `<label class="merge-clean-opt"><input type="checkbox" id="merge-clean-remote"> Also push <strong>${escapeHtml(def)}</strong> to the server and delete the branch there <span class="muted tiny">(uses your Git sign-in; affects the shared remote)</span></label>`;
    foot.appendChild(mergeBtnEl('Not now', '', () => { closeMergeWizard(); refreshExplorer(); }));
    foot.appendChild(mergeBtnEl('Delete', 'btn-primary', mergeCleanup));
}

async function mergeCleanup() {
    const remote = $('merge-clean-remote') ? $('merge-clean-remote').checked : false;
    if (remote) {
        if (!window.confirm(`This will push ${merge.defaultBranch || 'main'} to the server and delete the branch there. It affects the shared remote and is hard to undo. Continue?`)) return;
    }
    merge.step = 'applying';
    renderMerge();
    try {
        const r = await api('POST', '/api/git/cleanup', { branch: merge.branch, deleteRemote: remote, pushDefaultBranch: remote });
        merge.applyResult = r;
        merge.step = 'done';
    } catch (e) { toast(e.message); merge.step = 'cleanup'; }
    renderMerge();
    refreshExplorer();
}

function renderMergeDone(body, foot, title) {
    title.textContent = 'Done';
    const r = merge.applyResult || {};
    let msg = '<div class="merge-ok">\u2713 Cleanup complete.</div><ul class="merge-clean-result">';
    if (r.localDeleted) msg += `<li>Deleted the local branch <strong>${escapeHtml(merge.branch)}</strong>.</li>`;
    else if (r.localSkipped) msg += '<li>No local branch to delete.</li>';
    else if (r.localError) msg += `<li class="merge-err-li">Could not delete the local branch: ${escapeHtml(r.localError)}</li>`;
    if (r.defaultPushed) msg += `<li>Pushed <strong>${escapeHtml(r.defaultBranch || 'main')}</strong> to the server.</li>`;
    else if (r.pushError) msg += `<li class="merge-err-li">Could not push: ${escapeHtml(r.pushError)}</li>`;
    if (r.remoteDeleted) msg += '<li>Deleted the branch on the server.</li>';
    else if (r.remoteError) msg += `<li class="merge-err-li">Could not delete on the server: ${escapeHtml(r.remoteError)}</li>`;
    msg += '</ul>';
    if (r.localError || r.pushError || r.remoteError) msg += '<div class="muted tiny">The local merge is safe; you can retry the remote steps later.</div>';
    body.innerHTML = msg;
    foot.appendChild(mergeBtnEl('Close', 'btn-primary', () => { closeMergeWizard(); refreshExplorer(); }));
}

async function mergeUndo() {
    if (!merge.preMergeSha) { toast('Nothing to undo.'); return; }
    if (!window.confirm(`Undo the merge and return ${merge.defaultBranch || 'main'} to its previous state? (Local only.)`)) return;
    try { await api('POST', '/api/git/merge/undo', { sha: merge.preMergeSha }); toast('Merge undone.'); }
    catch (e) { toast(e.message); return; }
    closeMergeWizard();
    refreshExplorer();
}

async function fetchTree(path) {
    try { return await api('GET', '/api/fs/tree?path=' + encodeURIComponent(path || '')); }
    catch (e) { return { entries: [], error: e.message }; }
}

async function buildTreeLevel(path, depth) {
    const data = await fetchTree(path);
    const ul = el('tree-level', 'ul');
    if (data.error) {
        const li = el('tree-msg muted tiny', 'li');
        li.textContent = '⚠ ' + data.error;
        ul.appendChild(li);
        return ul;
    }
    if (!data.entries.length) {
        const li = el('tree-msg muted tiny', 'li');
        li.textContent = depth === 0 ? 'Empty project.' : 'Empty folder.';
        ul.appendChild(li);
        return ul;
    }
    for (const ent of data.entries) {
        ul.appendChild(ent.type === 'dir' ? await buildDirNode(ent, depth) : buildFileNode(ent));
    }
    return ul;
}

async function buildDirNode(ent, depth) {
    const li = el('tree-node tree-dir', 'li');
    const row = el('tree-row', 'button');
    row.innerHTML = `<span class="tree-caret">▸</span><span class="tree-ico">📁</span><span class="tree-name"></span><span class="tree-status"></span>`;
    row.querySelector('.tree-name').textContent = ent.name;
    row.title = ent.path;
    decorateTreeRow(li, row, gitStatusFor(ent.path, true), ent.path);
    let loaded = false;
    const childWrap = el('tree-children hidden');

    const expand = async () => {
        li.classList.add('open');
        row.querySelector('.tree-caret').textContent = '▾';
        childWrap.classList.remove('hidden');
        state.explorerExpanded.add(ent.path);
        if (!loaded) {
            loaded = true;
            childWrap.innerHTML = '<div class="muted tiny tree-msg">Loading…</div>';
            const level = await buildTreeLevel(ent.path, depth + 1);
            childWrap.innerHTML = '';
            childWrap.appendChild(level);
        }
    };
    const collapse = () => {
        li.classList.remove('open');
        row.querySelector('.tree-caret').textContent = '▸';
        childWrap.classList.add('hidden');
        state.explorerExpanded.delete(ent.path);
    };
    row.onclick = () => { if (li.classList.contains('open')) collapse(); else expand(); };
    li.append(row, childWrap);

    // Re-open folders the user had expanded before this refresh so an automatic
    // refresh keeps the tree exactly as they left it.
    if (state.explorerExpanded.has(ent.path)) await expand();
    return li;
}

function buildFileNode(ent) {
    const li = el('tree-node tree-file', 'li');
    const row = el('tree-row', 'button');
    row.innerHTML = `<span class="tree-caret"></span><span class="tree-ico">📄</span><span class="tree-name"></span><span class="tree-status"></span><span class="tree-size muted tiny">${formatBytes(ent.bytes)}</span>`;
    row.querySelector('.tree-name').textContent = ent.name;
    row.title = ent.path;
    decorateTreeRow(li, row, gitStatusFor(ent.path, false), ent.path);
    row.onclick = () => openFileViewer(ent);
    li.appendChild(row);
    return li;
}

// Marks a row with its Git status, the way an IDE explorer does: a colour on the
// name plus a one-letter status for a file, and a count of what changed beneath
// for a folder. Without this the only sign that the agent touched a file is the
// Activity panel, which is collapsed by default.
function decorateTreeRow(li, row, status, absPath) {
    const pending = aiChangeFor(absPath);
    if (pending && pending.status !== 'unchanged') li.classList.add('is-ai-change');
    if (!status) return;
    li.classList.add('is-changed', 'chg-' + status);
    const badge = row.querySelector('.tree-status');
    if (!badge) return;
    if (status === 'contains') {
        const rel = projectRelPath(absPath);
        const n = rel == null ? 0 : (gitChanges.dirs.get(rel.toLowerCase()) || 0);
        badge.textContent = n ? String(n) : '•';
        badge.title = n === 1 ? '1 changed file inside' : `${n} changed files inside`;
    }
    else {
        badge.textContent = statusGlyph(status);
        badge.title = pending ? statusLabel(status) + ' — changed by DeskPilot, not reviewed yet' : statusLabel(status);
    }
}

function formatBytes(n) {
    if (n == null) return '';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
    return (n / 1024 / 1024 / 1024).toFixed(1) + ' GB';
}

// ===== File viewer =====
const fileViewer = { data: null, name: '', markdown: false, mode: 'rendered' };

function isMarkdownName(name) {
    return /\.(md|markdown|mdown|mkd|mkdn)$/i.test(name || '');
}

async function openFileViewer(ent) {
    fileViewer.name = ent.name;
    fileViewer.markdown = isMarkdownName(ent.name);
    fileViewer.mode = fileViewer.markdown ? 'rendered' : 'raw';
    fileViewer.data = null;
    $('file-title').textContent = ent.name;
    $('file-title').title = ent.path || ent.name;
    $('file-meta').textContent = '';
    $('file-viewmode').classList.add('hidden');
    $('file-body').innerHTML = '<div class="muted tiny file-msg">Loading…</div>';
    $('file-backdrop').classList.remove('hidden');
    $('file-modal').classList.remove('hidden');
    let data;
    try { data = await api('GET', '/api/fs/file?path=' + encodeURIComponent(ent.path || '')); }
    catch (e) { $('file-body').innerHTML = `<div class="file-error">⚠ ${escapeHtml(e.message)}</div>`; return; }
    if (data.error) { $('file-body').innerHTML = `<div class="file-error">⚠ ${escapeHtml(data.error)}</div>`; return; }
    fileViewer.data = data;
    renderFileView();
}

function renderFileView() {
    const data = fileViewer.data;
    const body = $('file-body');
    if (!data) return;

    const bits = [formatBytes(data.bytes)];
    if (data.truncated) bits.push('preview truncated to the first ' + formatBytes((data.text || '').length));
    $('file-meta').textContent = bits.join(' · ');

    // The rendered/raw switch only makes sense for Markdown text.
    const showToggle = fileViewer.markdown && !data.binary;
    $('file-viewmode').classList.toggle('hidden', !showToggle);
    $('file-view-rendered').classList.toggle('active', fileViewer.mode === 'rendered');
    $('file-view-raw').classList.toggle('active', fileViewer.mode === 'raw');

    if (data.binary) {
        body.innerHTML = '<div class="file-msg muted">This file can’t be previewed as text.</div>';
        return;
    }

    if (showToggle && fileViewer.mode === 'rendered') {
        const md = el('content file-content');
        md.innerHTML = renderMarkdown(data.text || '');
        hydrateCopies(md);
        body.innerHTML = '';
        body.appendChild(md);
    } else {
        const pre = el('file-raw', 'pre');
        pre.textContent = data.text || '';
        body.innerHTML = '';
        body.appendChild(pre);
    }
}

function setFileViewMode(mode) {
    if (fileViewer.mode === mode) return;
    fileViewer.mode = mode;
    renderFileView();
}

function closeFileViewer() {
    $('file-backdrop').classList.add('hidden');
    $('file-modal').classList.add('hidden');
    $('file-body').innerHTML = '';
    fileViewer.data = null;
}

// ===== Customizations (manage AI resources: agents, skills, instructions, prompts) =====
const CUST_ICONS = { agent: '🤖', skill: '📘', instruction: '📋', prompt: '✍️' };
const CUST_SINGULAR = { agent: 'agent', skill: 'skill', instruction: 'instruction', prompt: 'prompt file' };
const cust = { list: null, category: 'agent', search: '', editor: null };

async function openCustomizations() {
    $('cust-backdrop').classList.remove('hidden');
    $('cust-modal').classList.remove('hidden');
    showCustList();
    $('cust-search').value = cust.search;
    await loadCustomizations();
}

function custConfirmDiscard() {
    return !cust.editor || !cust.editor.dirty || window.confirm('Discard unsaved changes?');
}

function closeCustomizations() {
    if (!custConfirmDiscard()) return;
    $('cust-backdrop').classList.add('hidden');
    $('cust-modal').classList.add('hidden');
    cust.editor = null;
}

function showCustList() {
    $('cust-editor-view').classList.add('hidden');
    $('cust-list-view').classList.remove('hidden');
}

function showCustEditor() {
    $('cust-list-view').classList.add('hidden');
    $('cust-editor-view').classList.remove('hidden');
}

async function loadCustomizations() {
    $('cust-items').innerHTML = '<div class="cust-empty">Loading…</div>';
    try {
        cust.list = await api('GET', '/api/customizations');
    } catch (e) {
        cust.list = { categories: [] };
        $('cust-items').innerHTML = `<div class="cust-empty">⚠ ${escapeHtml(e.message)}</div>`;
        return;
    }
    const cats = (cust.list && cust.list.categories) || [];
    if (!cats.find((c) => c.id === cust.category)) cust.category = (cats[0] && cats[0].id) || 'agent';
    renderCustRail();
    renderCustItems();
}

function currentCustCategory() {
    const cats = (cust.list && cust.list.categories) || [];
    return cats.find((c) => c.id === cust.category) || null;
}

function renderCustRail() {
    const rail = $('cust-rail');
    const cats = (cust.list && cust.list.categories) || [];
    rail.innerHTML = '';
    for (const c of cats) {
        const btn = el('cust-rail-item' + (c.id === cust.category ? ' active' : ''), 'button');
        btn.innerHTML = `<span class="cust-rail-ico">${CUST_ICONS[c.id] || '•'}</span><span class="cust-rail-name"></span><span class="cust-rail-count">${c.count}</span>`;
        btn.querySelector('.cust-rail-name').textContent = c.label;
        btn.onclick = () => selectCustCategory(c.id);
        rail.appendChild(btn);
    }
}

function selectCustCategory(id) {
    cust.category = id;
    renderCustRail();
    renderCustItems();
}

function renderCustItems() {
    const wrap = $('cust-items');
    const cat = currentCustCategory();
    wrap.innerHTML = '';
    if (!cat) { wrap.innerHTML = '<div class="cust-empty">No categories.</div>'; return; }
    const q = cust.search.trim().toLowerCase();
    let items = cat.items || [];
    if (q) items = items.filter((it) => (it.name || '').toLowerCase().includes(q) || (it.description || '').toLowerCase().includes(q));
    if (!items.length) {
        if (!(cat.roots || []).length) {
            wrap.innerHTML = `<div class="cust-empty">No ${escapeHtml(cat.label.toLowerCase())} folder is configured. Set one in Settings.</div>`;
        } else if (q) {
            wrap.innerHTML = '<div class="cust-empty">No matches.</div>';
        } else {
            wrap.innerHTML = `<div class="cust-empty">Nothing here yet. Use ＋ New to create one.</div>`;
        }
        return;
    }
    // Group by scope (User for ~/.copilot, otherwise Workspace), like VS Code's list.
    const groups = {};
    const order = [];
    for (const it of items) {
        const scope = it.scope || 'Other';
        if (!groups[scope]) { groups[scope] = []; order.push(scope); }
        groups[scope].push(it);
    }
    for (const scope of order) {
        const head = el('cust-group-head');
        head.textContent = `${scope} · ${groups[scope].length}`;
        wrap.appendChild(head);
        for (const it of groups[scope]) {
            const row = el('cust-item', 'button');
            row.innerHTML = `<div class="cust-item-name"></div><div class="cust-item-desc"></div>`;
            row.querySelector('.cust-item-name').textContent = it.name;
            row.querySelector('.cust-item-desc').textContent = it.description || it.path;
            row.title = it.path;
            row.onclick = () => openCustEditor(it);
            wrap.appendChild(row);
        }
    }
}

async function openCustEditor(item) {
    cust.editor = { category: item.category, path: item.path, name: item.name, dirty: false, mode: 'edit', readonly: false };
    $('cust-editor-name').textContent = item.name;
    $('cust-editor-file').textContent = item.path;
    $('cust-editor-file').title = item.path;
    $('cust-editor-meta').textContent = '';
    const ta = $('cust-editor');
    ta.value = '';
    ta.readOnly = false;
    setCustViewMode('edit');
    showCustEditor();
    $('cust-save').disabled = true;
    let data;
    try {
        data = await api('GET', '/api/customizations/content?category=' + encodeURIComponent(item.category) + '&path=' + encodeURIComponent(item.path));
    } catch (e) { $('cust-editor-meta').textContent = '⚠ ' + e.message; ta.readOnly = true; return; }
    if (data.error) { $('cust-editor-meta').textContent = '⚠ ' + data.error; ta.readOnly = true; return; }
    if (data.binary) { $('cust-editor-meta').textContent = 'This file can’t be edited as text.'; ta.readOnly = true; return; }
    ta.value = data.text || '';
    cust.editor.readonly = !!data.truncated;
    ta.readOnly = !!data.truncated;
    $('cust-editor-meta').textContent = formatBytes(data.bytes) + (data.truncated ? ' · too large to edit (read-only)' : '');
    renderGutter();
    ta.scrollTop = 0;
    syncGutterScroll();
}

function custLineCount(text) {
    let n = 1;
    for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) n++;
    return n;
}

function renderGutter() {
    const n = custLineCount($('cust-editor').value);
    let s = '';
    for (let i = 1; i <= n; i++) s += i + '\n';
    $('cust-gutter').textContent = s;
}

function syncGutterScroll() {
    $('cust-gutter').scrollTop = $('cust-editor').scrollTop;
}

function onCustEditorInput() {
    if (cust.editor) {
        cust.editor.dirty = true;
        $('cust-save').disabled = cust.editor.readonly;
    }
    renderGutter();
    syncGutterScroll();
}

function custEditorKeydown(e) {
    // Tab inserts four spaces instead of leaving the textarea.
    if (e.key === 'Tab') {
        e.preventDefault();
        const ta = e.target;
        const s = ta.selectionStart, en = ta.selectionEnd;
        ta.value = ta.value.slice(0, s) + '    ' + ta.value.slice(en);
        ta.selectionStart = ta.selectionEnd = s + 4;
        onCustEditorInput();
    }
}

function setCustViewMode(mode) {
    if (cust.editor) cust.editor.mode = mode;
    $('cust-view-edit').classList.toggle('active', mode === 'edit');
    $('cust-view-preview').classList.toggle('active', mode === 'preview');
    const editing = mode === 'edit';
    $('cust-editor-wrap').classList.toggle('hidden', !editing);
    const preview = $('cust-preview');
    preview.classList.toggle('hidden', editing);
    if (!editing) {
        preview.innerHTML = renderMarkdown($('cust-editor').value || '');
        hydrateCopies(preview);
    } else {
        syncGutterScroll();
    }
}

async function saveCustEditor() {
    if (!cust.editor || cust.editor.readonly) return;
    const ed = cust.editor;
    $('cust-save').disabled = true;
    try {
        const res = await api('PUT', '/api/customizations/content', { category: ed.category, path: ed.path, text: $('cust-editor').value });
        ed.dirty = false;
        $('cust-editor-meta').textContent = formatBytes(res.bytes) + ' · saved';
        toast('Saved.');
        // An edited agent persona changes the composer Agent menu; keep it fresh.
        if (ed.category === 'agent') loadAgents();
    } catch (e) { toast(e.message); $('cust-save').disabled = false; }
}

function backToCustList() {
    if (!custConfirmDiscard()) return;
    cust.editor = null;
    showCustList();
    loadCustomizations();
}

async function newCustomization() {
    const cat = currentCustCategory();
    if (!cat) return;
    if (!(cat.roots || []).length) { toast(`Set a ${cat.label.toLowerCase()} folder in Settings first.`); return; }
    const noun = CUST_SINGULAR[cat.id] || 'customization';
    const name = (window.prompt(`Name for the new ${noun} (letters, digits, dot, dash, underscore):`) || '').trim();
    if (!name) return;
    try {
        const created = await api('POST', '/api/customizations', { category: cat.id, name });
        await loadCustomizations();
        if (cat.id === 'agent') loadAgents();
        openCustEditor({ category: created.category, path: created.path, name: created.name });
        toast(`Created ${noun} “${created.name}”.`);
    } catch (e) { toast(e.message); }
}

// ===== File uploads =====
async function uploadFiles(files) {
    // No Project required: with no Workspace Folder the server saves uploads to
    // an 'uploads' folder in the data directory and returns their absolute paths.
    const fd = new FormData();
    for (const f of files) fd.append('files', f, f.name);
    try {
        // Note: do NOT set Content-Type here — the browser must set the multipart
        // boundary itself. We only add the session-token header (the api() helper
        // isn't used because it JSON-encodes the body).
        const res = await fetch('/api/uploads', {
            method: 'POST',
            headers: { 'X-DeskPilot-Token': token },
            body: fd,
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) { toast((data && data.error && data.error.message) || ('Upload failed (' + res.status + ')')); return; }
        for (const saved of (data.files || [])) state.pendingAttachments.push(saved);
        renderAttachments();
        setSendEnabled(!!$('prompt').value.trim() || !!state.pendingAttachments.length);
    } catch (e) { toast(e.message); }
}

function renderAttachments() {
    const row = $('attachment-row');
    if (!row) return;
    if (!state.pendingAttachments.length) { row.classList.add('hidden'); row.innerHTML = ''; return; }
    row.classList.remove('hidden');
    row.innerHTML = state.pendingAttachments.map((f, i) => (
        `<span class="attachment-chip" title="${escapeHtml(f.path || '')}">📎 ${escapeHtml(f.savedAs)} <button class="attachment-x" data-idx="${i}" aria-label="Remove">×</button></span>`
    )).join('');
    row.querySelectorAll('.attachment-x').forEach((btn) => {
        btn.addEventListener('click', () => {
            const i = Number(btn.dataset.idx);
            state.pendingAttachments.splice(i, 1);
            renderAttachments();
            setSendEnabled(!!$('prompt').value.trim() || !!state.pendingAttachments.length);
        });
    });
}

// ===== Settings backup / restore =====
async function exportSettings() {
    try {
        const backup = await api('GET', '/api/settings/export');
        const blob = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
        const a = document.createElement('a');
        a.href = url;
        a.download = `deskpilot-settings-${stamp}.json`;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
        toast('Settings backed up.');
    } catch (e) { toast(e.message); }
}

async function importSettings(file) {
    let parsed;
    try { parsed = JSON.parse(await file.text()); }
    catch { toast('That file is not valid JSON.'); return; }
    if (!window.confirm('Restore settings from this file? This replaces your current settings.')) return;
    try {
        state.settings = await api('POST', '/api/settings/import', parsed);
        // Re-sync everything that reads settings.
        updatePermDot();
        populateProjectSelect();
        await loadAgents();
        syncExplorerAvailability();
        if (explorerOpen()) refreshExplorer();
        closeSettings();
        openSettings();
        toast('Settings restored.');
    } catch (e) { toast(e.message); }
}

// ===== Settings drawer =====
// The tool-iteration budget. 200 is the recommended ceiling: past it a Turn is long
// enough to outlive its own Copilot session token, which ends it with a sign-in error
// that cannot be resumed, so a higher value is confirmed rather than saved silently.
// The hard bound only exists so a typo cannot start an unattended runaway - the Host
// Server enforces the same number, and a value approved here must still load from disk.
const MAXITER_RECOMMENDED = 200;
const MAXITER_HARD = 1000;
function openSettings() {
    const body = $('settings-body');
    const s = state.settings || {};
    // Intercom's own fields come from GET /api/intercom (the token lives outside
    // Settings), falling back to the Settings copy before the first fetch lands.
    const ic = state.intercom || s.intercom || {};
    // The drawer groups its fields into tabs so it stays easy to navigate as
    // settings grow. Every panel is rendered up front (only the active one is
    // shown) so all the field handlers below can bind by id exactly as before.
    body.innerHTML = `
    <nav class="settings-tabs" role="tablist" aria-label="Settings sections">
      <button type="button" class="settings-tab-btn active" role="tab" id="stab-general" data-tab="general" aria-controls="spane-general" aria-selected="true">General</button>
      <button type="button" class="settings-tab-btn" role="tab" id="stab-permissions" data-tab="permissions" aria-controls="spane-permissions" aria-selected="false" tabindex="-1">Permissions</button>
      <button type="button" class="settings-tab-btn" role="tab" id="stab-projects" data-tab="projects" aria-controls="spane-projects" aria-selected="false" tabindex="-1">Projects</button>
      <button type="button" class="settings-tab-btn" role="tab" id="stab-custom" data-tab="custom" aria-controls="spane-custom" aria-selected="false" tabindex="-1">Customizations</button>
      <button type="button" class="settings-tab-btn" role="tab" id="stab-memory" data-tab="memory" aria-controls="spane-memory" aria-selected="false" tabindex="-1">Memory &amp; context</button>
      <button type="button" class="settings-tab-btn" role="tab" id="stab-engine" data-tab="engine" aria-controls="spane-engine" aria-selected="false" tabindex="-1">Engine &amp; data</button>
      <button type="button" class="settings-tab-btn" role="tab" id="stab-intercom" data-tab="intercom" aria-controls="spane-intercom" aria-selected="false" tabindex="-1">Intercom</button>
    </nav>
    <section class="settings-tab active" id="spane-general" data-tab="general" role="tabpanel" aria-labelledby="stab-general">
      <div class="field">
        <label>Default model</label>
        <select id="set-model">${(state.models.length ? state.models.map((m) => m.id) : [s.model || state.defaultModel].filter(Boolean))
            .map((id) => `<option value="${id}" ${id === (s.model || state.defaultModel) ? 'selected' : ''}>${id}</option>`).join('')}</select>
        <p class="hint">Used for new conversations.</p>
      </div>
      <div class="field">
        <label>Reasoning effort</label>
        <select id="set-effort"></select>
        <p class="hint" id="set-effort-hint"></p>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-thinking" ${s.showThinking ? 'checked' : ''} /> Show the model’s thinking</label>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-tasktracking" ${s.taskTracking !== false ? 'checked' : ''} /> Track tasks for multi-step work</label>
        <p class="hint">Lets the agent keep a live checklist of sub-tasks while it works through a turn.</p>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-pushinstructions" ${s.pushInstructions !== false ? 'checked' : ''} /> Always apply workspace-wide instructions</label>
        <p class="hint">Puts instruction files that apply to everything straight into the agent&rsquo;s brief, instead of leaving it to fetch them. Turn off to save context on a small model.</p>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-workspacecontext" ${s.workspaceContext !== false ? 'checked' : ''} /> Describe the project folder to the agent</label>
        <p class="hint">Puts the current branch, whether anything is uncommitted, and a bounded file listing into the agent&rsquo;s brief, so it does not spend its first steps looking them up. Turn off on a very large repository.</p>
      </div>
      <div class="field">
        <label>Max tool iterations</label>
        <input type="number" id="set-maxiter" min="1" max="${MAXITER_HARD}" value="${s.maxToolIterations || 50}" />
        <p class="hint">How many tool steps the agent may take in one job. ${MAXITER_RECOMMENDED} is the recommended maximum &mdash; above that DeskPilot asks you to confirm, because every step is a paid round trip and a very long job can outlive its own sign-in token.</p>
      </div>
      <div class="field">
        <label>Send a message with</label>
        <select id="set-sendkey">
          <option value="ctrl-enter" ${sendKeyMode() === 'ctrl-enter' ? 'selected' : ''}>Ctrl+Enter (Enter makes a new line)</option>
          <option value="enter" ${sendKeyMode() === 'enter' ? 'selected' : ''}>Enter (Shift+Enter makes a new line)</option>
        </select>
        <p class="hint">Ctrl+Enter by default, so a stray Enter mid-thought cannot send a half-written instruction.</p>
      </div>
      <div class="field">
        <label>Voice language</label>
        <select id="set-voicelang">
          ${VOICE_LANGS.map((l) => `<option value="${l.id}" ${voiceLangPref() === l.id ? 'selected' : ''}>${escapeHtml(l.label)}</option>`).join('')}
        </select>
        <p class="hint">Used by 🎤 Dictate and 🔊 Read aloud. Auto follows your browser — pick a language when your browser is set to one and you speak another.</p>
      </div>
      <div class="field">
        <label>Voice</label>
        <select id="set-voice"></select>
        <p class="hint">A voice marked <em>Natural</em> or <em>Online</em> is a modern one; a <em>Desktop</em> voice is the old robotic set Windows ships with. Automatic already prefers the best one installed.</p>
      </div>
      <div class="field">
        <label>Theme</label>
        <select id="set-theme">
          ${['system', 'light', 'dark'].map((t) => `<option value="${t}" ${(localStorage.getItem('ad_theme') || 'system') === t ? 'selected' : ''}>${t}</option>`).join('')}
        </select>
      </div>
    </section>
    <section class="settings-tab" id="spane-permissions" data-tab="permissions" role="tabpanel" aria-labelledby="stab-permissions" hidden>
      <div class="field">
        <label>Permissions</label>
        <div class="perm-list" id="set-perms"></div>
      </div>
    </section>
    <section class="settings-tab" id="spane-projects" data-tab="projects" role="tabpanel" aria-labelledby="stab-projects" hidden>
      <div class="field">
        <label>Projects</label>
        <div class="projects-manager" id="set-projects"></div>
        <div class="project-add">
          <button class="btn btn-small" id="proj-browse">📁 Add project…</button>
        </div>
        <p class="hint">A project is a working folder. The selected project is where the File and Terminal tools work, and is the default for new prompts.</p>
      </div>
      <div class="field">
        <label>Reference files (one project-relative path per line)</label>
        <textarea id="set-reffiles" rows="3" placeholder="docs/style-guide.md&#10;data/contacts.csv">${escapeHtml((s.referenceFiles || []).join('\n'))}</textarea>
        <p class="hint">Files the agent should always treat as relevant for the selected project. Their paths are added to every turn so the agent reads them with its File tool when useful (no vector database needed).</p>
      </div>
    </section>
    <section class="settings-tab" id="spane-custom" data-tab="custom" role="tabpanel" aria-labelledby="stab-custom" hidden>
      <div class="field">
        <label>Skill folders (one path per line)</label>
        <textarea id="set-skills" placeholder="C:\\path\\to\\skills">${escapeHtml((s.skillRoots || []).join('\n'))}</textarea>
      </div>
      <div class="field">
        <label>Instruction folders (one path per line)</label>
        <textarea id="set-instructions">${escapeHtml((s.instructionRoots || []).join('\n'))}</textarea>
      </div>
      <div class="field">
        <label>Prompt folders (one path per line)</label>
        <textarea id="set-prompts" placeholder="C:\\Users\\you\\.copilot\\prompts">${escapeHtml((s.promptRoots || []).join('\n'))}</textarea>
        <p class="hint">Folders of <code>*.prompt.md</code> files; browse and edit them under 🧩 Customizations.</p>
      </div>
      <div class="field">
        <label>Agents folder</label>
        <input type="text" id="set-agents" value="${escapeHtml(s.agentsRoot || '')}" placeholder="C:\\Users\\you\\.copilot\\agents" />
        <p class="hint">Folder of <code>*.agent.md</code> personas; pick one from the Agent menu in the composer.</p>
      </div>
      <div class="field">
        <label>Atelier health</label>
        <div class="atelier-health" id="set-atelier"><button class="btn btn-small" id="atelier-refresh" type="button">Check customization folders</button></div>
        <p class="hint">Whether each <code>~/.copilot</code> customization folder resolves, and how many agents, skills, instructions and prompts were found.</p>
      </div>
    </section>
    <section class="settings-tab" id="spane-memory" data-tab="memory" role="tabpanel" aria-labelledby="stab-memory" hidden>
      <div class="field">
        <label>User profile — about you</label>
        <textarea id="set-preferences" rows="4" placeholder="e.g. I'm a paralegal. Write in plain British English, cite sources, and keep answers concise.">${escapeHtml(s.preferences || '')}</textarea>
        <p class="hint">A durable note <em>you</em> write about yourself — role, writing style, recurring context. Added to every turn so the agent serves you consistently.</p>
      </div>
      <div class="field">
        <label>Agent memory — what DeskPilot has learned <span id="mem-updated" class="muted tiny"></span></label>
        <textarea id="set-agent-memory" rows="8" placeholder="DeskPilot fills this in as it learns durable facts about you and your projects. You can edit or clear it."></textarea>
        <div class="mem-row">
          <span id="mem-count" class="muted tiny"></span>
          <button class="btn btn-small mem-learn-btn" id="set-memory-learn" type="button">Update from this conversation</button>
        </div>
        <p class="hint">Durable notes the agent keeps about you and your environment across conversations, injected into every turn as background reference.</p>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-memory-learning" ${s.memoryLearning !== false ? 'checked' : ''} /> Let DeskPilot learn about you automatically</label>
        <p class="hint">Every few turns, DeskPilot folds durable facts from the conversation into its agent memory (a brief background step that uses a little credit); you’ll see a note when it does. Turn this off to curate memory yourself.</p>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-autocompact" ${s.autoCompaction !== false ? 'checked' : ''} /> Automatically compact long conversations</label>
        <p class="hint">When a conversation fills most of the model’s context window, DeskPilot summarises the earlier turns to free space so it keeps working. Your visible messages are always kept, and you’ll see a note each time it happens.</p>
      </div>
      <div class="field">
        <label>Compact when context reaches (%)</label>
        <input type="number" id="set-compact-threshold" min="50" max="95" step="5" value="${Math.round((s.compactionThreshold || 0.8) * 100)}" />
        <p class="hint">Percent of the model’s context window that triggers an automatic compaction (50–95).</p>
      </div>
      <div class="field">
        <label>Recent messages to keep in full</label>
        <input type="number" id="set-compact-keep" min="2" max="100" value="${s.compactionKeepRecent || 4}" />
        <p class="hint">The most recent messages are never summarised, so recent detail stays intact.</p>
      </div>
    </section>
    <section class="settings-tab" id="spane-engine" data-tab="engine" role="tabpanel" aria-labelledby="stab-engine" hidden>
      <div class="field">
        <label>Spend warning (USD this session, 0 = off)</label>
        <input type="number" id="set-budget" min="0" step="0.5" value="${(s.costBudgetUSD || 0)}" />
        <p class="hint">Shows a one-time warning when this session's estimated cost crosses the amount.</p>
      </div>
      <div class="field">
        <label>Updates</label>
        <div class="update-panel" id="set-update-status">Checking…</div>
        <div class="backup-row">
          <button class="btn btn-small" id="update-check" type="button">Check for updates</button>
          <button class="btn btn-small btn-primary hidden" id="set-update-now" type="button">Update now</button>
        </div>
        <label style="margin-top:10px"><input type="checkbox" id="set-update-prerelease" ${s.updateIncludePrereleases ? 'checked' : ''} /> Include preview releases</label>
        <div class="update-interval-row">
          <label for="set-update-interval">Check every</label>
          <input type="number" id="set-update-interval" min="1" max="1440" step="1" value="${(s.updateCheckIntervalMinutes || 5)}" />
          <span class="muted tiny">minutes</span>
        </div>
        <p class="hint">DeskPilot checks the PowerShell Gallery for a newer version. Updating also updates ShellPilot; a preview update accepts ShellPilot previews. Changes apply after you restart DeskPilot.</p>
      </div>
      <div class="field">
        <label>Engine</label>
        <div class="engine-status" id="set-engine">Checking…</div>
        <button class="btn" id="set-reauth" style="margin-top:10px">Re-authenticate</button>
      </div>
      <div class="field">
        <label>Back up &amp; restore</label>
        <div class="backup-row">
          <button class="btn btn-small" id="set-export">⬇ Back up settings</button>
          <button class="btn btn-small" id="set-import">⬆ Restore settings</button>
          <input id="set-import-file" type="file" accept="application/json,.json" class="hidden" />
        </div>
        <p class="hint">Save your projects, permissions, agent and tool settings to a JSON file, or restore them. Restore replaces the current settings.</p>
      </div>
    </section>
    <section class="settings-tab" id="spane-intercom" data-tab="intercom" role="tabpanel" aria-labelledby="stab-intercom" hidden>
      <div class="field">
        <label><input type="checkbox" id="set-ic-enabled" ${ic.enabled ? 'checked' : ''} /> Let me reach DeskPilot from my phone</label>
        <p class="hint">DeskPilot messages you on Telegram when the agent needs an answer, finishes, fails, or goes quiet — and you can reply to answer it or give it a new instruction. Off by default. <a href="${INTERCOM_GUIDE_URL}" target="_blank" rel="noopener noreferrer"><strong>Follow the getting-started guide</strong></a> before switching this on.</p>
      </div>
      <div class="field">
        <label>Status</label>
        <div class="intercom-panel" id="set-intercom-status">Checking…</div>
      </div>
      <div class="field">
        <label>Bot token ${ic.tokenConfigured ? '<span class="project-badge">stored</span>' : ''}</label>
        <input type="password" id="set-ic-token" autocomplete="off" spellcheck="false" placeholder="123456789:AA… from @BotFather" />
        <div class="backup-row">
          <button class="btn btn-small" id="set-ic-token-save" type="button">Save token</button>
          <button class="btn btn-small btn-danger" id="set-ic-token-clear" type="button">Remove token</button>
        </div>
        <p class="hint">Anyone holding this token <em>is</em> your bot. It is stored encrypted for your Windows account, never in your settings file, and never shown again — so a settings backup can never leak it. Lost your phone? Revoke it in @BotFather.</p>
      </div>
      <div class="field">
        <label>Your phone</label>
        <div class="intercom-panel" id="set-ic-pairing">Checking…</div>
        <input type="text" id="set-ic-chat" inputmode="numeric" spellcheck="false" placeholder="e.g. 123456789" value="${escapeHtml(ic.chatId || '')}" />
        <p class="hint">Only this one Telegram chat can reach DeskPilot. A message from anywhere else is counted and thrown away without being read as a command. Use <strong>Link my phone</strong> above and DeskPilot will find this number for you — you never have to look it up.</p>
      </div>
      <div class="field">
        <div class="backup-row">
          <button class="btn btn-small" id="set-ic-test" type="button">Send a test message</button>
        </div>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-ic-done" ${ic.notifyOnDone !== false ? 'checked' : ''} /> Tell me when a job finishes or fails</label>
      </div>
      <div class="field">
        <label><input type="checkbox" id="set-ic-answer" ${ic.sendFinalAnswer !== false ? 'checked' : ''} /> Include the agent’s answer in that message</label>
        <p class="hint">Turn this off if you would rather read results only at the machine — the answer text passes through Telegram’s servers.</p>
      </div>
      <div class="field">
        <label>Check in every (minutes)</label>
        <input type="number" id="set-ic-heartbeat" min="1" max="1440" value="${ic.heartbeatMinutes || 5}" />
        <p class="hint">DeskPilot keeps one status message up to date on your phone, always stating the time of its next check-in. It updates silently, so it never notifies you. If that time has passed, DeskPilot has stopped.</p>
      </div>
      <div class="field">
        <label>Warn me if the agent goes quiet for (minutes)</label>
        <input type="number" id="set-ic-stall" min="1" max="1440" value="${ic.stallMinutes || 5}" />
      </div>
      <div class="field">
        <label>A question expires after (minutes)</label>
        <input type="number" id="set-ic-question" min="1" max="1440" value="${ic.questionTimeoutMinutes || 60}" />
      </div>
      <div class="field">
        <label>Never send more than (messages per hour)</label>
        <input type="number" id="set-ic-rate" min="1" max="1000" value="${ic.maxMessagesPerHour || 60}" />
      </div>
      <div class="field">
        <label>What this cannot do</label>
        <p class="hint">If the machine loses power, is put to sleep, or loses its network, DeskPilot <strong>cannot</strong> tell you — nothing is left running to send the message. That is what the check-in time above is for: if it has passed, assume DeskPilot has stopped. It also only covers jobs running <em>in DeskPilot</em>, not ones you started in VS Code.</p>
      </div>
    </section>`;

    buildPermList($('set-perms'));
    renderProjectsManager();
    wireSettingsTabs(body);

    const save = async (patch) => {
        try { state.settings = await api('PUT', '/api/settings', patch); updatePermDot(); populateProjectSelect(); }
        catch (e) { toast(e.message); }
    };
    // The reasoning-effort menu is model-aware: a Model advertises which efforts
    // it supports (empty means none), so we offer only those plus the Engine
    // default. This prevents picking an effort a Model would reject (HTTP 400);
    // the Host Server also guards this on every Turn. Falls back to the full list
    // only when the Model's capabilities are not yet loaded.
    const FALLBACK_EFFORTS = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
    const refreshEffortField = () => {
        const modelId = $('set-model').value || (state.settings && state.settings.model) || state.defaultModel;
        const m = state.models.find((x) => x.id === modelId);
        const supported = m ? (m.reasoningEfforts || []) : FALLBACK_EFFORTS;
        const current = (state.settings && state.settings.reasoningEffort) || '';
        const selected = supported.includes(current) ? current : '';
        $('set-effort').innerHTML = ['', ...supported]
            .map((eff) => `<option value="${eff}" ${eff === selected ? 'selected' : ''}>${eff || 'default'}</option>`).join('');
        const hint = $('set-effort-hint');
        if (m && supported.length === 0) {
            hint.textContent = `${modelId} doesn’t support reasoning effort, so this setting stays inactive while it’s selected.`;
        } else if (current && !supported.includes(current)) {
            hint.textContent = `Your saved effort “${current}” isn’t offered for ${modelId}; the model’s default is used until you choose a supported level.`;
        } else {
            hint.textContent = 'Higher effort lets the model think longer before answering. Available levels depend on the selected model.';
        }
    };
    refreshEffortField();
    $('set-model').onchange = (e) => { save({ model: e.target.value }); refreshEffortField(); };
    $('proj-browse').onclick = async () => {
        const sel = projects().find((p) => p.id === (state.settings && state.settings.selectedProjectId));
        const picked = await pickFolder({ title: 'New project folder', start: sel ? sel.path : '', requireName: true });
        if (!picked || !picked.path) { return; }
        if (await registerProject(picked)) {
            renderProjectsManager();
            populateProjectSelect();
        }
    };
    $('set-skills').onchange = (e) => save({ skillRoots: e.target.value.split('\n').map((x) => x.trim()).filter(Boolean) });
    $('set-instructions').onchange = (e) => save({ instructionRoots: e.target.value.split('\n').map((x) => x.trim()).filter(Boolean) });
    $('set-prompts').onchange = (e) => save({ promptRoots: e.target.value.split('\n').map((x) => x.trim()).filter(Boolean) });
    $('set-agents').onchange = async (e) => {
        try {
            state.settings = await api('PUT', '/api/settings', { agentsRoot: e.target.value.trim() || null });
            await loadAgents();
        } catch (err) { toast(err.message); }
    };
    $('set-effort').onchange = (e) => save({ reasoningEffort: e.target.value || null });
    $('set-thinking').onchange = (e) => save({ showThinking: e.target.checked });
    $('set-tasktracking').onchange = (e) => save({ taskTracking: e.target.checked });
    $('set-pushinstructions').onchange = (e) => save({ pushInstructions: e.target.checked });
    $('set-workspacecontext').onchange = (e) => save({ workspaceContext: e.target.checked });
    $('set-autocompact').onchange = (e) => save({ autoCompaction: e.target.checked });
    $('set-compact-threshold').onchange = (e) => {
        const pct = Math.min(95, Math.max(50, parseInt(e.target.value, 10) || 80));
        e.target.value = pct;
        save({ compactionThreshold: pct / 100 });
    };
    $('set-compact-keep').onchange = (e) => {
        const keep = Math.min(100, Math.max(2, parseInt(e.target.value, 10) || 4));
        e.target.value = keep;
        save({ compactionKeepRecent: keep });
    };
    $('set-preferences').onchange = (e) => save({ preferences: e.target.value.trim() || null });
    // Agent memory: loaded from /api/memory, edited/cleared via PUT, and learned
    // on demand via POST /api/memory/learn. The User profile above stays the
    // preferences Setting; this is the separate, agent-curated store.
    const renderMemMeta = (m) => {
        const am = (m && m.agentMemory) || {};
        state._memCap = am.cap || 12000;
        const ta = $('set-agent-memory');
        if (ta && document.activeElement !== ta) ta.value = am.text || '';
        const cnt = $('mem-count');
        if (cnt) cnt.textContent = ((ta ? ta.value.length : am.chars || 0)).toLocaleString() + ' / ' + state._memCap.toLocaleString() + ' chars';
        const upd = $('mem-updated');
        if (upd) upd.textContent = am.updatedUtc ? '· updated ' + new Date(am.updatedUtc).toLocaleString() : '';
    };
    api('GET', '/api/memory').then(renderMemMeta).catch(() => { });
    $('set-agent-memory').oninput = () => {
        const cnt = $('mem-count'); const ta = $('set-agent-memory');
        if (cnt) cnt.textContent = ta.value.length.toLocaleString() + ' / ' + (state._memCap || 12000).toLocaleString() + ' chars';
    };
    $('set-agent-memory').onchange = async (e) => {
        try { renderMemMeta(await api('PUT', '/api/memory', { agentMemory: e.target.value })); toast('Memory saved.'); }
        catch (err) { toast((err && err.message) || 'Could not save memory.'); }
    };
    $('set-memory-learn').onclick = async () => {
        if (!state.current) { toast('Open a conversation first, then update memory from it.'); return; }
        const btn = $('set-memory-learn'); const old = btn.textContent;
        btn.disabled = true; btn.textContent = 'Updating…';
        try {
            const r = await api('POST', '/api/memory/learn', { conversationId: state.current.id });
            renderMemMeta(r);
            toast(r && r.changed ? 'Memory updated from this conversation.' : 'Nothing new worth remembering yet.');
        } catch (e) { toast((e && e.message) || 'Could not update memory.'); }
        finally { btn.disabled = false; btn.textContent = old; }
    };
    $('set-memory-learning').onchange = (e) => save({ memoryLearning: e.target.checked });
    $('set-reffiles').onchange = (e) => save({ referenceFiles: e.target.value.split('\n').map((x) => x.trim()).filter(Boolean) });
    $('set-budget').onchange = (e) => { state._budgetWarned = false; save({ costBudgetUSD: parseFloat(e.target.value) || 0 }); };
    $('set-maxiter').onchange = (e) => {
        const previous = (state.settings && state.settings.maxToolIterations) || 50;
        let v = parseInt(e.target.value, 10);
        if (!v || v < 1) { v = 50; }
        if (v > MAXITER_HARD) { v = MAXITER_HARD; }
        if (v > MAXITER_RECOMMENDED && !window.confirm(
            `${v} tool steps is above the recommended maximum of ${MAXITER_RECOMMENDED}.\n\n`
            + 'Every step is a paid model round trip, so a job that goes wrong can run up real cost unattended. '
            + 'A job this long can also outlive its own Copilot session token and stop with a sign-in error that cannot be resumed.'
            + `\n\nUse ${v} steps?`)) {
            e.target.value = previous;
            return;
        }
        e.target.value = v;
        save({ maxToolIterations: v });
    };
    $('set-theme').onchange = (e) => { localStorage.setItem('ad_theme', e.target.value); applyTheme(); };
    $('set-sendkey').onchange = (e) => { localStorage.setItem('ad_sendkey', e.target.value); applySendKeyHint(); };
    $('set-voicelang').onchange = (e) => {
        localStorage.setItem('ad_voicelang', e.target.value);
        localStorage.removeItem('ad_voicename'); // a voice chosen for German cannot read English
        stopDictation();
        renderVoiceOptions();
    };
    $('set-voice').onchange = (e) => { localStorage.setItem('ad_voicename', e.target.value); };
    renderVoiceOptions();
    $('set-reauth').onclick = () => { closeSettings(); showAuth({ expired: true }); };
    $('atelier-refresh').onclick = () => loadAtelierHealth();
    $('update-check').onclick = () => checkForUpdates();
    $('set-update-now').onclick = () => installUpdate();
    $('set-update-prerelease').onchange = async (e) => { await save({ updateIncludePrereleases: e.target.checked }); checkForUpdates(); };
    $('set-update-interval').onchange = (e) => { let v = parseInt(e.target.value, 10); if (!v || v < 1) { v = 5; } if (v > 1440) { v = 1440; } e.target.value = v; save({ updateCheckIntervalMinutes: v }); };
    renderUpdatePanel();
    refreshUpdateStatus();

    // Intercom. Everything here goes through PUT /api/intercom rather than the
    // Settings route, because that endpoint also owns the write-only bot token.
    const saveIntercom = async (patch) => {
        try {
            state.intercom = await api('PUT', '/api/intercom', patch);
            updateIntercomChip();
            renderIntercomPanel();
        } catch (e) { toast((e && e.message) || 'Could not save Intercom settings.'); refreshIntercom(); }
    };
    const icNumber = (id, key, fallback, min, max) => {
        $(id).onchange = (e) => {
            let v = parseInt(e.target.value, 10);
            if (!v || v < min) { v = fallback; }
            if (v > max) { v = max; }
            e.target.value = v;
            saveIntercom({ [key]: v });
        };
    };
    $('set-ic-enabled').onchange = (e) => saveIntercom({ enabled: e.target.checked });
    $('set-ic-done').onchange = (e) => saveIntercom({ notifyOnDone: e.target.checked });
    $('set-ic-answer').onchange = (e) => saveIntercom({ sendFinalAnswer: e.target.checked });
    $('set-ic-chat').onchange = (e) => saveIntercom({ chatId: e.target.value.trim() });
    renderIntercomPairing();
    icNumber('set-ic-heartbeat', 'heartbeatMinutes', 5, 1, 1440);
    icNumber('set-ic-stall', 'stallMinutes', 5, 1, 1440);
    icNumber('set-ic-question', 'questionTimeoutMinutes', 60, 1, 1440);
    icNumber('set-ic-rate', 'maxMessagesPerHour', 60, 1, 1000);
    $('set-ic-token-save').onclick = async () => {
        const field = $('set-ic-token');
        const value = field.value.trim();
        if (!value) { toast('Paste the token from @BotFather first.'); return; }
        await saveIntercom({ botToken: value });
        // Never leave a bearer credential sitting in a form field.
        field.value = '';
        toast('Bot token stored.');
    };
    $('set-ic-token-clear').onclick = async () => {
        if (!window.confirm('Remove the stored bot token? Intercom will stop until you add one again.')) return;
        await saveIntercom({ botToken: '' });
        $('set-ic-token').value = '';
        toast('Bot token removed.');
    };
    $('set-ic-test').onclick = async () => {
        const btn = $('set-ic-test'); const old = btn.textContent;
        btn.disabled = true; btn.textContent = 'Sending…';
        try {
            const r = await api('POST', '/api/intercom/test', {});
            toast(r && r.botName ? `Test message sent by @${r.botName}.` : 'Test message sent.');
        } catch (e) { toast((e && e.message) || 'Could not send the test message.'); }
        finally { btn.disabled = false; btn.textContent = old; refreshIntercom(); }
    };
    renderIntercomPanel();
    refreshIntercom();
    $('set-export').onclick = () => exportSettings();
    $('set-import').onclick = () => $('set-import-file').click();
    $('set-import-file').addEventListener('change', (e) => {
        const file = (e.target.files || [])[0];
        e.target.value = '';
        if (file) importSettings(file);
    });

    api('GET', '/api/health').then((h) => {
        $('set-engine').innerHTML = `Module: <span class="path">${escapeHtml(h.engineModulePath || 'by name')}</span><br/>Loaded: ${h.engineImported ? 'yes' : 'no'}<br/>Signed in: ${h.authenticated ? 'yes' : 'no'}`;
    }).catch(() => { });

    loadAtelierHealth();

    $('settings-drawer').classList.remove('hidden');
    $('settings-backdrop').classList.remove('hidden');
}

// Fetch and render the Atelier health panel: per-category roots with a ✓/✗ and a
// discovered count, so the user can see at a glance whether ~/.copilot resolves.
async function loadAtelierHealth() {
    const box = $('set-atelier');
    if (!box) return;
    box.innerHTML = '<span class="muted tiny">Checking…</span>';
    let data;
    try { data = await api('GET', '/api/atelier/health'); }
    catch (e) { box.innerHTML = `<span class="muted tiny">${escapeHtml(e.message)}</span>`; return; }
    const rows = [];
    for (const cat of asArray(data.categories)) {
        const roots = asArray(cat.roots);
        if (roots.length === 0) {
            rows.push(`<div class="atelier-row"><span class="atelier-ico warn">○</span><span class="atelier-label">${escapeHtml(cat.label)}</span><span class="muted tiny">no folder configured</span></div>`);
            continue;
        }
        for (const r of roots) {
            const ok = r.exists && !r.error;
            const ico = ok ? '<span class="atelier-ico ok">✓</span>' : '<span class="atelier-ico bad">✗</span>';
            const count = ok ? `<span class="atelier-count">${r.count}</span>` : '';
            const note = r.error ? `<span class="atelier-err tiny">${escapeHtml(r.error)}</span>` : (r.isReparsePoint ? '<span class="muted tiny">junction</span>' : '');
            rows.push(
                `<div class="atelier-row" title="${escapeHtml(r.path)}">${ico}<span class="atelier-label">${escapeHtml(cat.label)} ${count}</span>` +
                `<span class="atelier-path tiny">${escapeHtml(r.path)}</span>${note}</div>`);
        }
    }
    const summary = `<div class="atelier-summary tiny">${data.okCount}/${data.totalRoots} folders OK${data.missingCount ? ' · ' + data.missingCount + ' missing' : ''}</div>`;
    box.innerHTML = rows.join('') + summary +
        '<button class="btn btn-small" id="atelier-refresh" type="button" style="margin-top:8px">Re-check</button>';
    $('atelier-refresh').onclick = () => loadAtelierHealth();
}
function closeSettings() {
    $('settings-drawer').classList.add('hidden');
    $('settings-backdrop').classList.add('hidden');
}

// Wire the Settings drawer's tab strip. Every panel stays in the DOM (only the
// active one is shown) so the field handlers keep binding by id; here we just
// toggle which tab button/panel is active. Keyboard follows the WAI-ARIA
// tablist pattern: Left/Right (and Home/End) move focus between tabs.
function wireSettingsTabs(body) {
    const btns = Array.from(body.querySelectorAll('.settings-tab-btn'));
    const panels = Array.from(body.querySelectorAll('.settings-tab'));
    const activate = (name) => {
        for (const b of btns) {
            const on = b.dataset.tab === name;
            b.classList.toggle('active', on);
            b.setAttribute('aria-selected', on ? 'true' : 'false');
            b.tabIndex = on ? 0 : -1;
        }
        for (const p of panels) {
            const on = p.dataset.tab === name;
            p.classList.toggle('active', on);
            p.hidden = !on;
        }
        body.scrollTop = 0;
    };
    btns.forEach((btn, i) => {
        btn.onclick = () => activate(btn.dataset.tab);
        btn.onkeydown = (e) => {
            let j = -1;
            if (e.key === 'ArrowRight') { j = (i + 1) % btns.length; }
            else if (e.key === 'ArrowLeft') { j = (i - 1 + btns.length) % btns.length; }
            else if (e.key === 'Home') { j = 0; }
            else if (e.key === 'End') { j = btns.length - 1; }
            else { return; }
            e.preventDefault();
            activate(btns[j].dataset.tab);
            btns[j].focus();
        };
    });
}

// ===== Auth =====
// showAuth({ expired }) opens the sign-in overlay. In expired mode it forces a
// fresh device-code flow (Initialize-Shp -Force) — needed because a stale token
// file still exists, so a non-forced sign-in would short-circuit as "already
// signed in" and never replace the dead token — and it swaps in re-auth wording.
function showAuth(opts) {
    const expired = !!(opts && opts.expired);
    state.authForce = expired;
    const title = $('auth-title');
    const sub = $('auth-subtitle');
    if (title) title.textContent = expired ? 'Your sign-in has expired' : 'Connect to GitHub Copilot';
    if (sub) sub.textContent = expired
        ? 'Your GitHub Copilot sign-in is no longer valid. Sign in again to keep using DeskPilot.'
        : 'DeskPilot uses your GitHub Copilot account through the local ShellPilot engine. Sign in once to get started.';
    $('auth-steps').classList.add('hidden');
    $('auth-error').classList.add('hidden');
    $('auth-overlay').classList.remove('hidden');
    reflectEngineState();
}
function hideAuth() { $('auth-overlay').classList.add('hidden'); }

// Open the sign-in overlay in expired mode when a running session discovers the
// token is no longer valid (for example the model list returned 401). Do not
// stack it if it is already open.
function promptReauth() {
    if (!$('auth-overlay').classList.contains('hidden')) return;
    showAuth({ expired: true });
}

// Reflect engine load state in the auth overlay: if the engine isn't loaded,
// sign-in cannot work, so explain that and disable Connect.
async function reflectEngineState() {
    const box = $('auth-engine');
    let health = null;
    try { health = await api('GET', '/api/health'); } catch { /* offline */ }
    if (!health) { box.classList.add('hidden'); return; }
    if (!health.engineImported) {
        box.className = 'auth-engine warn';
        box.textContent = 'Engine not loaded: ' + (health.engineError || 'ShellPilot is unavailable.') +
            ' Install or point DeskPilot at the ShellPilot module, then restart.';
        box.classList.remove('hidden');
        $('auth-connect').disabled = true;
    } else {
        box.classList.add('hidden');
        $('auth-connect').disabled = false;
    }
    return health;
}

// Re-check auth without restarting — for when the user ran Initialize-Shp in a
// terminal while DeskPilot was already open.
async function recheckAuth() {
    const btn = $('auth-recheck');
    btn.disabled = true;
    try {
        const health = await api('GET', '/api/health');
        if (health && health.authenticated) { toast('Signed in.'); await enterApp(); }
        else { toast('Not signed in yet. Run Initialize-Shp, then try again.'); }
    } catch (e) { toast(e.message); }
    finally { btn.disabled = false; }
}
function showBanner(msg) {
    const b = $('engine-notice');
    b.textContent = msg;
    b.classList.remove('hidden');
}

// Show the running DeskPilot version in the sidebar corner (from /api/health).
function setAppVersion(v) {
    const el = $('app-version');
    if (el) { el.textContent = v ? ('DeskPilot v' + v) : ''; }
}

async function startAuth() {
    const steps = $('auth-steps');
    const errEl = $('auth-error');
    errEl.classList.add('hidden');
    steps.classList.remove('hidden');
    let progress = createAuthProgress();
    renderAuthProgress(steps, progress);
    $('auth-connect').disabled = true;
    try {
        await streamPost('/api/auth/start', { force: !!state.authForce }, {
            waiting: (d) => {
                progress = { ...progress, status: (d && d.message) || progress.status };
                renderAuthProgress(steps, progress);
            },
            code: (d) => {
                progress = applyAuthLine(progress, (d && d.message) || '');
                renderAuthProgress(steps, progress);
            },
            done: async (d) => {
                if (d && d.authenticated) { toast('Signed in.'); await enterApp(); }
                else {
                    errEl.textContent = 'Sign-in did not complete. The code may have expired — choose Connect to get a new one.';
                    errEl.classList.remove('hidden');
                }
            },
            error: (d) => { errEl.textContent = (d && d.message) || 'Sign-in failed.'; errEl.classList.remove('hidden'); },
        });
    } catch (e) {
        errEl.textContent = e.message || String(e);
        errEl.classList.remove('hidden');
    } finally {
        $('auth-connect').disabled = false;
    }
}

// Render the sign-in panel from the reduced progress state. The link and the
// code stay pinned in place: the engine's poll heartbeat only updates the
// single status line, so nothing scrolls out of view while the user is on
// GitHub.
function renderAuthProgress(container, progress) {
    const statusText = container.querySelector('.auth-status-text');
    // Rebuilding on every heartbeat would restart the spinner animation, so
    // only the status line is touched while the link and code are unchanged.
    if (statusText && container.dataset.authUrl === progress.url && container.dataset.authCode === progress.code) {
        statusText.textContent = progress.status || AUTH_WAITING_STATUS;
        return;
    }
    container.textContent = '';
    container.dataset.authUrl = progress.url;
    container.dataset.authCode = progress.code;
    if (progress.url) {
        const step = el('auth-step');
        const label = el('auth-step-label');
        label.textContent = '1. Open this page in your browser';
        const link = el('', 'a');
        link.href = progress.url;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        link.textContent = progress.url;
        step.append(label, link);
        container.appendChild(step);
    }
    if (progress.code) {
        const step = el('auth-step');
        const label = el('auth-step-label');
        label.textContent = '2. Enter this code on that page';
        const row = el('auth-code-row');
        const pill = el('code-pill');
        pill.textContent = progress.code;
        const copy = el('btn auth-copy', 'button');
        copy.type = 'button';
        copy.textContent = 'Copy code';
        copy.onclick = () => copyAuthCode(progress.code);
        row.append(pill, copy);
        const hint = el('auth-hint');
        hint.textContent = 'GitHub may ask for your password and two-factor code first — that is your normal sign-in. ' +
            'This code belongs only in the "Device activation" box that comes after it.';
        step.append(label, row, hint);
        container.appendChild(step);
    }
    const status = el('auth-status');
    status.appendChild(el('spinner', 'span'));
    const text = el('auth-status-text', 'span');
    text.textContent = progress.status || AUTH_WAITING_STATUS;
    status.appendChild(text);
    container.appendChild(status);
}

function copyAuthCode(code) {
    navigator.clipboard.writeText(code).then(
        () => toast('Code copied.'),
        () => toast('Copy failed — type the code manually.'));
}

// ===== Examples =====
function renderExamples() {
    const node = $('examples');
    if (!node) return;
    const examples = [
        ['Summarise a folder', 'Read every Markdown file in my workspace folder and write a one-page summary to summary.md.'],
        ['Draft a reply', 'Read letter.txt and draft a polite but firm response.'],
        ['Check the web', 'What changed in the PowerShell/PowerShell repository today?'],
        ['Explain simply', 'Explain what an AI agent is, in plain language, in two short paragraphs.'],
    ];
    node.innerHTML = '';
    for (const [title, prompt] of examples) {
        const card = el('example');
        card.innerHTML = `<b>${title}</b><span class="muted">${escapeHtml(prompt)}</span>`;
        card.onclick = () => { $('prompt').value = prompt; autoGrow($('prompt')); setSendEnabled(true); $('prompt').focus(); };
        node.appendChild(card);
    }
}

// ===== Composer behaviour =====
function autoGrow(t) {
    t.style.height = 'auto';
    t.style.height = Math.min(t.scrollHeight, 220) + 'px';
}
function setSendEnabled(on) {
    if (!state.streaming) $('btn-send').disabled = !on;
}

// ===== Prompt history (shell-style Up/Down recall) =====
function resetPromptNav() { state.historyIndex = -1; state.historyDraft = ''; }

function seedPromptHistory(messages) {
    state.promptHistory = (messages || [])
        .filter((m) => m.role === 'user' && m.text)
        .map((m) => m.text);
    resetPromptNav();
}

function recordPrompt(text) {
    if (!text) return;
    const h = state.promptHistory;
    if (h[h.length - 1] !== text) h.push(text);
    resetPromptNav();
}

function applyHistoryValue(el, value) {
    el.value = value;
    autoGrow(el);
    setSendEnabled(!!el.value.trim() || !!state.pendingAttachments.length);
    const end = el.value.length;
    el.setSelectionRange(end, end);
}

// dir: -1 older (Up), +1 newer (Down). Returns true if it consumed the key.
function navPromptHistory(dir, el) {
    const h = state.promptHistory;
    if (!h.length) return false;
    if (state.historyIndex === -1) {
        if (dir > 0) return false;        // already at the live draft; nothing newer
        state.historyDraft = el.value;    // remember what was being typed
        state.historyIndex = h.length - 1;
    } else {
        const next = state.historyIndex + dir;
        if (next < 0) return true;        // clamp at the oldest entry (key consumed)
        if (next >= h.length) {           // past the newest → restore the draft
            const draft = state.historyDraft;
            resetPromptNav();
            applyHistoryValue(el, draft);
            return true;
        }
        state.historyIndex = next;
    }
    applyHistoryValue(el, h[state.historyIndex]);
    return true;
}

// ===== Sidebar (mobile) =====
function closeSidebar() { $('sidebar').classList.remove('open'); }

// ===== Message actions (copy, read aloud) =====
function buildMessageActions(node, m) {
    node.innerHTML = '';
    const text = (m && m.text) || '';
    if (!text.trim()) return;
    const copy = el('msg-action-btn', 'button');
    copy.type = 'button';
    copy.title = 'Copy message';
    copy.setAttribute('aria-label', 'Copy message');
    copy.textContent = '⧉';
    copy.onclick = () => copyMessageText(text);
    node.appendChild(copy);
    if (canSpeak()) {
        const speak = el('msg-action-btn', 'button');
        speak.type = 'button';
        speak.title = 'Read aloud';
        speak.setAttribute('aria-label', 'Read aloud');
        speak.textContent = '🔊';
        speak.onclick = () => speakText(text, speak);
        node.appendChild(speak);
    }
    // Regenerate — only acts on the last assistant message; CSS hides it elsewhere.
    const regen = el('msg-action-btn regen-btn', 'button');
    regen.type = 'button';
    regen.title = 'Regenerate this response';
    regen.setAttribute('aria-label', 'Regenerate this response');
    regen.textContent = '↻';
    regen.onclick = () => regenerateTurn();
    node.appendChild(regen);
}

// ===== Regenerate & edit-and-resend (re-run a Turn) =====

// Re-run the last user prompt, replacing the last assistant response. The server
// truncates to the last user message and streams a fresh answer.
async function regenerateTurn() {
    if (state.streaming) { toast('Finish the current turn first.'); return; }
    if (!state.current) return;
    const thread = $('thread');
    const assistants = thread.querySelectorAll('.msg-assistant');
    const lastEl = assistants[assistants.length - 1];
    if (lastEl) lastEl.remove();
    await _streamRerun({ endpoint: '/regenerate', body: {} });
}

// Turn a user bubble into an inline editor; on save, truncate the conversation at
// that message and re-run it with the new text.
function startEditMessage(wrap, m) {
    if (state.streaming) { toast('Finish the current turn first.'); return; }
    if (wrap.querySelector('.edit-box')) return;
    const bubble = wrap.querySelector('.bubble');
    const original = (m && m.text) || (bubble ? bubble.textContent : '');
    const box = el('edit-box');
    const ta = document.createElement('textarea');
    ta.className = 'edit-textarea';
    ta.value = original;
    const row = el('edit-actions');
    const save = el('btn btn-primary btn-small', 'button');
    save.type = 'button'; save.textContent = 'Save & resend';
    const cancel = el('btn btn-small', 'button');
    cancel.type = 'button'; cancel.textContent = 'Cancel';
    row.append(save, cancel);
    box.append(ta, row);
    wrap.appendChild(box);
    if (bubble) bubble.style.display = 'none';
    ta.focus();
    autoGrow(ta);
    ta.addEventListener('input', () => autoGrow(ta));
    const close = () => { box.remove(); if (bubble) bubble.style.display = ''; };
    cancel.onclick = close;
    ta.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.preventDefault(); close(); }
        else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save.click(); }
    });
    save.onclick = async () => {
        const next = ta.value.trim();
        if (!next) { toast('Message cannot be empty.'); return; }
        if (!m || !m.id) { toast('This message cannot be edited yet.'); return; }
        // Remove this bubble and everything after it; the server truncates to match.
        const thread = $('thread');
        let node = wrap;
        while (node) { const nx = node.nextElementSibling; node.remove(); node = nx; }
        thread.appendChild(buildUserEl({ id: m.id, text: next }));
        await _streamRerun({ endpoint: '/edit', body: { messageId: m.id, prompt: next } });
    };
}

// Shared streaming runner for regenerate/edit: appends a fresh assistant bubble,
// streams the response into it, and reconciles state afterwards.
async function _streamRerun({ endpoint, body }) {
    const thread = $('thread');
    const wrap = buildAssistantEl({ id: 'pending' });
    wrap._refs.content.classList.add('stream-caret');
    thread.appendChild(wrap);
    markLastAssistant();
    scrollThread();
    state.streaming = true;
    state.stopRequested = false;
    state.streamEndPromise = new Promise((resolve) => { state.streamEndResolve = resolve; });
    setStreamingUI(true);
    const conversationId = state.current.id;
    let raw = '';
    let think = '';
    let turnStopped = false;
    let renderScheduled = false;
    const renderLive = () => {
        renderScheduled = false;
        if (state.stopRequested || turnStopped) return;
        wrap._refs.content.innerHTML = renderMarkdown(raw);
        followThread();
    };
    try {
        await streamPost('/api/conversations/' + conversationId + endpoint, body, {
            start: (d) => { if (d && d.messageId) wrap.dataset.id = d.messageId; },
            delta: (d) => { if (!state.stopRequested) { raw += (d && d.text) || ''; if (!renderScheduled) { renderScheduled = true; requestAnimationFrame(renderLive); } } },
            reasoning: (d) => { if (!state.stopRequested) { think += (d && d.text) || ''; renderThinking(wrap, think); } },
            tasks: (d) => { if (!state.stopRequested && d && d.tasks) renderTasks(wrap._refs.tasks, d.tasks); },
            activity: (d) => { if (!state.stopRequested && d) noteActivity(wrap, d); },
            question: (d) => { if (!state.stopRequested) renderUserPrompt(wrap._refs.userPrompts, d, conversationId); },
            stopping: (d) => { turnStopped = true; state.stopRequested = true; setStoppingUI(); wrap._refs.content.classList.remove('stream-caret'); showInlineError(wrap, (d && d.message) || 'Turn stopped.'); },
            stopped: (m) => { turnStopped = true; wrap._refs.content.classList.remove('stream-caret'); finalizeAssistant(wrap, m, { isLast: true }); markLastAssistant(); followThread(); },
            done: (m) => { wrap._refs.content.classList.remove('stream-caret'); finalizeAssistant(wrap, m, { isLast: true }); markLastAssistant(); followThread(); },
            error: (d) => { wrap._refs.content.classList.remove('stream-caret'); showInlineError(wrap, (d && d.message) || 'Something went wrong.'); },
        });
    } catch (e) {
        wrap._refs.content.classList.remove('stream-caret');
        showInlineError(wrap, e.message || String(e));
    } finally {
        state.streaming = false;
        state.stopRequested = false;
        setStreamingUI(false);
        const resolveEnd = state.streamEndResolve;
        state.streamEndPromise = null; state.streamEndResolve = null;
        if (resolveEnd) resolveEnd();
        await refreshCurrentConversation();
        await loadConversations();
        await refreshUsage();
        if (explorerOpen()) refreshExplorer();
    }
}

// Silently refresh state.current.messages from the server (ids + authoritative
// content) without re-rendering, so edit/regenerate keep working after a re-run.
async function refreshCurrentConversation() {
    if (!state.current) return;
    try { state.current = await api('GET', '/api/conversations/' + state.current.id); } catch { /* keep optimistic */ }
    syncCheckpointDividers();
    renderContextMeter();
}

// The bubble for a live turn is built optimistically, before the server has
// taken the snapshot, so its checkpoint only exists once the conversation is
// refreshed. Fill the dividers in then rather than re-rendering the thread.
function syncCheckpointDividers() {
    const thread = $('thread');
    if (!thread || !state.current || !state.current.messages) return;
    for (const m of state.current.messages) {
        if (m.role !== 'user' || !m.checkpoint || !m.checkpoint.sha || !m.id) continue;
        const el = thread.querySelector(`.msg-user[data-id="${CSS.escape(m.id)}"]`);
        if (!el || (el.previousElementSibling && el.previousElementSibling.classList.contains('checkpoint'))) continue;
        thread.insertBefore(buildCheckpointEl(m), el);
    }
}

// ===== Voice: language =====
// Which language 🎤 Dictate and 🔊 Read aloud use. A per-machine input
// preference, so it lives in localStorage beside the theme rather than in
// Settings - the Host Server gains nothing from knowing it. "auto" follows the
// browser, which is only right while the browser's UI language and the language
// the user actually speaks agree; a German speaker on an English Windows got an
// English recogniser that transcribed nonsense.
const VOICE_LANGS = [
    { id: 'auto', label: 'Auto (browser language)' },
    { id: 'en-US', label: 'English (United States)' },
    { id: 'en-GB', label: 'English (United Kingdom)' },
    { id: 'de-DE', label: 'German (Germany)' },
    { id: 'de-AT', label: 'German (Austria)' },
    { id: 'de-CH', label: 'German (Switzerland)' },
];

function voiceLangPref() {
    const v = localStorage.getItem('ad_voicelang') || 'auto';
    return VOICE_LANGS.some((l) => l.id === v) ? v : 'auto';
}

function voiceLang() {
    const v = voiceLangPref();
    return v === 'auto' ? (navigator.language || 'en-US') : v;
}

function availableVoices() {
    try { return window.speechSynthesis.getVoices() || []; } catch { return []; }
}

function preferredVoiceName() { return localStorage.getItem('ad_voicename') || ''; }

// The list arrives late in Chrome and the picker is only in the DOM while
// Settings is open, so this has to be safe to call at any moment.
function renderVoiceOptions() {
    const sel = $('set-voice');
    if (!sel) return;
    const lang = voiceLang();
    const base = lang.toLowerCase().replace('_', '-').split('-')[0];
    const matches = availableVoices()
        .filter((v) => String(v.lang || '').toLowerCase().replace('_', '-').split('-')[0] === base);
    if (!matches.length) {
        sel.innerHTML = '<option value="">No voice installed for this language</option>';
        return;
    }
    const auto = pickVoice(matches, lang);
    const saved = preferredVoiceName();
    sel.innerHTML = `<option value="">Automatic${auto ? ' \u2014 ' + escapeHtml(auto.name) : ''}</option>` +
        matches.map((v) => `<option value="${escapeHtml(v.name)}" ${v.name === saved ? 'selected' : ''}>${escapeHtml(v.name)}</option>`).join('');
}

// ===== Voice: dictation (speech-to-text) =====
const voice = { rec: null, listening: false, base: '' };

function speechRecognitionCtor() {
    return window.SpeechRecognition || window.webkitSpeechRecognition || null;
}

function initVoice() {
    // Chrome loads the voice list asynchronously and returns [] until it lands,
    // so ask once up front or the first read-aloud misses its German voice.
    if (canSpeak()) {
        try { window.speechSynthesis.getVoices(); } catch { /* ignore */ }
        window.speechSynthesis.onvoiceschanged = () => renderVoiceOptions();
    }
    const micBtn = $('btn-mic');
    if (!micBtn || !speechRecognitionCtor()) return; // unsupported → stays hidden
    micBtn.classList.remove('hidden');
    micBtn.onclick = () => toggleDictation();
}

function toggleDictation() {
    if (voice.listening) { stopDictation(); return; }
    const Ctor = speechRecognitionCtor();
    if (!Ctor) return;
    const rec = new Ctor();
    rec.lang = voiceLang();
    rec.interimResults = true;
    rec.continuous = true;
    const promptEl = $('prompt');
    voice.base = promptEl.value ? promptEl.value.replace(/\s*$/, '') + ' ' : '';
    rec.onresult = (e) => {
        let finalText = '', interim = '';
        for (let i = e.resultIndex; i < e.results.length; i++) {
            const r = e.results[i];
            if (r.isFinal) finalText += r[0].transcript;
            else interim += r[0].transcript;
        }
        if (finalText) voice.base = (voice.base + finalText).replace(/\s*$/, '') + ' ';
        promptEl.value = (voice.base + interim).replace(/^\s+/, '');
        autoGrow(promptEl);
        setSendEnabled(!!promptEl.value.trim() || !!state.pendingAttachments.length);
    };
    rec.onerror = (e) => { if (e && e.error && e.error !== 'aborted') toast('Dictation: ' + e.error); stopDictation(); };
    rec.onend = () => { setMicState(false); voice.rec = null; voice.listening = false; };
    voice.rec = rec;
    voice.listening = true;
    setMicState(true);
    try { rec.start(); } catch { stopDictation(); }
}

function stopDictation() {
    voice.listening = false;
    setMicState(false);
    if (voice.rec) { try { voice.rec.stop(); } catch { /* ignore */ } voice.rec = null; }
}

function setMicState(on) {
    const btn = $('btn-mic');
    if (!btn) return;
    btn.classList.toggle('recording', on);
    btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    btn.title = on ? 'Stop dictation' : 'Dictate (speech to text)';
}

// ===== Voice: read aloud (text-to-speech) =====
const speech = { speaking: false, btn: null };

function canSpeak() { return 'speechSynthesis' in window && 'SpeechSynthesisUtterance' in window; }

function resetSpeakBtn() {
    if (speech.btn) { speech.btn.classList.remove('speaking'); speech.btn.textContent = '🔊'; speech.btn.title = 'Read aloud'; }
    speech.speaking = false;
    speech.btn = null;
}

function speakText(text, btn) {
    if (!canSpeak()) return;
    const wasSameBtn = speech.btn === btn;
    if (speech.speaking) { window.speechSynthesis.cancel(); resetSpeakBtn(); if (wasSameBtn) return; }
    const lang = voiceLang();
    const clean = numbersToSpeech(markdownToSpeech(text), lang);
    if (!clean.trim()) return;
    const u = new SpeechSynthesisUtterance(clean);
    u.lang = lang;
    const v = pickVoice(availableVoices(), lang, preferredVoiceName());
    if (v) u.voice = v;
    u.onend = () => resetSpeakBtn();
    u.onerror = () => resetSpeakBtn();
    speech.speaking = true;
    speech.btn = btn;
    if (btn) { btn.classList.add('speaking'); btn.textContent = '⏹'; btn.title = 'Stop reading'; }
    window.speechSynthesis.speak(u);
}

// ===== Artifacts (sandboxed preview of html / svg blocks) =====
const ARTIFACT_LANGS = new Set(['html', 'svg']);
const artifact = { src: '', lang: 'html', mode: 'preview' };

function decorateArtifacts(container) {
    container.querySelectorAll('pre[data-lang]').forEach((pre) => {
        const lang = (pre.getAttribute('data-lang') || '').toLowerCase();
        if (!ARTIFACT_LANGS.has(lang)) return;
        if (pre.querySelector('.artifact-btn')) return;
        const code = pre.querySelector('code');
        const src = code ? code.textContent : '';
        if (!src.trim()) return;
        const btn = el('artifact-btn', 'button');
        btn.type = 'button';
        btn.textContent = '▶ Preview';
        btn.title = 'Render this ' + lang.toUpperCase() + ' in a sandbox';
        btn.onclick = () => openArtifact(src, lang);
        pre.appendChild(btn);
    });
}

// Build a self-contained document with a strict CSP: inline html/svg/scripts may
// render, but the frame can reach no network, cookies, or storage. Combined with
// sandbox="allow-scripts" (no allow-same-origin) the frame runs at a null origin
// with no access to DeskPilot, the session token, or the user's files.
function artifactDoc(src, lang) {
    const csp = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:;">`;
    if (lang === 'svg') {
        return `<!doctype html><html><head><meta charset="utf-8">${csp}</head><body style="margin:0;display:grid;place-items:center;min-height:100vh">${src}</body></html>`;
    }
    if (/<head[\s>]/i.test(src)) return src.replace(/<head([\s>])/i, `<head$1${csp}`);
    return `<!doctype html><html><head><meta charset="utf-8">${csp}</head><body>${src}</body></html>`;
}

function openArtifact(src, lang) {
    artifact.src = src;
    artifact.lang = lang;
    $('artifact-title').textContent = (lang === 'svg' ? 'SVG' : 'HTML') + ' preview';
    $('artifact-backdrop').classList.remove('hidden');
    $('artifact-modal').classList.remove('hidden');
    setArtifactMode('preview');
}

function setArtifactMode(mode) {
    artifact.mode = mode;
    $('artifact-view-preview').classList.toggle('active', mode === 'preview');
    $('artifact-view-source').classList.toggle('active', mode === 'source');
    const body = $('artifact-body');
    body.innerHTML = '';
    if (mode === 'source') {
        const pre = el('artifact-source', 'pre');
        pre.textContent = artifact.src;
        body.appendChild(pre);
        return;
    }
    const frame = document.createElement('iframe');
    frame.className = 'artifact-frame';
    frame.setAttribute('sandbox', 'allow-scripts');
    frame.setAttribute('referrerpolicy', 'no-referrer');
    frame.setAttribute('srcdoc', artifactDoc(artifact.src, artifact.lang));
    body.appendChild(frame);
}

function closeArtifact() {
    $('artifact-backdrop').classList.add('hidden');
    $('artifact-modal').classList.add('hidden');
    $('artifact-body').innerHTML = '';
    artifact.src = '';
}

// ===== Composer insert menu (/ prompt files, # project files) =====
const composerMenu = { open: false, kind: null, ctx: null, items: [], filtered: [], active: 0 };

function fileMentionAvailable() { return !!(state.settings && state.settings.workspaceFolder); }

// Detect a leading "/" or "#" token at the caret (start of input or after space).
function composerTriggerContext() {
    const ta = $('prompt');
    const pos = ta.selectionStart;
    const upto = ta.value.slice(0, pos);
    const m = upto.match(/(?:^|\s)([/#])([^\s/#]*)$/);
    if (!m) return null;
    const trigger = m[1];
    const query = m[2];
    return { trigger, query, tokenStart: pos - (trigger.length + query.length), pos };
}

async function maybeOpenComposerMenu() {
    if (composerMenu.open) return;
    const ctx = composerTriggerContext();
    if (!ctx) return;
    if (ctx.trigger === '/') await openComposerMenu('prompt', ctx);
    else if (ctx.trigger === '#' && fileMentionAvailable()) await openComposerMenu('file', ctx);
}

async function loadPromptItems() {
    try {
        const data = await api('GET', '/api/customizations');
        const cat = ((data && data.categories) || []).find((c) => c.id === 'prompt');
        return (cat && cat.items) || [];
    } catch { return []; }
}

async function loadProjectFileItems() {
    try {
        const data = await api('GET', '/api/fs/find?q=');
        return (data && data.files) || [];
    } catch { return []; }
}

async function openComposerMenu(kind, ctx) {
    composerMenu.kind = kind;
    composerMenu.ctx = ctx || null;
    composerMenu.active = 0;
    $('composer-menu-title').textContent = kind === 'prompt' ? 'Insert a prompt file' : 'Reference a project file';
    const searchEl = $('composer-menu-search');
    searchEl.placeholder = kind === 'prompt' ? 'Filter prompt files…' : 'Filter project files…';
    $('composer-menu-list').innerHTML = '<div class="cust-empty">Loading…</div>';
    positionComposerMenu();
    $('composer-menu').classList.remove('hidden');
    composerMenu.open = true;
    composerMenu.items = kind === 'prompt' ? await loadPromptItems() : await loadProjectFileItems();
    searchEl.value = (ctx && ctx.query) || '';
    filterComposerMenu();
    searchEl.focus();
}

function positionComposerMenu() {
    const pop = $('composer-menu');
    const anchor = $('prompt');
    const rect = anchor.getBoundingClientRect();
    pop.style.transform = 'none';
    pop.style.bottom = (window.innerHeight - rect.top + 8) + 'px';
    const width = pop.offsetWidth || 360;
    pop.style.left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8)) + 'px';
}

function filterComposerMenu() {
    const q = $('composer-menu-search').value.trim().toLowerCase();
    const items = composerMenu.items;
    composerMenu.filtered = q
        ? items.filter((it) => ((it.name || '') + ' ' + (it.rel || it.description || it.path || '')).toLowerCase().includes(q))
        : items.slice(0, 200);
    if (composerMenu.active >= composerMenu.filtered.length) composerMenu.active = 0;
    renderComposerMenu();
}

function renderComposerMenu() {
    const list = $('composer-menu-list');
    list.innerHTML = '';
    const items = composerMenu.filtered;
    if (!items.length) {
        const empty = el('cust-empty');
        empty.textContent = composerMenu.kind === 'prompt'
            ? 'No prompt files. Add a prompt folder in Settings.'
            : (fileMentionAvailable() ? 'No files found.' : 'Select a project first.');
        list.appendChild(empty);
        return;
    }
    items.forEach((it, idx) => {
        const item = document.createElement('button');
        item.type = 'button';
        item.className = 'menu-item' + (idx === composerMenu.active ? ' selected' : '');
        item.setAttribute('role', 'menuitem');
        const primary = it.name || it.rel || it.path || '';
        const sub = composerMenu.kind === 'prompt' ? (it.description || it.path || '') : (it.rel || '');
        item.innerHTML = `<span class="check"></span><span class="menu-text"><span class="menu-name"></span><span class="menu-sub muted tiny"></span></span>`;
        item.querySelector('.menu-name').textContent = primary;
        item.querySelector('.menu-sub').textContent = shortText(sub, 70);
        item.title = it.path || primary;
        item.onmousemove = () => { if (composerMenu.active !== idx) { composerMenu.active = idx; renderComposerMenu(); } };
        item.onclick = () => chooseComposerItem(it);
        list.appendChild(item);
    });
}

function chooseComposerItem(it) {
    if (composerMenu.kind === 'prompt') insertPromptFile(it);
    else insertFileMention(it);
}

function composerMenuKeydown(e) {
    if (!composerMenu.open) return;
    const items = composerMenu.filtered;
    if (e.key === 'ArrowDown') { e.preventDefault(); composerMenu.active = Math.min(items.length - 1, composerMenu.active + 1); renderComposerMenu(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); composerMenu.active = Math.max(0, composerMenu.active - 1); renderComposerMenu(); }
    else if (e.key === 'Enter') { e.preventDefault(); if (items[composerMenu.active]) chooseComposerItem(items[composerMenu.active]); }
    else if (e.key === 'Escape') { e.preventDefault(); closeComposerMenu(); $('prompt').focus(); }
}

function closeComposerMenu() {
    $('composer-menu').classList.add('hidden');
    composerMenu.open = false;
    composerMenu.ctx = null;
}

function stripFrontmatter(text) {
    return (text || '').replace(/^\uFEFF?---\r?\n[\s\S]*?\r?\n---\r?\n?/, '').replace(/^\s+/, '');
}

function fillTemplateVars(body) {
    const names = [...new Set((body.match(/\{\{\s*[\w.-]+\s*\}\}/g) || []).map((m) => m.replace(/[{}]/g, '').trim()))];
    let out = body;
    for (const name of names) {
        const val = window.prompt('Value for “' + name + '”:', '');
        if (val === null) continue;
        const esc = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        out = out.replace(new RegExp('\\{\\{\\s*' + esc + '\\s*\\}\\}', 'g'), val);
    }
    return out;
}

async function insertPromptFile(item) {
    let data;
    try { data = await api('GET', '/api/customizations/content?category=prompt&path=' + encodeURIComponent(item.path)); }
    catch (e) { toast(e.message); return; }
    if (!data || data.error) { toast((data && data.error) || 'Could not read the prompt file.'); return; }
    if (data.binary) { toast('That file is not text.'); return; }
    replaceComposerToken(fillTemplateVars(stripFrontmatter(data.text || '')));
}

function insertFileMention(item) {
    replaceComposerToken('`' + (item.rel || item.name) + '`');
}

function replaceComposerToken(text) {
    const ta = $('prompt');
    const ctx = composerMenu.ctx;
    if (ctx) {
        const before = ta.value.slice(0, ctx.tokenStart);
        const after = ta.value.slice(ctx.pos);
        ta.value = before + text + after;
        const caret = (before + text).length;
        ta.setSelectionRange(caret, caret);
    } else {
        const sep = ta.value && !/\s$/.test(ta.value) ? '\n' : '';
        ta.value = ta.value + sep + text;
    }
    closeComposerMenu();
    autoGrow(ta);
    setSendEnabled(!!ta.value.trim() || !!state.pendingAttachments.length);
    ta.focus();
}

// ===== Explain this Customization =====
async function explainCustomization() {
    if (!cust.editor) return;
    const ed = cust.editor;
    const text = $('cust-editor').value || '';
    if (!text.trim()) { toast('Nothing to explain yet.'); return; }
    if (state.streaming) { toast('Finish the current turn first.'); return; }
    const noun = CUST_SINGULAR[ed.category] || 'customization';
    const prompt =
        `Explain this ${noun} in plain language for a non-technical reader: what it does, when it applies, ` +
        `and its key rules or steps. Be concise.\n\nFile: ${ed.name}\n\n\`\`\`markdown\n${text}\n\`\`\``;
    closeCustomizations();
    await newConversation();
    const ta = $('prompt');
    ta.value = prompt;
    autoGrow(ta);
    await send();
}

// ===== Command palette (Ctrl/Cmd+K) =====
const palette = { open: false, items: [], filtered: [], active: 0 };

function paletteCommands() {
    const cmds = [
        { label: 'New conversation', hint: 'Ctrl+Shift+O', run: () => newConversation() },
        { label: 'Go to home screen', run: () => goHome() },
        { label: 'Search conversations', run: () => { $('conv-search').focus(); } },
        { label: 'Open settings', run: () => openSettings() },
        { label: 'Open customizations', run: () => openCustomizations() },
        { label: 'Toggle light / dark theme', run: () => toggleTheme() },
        { label: 'Focus the message box', run: () => $('prompt').focus() },
    ];
    if (state.settings && state.settings.workspaceFolder) {
        cmds.push({ label: 'Save all changes', hint: 'commit', run: () => openSaveWizard() });
    }
    if (state.current) {
        cmds.push({ label: 'Regenerate last response', run: () => regenerateTurn() });
        cmds.push({ label: 'Export current conversation', run: () => exportConversation(state.current.id) });
    }
    return cmds;
}

function openPalette() {
    palette.open = true;
    palette.active = 0;
    $('palette-input').value = '';
    $('palette-backdrop').classList.remove('hidden');
    $('palette').classList.remove('hidden');
    filterPalette();
    $('palette-input').focus();
}

function closePalette() {
    palette.open = false;
    $('palette').classList.add('hidden');
    $('palette-backdrop').classList.add('hidden');
}

function filterPalette() {
    const q = $('palette-input').value.trim().toLowerCase();
    const cmds = paletteCommands().map((c) => ({ kind: 'command', label: c.label, hint: c.hint, run: c.run }));
    let items = cmds;
    if (q) {
        items = cmds.filter((c) => c.label.toLowerCase().includes(q));
        // Also offer matching conversations.
        for (const c of state.conversations) {
            if ((c.title || '').toLowerCase().includes(q)) {
                items.push({ kind: 'conversation', label: c.title || 'New conversation', hint: 'conversation', run: () => selectConversation(c.id) });
            }
        }
    }
    palette.filtered = items.slice(0, 50);
    if (palette.active >= palette.filtered.length) palette.active = 0;
    renderPalette();
}

function renderPalette() {
    const list = $('palette-list');
    list.innerHTML = '';
    if (palette.filtered.length === 0) {
        const empty = el('cust-empty');
        empty.textContent = 'No matching commands.';
        list.appendChild(empty);
        return;
    }
    palette.filtered.forEach((it, idx) => {
        const row = document.createElement('button');
        row.type = 'button';
        row.className = 'palette-item' + (idx === palette.active ? ' selected' : '');
        row.setAttribute('role', 'option');
        row.innerHTML = `<span class="palette-label"></span>${it.hint ? '<span class="palette-hint"></span>' : ''}`;
        row.querySelector('.palette-label').textContent = it.label;
        if (it.hint) row.querySelector('.palette-hint').textContent = it.hint;
        row.onmousemove = () => { if (palette.active !== idx) { palette.active = idx; renderPalette(); } };
        row.onclick = () => runPaletteItem(it);
        list.appendChild(row);
    });
}

function runPaletteItem(it) {
    closePalette();
    if (it && typeof it.run === 'function') {
        try { it.run(); } catch (e) { toast(e.message || String(e)); }
    }
}

function paletteKeydown(e) {
    if (!palette.open) return;
    const items = palette.filtered;
    if (e.key === 'ArrowDown') { e.preventDefault(); palette.active = Math.min(items.length - 1, palette.active + 1); renderPalette(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); palette.active = Math.max(0, palette.active - 1); renderPalette(); }
    else if (e.key === 'Enter') { e.preventDefault(); if (items[palette.active]) runPaletteItem(items[palette.active]); }
    else if (e.key === 'Escape') { e.preventDefault(); closePalette(); }
}

// ===== Global wiring =====
function wireGlobal() {
    $('btn-new').onclick = () => newConversation();
    $('btn-home').onclick = () => goHome();
    $('conv-search').addEventListener('input', (e) => runConversationSearch(e.target.value));
    $('conv-search').addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.target.value = ''; runConversationSearch(''); }
    });
    $('btn-show-archived').onclick = () => { state.showArchived = !state.showArchived; renderConversationList(); };
    $('btn-mark-all-read').onclick = () => markAllConversationsRead();
    $('btn-send').onclick = () => send();
    $('btn-dispatch').onclick = (e) => { e.stopPropagation(); toggleDispatchPopover(); };
    $('dispatch-stop-send').onclick = () => dispatchStopAndSend();
    $('dispatch-queue-add').onclick = () => dispatchEnqueue('queue');
    $('dispatch-steer').onclick = () => dispatchEnqueue('steer');
    $('btn-settings').onclick = () => openSettings();
    $('settings-close').onclick = () => closeSettings();
    $('settings-backdrop').onclick = () => closeSettings();
    $('btn-permissions').onclick = (e) => {
        e.stopPropagation();
        const pop = $('permissions-popover');
        if (pop.classList.contains('hidden')) { buildPermList($('perm-list')); pop.classList.remove('hidden'); }
        else pop.classList.add('hidden');
    };
    $('btn-project').onclick = (e) => { e.stopPropagation(); toggleProjectMenu(); };
    $('btn-agent').onclick = (e) => { e.stopPropagation(); toggleAgentMenu(); };
    $('btn-theme').onclick = () => toggleTheme();
    $('btn-files').onclick = () => toggleExplorer();
    $('explorer-refresh').onclick = () => refreshExplorer();
    wireExplorerAutoRefresh();
    wireExplorerResize();
    wireThreadFollow();
    $('btn-attach').onclick = () => $('file-input').click();
    $('file-input').addEventListener('change', (e) => {
        const files = Array.from(e.target.files || []);
        e.target.value = '';
        if (files.length) uploadFiles(files);
    });
    $('usage-chip').onclick = (e) => {
        e.stopPropagation();
        const pop = $('usage-popover');
        if (pop.classList.contains('hidden')) {
            // Populate the popover (grids + chart) from fresh data BEFORE revealing
            // it. refreshUsage's own populate call is guarded on the popover being
            // visible, which it isn't yet here, so do it explicitly.
            refreshUsage().then(() => {
                if (state.usage) populateUsagePopover(state.usage);
                pop.classList.remove('hidden');
            });
        }
        else pop.classList.add('hidden');
    };
    $('btn-context').onclick = (e) => {
        e.stopPropagation();
        openSessionInfo($('btn-context'));
    };
    $('btn-reset-lifetime').onclick = () => resetLifetime();
    document.querySelectorAll('.range-btn').forEach((b) => {
        b.addEventListener('click', (e) => { e.stopPropagation(); setUsageRange(Number(b.dataset.range)); });
    });
    $('btn-sidebar').onclick = () => $('sidebar').classList.toggle('open');
    $('auth-connect').onclick = () => startAuth();
    $('auth-recheck').onclick = () => recheckAuth();

    // Folder picker
    $('folder-close').onclick = () => closeFolderPicker(null);
    $('folder-cancel').onclick = () => closeFolderPicker(null);
    $('folder-backdrop').onclick = () => closeFolderPicker(null);
    $('folder-up').onclick = () => { if (folderCurrent.parent) folderNavigate(folderCurrent.parent); };
    $('folder-home').onclick = () => folderNavigate(folderCurrent.home || '');
    $('folder-newdir').onclick = () => folderMkdir();
    $('folder-select').onclick = () => folderConfirm();
    $('folder-name').addEventListener('input', (e) => { e.target.dataset.touched = '1'; });
    $('folder-path').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); folderNavigate(e.target.value.trim()); }
    });
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && !$('folder-modal').classList.contains('hidden')) closeFolderPicker(null);
    });

    // File viewer
    $('file-close').onclick = () => closeFileViewer();
    $('file-backdrop').onclick = () => closeFileViewer();
    $('file-view-rendered').onclick = () => setFileViewMode('rendered');
    $('file-view-raw').onclick = () => setFileViewMode('raw');
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && !$('file-modal').classList.contains('hidden')) closeFileViewer();
    });

    // CopilotAtelier setup (opt-in, consent-gated)
    $('atelier-close').onclick = () => closeAtelierSetup();
    $('atelier-backdrop').onclick = () => closeAtelierSetup();
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && !$('atelier-modal').classList.contains('hidden')) closeAtelierSetup();
    });

    // Customizations (manage AI resources)
    $('btn-customizations').onclick = () => openCustomizations();
    $('cust-close').onclick = () => closeCustomizations();
    $('cust-backdrop').onclick = () => closeCustomizations();
    $('cust-back').onclick = () => backToCustList();
    $('cust-new').onclick = () => newCustomization();
    $('cust-save').onclick = () => saveCustEditor();
    $('cust-view-edit').onclick = () => setCustViewMode('edit');
    $('cust-view-preview').onclick = () => setCustViewMode('preview');
    $('cust-search').addEventListener('input', (e) => { cust.search = e.target.value; renderCustItems(); });
    $('cust-editor').addEventListener('input', onCustEditorInput);
    $('cust-editor').addEventListener('scroll', syncGutterScroll);
    $('cust-editor').addEventListener('keydown', custEditorKeydown);
    document.addEventListener('keydown', (e) => {
        if ($('cust-modal').classList.contains('hidden')) return;
        const inEditor = !$('cust-editor-view').classList.contains('hidden');
        if (e.key === 'Escape') {
            if (inEditor) backToCustList();
            else closeCustomizations();
        } else if (inEditor && (e.ctrlKey || e.metaKey) && (e.key === 's' || e.key === 'S')) {
            e.preventDefault();
            saveCustEditor();
        }
    });
    $('cust-explain').onclick = () => explainCustomization();

    // Artifact preview
    $('artifact-close').onclick = () => closeArtifact();
    $('artifact-backdrop').onclick = () => closeArtifact();
    $('artifact-view-preview').onclick = () => setArtifactMode('preview');
    $('artifact-view-source').onclick = () => setArtifactMode('source');
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && !$('artifact-modal').classList.contains('hidden')) closeArtifact();
    });

    // Merge Wizard
    $('merge-close').onclick = () => closeMergeWizard();
    $('merge-backdrop').onclick = () => closeMergeWizard();
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && !$('merge-modal').classList.contains('hidden')) closeMergeWizard();
    });

    // Branch Wizard
    $('branch-close').onclick = () => closeBranchWizard();
    $('branch-backdrop').onclick = () => closeBranchWizard();
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && !$('branch-modal').classList.contains('hidden')) closeBranchWizard();
    });

    // Save (bulk commit)
    $('save-close').onclick = () => closeSaveWizard();
    $('save-backdrop').onclick = () => closeSaveWizard();
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && saveWizIsOpen()) closeSaveWizard();
    });

    // Diff viewer
    $('diff-close').onclick = () => closeDiffViewer();
    $('diff-backdrop').onclick = () => closeDiffViewer();
    $('diff-prev').onclick = () => diffStep(-1);
    $('diff-next').onclick = () => diffStep(1);
    document.addEventListener('keydown', (e) => {
        if ($('diff-modal').classList.contains('hidden')) return;
        if (e.key === 'Escape') { closeDiffViewer(); return; }
        const inField = /^(INPUT|TEXTAREA|SELECT)$/.test((e.target && e.target.tagName) || '');
        if (inField) return;
        if (e.key === 'ArrowDown' || e.key === 'j') { e.preventDefault(); diffStep(1); }
        else if (e.key === 'ArrowUp' || e.key === 'k') { e.preventDefault(); diffStep(-1); }
    });

    // Composer insert menu (/ prompt files, # project files)
    $('btn-insert').onclick = (e) => {
        e.stopPropagation();
        if (composerMenu.open) { closeComposerMenu(); return; }
        openComposerMenu('prompt', null);
    };
    $('composer-menu-search').addEventListener('input', () => filterComposerMenu());
    $('composer-menu-search').addEventListener('keydown', composerMenuKeydown);

    // Command palette + global keyboard shortcuts.
    $('palette-backdrop').onclick = () => closePalette();
    $('palette-input').addEventListener('input', () => filterPalette());
    $('palette-input').addEventListener('keydown', paletteKeydown);
    document.addEventListener('keydown', (e) => {
        const inField = /^(INPUT|TEXTAREA|SELECT)$/.test((e.target && e.target.tagName) || '') || (e.target && e.target.isContentEditable);
        if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
            e.preventDefault();
            if (palette.open) closePalette(); else openPalette();
            return;
        }
        if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === 'o' || e.key === 'O')) {
            e.preventDefault();
            newConversation();
            return;
        }
        if (e.key === '/' && !inField && !palette.open) {
            e.preventDefault();
            $('prompt').focus();
        }
    });

    // Drag-and-drop attachments onto the composer
    const composerEl = document.querySelector('.composer');
    if (composerEl) {
        ['dragenter', 'dragover'].forEach((ev) => composerEl.addEventListener(ev, (e) => {
            if (e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files')) {
                e.preventDefault();
                composerEl.classList.add('drag-over');
            }
        }));
        composerEl.addEventListener('dragleave', (e) => { if (e.target === composerEl) composerEl.classList.remove('drag-over'); });
        composerEl.addEventListener('drop', (e) => {
            e.preventDefault();
            composerEl.classList.remove('drag-over');
            const files = Array.from((e.dataTransfer && e.dataTransfer.files) || []);
            if (files.length) uploadFiles(files);
        });
    }

    const promptEl = $('prompt');
    wireClipboardAttachments(promptEl, uploadFiles);
    promptEl.addEventListener('input', () => {
        // Real typing exits history navigation (programmatic value sets don't fire input).
        state.historyIndex = -1;
        autoGrow(promptEl);
        setSendEnabled(!!promptEl.value.trim() || !!state.pendingAttachments.length);
        maybeOpenComposerMenu();
    });
    promptEl.addEventListener('keydown', (e) => {
        // While a Turn is streaming the send keystroke steers instead, and adding
        // Alt queues. Shift+Enter still inserts a newline.
        if (state.streaming && isSendKey(e)) {
            e.preventDefault();
            if (e.altKey) dispatchEnqueue('queue');
            else dispatchEnqueue('steer');
            return;
        }
        if (isSendKey(e)) { e.preventDefault(); send(); return; }
        if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
        const navigating = state.historyIndex !== -1;
        const collapsed = promptEl.selectionStart === promptEl.selectionEnd;
        const atFirstLine = collapsed && !promptEl.value.slice(0, promptEl.selectionStart).includes('\n');
        const atLastLine = collapsed && !promptEl.value.slice(promptEl.selectionEnd).includes('\n');
        if (e.key === 'ArrowUp' && (navigating || atFirstLine)) {
            if (navPromptHistory(-1, promptEl)) e.preventDefault();
        } else if (e.key === 'ArrowDown' && navigating && atLastLine) {
            if (navPromptHistory(1, promptEl)) e.preventDefault();
        }
    });

    $('conv-title').addEventListener('change', async () => {
        if (!state.current) return;
        try {
            await api('PATCH', '/api/conversations/' + state.current.id, { title: $('conv-title').value });
            await loadConversations();
        } catch (e) { toast(e.message); }
    });

    $('model-select').addEventListener('change', async () => {
        if (!state.current) return;
        const model = $('model-select').value;
        try {
            await api('PATCH', '/api/conversations/' + state.current.id, { model });
            state.current.model = model;
        } catch (e) { toast(e.message); }
    });

    // dismiss popover on outside click
    document.addEventListener('click', (e) => {
        const perm = $('permissions-popover');
        if (!perm.classList.contains('hidden') && !perm.contains(e.target) && e.target.id !== 'btn-permissions') {
            perm.classList.add('hidden');
        }
        const usage = $('usage-popover');
        if (!usage.classList.contains('hidden') && !usage.contains(e.target) && !$('usage-chip').contains(e.target)) {
            usage.classList.add('hidden');
        }
        const session = $('session-popover');
        if (session && !session.classList.contains('hidden') && !session.contains(e.target) && !$('btn-context').contains(e.target)) {
            session.classList.add('hidden');
        }
        const project = $('project-popover');
        if (!project.classList.contains('hidden') && !project.contains(e.target) && !$('btn-project').contains(e.target)) {
            closeProjectMenu();
        }
        const agent = $('agent-popover');
        if (!agent.classList.contains('hidden') && !agent.contains(e.target) && !$('btn-agent').contains(e.target)) {
            closeAgentMenu();
        }
        const dispatch = $('dispatch-popover');
        if (dispatch && !dispatch.classList.contains('hidden') && !dispatch.contains(e.target) && !$('btn-dispatch').contains(e.target)) {
            closeDispatchPopover();
        }
        const cmenu = $('composer-menu');
        if (cmenu && !cmenu.classList.contains('hidden') && !cmenu.contains(e.target) && !$('btn-insert').contains(e.target)) {
            closeComposerMenu();
        }
    });

    initVoice();
}

init();
