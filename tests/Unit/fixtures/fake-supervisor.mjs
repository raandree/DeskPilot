// A stand-in that speaks the supervisor protocol without Playwright, so the
// PowerShell side's framing, correlation, event collection, deadline handling
// and process teardown can be proved on a machine where no browser is
// installed. It also produces the misbehaviours a real supervisor would only
// produce when something has already gone wrong: hanging, crashing, answering
// the wrong id, and emitting output that is not protocol.

import { createInterface } from 'node:readline';

function emit(payload) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
}

const handlers = {
    scope: (request) => ({ scope: request.hosts ?? [] }),
    echo: (request) => ({ echoed: request.value ?? null }),
    events: (request) => {
        const count = Math.min(Number(request.count ?? 3), 50);
        for (let index = 0; index < count; index += 1) {
            emit({ event: 'blocked', reason: 'resource', url: `https://attacker.test/${index}`, resourceType: 'script' });
        }
        return { emitted: count };
    },
    fail: () => {
        throw new Error('the supervisor refused');
    }
};

const reader = createInterface({ input: process.stdin });

reader.on('line', (line) => {
    const text = line.trim();
    if (!text) return;

    let request;
    try {
        request = JSON.parse(text);
    } catch {
        return emit({ id: null, ok: false, error: 'Unparseable request.' });
    }

    switch (request.command) {
        case 'hang':
            return;
        case 'crash':
            return process.exit(3);
        case 'wrong_id':
            return emit({ id: (request.id ?? 0) + 9999, ok: true, result: {} });
        case 'garbage':
            process.stdout.write('this is not json\n');
            return;
        case 'flood':
            process.stdout.write(`${'x'.repeat(9000000)}\n`);
            return;
        default:
            break;
    }

    const handler = handlers[request.command];
    if (!handler) return emit({ id: request.id ?? null, ok: false, error: `Unknown command '${request.command}'.` });

    try {
        emit({ id: request.id ?? null, ok: true, result: handler(request) });
    } catch (error) {
        emit({ id: request.id ?? null, ok: false, error: String(error.message) });
    }
});

reader.on('close', () => process.exit(0));

emit({ event: 'ready', limits: { actions: 50 } });
