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
import { mkdirSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';
import { lookup } from 'node:dns/promises';
import { resolveUrlDecision, isResourceAllowed, isFieldFillable, isInternalAddress, normalizeScopeEntry } from './policy.mjs';

// Bounds, so a hostile or merely broken page cannot exhaust the session. Every
// one of these is a refusal the user can see, not a silent truncation of intent.
const LIMITS = {
    actions: 50,
    navigations: 20,
    pageTextChars: 20000,
    titleChars: 500,
    hrefChars: 2048,
    links: 200,
    screenshots: 10,
    downloads: 10,
    downloadBytes: 50 * 1024 * 1024,
    // Distinct hostnames the page may make DeskPilot resolve, per page. A page
    // chooses how many names it asks for, so without this it chooses how much
    // DNS traffic leaves the machine and how large the cache grows - and a
    // session-wide budget let one hostile page starve every later page of its
    // sub-resources. Reset on each main-frame navigation.
    hostLookups: 256,
    // A name that answered publicly is not trusted for the rest of the session:
    // that is what rebinding is.
    hostLookupTtlMs: 60000,
    actionTimeoutMs: 30000,
    navigationTimeoutMs: 45000
};

const state = {
    scope: [],
    allowDownload: false,
    downloadRoot: null,
    testInsecure: false,
    browser: null,
    context: null,
    page: null,
    actions: 0,
    navigations: 0,
    screenshots: 0,
    downloads: 0,
    pendingDownload: false,
    // Incremented only by a real main-frame navigation, so a page cannot restore
    // it the way history.replaceState restores a URL.
    navigationId: 0,
    // Hostname -> whether it resolves to an address the browser may not reach.
    // Per session, so an ordinary page costs one lookup per host rather than one
    // per request, and bounded by LIMITS.hostLookups.
    resolved: new Map(),
    lookups: 0,
    // Set when a response came back from an internal peer. A sub-resource cannot
    // be un-sent, so the next action refuses instead of the run continuing as if
    // nothing had happened.
    internalPeer: null,
    blocked: [],
    // Counted separately from the reported ring. `blocked` is bounded so a
    // looping page cannot grow the process, but the navigate/click/press paths
    // decide "was this refused?" by looking at what arrived since they started -
    // and once the ring was full they saw nothing, fell through to the old
    // in-scope URL, and reported a refused navigation as a success (B4-6,
    // 2026-09-05). The counter is unbounded and cheap; only the reporting is capped.
    blockedCount: 0,
    blockedLast: null
};

function emit(payload) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
}
// Refusals are reported, never silently dropped: a page that tried to reach
// somewhere is evidence, and Activity is where the user sees it. Bounded so a
// page looping on a blocked request cannot grow the process without limit.
function recordBlocked(reason, url, resourceType) {
    const entry = { reason, url: String(url).slice(0, 500), resourceType };
    state.blockedCount += 1;
    state.blockedLast = entry;
    // Bounds the array *and* the emit. A page looping on a blocked request would
    // otherwise write unbounded lines to stdout even though the array stopped.
    if (state.blocked.length >= 200) return;
    state.blocked.push(entry);
    emit({ event: 'blocked', ...entry });
}

// What was refused since a marker, without depending on the reporting ring
// having room. Returns the newest navigation refusal, or null.
function navigationRefusedSince(marker) {
    if (state.blockedCount === marker.count) return null;
    const fromRing = state.blocked.slice(marker.length).find((entry) => String(entry.reason).startsWith('navigation-'));
    if (fromRing) return fromRing;
    const last = state.blockedLast;
    return last && String(last.reason).startsWith('navigation-') ? last : null;
}

function blockedMarker() {
    return { length: state.blocked.length, count: state.blockedCount };
}

