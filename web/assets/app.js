import { renderMarkdown } from './markdown.js';

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
    pendingAttachments: [],
    agents: [],
    usageRange: 14,
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
    wireGlobal();
    renderExamples();
    let health = null;
    try { health = await api('GET', '/api/health'); } catch { /* offline */ }
    if (!health) { showBanner('Cannot reach the DeskPilot Host Server. Is it still running?'); return; }
    if (health.engineError) showBanner('Engine not loaded: ' + health.engineError);
    try { await loadSettings(); } catch { /* defaults */ }
    if (health.authenticated) await enterApp();
    else showAuth();
}

async function enterApp() {
    hideAuth();
    await loadModels();
    await loadAgents();
    await loadConversations();
    await refreshUsage();
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
    return [
        ['Credits', formatCredits(block.credits), true],
        ['Cost', '$' + (block.costUSD || 0).toFixed(4), false],
        ['Tokens', (block.totalTokens || 0).toLocaleString(), false],
        ['Turns', (block.turns || 0).toLocaleString(), false],
    ];
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
        const del = el('conv-del', 'button');
        del.textContent = '✕';
        del.title = 'Delete';
        del.onclick = (e) => { e.stopPropagation(); deleteConversation(c.id); };
        item.append(menu, del);
        item.onclick = () => selectConversation(c.id);
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

// Sum the per-Message Usage (cost, credits, tokens) across a Conversation.
function sumConversationUsage(messages) {
    let costUSD = 0, credits = 0, totalTokens = 0;
    for (const m of asArray(messages)) {
        const u = m.usage || {};
        costUSD += Number(u.costUSD) || 0;
        credits += Number(u.credits) || 0;
        totalTokens += Number(u.totalTokens) || 0;
    }
    return { costUSD, credits, totalTokens };
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
        setVal('Cost', '$' + u.costUSD.toFixed(4));
        setVal('Credits', formatCredits(u.credits));
        setVal('Tokens', u.totalTokens.toLocaleString());
    } catch {
        setVal('Cost', '—'); setVal('Credits', '—'); setVal('Tokens', '—');
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
    closeSidebar();
    $('prompt').focus();
}

async function selectConversation(id) {
    state.current = await api('GET', '/api/conversations/' + id);
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
    closeSidebar();
}

async function deleteConversation(id) {
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
    // Edit & resend (only meaningful for a persisted message with an id).
    if (m && m.id && m.text) {
        const actions = el('user-actions');
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
    const content = el('content');
    const tasks = el('tasks-panel hidden');
    const activity = el('disclosure activity hidden', 'details');
    const usage = el('usage-foot hidden');
    wrap.append(role, thinking, content, tasks, activity, usage);
    wrap._refs = { content, thinking, tasks, activity, usage, actions };
    return wrap;
}

function finalizeAssistant(wrap, m, opts) {
    const r = wrap._refs;
    r.content.innerHTML = renderMarkdown(m.text || '');
    hydrateCopies(r.content);
    decorateArtifacts(r.content);
    if (r.actions) buildMessageActions(r.actions, m, opts && opts.isLast);
    if (m.reasoning) {
        wrap.querySelector('.thinking').classList.remove('hidden');
        wrap.querySelector('.thinking .disclosure-body').textContent = m.reasoning;
    }
    renderTasks(r.tasks, m.tasks);
    renderActivity(r.activity, m.activity);
    renderUsage(r.usage, m);
    return wrap;
}

function renderActivity(node, activity) {
    if (!activity) { node.classList.add('hidden'); return; }
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
    const undoBtn = (gitOn && written.length > 0)
        ? `<button class="btn btn-small git-undo-btn" type="button" title="Revert these file changes using Git">↩ Undo file changes</button>`
        : '';
    node.innerHTML =
        `<summary>Activity — ${n} action${n === 1 ? '' : 's'}</summary>` +
        `<div class="disclosure-body"><div class="activity-list">${items.join('') || '<span class="muted tiny">' + toolCount + ' tool call(s)</span>'}</div>${undoBtn}</div>`;
    node.querySelectorAll('.git-diff-btn').forEach((btn) => {
        btn.onclick = (e) => { e.preventDefault(); toggleGitDiff(btn.dataset.path, btn.closest('.activity-item')); };
    });
    const undo = node.querySelector('.git-undo-btn');
    if (undo) undo.onclick = (e) => { e.preventDefault(); undoTurnFiles(written, undo); };
}

// Toggle an inline, colourised Git diff for a written file beneath its row.
async function toggleGitDiff(path, row) {
    if (!row) return;
    const existing = row.nextElementSibling;
    if (existing && existing.classList.contains('git-diff-block')) { existing.remove(); return; }
    let data;
    try { data = await api('GET', '/api/git/diff?path=' + encodeURIComponent(path)); }
    catch (e) { toast(e.message); return; }
    if (data.error) { toast(data.error); return; }
    const block = el('git-diff-block');
    if (data.untracked) {
        if (data.binary) { block.innerHTML = '<div class="muted tiny">New binary file (no text preview).</div>'; }
        else {
            const pre = el('git-diff', 'pre');
            pre.appendChild(diffLine('New file:', 'meta'));
            for (const ln of (data.content || '').split('\n')) pre.appendChild(diffLine(ln, 'add'));
            block.appendChild(pre);
        }
    } else if (!data.diff || !data.diff.trim()) {
        block.innerHTML = '<div class="muted tiny">No tracked changes against the last commit.</div>';
    } else {
        const pre = el('git-diff', 'pre');
        for (const ln of data.diff.split('\n')) {
            const cls = ln.startsWith('+') && !ln.startsWith('+++') ? 'add'
                : ln.startsWith('-') && !ln.startsWith('---') ? 'del'
                    : ln.startsWith('@@') ? 'hunk'
                        : /^(diff |index |--- |\+\+\+ )/.test(ln) ? 'meta' : '';
            pre.appendChild(diffLine(ln, cls));
        }
        block.appendChild(pre);
    }
    row.insertAdjacentElement('afterend', block);
}

function diffLine(text, cls) {
    const span = document.createElement('span');
    span.className = 'diff-line' + (cls ? ' diff-' + cls : '');
    span.textContent = text === '' ? '\u200b' : text;
    return span;
}

// Undo the file changes a Turn made: revert tracked files to the last commit and
// delete files the Turn newly created. Confirmed first because it is destructive.
async function undoTurnFiles(paths, btn) {
    const list = asArray(paths).map(String);
    if (list.length === 0) return;
    const msg = 'Undo file changes from this turn?\n\n' +
        'Tracked files are reverted to the last Git commit, and files this turn created are deleted. ' +
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
        if (state.explorerPath) refreshExplorer();
        if (typeof refreshGitBar === 'function') { try { refreshGitBar(); } catch { /* optional */ } }
    } catch (e) { toast(e.message); }
    finally { if (btn) { btn.disabled = false; btn.textContent = '↩ Undo file changes'; } }
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

function renderUsage(node, m) {
    const u = m.usage || {};
    const bits = [];
    if (u.totalTokens) bits.push(`${u.totalTokens.toLocaleString()} tokens`);
    if (u.costUSD) bits.push(`$${u.costUSD.toFixed(4)}`);
    if (u.credits) bits.push(`${u.credits} credits`);
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

function scrollThread() {
    const t = $('thread');
    t.scrollTop = t.scrollHeight;
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
    if (state.pendingAttachments.length) {
        const count = state.pendingAttachments.length;
        const hasWorkspace = !!(state.settings && state.settings.workspaceFolder);
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
    await _runTurn({ prompt, displayText: prompt });
}

// Core Turn runner. `prompt` is what the server sees; `displayText` is what the
// user bubble shows; `dispatch` (optional) is 'queued' or 'steered' and renders
// a small badge below the bubble so the user sees how the message was sent.
async function _runTurn({ prompt, displayText, dispatch }) {
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
    state.streamEndPromise = new Promise((resolve) => { state.streamEndResolve = resolve; });
    setStreamingUI(true);
    let raw = '';
    let think = '';
    // Render the live answer as Markdown, but coalesce to one paint per frame so a
    // fast token stream doesn't re-parse the whole message on every delta.
    let renderScheduled = false;
    const renderLive = () => {
        renderScheduled = false;
        wrap._refs.content.innerHTML = renderMarkdown(raw);
        scrollThread();
    };

    try {
        await streamPost('/api/conversations/' + state.current.id + '/messages', { prompt }, {
            start: (d) => { if (d && d.messageId) wrap.dataset.id = d.messageId; if (d && d.userMessageId) userEl.dataset.id = d.userMessageId; },
            delta: (d) => {
                raw += (d && d.text) || '';
                if (!renderScheduled) {
                    renderScheduled = true;
                    requestAnimationFrame(renderLive);
                }
            },
            reasoning: (d) => {
                think += (d && d.text) || '';
                wrap.querySelector('.thinking').classList.remove('hidden');
                wrap.querySelector('.thinking .disclosure-body').textContent = think;
            },
            tasks: (d) => { if (d && d.tasks) renderTasks(wrap._refs.tasks, d.tasks); },
            done: (m) => {
                wrap._refs.content.classList.remove('stream-caret');
                finalizeAssistant(wrap, m, { isLast: true });
                markLastAssistant();
                scrollThread();
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
        // Give a brand-new Conversation a concise AI title (like GitHub Copilot).
        await maybeAutoTitle();
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

async function stopTurn() {
    if (!state.current) return;
    try { await api('POST', '/api/conversations/' + state.current.id + '/stop'); } catch { /* ignore */ }
    toast('Stopping…');
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
        hint.innerHTML = '<span class="spinner"></span> Working…';
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
    label.textContent = selected ? selected.name : (list.length ? 'No project' : 'No project');
    label.title = selected ? selected.path : '';
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
    } catch { state.agents = []; }
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
        return;
    }

    const divider = el('menu-divider');
    menu.appendChild(divider);

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
    refreshGitBar(silent);
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
        if (!explorerOpen() || document.visibilityState !== 'visible') return;
        const active = document.activeElement;
        if (active && $('explorer').contains(active)) return;
        refreshExplorer({ silent: true });
    };
    window.addEventListener('focus', tick);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') tick(); });
    setInterval(tick, 5000);
}

// ===== Git bar (in the explorer) =====
async function refreshGitBar(silent) {
    const bar = $('git-bar');
    if (!bar) return;
    if (!(state.settings && state.settings.workspaceFolder)) { bar.classList.add('hidden'); return; }
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
    renderGitBar(status, branchData);
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

function renderGitBar(status, branchData) {
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

    // The "Merge into <default>…" entry point opens the guided Merge Wizard.
    // Hidden when the Default Branch is already the current branch: there is no
    // feature branch to bring in, so "Merge into main" while on main is moot.
    const currentBranch = (branchData && branchData.currentBranch) || (status.detached ? null : status.branch);
    if (def && currentBranch !== def) {
        const mergeBtn = document.createElement('button');
        mergeBtn.className = 'btn btn-small git-merge-btn';
        mergeBtn.textContent = `Merge into ${def}…`;
        mergeBtn.title = `Merge a branch into ${def} with a guided wizard`;
        mergeBtn.onclick = () => openMergeWizard();
        bar.append(mergeBtn);
    }
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
    row.innerHTML = `<span class="tree-caret">▸</span><span class="tree-ico">📁</span><span class="tree-name"></span>`;
    row.querySelector('.tree-name').textContent = ent.name;
    row.title = ent.path;
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
    row.innerHTML = `<span class="tree-caret"></span><span class="tree-ico">📄</span><span class="tree-name"></span><span class="tree-size muted tiny">${formatBytes(ent.bytes)}</span>`;
    row.querySelector('.tree-name').textContent = ent.name;
    row.title = ent.path;
    row.onclick = () => openFileViewer(ent);
    li.appendChild(row);
    return li;
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
function openSettings() {
    const body = $('settings-body');
    const s = state.settings || {};
    body.innerHTML = `
    <div class="field">
      <label>Default model</label>
      <select id="set-model">${(state.models.length ? state.models.map((m) => m.id) : [s.model].filter(Boolean))
            .map((id) => `<option value="${id}" ${id === s.model ? 'selected' : ''}>${id}</option>`).join('')}</select>
      <p class="hint">Used for new conversations.</p>
    </div>
    <div class="field">
      <label>Permissions</label>
      <div class="perm-list" id="set-perms"></div>
    </div>
    <div class="field">
      <label>Projects</label>
      <div class="projects-manager" id="set-projects"></div>
      <div class="project-add">
        <button class="btn btn-small" id="proj-browse">📁 Add project…</button>
      </div>
      <p class="hint">A project is a working folder. The selected project is where the File and Terminal tools work, and is the default for new prompts.</p>
    </div>
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
    <div class="field">
      <label>About you (preferences)</label>
      <textarea id="set-preferences" rows="4" placeholder="e.g. I'm a paralegal. Write in plain British English, cite sources, and keep answers concise.">${escapeHtml(s.preferences || '')}</textarea>
      <p class="hint">A durable note about you — role, writing style, recurring context. Added to every turn so the agent serves you consistently.</p>
    </div>
    <div class="field">
      <label>Reference files (one project-relative path per line)</label>
      <textarea id="set-reffiles" rows="3" placeholder="docs/style-guide.md&#10;data/contacts.csv">${escapeHtml((s.referenceFiles || []).join('\n'))}</textarea>
      <p class="hint">Files the agent should always treat as relevant for the selected project. Their paths are added to every turn so the agent reads them with its File tool when useful (no vector database needed).</p>
    </div>
    <div class="field">
      <label>Spend warning (USD this session, 0 = off)</label>
      <input type="number" id="set-budget" min="0" step="0.5" value="${(s.costBudgetUSD || 0)}" />
      <p class="hint">Shows a one-time warning when this session's estimated cost crosses the amount.</p>
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
      <label>Max tool iterations</label>
      <input type="number" id="set-maxiter" min="1" value="${s.maxToolIterations || 25}" />
    </div>
    <div class="field">
      <label>Theme</label>
      <select id="set-theme">
        ${['system', 'light', 'dark'].map((t) => `<option value="${t}" ${(localStorage.getItem('ad_theme') || 'system') === t ? 'selected' : ''}>${t}</option>`).join('')}
      </select>
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
    </div>`;

    buildPermList($('set-perms'));
    renderProjectsManager();

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
    $('set-preferences').onchange = (e) => save({ preferences: e.target.value.trim() || null });
    $('set-reffiles').onchange = (e) => save({ referenceFiles: e.target.value.split('\n').map((x) => x.trim()).filter(Boolean) });
    $('set-budget').onchange = (e) => { state._budgetWarned = false; save({ costBudgetUSD: parseFloat(e.target.value) || 0 }); };
    $('set-maxiter').onchange = (e) => save({ maxToolIterations: parseInt(e.target.value, 10) || 25 });
    $('set-theme').onchange = (e) => { localStorage.setItem('ad_theme', e.target.value); applyTheme(); };
    $('set-reauth').onclick = () => { closeSettings(); showAuth({ expired: true }); };
    $('atelier-refresh').onclick = () => loadAtelierHealth();
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

async function startAuth() {
    const steps = $('auth-steps');
    const errEl = $('auth-error');
    errEl.classList.add('hidden');
    steps.classList.remove('hidden');
    steps.innerHTML = '<div class="muted">Starting…</div>';
    $('auth-connect').disabled = true;
    try {
        await streamPost('/api/auth/start', { force: !!state.authForce }, {
            waiting: (d) => { steps.innerHTML = `<div class="muted">${escapeHtml((d && d.message) || 'Working…')}</div>`; },
            code: (d) => { appendAuthLine(steps, (d && d.message) || ''); },
            done: async (d) => {
                if (d && d.authenticated) { toast('Signed in.'); await enterApp(); }
                else { errEl.textContent = 'Sign-in did not complete. Try again.'; errEl.classList.remove('hidden'); }
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

function appendAuthLine(container, line) {
    if (container.querySelector('.muted')) container.innerHTML = '';
    const codeMatch = line.match(/\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/);
    const urlMatch = line.match(/https?:\/\/\S+/);
    const div = document.createElement('div');
    if (codeMatch) {
        div.innerHTML = escapeHtml(line.replace(codeMatch[1], '')).trim() + `<div class="code-pill">${codeMatch[1]}</div>`;
    } else if (urlMatch) {
        const safe = urlMatch[0].replace(/"/g, '%22');
        div.innerHTML = escapeHtml(line.replace(urlMatch[0], '')).trim() + ` <a href="${safe}" target="_blank" rel="noopener noreferrer">${escapeHtml(urlMatch[0])}</a>`;
    } else {
        div.textContent = line;
    }
    container.appendChild(div);
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
    copy.onclick = () => navigator.clipboard.writeText(text).then(() => toast('Copied message.'), () => toast('Copy failed.'));
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
    state.streamEndPromise = new Promise((resolve) => { state.streamEndResolve = resolve; });
    setStreamingUI(true);
    let raw = '';
    let think = '';
    let renderScheduled = false;
    const renderLive = () => { renderScheduled = false; wrap._refs.content.innerHTML = renderMarkdown(raw); scrollThread(); };
    try {
        await streamPost('/api/conversations/' + state.current.id + endpoint, body, {
            start: (d) => { if (d && d.messageId) wrap.dataset.id = d.messageId; },
            delta: (d) => { raw += (d && d.text) || ''; if (!renderScheduled) { renderScheduled = true; requestAnimationFrame(renderLive); } },
            reasoning: (d) => { think += (d && d.text) || ''; wrap.querySelector('.thinking').classList.remove('hidden'); wrap.querySelector('.thinking .disclosure-body').textContent = think; },
            tasks: (d) => { if (d && d.tasks) renderTasks(wrap._refs.tasks, d.tasks); },
            done: (m) => { wrap._refs.content.classList.remove('stream-caret'); finalizeAssistant(wrap, m, { isLast: true }); markLastAssistant(); scrollThread(); },
            error: (d) => { wrap._refs.content.classList.remove('stream-caret'); showInlineError(wrap, (d && d.message) || 'Something went wrong.'); },
        });
    } catch (e) {
        wrap._refs.content.classList.remove('stream-caret');
        showInlineError(wrap, e.message || String(e));
    } finally {
        state.streaming = false;
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
}

// ===== Voice: dictation (speech-to-text) =====
const voice = { rec: null, listening: false, base: '' };

function speechRecognitionCtor() {
    return window.SpeechRecognition || window.webkitSpeechRecognition || null;
}

function initVoice() {
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
    rec.lang = navigator.language || 'en-US';
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
    // Strip code so the reader doesn't dictate punctuation soup.
    const clean = text.replace(/```[\s\S]*?```/g, ' (code block) ').replace(/`([^`]+)`/g, '$1');
    if (!clean.trim()) return;
    const u = new SpeechSynthesisUtterance(clean);
    u.lang = navigator.language || 'en-US';
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
    promptEl.addEventListener('input', () => {
        // Real typing exits history navigation (programmatic value sets don't fire input).
        state.historyIndex = -1;
        autoGrow(promptEl);
        setSendEnabled(!!promptEl.value.trim() || !!state.pendingAttachments.length);
        maybeOpenComposerMenu();
    });
    promptEl.addEventListener('keydown', (e) => {
        // While a Turn is streaming, Enter steers and Alt+Enter queues. Both
        // skip the normal send path. Shift+Enter still inserts a newline.
        if (state.streaming && e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            if (e.altKey) dispatchEnqueue('queue');
            else dispatchEnqueue('steer');
            return;
        }
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); return; }
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
