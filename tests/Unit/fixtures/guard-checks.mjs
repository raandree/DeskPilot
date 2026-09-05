// Runs the guard checks against a *supplied* implementation, so the same checks
// can be pointed at the real guards and at deliberately broken copies of them.
//
// Every check is written to fail when the control it names is removed or
// inverted. mutate-guards.mjs proves that claim rather than asserting it.

export async function runChecks({ createHostGuard, createRefusalLog, pageBindingRefusal, safeDownloadName, isFieldFillable }) {
    const checks = [];
    const record = (name, pass, detail) => checks.push({ name, pass, detail: String(detail) });

    const limits = { hostLookups: 2, hostCacheEntries: 3, hostLookupTtlMs: 1000 };
    const publicAddresses = ['93.184.216.34'];
    const isInternal = (address) => address.startsWith('127.') || address.startsWith('169.254.');

    function counting(answer) {
        const calls = [];
        const lookup = async (hostname) => {
            calls.push(hostname);
            if (typeof answer === 'function') return answer(hostname, calls.length);
            return answer;
        };
        return { lookup, calls };
    }

    const safely = async (name, body) => {
        try { await body(); }
        catch (error) { record(name, false, `threw: ${error?.message ?? error}`); }
    };

    // The budget counts hostnames, and concurrent requests for one host share a
    // single resolver call. Counting resolver calls instead let one hostname
    // spend the whole budget and then refuse the page's own images.
    await safely('host budget', async () => {
        const { lookup, calls } = counting(async () => {
            await new Promise((resolve) => setTimeout(resolve, 5));
            return publicAddresses;
        });
        const guard = createHostGuard({ lookup, isInternal, limits });
        const answers = await Promise.all(
            Array.from({ length: 50 }, () => guard.refusalReason('https://one.example/x.png'))
        );
        record('one hostname costs one lookup', calls.length === 1, `resolver calls=${calls.length}`);
        record('concurrent requests for one host are all allowed',
            answers.every((a) => a === null), `refusals=${answers.filter(Boolean).length}`);
        record('the budget counts hostnames', guard.stats().hostnames === 1, JSON.stringify(guard.stats()));
        record('a second hostname is still allowed',
            (await guard.refusalReason('https://two.example/a.png')) === null, 'second host');
        record('a third hostname is refused past the budget',
            (await guard.refusalReason('https://three.example/a.png')) === 'resource-lookup-budget', 'third host');
        guard.resetBudget();
        record('resetBudget restores the budget',
            (await guard.refusalReason('https://four.example/a.png')) === null, 'after reset');
    });

    // A resolver failure refuses, says so honestly, and is not remembered.
    await safely('resolver failure', async () => {
        let attempt = 0;
        const { lookup, calls } = counting(async () => {
            attempt += 1;
            if (attempt === 1) throw new Error('SERVFAIL');
            return publicAddresses;
        });
        const guard = createHostGuard({ lookup, isInternal, limits: { ...limits, hostLookups: 10 } });
        const first = await guard.refusalReason('https://flaky.example/a.png');
        const second = await guard.refusalReason('https://flaky.example/a.png');
        record('a name that will not resolve is refused', first === 'resource-unresolved', `first=${first}`);
        record('a resolver failure is not reported as an internal address',
            first !== 'resource-internal-address', `first=${first}`);
        record('a transient failure is not cached', second === null && calls.length === 2,
            `second=${second} calls=${calls.length}`);
    });

    await safely('internal address', async () => {
        const { lookup } = counting(['169.254.169.254']);
        const guard = createHostGuard({ lookup, isInternal, limits });
        const answer = await guard.refusalReason('https://public-name.example/x.png');
        record('a public name resolving inward is refused',
            answer === 'resource-internal-address', `answer=${answer}`);
    });

    // A name that answered publicly is re-checked, which is what rebinding needs.
    await safely('resolution lifetime', async () => {
        let clock = 0;
        const { lookup, calls } = counting(publicAddresses);
        const guard = createHostGuard({ lookup, isInternal, limits: { ...limits, hostLookups: 10 }, now: () => clock });
        await guard.refusalReason('https://cached.example/a.png');
        await guard.refusalReason('https://cached.example/b.png');
        const cachedCalls = calls.length;
        clock += limits.hostLookupTtlMs + 1;
        await guard.refusalReason('https://cached.example/c.png');
        record('a resolution is cached within its lifetime', cachedCalls === 1, `calls=${cachedCalls}`);
        record('a resolution expires', calls.length === 2, `calls=${calls.length}`);
    });

    // Expiry alone never removes anything, so the cache needs eviction.
    await safely('cache bound', async () => {
        const { lookup } = counting(publicAddresses);
        const guard = createHostGuard({ lookup, isInternal, limits: { ...limits, hostLookups: 100, hostCacheEntries: 3 } });
        for (let index = 0; index < 20; index += 1) {
            await guard.refusalReason(`https://h${index}.example/a.png`);
        }
        record('the cache is bounded by eviction', guard.stats().cached <= 3, JSON.stringify(guard.stats()));
    });

    // The refusal log answers "was a navigation refused while I acted?" without
    // depending on the report having room, and only the main frame answers.
    await safely('refusal report cap', async () => {
        const log = createRefusalLog({ cap: 2 });
        // The report is filled first, so the navigation refusal that follows is
        // recorded entirely past the cap. That is the case the original defect
        // was: a full report answered "nothing was refused".
        log.record('resource', 'https://noise.test/1.png', 'image', true);
        log.record('resource', 'https://noise.test/2.png', 'image', true);
        const marker = log.marker();
        for (let index = 0; index < 5; index += 1) {
            log.record('navigation-off-scope', `https://evil.test/${index}`, 'document', true);
        }
        const answered = log.navigationRefusedSince(marker);
        record('a refusal past the report cap is still answered',
            answered?.url === 'https://evil.test/4', JSON.stringify(answered));
        record('the report itself stays bounded', log.entries().length === 2, `entries=${log.entries().length}`);
        record('the total is not bounded', log.total() === 7, `total=${log.total()}`);
    });

    await safely('refusal attribution', async () => {
        const log = createRefusalLog({ cap: 200 });
        const marker = log.marker();
        log.record('subframe-off-scope', 'https://attacker.test/frame', 'document', false);
        record('a sub-frame refusal does not answer for the main frame',
            log.navigationRefusedSince(marker) === null, 'subframe');

        log.record('resource', 'https://evil.test/x.png', 'image', true);
        record('a sub-resource refusal does not answer for a navigation',
            log.navigationRefusedSince(marker) === null, 'resource');

        log.record('navigation-off-scope', 'https://real.test/go', 'document', true);
        const answered = log.navigationRefusedSince(marker);
        record('a main-frame navigation refusal answers, and names its own url',
            answered?.url === 'https://real.test/go', JSON.stringify(answered));
    });

    // A write acts on the page the user approved, or it does not act.
    await safely('write binding', async () => {
        const page = 'https://weather.example/form';
        record('the approved page is acted on',
            pageBindingRefusal({ currentUrl: page, currentNavigation: 3, expectedUrl: page, expectedNavigation: 3 }) === null,
            'same page');
        record('a page that moved is refused',
            pageBindingRefusal({ currentUrl: 'https://weather.example/other', currentNavigation: 3, expectedUrl: page, expectedNavigation: 3 }) === 'page-changed',
            'different url');
        // history.replaceState rewrites the document and restores the address, so
        // the URL alone was never enough (NEW-006).
        record('a page that navigated and came back is refused',
            pageBindingRefusal({ currentUrl: page, currentNavigation: 5, expectedUrl: page, expectedNavigation: 3 }) === 'page-changed',
            'replaceState');
        record('a missing expectation is a refusal, not a disabled check',
            pageBindingRefusal({ currentUrl: page, currentNavigation: 3, expectedUrl: '', expectedNavigation: 3 }) === 'unknown-page',
            'no expectation');
    });

    // The suggested filename is page-controlled by definition.
    await safely('download name', async () => {
        record('a traversal is reduced to a leaf',
            safeDownloadName('../../Windows/System32/evil.exe') === 'evil.exe',
            safeDownloadName('../../Windows/System32/evil.exe'));
        record('a backslash traversal is reduced too',
            safeDownloadName('..\\..\\Windows\\System32\\evil.exe') === 'evil.exe',
            safeDownloadName('..\\..\\Windows\\System32\\evil.exe'));
        record('a leading dot cannot make a dotfile',
            !safeDownloadName('.bashrc').startsWith('.'), safeDownloadName('.bashrc'));
        record('an empty name still produces one',
            safeDownloadName('') === 'download.bin', safeDownloadName(''));
        record('a name is bounded', safeDownloadName('a'.repeat(500)).length <= 120,
            String(safeDownloadName('a'.repeat(500)).length));
        record('nothing outside the allowed set survives',
            /^[A-Za-z0-9._-]+$/.test(safeDownloadName('re;po rt$(whoami).txt')),
            safeDownloadName('re;po rt$(whoami).txt'));
    });

    // The refusal that cannot be delegated to the approval card: the user judges
    // a description, and only the live input can say whether that field is a
    // password box. Refused, never masked - the user signs in themselves.
    await safely('field refusals', async () => {
        const refuses = (field, why) => {
            const verdict = isFieldFillable(field);
            record(why, verdict.fillable === false, JSON.stringify(verdict));
        };
        refuses({ type: 'password', name: 'reference', visible: true }, 'a password box is refused whatever it is called');
        refuses({ type: 'text', autocomplete: 'current-password', visible: true }, 'a field the site declares as a password is refused');
        refuses({ type: 'text', autocomplete: 'one-time-code', visible: true }, 'a one-time-code field is refused');
        refuses({ type: 'text', autocomplete: 'cc-number', visible: true }, 'a card-number field is refused');
        refuses({ type: 'text', name: 'api_key', visible: true }, 'a field named like a credential is refused');
        refuses({ type: 'text', label: 'API key', visible: true }, 'a credential named in the label is refused');
        refuses({ type: 'hidden', name: 'csrf' }, 'a hidden field is refused');
        refuses({ type: 'text', name: 'ghost', visible: false }, 'an invisible field is refused');
        refuses({ type: 'file', name: 'attachment', visible: true }, 'a file input is refused, being a different capability');
        refuses({ type: 'text', name: 'locked', visible: true, readOnly: true }, 'a read-only field is refused');

        const ordinary = isFieldFillable({ type: 'text', name: 'city', label: 'City', visible: true });
        record('an ordinary field is fillable', ordinary.fillable === true, JSON.stringify(ordinary));
    });

    return checks;
}