async function ensureBrowser() {
    if (state.browser) return;

    // Test hooks for the hostile-site harness, which has to serve a real https
    // origin on a real hostname to exercise the policy honestly - the policy
    // correctly refuses plain http, IP literals and single-label hosts, and
    // weakening any of those to make testing easier would test the wrong thing.
    //
    // Environment only. A page cannot set one, the model cannot set one, and
    // nothing in source/Private sets one either - which is asserted by a test
    // rather than merely intended.
    // One argument per line: a Chromium argument value can legitimately contain
    // a comma, as --host-resolver-rules does.
    const testArgs = (process.env.DESKPILOT_BROWSER_TEST_ARGS ?? '').split(/\r?\n/).map((a) => a.trim()).filter(Boolean);
    // Also permits an internal peer address: the harness serves its hostile site
    // on loopback with a self-signed certificate, which is the same test-rig
    // condition, so it reuses this hook rather than adding another.
    const testInsecure = process.env.DESKPILOT_BROWSER_TEST_INSECURE === '1';
    state.testInsecure = testInsecure;

    state.browser = await chromium.launch({
        headless: false,
        // No personal profile is reachable from here: launch() plus a fresh
        // context is ephemeral by construction - no cookie jar on disk, no
        // history, no password store, no extensions, no ambient single sign-on.
        args: ['--no-default-browser-check', '--no-first-run', '--disable-extensions', ...testArgs]
    });

    state.context = await state.browser.newContext({
        acceptDownloads: state.allowDownload,
        ignoreHTTPSErrors: testInsecure,
        // Playwright's own types say route() does not intercept requests made by
        // a Service Worker. It does on this version - measured - but a control
        // that holds only because the vendor's documentation is stale is not a
        // control. Blocking registration makes the contract the documented one.
        serviceWorkers: 'block',
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

        // A sub-resource has no peer address at this boundary, so the name is
        // resolved here instead. `<img src="https://public.example/x.png">` whose
        // A record points at 169.254.169.254 or 127.0.0.1 was previously issued
        // from the user's machine with no address check at all, because
        // assertPeerAllowed is only wired into the main-document paths (B3-5,
        // 2026-09-05). This is TOCTOU-able by a fast rebind; the response check
        // below is not, and catches what this misses.
        const refusal = await hostRefusalReason(url);
        if (refusal) {
            recordBlocked(refusal, url, resourceType);
            return route.abort('blockedbyclient');
        }

        return route.continue();
    });

    state.context.on('response', (response) => {
        if (state.testInsecure || state.internalPeer) return;
        Promise.resolve(response.serverAddr?.()).then((peer) => {
            if (!peer || !isInternalAddress(peer.ipAddress)) return;
            state.internalPeer = peer.ipAddress;
            recordBlocked('internal-address', response.url(), response.request().resourceType());
        }).catch(() => {});
    });

    if (typeof state.context.routeWebSocket !== 'function') {
        // Never silently: an absent control is not a control that passed.
        throw new Error('This Playwright build cannot intercept WebSocket traffic, so DeskPilot will not open a browser.');
    }
    await state.context.routeWebSocket('**/*', (ws) => {
        const url = ws.url();
        if (resolveUrlDecision(url, state.scope).decision === 'allow') return ws.connectToServer();
        recordBlocked('websocket', url, 'websocket');
        return ws.close();
    });

    state.page = await state.context.newPage();

    state.page.on('framenavigated', (frame) => {
        if (frame !== state.page.mainFrame()) return;
        state.navigationId += 1;
        // The lookup budget is the page's to spend, so it is the page's to lose.
        state.lookups = 0;
    });

    // Registered only after the main page exists. The 'page' event fires for
    // newPage() too, so a handler installed earlier closes the page it was
    // meant to protect - which aborts every navigation with a detached frame.
    state.context.on('page', async (opened) => {
        if (opened === state.page) return;
        recordBlocked('popup', opened.url(), 'document');
        await opened.close().catch(() => {});
    });

    state.page.on('download', async (download) => {
        // A download the user did not approve is still refused even when the
        // capability is granted: the capability decides that downloading is
        // possible, the approval decides that this one happens. A page starting
        // one on its own has had neither.
        if (!state.allowDownload || !state.pendingDownload) {
            recordBlocked('download', download.url(), 'download');
            return download.cancel().catch(() => {});
        }
        // An armed download is taken by the download command's own waiter.
    });

    // A modal blocks automation and is page-controlled text, so it is dismissed
    // rather than shown: a dialog the user did not ask for is not a decision.
    state.page.on('dialog', async (dialog) => {
        recordBlocked(`dialog-${dialog.type()}`, state.page.url(), 'dialog');
        await dialog.dismiss().catch(() => {});
    });
}

