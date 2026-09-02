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