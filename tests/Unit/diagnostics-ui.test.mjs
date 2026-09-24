import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../source/web/assets/diagnostics.js', import.meta.url), 'utf8');
const context = vm.createContext({});
vm.runInContext(source.replace(/\bexport\s+/g, ''), context);

test('Diagnostic context rendering projects safe scalars and preserves unknown Usage', () => {
    assert.equal(typeof context.formatDiagnosticContext, 'function');
    const text = context.formatDiagnosticContext({
        conversationId: 'c_0123456789', turnId: 'm_abcdef0123',
        outcome: 'completed', toolSequence: 1, durationMs: 25, costUSD: null,
        prompt: 'PRIVATE-PROMPT', arguments: { path: 'PRIVATE-PATH' },
    });
    const fields = JSON.parse(text);
    assert.equal(fields.turnId, 'm_abcdef0123');
    assert.equal(fields.durationMs, 25);
    assert.equal(fields.costUSD, null);
    assert.ok(!text.includes('PRIVATE-'));
});

test('Diagnostic context rendering rejects invalid scalars without echoing them', () => {
    assert.equal(typeof context.formatDiagnosticContext, 'function');
    assert.equal(context.formatDiagnosticContext({
        turnId: '<script>PRIVATE</script>', outcome: 'PRIVATE-OUTCOME',
        durationMs: -1, toolSequence: 1.5, costUSD: Infinity, partial: 'false',
    }), '');
    assert.equal(context.formatDiagnosticContext(null), '');
    assert.equal(context.formatDiagnosticContext([]), '');
});

test('Diagnostics binds correlation details to textContent, never markup', () => {
    const app = readFileSync(new URL('../../source/web/assets/app.js', import.meta.url), 'utf8');
    assert.ok(/formatDiagnosticContext\(entry\.context\)/.test(app), 'context must be formatted');
    assert.ok(/contextText\.textContent\s*=/.test(app), 'context must use textContent');
    assert.ok(!/contextText\.innerHTML\s*=/.test(app), 'context must never use innerHTML');
});
