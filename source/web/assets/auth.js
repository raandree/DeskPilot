// Sign-in progress model for the GitHub device-code flow.
//
// The engine streams its sign-in output line by line, including a '.' heartbeat
// per poll. Rendering those lines as a growing log scrolled the verification
// link and the user code out of the small progress box, so the screen looked
// stuck and the code was no longer visible when the user needed it. These pure
// helpers reduce that stream into a stable {url, code, status} panel instead.

export const AUTH_WAITING_STATUS = 'Waiting for you to enter the code on GitHub\u2026';

// Classify one line of engine sign-in output.
export function parseAuthLine(line) {
    const text = (line || '').trim();
    // A heartbeat (or an empty write) carries no new information.
    if (!text || /^[.\u00b7\u2022\s]+$/.test(text)) return { kind: 'progress', value: '' };
    const code = text.match(/\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/);
    if (code) return { kind: 'code', value: code[1] };
    const url = text.match(/https?:\/\/[^\s"'<>]+/);
    if (url) return { kind: 'url', value: url[0] };
    return { kind: 'status', value: text };
}

export function createAuthProgress(status) {
    return { url: '', code: '', status: status || 'Starting GitHub sign-in\u2026' };
}

// Fold one output line into the progress state, returning a new state.
export function applyAuthLine(progress, line) {
    const base = progress || createAuthProgress();
    const next = { url: base.url, code: base.code, status: base.status };
    const parsed = parseAuthLine(line);
    if (parsed.kind === 'code') next.code = parsed.value;
    else if (parsed.kind === 'url') next.url = parsed.value;
    else if (parsed.kind === 'status') next.status = parsed.value;
    // Once the code is known, a heartbeat means "still waiting for the user".
    else if (next.code) next.status = AUTH_WAITING_STATUS;
    return next;
}
