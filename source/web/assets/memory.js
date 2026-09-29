// Agent Memory panel helpers. Pure functions only - no DOM - so the rules that
// decide what a note says about itself and what an edit is allowed to touch can
// be tested directly, and so the panel cannot quietly disagree with the server
// about either.

const ORIGIN_KEYS = {
    user: 'memory.origin.user',
    learned: 'memory.origin.learned',
    legacy: 'memory.origin.legacy',
};

// What DeskPilot can honestly say about one note: where it came from, where it
// applies, and whether anyone has checked it. A note's own text never gets a
// say - only the fields the Host recorded.
export function memoryNoteLabel(note, t) {
    const translate = typeof t === 'function' ? t : (key) => key;
    const record = note || {};
    const origin = ORIGIN_KEYS[record.source] || ORIGIN_KEYS.legacy;
    const scope = record.scope === 'project'
        ? (record.projectName
            ? translate('memory.scope.project', { name: record.projectName })
            : translate('memory.scope.projectGone'))
        : translate('memory.scope.global');
    const trust = record.verified === true ? translate('memory.trust.verified') : translate('memory.trust.unverified');
    return `${translate(origin)} · ${scope} · ${trust}`;
}

// The text the editor shows for one scope. Global is the version-1 projection
// the server already sends; a Project shows only its own notes, so saving the
// box can never move a note from one scope into another.
export function memoryScopeText(payload, scopeKind) {
    const memory = (payload && payload.agentMemory) || {};
    if (scopeKind !== 'project') return memory.text || '';
    const projectId = (memory.project && memory.project.id) || null;
    if (!projectId) return '';
    return (memory.notes || [])
        .filter((note) => note && note.scope === 'project' && note.projectId === projectId)
        .map((note) => note.text)
        .join('\n');
}

// The body for an edit. It states the scope it means, and carries nothing else:
// an edit is not a way to forget a note somewhere the user was not looking.
export function memoryScopeRequest(text, scope) {
    const kind = (scope && scope.kind) || 'global';
    if (kind !== 'global' && kind !== 'project') throw new Error('Memory can be scoped to all projects or to one project.');
    const body = { agentMemory: String(text ?? '') };
    if (kind === 'project') {
        const projectId = (scope && scope.projectId) || '';
        if (!projectId) throw new Error('Select a project before editing its memory.');
        body.scope = { kind, projectId };
    } else {
        body.scope = { kind };
    }
    return body;
}

// And the body for forgetting one note: an id and nothing else, so a stale
// panel cannot rewrite a scope while trying to remove a single fact.
export function memoryForgetRequest(note) {
    const id = (note && note.id) || '';
    if (!id) throw new Error('That memory note no longer exists.');
    return { forget: [String(id)] };
}

// Learning names the turn it is about. The server files the notes against the
// project THAT turn ran in, so the request has to carry the assistant message's
// id rather than leaving the server to pick the conversation's latest one - a
// conversation can move between projects between a turn and its learning.
export function memoryLearnRequest(conversation, messageId) {
    const conversationId = (conversation && conversation.id) || '';
    if (!conversationId) throw new Error('Open a conversation first, then update memory from it.');
    const messages = (conversation && conversation.messages) || [];
    let id = messageId || '';
    if (!id) {
        for (let index = messages.length - 1; index >= 0; index -= 1) {
            const message = messages[index];
            if (message && message.role === 'assistant' && message.id) { id = message.id; break; }
        }
    }
    if (!id) throw new Error('There is no completed turn in this conversation to learn from yet.');
    return { conversationId, messageId: String(id) };
}