function budget(kind) {
    // A response already came back from an address inside this machine or its
    // network. It cannot be recalled, so the run stops here rather than carrying
    // on around it.
    if (state.internalPeer) {
        throw new Error(`A request on this page reached ${state.internalPeer}, which is on this machine or the local network, so DeskPilot stopped.`);
    }
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
    // Playwright dispatches 'framenavigated' asynchronously, so the counter can
    // still be one behind when goto() resolves. One turn of the event loop
    // guarantees a pending handler has run before the identity is stamped -
    // without it the stamp races the navigation that produced it, and a write
    // approved for a page is refused on that same page, intermittently.
    await new Promise((resolve) => setImmediate(resolve));

    // A read can race a navigation the interceptor just aborted, which destroys
    // the execution context mid-evaluate. That is an ordinary outcome of the
    // policy doing its job, so it is waited out rather than reported as a fault.
    const evaluate = async (fn) => {
        try {
            return await state.page.evaluate(fn);
        }
        catch (error) {
            if (!/execution context|destroyed|navigation/i.test(String(error?.message ?? ''))) throw error;
            await state.page.waitForLoadState('domcontentloaded').catch(() => {});
            return state.page.evaluate(fn);
        }
    };

    const text = await evaluate(() => document.body?.innerText ?? '');
    const links = await evaluate(() =>
        Array.from(document.querySelectorAll('a[href]'))
            .map((a) => ({ text: (a.textContent ?? '').trim().slice(0, 200), href: a.href }))
            .filter((link) => link.text.length > 0)
    );

    const trimmed = text.slice(0, LIMITS.pageTextChars);
    const title = await state.page.title().catch(() => '');
    return {
        url: state.page.url(),
        navigationId: state.navigationId,
        title: String(title).slice(0, LIMITS.titleChars),
        text: trimmed,
        truncated: text.length > LIMITS.pageTextChars,
        // href and title are page-controlled text that reaches the model, so
        // they are bounded like page text. Unbounded hrefs turned the 20,000
        // character page-text bound into a formality and could fault the session
        // by overrunning the protocol line cap.
        links: links.slice(0, LIMITS.links).map((link) => ({
            text: link.text,
            href: String(link.href).slice(0, LIMITS.hrefChars)
        }))
    };
}

// Located by accessible name, label, placeholder or attribute - never by a
// selector string the page or the model composed. Attribute values go through
// JSON.stringify so a name containing a quote cannot end the selector early.
function findField(name) {
    const text = String(name ?? '').trim();
    if (!text) throw new Error('A field name is required.');
    if (text.length > 200) throw new Error('That field name is too long to be a field name.');

    const escaped = JSON.stringify(text);
    return state.page.getByLabel(text, { exact: false })
        .or(state.page.getByPlaceholder(text, { exact: false }))
        .or(state.page.locator(`[name=${escaped}], [id=${escaped}], [aria-label=${escaped}]`))
        .first();
}

// Read from the live element rather than inferred from the name the model used,
// because the name is the part an attacker controls and the type is not.
async function describeField(locator) {
    const count = await locator.count().catch(() => 0);
    if (count === 0) return { found: false };

    const info = await locator.evaluate((element) => ({
        type: (element.getAttribute('type') || element.tagName || '').toLowerCase(),
        autocomplete: element.getAttribute('autocomplete') || '',
        name: element.getAttribute('name') || '',
        id: element.id || '',
        label: element.getAttribute('aria-label') || '',
        disabled: element.disabled === true,
        readOnly: element.readOnly === true
    })).catch(() => null);
    if (!info) return { found: false };

    return { found: true, visible: await locator.isVisible().catch(() => false), ...info };
}

async function clickControl(text) {
    const name = String(text ?? '').trim();
    if (!name) throw new Error('A button name is required.');
    if (name.length > 200) throw new Error('That button name is too long to be a button name.');

    const escaped = JSON.stringify(name);
    const control = state.page.getByRole('button', { name, exact: false })
        .or(state.page.getByRole('link', { name, exact: false }))
        .or(state.page.locator(`input[type="submit"][value=${escaped}], input[type="button"][value=${escaped}]`))
        .first();

    await control.click({ timeout: LIMITS.actionTimeoutMs });
}

