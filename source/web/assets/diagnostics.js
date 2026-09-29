export function diagnosticStateMeta(state) {
    switch (state) {
        case 'healthy':
            return { label: 'Healthy', className: 'is-healthy', glyph: 'OK' };
        case 'degraded':
            return { label: 'Needs attention', className: 'is-degraded', glyph: '!' };
        case 'unavailable':
            return { label: 'Unavailable', className: 'is-unavailable', glyph: 'x' };
        case 'not configured':
            return { label: 'Not configured', className: 'is-not-configured', glyph: '-' };
        default:
            return { label: 'Not checked', className: 'is-unavailable', glyph: '?' };
    }
}

export function mergeDiagnosticEntries(current, incoming, capacity = 500) {
    const bySequence = new Map();
    for (const entry of [...(current || []), ...(incoming || [])]) {
        const sequence = Number(entry && entry.sequence);
        if (Number.isFinite(sequence)) bySequence.set(sequence, entry);
    }
    return Array.from(bySequence.values())
        .sort((left, right) => Number(left.sequence) - Number(right.sequence))
        .slice(-Math.max(1, capacity));
}
export function formatDiagnosticContext(context) {
    if (!context || typeof context !== 'object' || Array.isArray(context)) return '';
    const fields = {};
    for (const [key, prefix] of [['conversationId', 'c'], ['turnId', 'm']]) {
        if (typeof context[key] === 'string' && new RegExp(`^${prefix}_[0-9a-f]{10,32}$`).test(context[key])) {
            fields[key] = context[key];
        }
    }
    const choices = {
        action: ['read', 'list', 'write', 'create', 'run', 'fetch', 'browse', 'search', 'ask', 'load', 'mcp', 'approval', 'other'],
        outcome: ['started', 'observed', 'completed', 'failed', 'stopped', 'budget-exhausted', 'requested', 'approved', 'denied', 'retry'],
    };
    for (const [key, allowed] of Object.entries(choices)) {
        if (allowed.includes(context[key])) fields[key] = context[key];
    }
    for (const key of ['toolSequence', 'durationMs', 'promptTokens', 'completionTokens', 'totalTokens', 'costUSD']) {
        const value = context[key];
        if (value === null || (typeof value === 'number' && Number.isFinite(value) && value >= 0 &&
            value <= Number.MAX_SAFE_INTEGER && (key === 'costUSD' || Number.isSafeInteger(value)))) fields[key] = value;
    }
    for (const key of ['estimated', 'partial']) {
        if (context[key] === null || typeof context[key] === 'boolean') fields[key] = context[key];
    }
    return Object.keys(fields).length ? JSON.stringify(fields) : '';
}
