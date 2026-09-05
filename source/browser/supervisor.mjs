// The supervised browser process for contained automation (decision 0003).
//
// Runs as a child of the Host Server, never inside it. Three reasons, all
// structural: the Engine Runspace is single-threaded and everything already
// queues behind it; a crashed page must not take DeskPilot with it; and Stop has
// to kill a whole process tree, which is only meaningful when there is a tree to
// kill.
//
// The only input channel is stdin, which is how the trifecta stays broken. Page
// content cannot reach stdin, so no page can widen its own scope, grant itself a
// host, or ask for an action the workflow does not expose. The Model cannot
// either - it speaks to PowerShell, which speaks here, and neither hands the
// page a way back up.
//
// Protocol: one JSON object per line in, one per line out. Requests carry an id
// and are answered with that id. Unsolicited lines carry an `event` instead, and
// exist so a refusal shows up in Activity rather than only in a log.

import { chromium } from 'playwright';
import { createInterface } from 'node:readline';
import { resolveUrlDecision, isResourceAllowed, normalizeScopeEntry } from './policy.mjs';

// Bounds, so a hostile or merely broken page cannot exhaust the session. Every
// one of these is a refusal the user can see, not a silent truncation of intent.
const LIMITS = {
    actions: 50,
    navigations: 20,
    pageTextChars: 20000,
    links: 200,
    screenshots: 10,
    actionTimeoutMs: 30000,
    navigationTimeoutMs: 45000
};

const state = {
    scope: [],
    browser: null,
    context: null,
    page: null,
    actions: 0,
    navigations: 0,
    screenshots: 0,
    blocked: []
};

function emit(payload) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
}

// Refusals are reported, never silently dropped: a page that tried to reach
// somewhere is evidence, and Activity is where the user sees it. Bounded so a
// page looping on a blocked request cannot grow the process without limit.
function recordBlocked(reason, url, resourceType) {
    const entry = { reason, url: String(url).slice(0, 500), resourceType };
    if (state.blocked.length < 200) state.blocked.push(entry);
    emit({ event: 'blocked', ...entry });
}

async function ensureBrowser() {
    if (state.browser) return;

    state.browser = await chromium.launch({
        headless: false,
        // No personal profile is reachable from here: launch() plus a fresh
        // context is ephemeral by construction - no cookie jar on disk, no
        // history, no password store, no extensions, no ambient single sign-on.
        args: ['--no-default-browser-check', '--no-first-run', '--disable-extensions']
    });

    state.context = await state.browser.newContext({
        acceptDownloads: false,
        // Nothing is granted. A page asking for geolocation, notifications,
        // camera or clipboard is refused without reaching the user, because the
        // first workflow needs none of them and a prompt is a decision surface
        // an injected page should not get to open.
        permissions: []
    });
    state.context.setDefaultTimeout(LIMITS.actionTimeoutMs);
    state.context.setDefaultNavigationTimeout(LIMITS.navigationTimeoutMs);

    // The in-path enforcement point. PowerShell has already approved the
    // top-level URL, but only this sees redirect chains, nested frames and
    // every sub-resource the page asks for.
    await state.context.route('**/*', async (route, request) => {
        const url = request.url();
        const resourceType = request.resourceType();

        if (request.isNavigationRequest()) {
            const decision = resolveUrlDecision(url, state.scope);
            if (decision.decision !== 'allow') {
                recordBlocked(`navigation-${decision.reason}`, url, resourceType);
                return route.abort('blockedbyclient');
            }
            return route.continue();
        }

        if (!isResourceAllowed(url, resourceType, state.scope)) {
            recordBlocked('resource', url, resourceType);
            return route.abort('blockedbyclient');
        }

        return route.continue();
    });

    // A pop-up is a navigation that skipped the approval path, so it is closed
    // rather than policed.
    state.context.on('page', async (opened) => {
        if (opened === state.page) return;
        recordBlocked('popup', opened.url(), 'document');
        await opened.close().catch(() => {});
    });

    if (typeof state.context.routeWebSocket === 'function') {
        await state.context.routeWebSocket('**/*', (ws) => {
            const url = ws.url();
            if (resolveUrlDecision(url, state.scope).decision === 'allow') return ws.connectToServer();
            recordBlocked('websocket', url, 'websocket');
            return ws.close();
        });
    }

    state.page = await state.context.newPage();

    state.page.on('download', async (download) => {
        recordBlocked('download', download.url(), 'download');
        await download.cancel().catch(() => {});
    });

    // A modal blocks automation and is page-controlled text, so it is dismissed
    // rather than shown: a dialog the user did not ask for is not a decision.
    state.page.on('dialog', async (dialog) => {
        recordBlocked(`dialog-${dialog.type()}`, state.page.url(), 'dialog');
        await dialog.dismiss().catch(() => {});
    });
}

function budget(kind) {
    if (state.actions >= LIMITS.actions) throw new Error(`This run has used its ${LIMITS.actions} browser actions.`);
    state.actions += 1;
    if (kind === 'navigation') {
        if (state.navigations >= LIMITS.navigations) throw new Error(`This run has used its ${LIMITS.navigations} navigations.`);
        state.navigations += 1;
    }
    if (kind === 'screenshot') {
        if (state.screenshots >= LIMITS.screenshots) throw new Error(`This run has used its ${LIMITS.screenshots} screenshots.`);
        state.screenshots += 1;
    }
}