// A press can navigate, and the page it lands on is checked against the scope
// exactly like a navigation - a form that posts to another site is a navigation
// wearing a button.
async function pressControl(text) {
    const before = blockedMarker();
    const [response] = await Promise.all([
        state.page.waitForNavigation({ waitUntil: 'domcontentloaded' }).catch(() => null),
        clickControl(text)
    ]);
    await assertPeerAllowed(response);

    // The interceptor may already have refused the post, in which case the page
    // never moved and the scope check below would see nothing wrong. Saying so
    // is the difference between "that did not work" and "that was not allowed".
    const refused = navigationRefusedSince(before);
    if (refused) {
        // Settled before returning: the aborted navigation is still transitioning
        // to Chromium's error page, and leaving it in flight interrupts whatever
        // the caller does next.
        await state.page.goto('about:blank').catch(() => {});
        await state.page.waitForLoadState('domcontentloaded').catch(() => {});
        throw new Error(`That control tried to send the page to ${refused.url}, which is not in scope, so nothing was sent.`);
    }

    const landed = resolveUrlDecision(state.page.url(), state.scope);
    if (landed.decision !== 'allow') {
        recordBlocked(`action-${landed.reason}`, state.page.url(), 'document');
        await state.page.goto('about:blank').catch(() => {});
        await state.page.waitForLoadState('domcontentloaded').catch(() => {});
        throw new Error(`That control led to ${landed.host || 'somewhere else'}, which is not in scope.`);
    }
}

// A page can navigate itself while the user reads the card - a meta refresh or a
// setTimeout is enough - and the values approved for one page would then be
// typed into another. Comparing URLs was not enough: history.replaceState lets a
// page rewrite the document and restore the address, so the check also carries a
// navigation counter that only a real navigation increments.
function assertSamePage(expectedUrl, expectedNavigation) {
    // A missing expectation used to disable the check silently. PowerShell now
    // refuses the write before it gets here, and this refuses it again.
    if (!expectedUrl) {
        throw new Error('DeskPilot does not know which page this was approved for, so nothing was done.');
    }
    if (state.page.url() !== expectedUrl || (expectedNavigation !== undefined && state.navigationId !== expectedNavigation)) {
        recordBlocked('page-changed', state.page.url(), 'document');
        throw new Error('The page changed while this was waiting for approval, so nothing was done. Read the page again first.'
            + ` (approved for ${expectedUrl} #${expectedNavigation}, now on ${state.page.url()} #${state.navigationId})`);
    }
}

// Every path that lands the browser on a new document goes through here. A
// public name can hold a private A record, so the address the connection
// actually reached is what decides - and a pre-flight resolve would be a TOCTOU
// against DNS rebinding.
async function assertPeerAllowed(response) {
    if (state.testInsecure) return;
    const peer = await response?.serverAddr?.().catch(() => null);
    if (peer && isInternalAddress(peer.ipAddress)) {
        recordBlocked('internal-address', state.page.url(), 'document');
        await state.page.goto('about:blank').catch(() => {});
        throw new Error('That address is on this machine or the local network, so DeskPilot will not open it.');
    }
}

// The best a route handler can do, which is not as good as a peer address:
// resolve the name and refuse if any answer is internal. Returns null when the
// request may go out, otherwise the reason it may not.
//
// Failure is **closed**, not open. The earlier reasoning - "a name that will not
// resolve produces a request that fails anyway" - assumes Node's resolver and
// Chromium's agree. They need not: Chromium runs its own resolver with Secure
// DNS, so a name that SERVFAILs the OS path and resolves to 127.0.0.1 over DoH
// would have been let out unchecked. If the two agree, refusing costs a request
// that was going to fail; if they disagree, refusing is the only check there is
// (B4-5, 2026-09-05).
//
// Entries expire so a name that answered publicly once is re-checked rather than
// trusted for the life of the session, and both the cache and the DNS traffic
// are bounded per page because the page chooses how many names to ask for.
async function hostRefusalReason(rawUrl) {
    if (state.testInsecure) return null;
    let hostname;
    try { hostname = new URL(rawUrl).hostname.replace(/^\[|\]$/g, '').toLowerCase(); }
    catch { return null; }
    if (!hostname) return null;

    const cached = state.resolved.get(hostname);
    if (cached && Date.now() - cached.at < LIMITS.hostLookupTtlMs) {
        return cached.internal ? 'resource-internal-address' : null;
    }

    if (state.lookups >= LIMITS.hostLookups) return 'resource-lookup-budget';
    state.lookups += 1;

    let internal = true;
    try {
        const answers = await lookup(hostname, { all: true, verbatim: true });
        internal = answers.some((answer) => isInternalAddress(answer.address));
    }
    catch { internal = true; }

    state.resolved.set(hostname, { internal, at: Date.now() });
    return internal ? 'resource-internal-address' : null;
}

