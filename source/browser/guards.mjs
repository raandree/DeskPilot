// The supervisor's two stateful guards, separated from the supervisor so a test
// can execute them instead of reading them.
//
// This file adds no control. Everything here was already in supervisor.mjs; it
// moved because the fifth review round measured that 53 of 54 ways to disable
// one of these controls left the test suite green - the assertions read
// supervisor.mjs as text, and supervisor.mjs cannot be imported without
// Playwright and a browser. Both guards now take their dependencies as
// arguments, so a test supplies a fake resolver and a fake clock and watches
// what the guard does.

// Refusals a page caused. Two jobs, and the fifth round found a hole in each.
//
// The report is bounded so a looping page cannot grow the process, but
// `click` and `press` ask a different question - "was a navigation refused
// while I was acting?" - and answering it from the bounded report meant a full
// report turned a refused navigation into a reported success (B4-6). A global
// "newest refusal" counter then let a sub-frame refusal answer for the main
// frame, so a page cycling `iframe.src` could deny every click and choose the
// address named in the refusal message (M5-3).
//
// So navigation refusals are counted per frame, and only the main frame's
// count answers that question.
export function createRefusalLog({ cap = 200, emit = () => {} } = {}) {
    const entries = [];
    let total = 0;
    const mainFrame = { count: 0, last: null };

    return {
        record(reason, url, resourceType, isMainFrame = true) {
            const entry = { reason, url: String(url).slice(0, 500), resourceType };
            total += 1;
            if (isMainFrame && String(reason).startsWith('navigation-')) {
                mainFrame.count += 1;
                mainFrame.last = entry;
            }
            if (entries.length >= cap) return entry;
            entries.push(entry);
            emit(entry);
            return entry;
        },
        // Opaque to the caller on purpose: it is a count, and comparing counts is
        // what makes this independent of whether the report had room.
        marker() { return mainFrame.count; },
        navigationRefusedSince(marker) {
            return mainFrame.count === marker ? null : mainFrame.last;
        },
        entries() { return entries; },
        total() { return total; }
    };
}

// Whether a sub-resource may leave, decided by resolving its hostname.
//
// A sub-resource has no peer address at the route boundary, so this is the only
// address check those requests get (B3-5). Three properties the fifth round
// showed the first version did not have:
//
//   - The budget counts *hostnames*, not resolver calls. Writing the cache only
//     after `await` meant 256 concurrent requests for one host missed the cache
//     256 times, spent the whole budget on a single name and then refused the
//     page's own images. An in-flight promise is shared instead.
//   - The budget is not resettable by the page. Resetting it on `framenavigated`
//     looked per-page and was not: `history.pushState` fires that event, so a
//     page could restore its own budget 500 times without a network request -
//     a control anti-correlated with the threat it named. Only a navigation the
//     Tool itself performed resets it.
//   - A resolver failure refuses but is not remembered, and does not claim the
//     host resolved inward. Failing closed is right - Node's resolver and
//     Chromium's need not agree - but caching a transient SERVFAIL pinned a
//     legitimate host for 60 seconds and reported it as `internal-address`,
//     which is a positive claim about the site that was never measured (m5-5).
//
// The cache is bounded by eviction rather than by the budget, because entries
// expire in place and expiry alone never removes anything.
export function createHostGuard({ lookup, isInternal, limits, now = () => Date.now() }) {
    const resolved = new Map();
    const inFlight = new Map();
    let hostnames = 0;

    function remember(hostname, internal) {
        if (resolved.size >= limits.hostCacheEntries) {
            const oldest = resolved.keys().next();
            if (!oldest.done) resolved.delete(oldest.value);
        }
        resolved.set(hostname, { internal, at: now() });
    }

    return {
        async refusalReason(rawUrl) {
            let hostname;
            try { hostname = new URL(rawUrl).hostname.replace(/^\[|\]$/g, '').toLowerCase(); }
            catch { return null; }
            if (!hostname) return null;

            const cached = resolved.get(hostname);
            if (cached && now() - cached.at < limits.hostLookupTtlMs) {
                return cached.internal ? 'resource-internal-address' : null;
            }

            let pending = inFlight.get(hostname);
            if (!pending) {
                if (hostnames >= limits.hostLookups) return 'resource-lookup-budget';
                hostnames += 1;
                pending = lookup(hostname)
                    .then((addresses) => {
                        const internal = addresses.some((address) => isInternal(address));
                        remember(hostname, internal);
                        return internal ? 'resource-internal-address' : null;
                    })
                    .catch(() => 'resource-unresolved')
                    .finally(() => inFlight.delete(hostname));
                inFlight.set(hostname, pending);
            }
            return pending;
        },
        // Only the Tool calls this, and only for a navigation it performed.
        resetBudget() { hostnames = 0; },
        stats() { return { hostnames, cached: resolved.size }; }
    };
}