// Page text and link lists are untrusted data. They are bounded and returned as
// values; nothing here interpolates them into a selector, a script or a URL.
async function readPage() {
    const text = await state.page.evaluate(() => document.body?.innerText ?? '');
    const links = await state.page.evaluate(() =>
        Array.from(document.querySelectorAll('a[href]'))
            .map((a) => ({ text: (a.textContent ?? '').trim().slice(0, 200), href: a.href }))
            .filter((link) => link.text.length > 0)
    );

    const trimmed = text.slice(0, LIMITS.pageTextChars);
    return {
        url: state.page.url(),
        title: await state.page.title(),
        text: trimmed,
        truncated: text.length > LIMITS.pageTextChars,
        links: links.slice(0, LIMITS.links)
    };
}

const handlers = {
    // Scope is set by PowerShell only. There is no command that lets a page,
    // or the Model reading that page, add to it.
    async scope({ hosts }) {
        state.scope = (hosts ?? []).map(normalizeScopeEntry).filter(Boolean);
        return { scope: state.scope };
    },

    async navigate({ url }) {
        const decision = resolveUrlDecision(url, state.scope);
        if (decision.decision !== 'allow') {
            throw new Error(`Refused to open ${decision.host || 'that address'}: ${decision.reason}.`);
        }
        budget('navigation');
        await ensureBrowser();
        const response = await state.page.goto(url, { waitUntil: 'domcontentloaded' });

        // The landing URL is checked again because a redirect chain can end
        // somewhere the first check never saw.
        const landed = resolveUrlDecision(state.page.url(), state.scope);
        if (landed.decision !== 'allow') {
            recordBlocked(`redirect-${landed.reason}`, state.page.url(), 'document');
            await state.page.goto('about:blank').catch(() => {});
            throw new Error(`That address redirected to ${landed.host || 'somewhere else'}, which is not in scope.`);
        }

        return { status: response?.status() ?? null, ...(await readPage()) };
    },

    async click({ linkText }) {
        budget('action');
        if (!state.page) throw new Error('No page is open.');
        const name = String(linkText ?? '').trim();
        if (!name) throw new Error('A link name is required.');
        if (name.length > 200) throw new Error('That link name is too long to be a link name.');

        // Role and accessible name, never a page-supplied selector string: there
        // is no path here from page text to a selector engine or to eval.
        const link = state.page.getByRole('link', { name, exact: false }).first();
        await Promise.all([
            state.page.waitForLoadState('domcontentloaded').catch(() => {}),
            link.click({ timeout: LIMITS.actionTimeoutMs })
        ]);

        const landed = resolveUrlDecision(state.page.url(), state.scope);
        if (landed.decision !== 'allow') {
            recordBlocked(`click-${landed.reason}`, state.page.url(), 'document');
            await state.page.goto('about:blank').catch(() => {});
            throw new Error(`That link led to ${landed.host || 'somewhere else'}, which is not in scope.`);
        }

        state.navigations += 1;
        return readPage();
    },

    async read() {
        budget('action');
        if (!state.page) throw new Error('No page is open.');
        return readPage();
    },

    async screenshot() {
        budget('screenshot');
        if (!state.page) throw new Error('No page is open.');
        const buffer = await state.page.screenshot({ fullPage: false, type: 'png' });
        return { base64: buffer.toString('base64'), url: state.page.url() };
    },

    async status() {
        return {
            scope: state.scope,
            actions: state.actions,
            navigations: state.navigations,
            screenshots: state.screenshots,
            blocked: state.blocked,
            url: state.page?.url() ?? null
        };
    },

    async close() {
        await shutdown();
        return { closed: true };
    }
};

async function shutdown() {
    const browser = state.browser;
    state.browser = null;
    state.context = null;
    state.page = null;
    if (browser) await browser.close().catch(() => {});
}

const reader = createInterface({ input: process.stdin });

reader.on('line', async (line) => {
    const text = line.trim();
    if (!text) return;

    let request;
    try {
        request = JSON.parse(text);
    } catch {
        return emit({ id: null, ok: false, error: 'Unparseable request.' });
    }

    const handler = handlers[request.command];
    if (!handler) return emit({ id: request.id ?? null, ok: false, error: `Unknown command '${request.command}'.` });

    try {
        const result = await handler(request);
        emit({ id: request.id ?? null, ok: true, result });
    } catch (error) {
        // Browser and page errors are untrusted data too - a page controls the
        // text of many of them - so the message is bounded before it travels.
        emit({ id: request.id ?? null, ok: false, error: String(error?.message ?? error).slice(0, 2000) });
    }
});

// Losing the parent is a Stop, and Stop closes the tree.
reader.on('close', async () => {
    await shutdown();
    process.exit(0);
});

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, async () => {
        await shutdown();
        process.exit(0);
    });
}

emit({ event: 'ready', limits: LIMITS });