const handlers = {
    // Scope and capabilities are set by PowerShell only. There is no command
    // that lets a page, or the model reading that page, add to either.
    async scope({ hosts }) {
        state.scope = (hosts ?? []).map(normalizeScopeEntry).filter(Boolean);
        return { scope: state.scope };
    },

    async configure({ allowDownload, downloadRoot }) {
        state.allowDownload = allowDownload === true;
        state.downloadRoot = typeof downloadRoot === 'string' && downloadRoot ? downloadRoot : null;
        return { allowDownload: state.allowDownload };
    },

    async navigate({ url }) {
        const decision = resolveUrlDecision(url, state.scope);
        if (decision.decision !== 'allow') {
            throw new Error(`Refused to open ${decision.host || 'that address'}: ${decision.reason}.`);
        }
        budget('navigation');
        await ensureBrowser();

        // Blocking a navigation leaves Chromium mid-transition to its own error
        // page, and that transition interrupts the *next* goto - so an ordinary
        // navigation after a refused one failed for a reason that had nothing to
        // do with the address being opened. Retried once, only for that.
        let response;
        for (let attempt = 0; ; attempt += 1) {
            try {
                response = await state.page.goto(url, { waitUntil: 'domcontentloaded' });
                break;
            }
            catch (error) {
                const interrupted = /interrupted by another navigation/i.test(String(error?.message ?? ''));
                if (!interrupted || attempt > 0) throw error;
                await state.page.waitForLoadState('domcontentloaded').catch(() => {});
            }
        }
        await assertPeerAllowed(response);

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
        // A click that follows a link is a navigation, and counting it as only an
        // action left LIMITS.navigations unenforced on the one path a page can
        // steer (m3-1, 2026-09-05).
        if (!state.page) throw new Error('No page is open.');
        budget('navigation');
        const name = String(linkText ?? '').trim();
        if (!name) throw new Error('A link name is required.');
        if (name.length > 200) throw new Error('That link name is too long to be a link name.');

        // Role and accessible name, never a page-supplied selector string: there
        // is no path here from page text to a selector engine or to eval.
        const before = blockedMarker();
        const link = state.page.getByRole('link', { name, exact: false }).first();
        const [response] = await Promise.all([
            state.page.waitForNavigation({ waitUntil: 'domcontentloaded' }).catch(() => null),
            link.click({ timeout: LIMITS.actionTimeoutMs })
        ]);
        await assertPeerAllowed(response);

        // Same as pressControl: the interceptor may already have refused this, in
        // which case the page never moved and the check below would see nothing
        // wrong. The settle matters as much as the message - an aborted
        // navigation left in flight interrupts whatever the caller does next.
        const refused = navigationRefusedSince(before);
        if (refused) {
            await state.page.goto('about:blank').catch(() => {});
            await state.page.waitForLoadState('domcontentloaded').catch(() => {});
            throw new Error(`That link tried to send the page to ${refused.url}, which is not in scope, so nothing was sent.`);
        }

        const landed = resolveUrlDecision(state.page.url(), state.scope);
        if (landed.decision !== 'allow') {
            recordBlocked(`click-${landed.reason}`, state.page.url(), 'document');
            await state.page.goto('about:blank').catch(() => {});
            await state.page.waitForLoadState('domcontentloaded').catch(() => {});
            throw new Error(`That link led to ${landed.host || 'somewhere else'}, which is not in scope.`);
        }

        return readPage();
    },

    async read() {
        budget('action');
        if (!state.page) throw new Error('No page is open.');
        return readPage();
    },

    // Every write below is already approved by the time it arrives: PowerShell
    // has shown the user the page, the values and the control, and blocked until
    // they answered. What is enforced here is the part an approval cannot cover,
    // because the user is judging a description and this is judging the live DOM.
    async fill({ fields, submitWith, expectedUrl, expectedNavigation }) {
        budget('action');
        if (!state.page) throw new Error('No page is open.');
        assertSamePage(expectedUrl, expectedNavigation);

        const filled = [];
        for (const entry of fields ?? []) {
            // Between every field, not only before the first. A page that
            // navigates itself after field one used to receive the remaining
            // approved values, and with no submitWith no check ever fired at all
            // (B4-4, 2026-09-05).
            assertSamePage(expectedUrl, expectedNavigation);
            const locator = findField(entry.name);
            const descriptor = await describeField(locator);
            if (!descriptor.found) throw new Error(`No field called '${entry.name}' was found on this page.`);

            // The refusal that cannot be delegated to the approval card: the
            // user approved a value for a field, and only the live input can say
            // whether that field is a password box. Refused, never masked - the
            // user signs in themselves.
            const verdict = isFieldFillable(descriptor);
            if (!verdict.fillable) {
                recordBlocked(`field-${verdict.reason}`, state.page.url(), 'field');
                throw new Error(`DeskPilot will not type into '${entry.name}' on this page (${verdict.reason}). Ask the user to fill that in themselves.`);
            }

            await locator.fill(String(entry.value ?? ''), { timeout: LIMITS.actionTimeoutMs });
            filled.push(entry.name);
        }

        if (submitWith) {
            // Re-checked, because filling takes time and the approval covered the
            // page as well as the values.
            assertSamePage(expectedUrl, expectedNavigation);
            await pressControl(submitWith);
        }

        return { filled, submitted: Boolean(submitWith), ...(await readPage()) };
    },

    async press({ buttonText, expectedUrl, expectedNavigation }) {
        budget('action');
        if (!state.page) throw new Error('No page is open.');
        assertSamePage(expectedUrl, expectedNavigation);
        await pressControl(buttonText);
        return readPage();
    },

    async upload({ fieldName, path, expectedUrl, expectedNavigation }) {
        budget('action');
        if (!state.page) throw new Error('No page is open.');
        assertSamePage(expectedUrl, expectedNavigation);
        if (typeof path !== 'string' || !path) throw new Error('A file path is required.');

        // The path arrives already resolved and confined to the project folder by
        // PowerShell. Nothing here derives a path from the page, which is the
        // rule that keeps an injected page from choosing what gets uploaded.
        const locator = findField(fieldName);
        const descriptor = await describeField(locator);
        if (!descriptor.found) throw new Error(`No file field called '${fieldName}' was found on this page.`);
        if (descriptor.type !== 'file') throw new Error(`'${fieldName}' is not a file field.`);

        await locator.setInputFiles(path, { timeout: LIMITS.actionTimeoutMs });
        return { attached: basename(path), ...(await readPage()) };
    },

    // Saved into a quarantine folder outside the project, never where the page
    // asked and never where other Tools would pick it up by accident. The
    // suggested name is page-controlled, so it is reduced to a leaf and stripped
    // before it is ever joined to a path.
    async download({ controlText, expectedUrl, expectedNavigation }) {
        budget('action');
        if (!state.page) throw new Error('No page is open.');
        assertSamePage(expectedUrl, expectedNavigation);
        if (!state.allowDownload) throw new Error('This project does not allow downloads.');
        if (state.downloads >= LIMITS.downloads) throw new Error(`This run has used its ${LIMITS.downloads} downloads.`);
        if (!state.downloadRoot) throw new Error('DeskPilot has nowhere to put a download.');

        mkdirSync(state.downloadRoot, { recursive: true });
        state.pendingDownload = true;
        try {
            const [download] = await Promise.all([
                state.page.waitForEvent('download', { timeout: LIMITS.actionTimeoutMs }),
                clickControl(controlText)
            ]);

            const suggested = (basename(download.suggestedFilename() || '') || 'download.bin')
                .replace(/[^A-Za-z0-9._-]/g, '_')
                .replace(/^\.+/, '_')
                .slice(0, 120) || 'download.bin';
            const target = join(state.downloadRoot, `${Date.now()}-${suggested}`);

            // Sized before it is copied anywhere DeskPilot keeps things. The
            // transfer has already happened by the time Playwright hands over a
            // path - the cap bounds what is kept, not what Chromium buffered -
            // but checking after saveAs meant writing the oversized file into the
            // quarantine folder first and deleting it afterwards, which is not
            // what "will not save" means (m3-3, 2026-09-05).
            const staged = await download.path();
            const written = staged ? statSync(staged).size : 0;
            if (written > LIMITS.downloadBytes) {
                await download.delete().catch(() => {});
                throw new Error(`That file is larger than the ${Math.round(LIMITS.downloadBytes / 1048576)} MB DeskPilot will save, so it was discarded.`);
            }

            await download.saveAs(target);
            state.downloads += 1;
            return { savedAs: target, name: suggested, bytes: written, from: download.url(), url: state.page.url() };
        }
        finally {
            state.pendingDownload = false;
        }
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

emit({
    event: 'ready',
    limits: LIMITS,
    // Reported so a hook left set cannot be silent.
    testHooks: Boolean(process.env.DESKPILOT_BROWSER_TEST_ARGS || process.env.DESKPILOT_BROWSER_TEST_INSECURE)
});
