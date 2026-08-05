// Pure helpers for the Changes review and the diff viewer. Kept free of DOM and
// network access so they can be unit-tested directly under Node.

// Splits a repository-relative path into the file name and its folder, the way
// the Changes list shows them (name first, dimmed folder after).
export function splitRelPath(rel) {
    const clean = String(rel || '').replace(/\\/g, '/').replace(/^\/+/, '');
    const idx = clean.lastIndexOf('/');
    return idx < 0
        ? { name: clean, dir: '' }
        : { name: clean.slice(idx + 1), dir: clean.slice(0, idx) };
}

// One-letter badge per change status, matching the words the API returns.
export function statusGlyph(status) {
    switch (status) {
        case 'added': return 'A';
        case 'untracked': return 'U';
        case 'deleted': return 'D';
        case 'renamed': return 'R';
        case 'conflicted': return '!';
        default: return 'M';
    }
}

export function statusLabel(status) {
    switch (status) {
        case 'added': return 'Added';
        case 'untracked': return 'New file (not tracked by Git yet)';
        case 'deleted': return 'Deleted';
        case 'renamed': return 'Renamed';
        case 'conflicted': return 'Has merge conflicts';
        default: return 'Modified';
    }
}

// Parses a unified diff into rows carrying their old/new line numbers, so the
// viewer can show a real two-column gutter instead of raw +/- text. Returns
// { rows, added, deleted }; a row is { type, oldNo, newNo, text } where type is
// one of meta, hunk, add, del, ctx.
export function parseUnifiedDiff(text) {
    const rows = [];
    let added = 0;
    let deleted = 0;
    let oldNo = 0;
    let newNo = 0;
    let inHunk = false;

    for (const raw of String(text || '').split('\n')) {
        const line = raw.replace(/\r$/, '');
        // A payload can hold more than one file; a new header ends the last hunk.
        if (/^diff --git /.test(line)) {
            inHunk = false;
            rows.push({ type: 'meta', oldNo: null, newNo: null, text: line });
            continue;
        }
        const hunk = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
        if (hunk) {
            oldNo = parseInt(hunk[1], 10);
            newNo = parseInt(hunk[3], 10);
            inHunk = true;
            rows.push({ type: 'hunk', oldNo: null, newNo: null, text: line });
            continue;
        }
        if (!inHunk) {
            // Everything before the first hunk is git's file header.
            if (line !== '') rows.push({ type: 'meta', oldNo: null, newNo: null, text: line });
            continue;
        }
        if (line.startsWith('\\')) {
            rows.push({ type: 'meta', oldNo: null, newNo: null, text: line });
            continue;
        }
        const marker = line.charAt(0);
        const body = line.slice(1);
        if (marker === '+') {
            added++;
            rows.push({ type: 'add', oldNo: null, newNo: newNo++, text: body });
        } else if (marker === '-') {
            deleted++;
            rows.push({ type: 'del', oldNo: oldNo++, newNo: null, text: body });
        } else {
            // A context line, including the empty line git writes as a bare ' '.
            rows.push({ type: 'ctx', oldNo: oldNo++, newNo: newNo++, text: body });
        }
    }
    return { rows, added, deleted };
}

// Renders an untracked (brand new) file as an all-additions diff so the viewer
// can show it with the same gutter as a tracked change.
export function newFileRows(content) {
    const lines = String(content == null ? '' : content).split('\n');
    if (lines.length && lines[lines.length - 1] === '') lines.pop();
    return lines.map((text, i) => ({ type: 'add', oldNo: null, newNo: i + 1, text }));
}

// A commit message suggestion for the Changes panel's Keep action: the user's
// own words when there are any, else a plain description of the file set.
export function suggestCommitMessage(promptText, files) {
    const first = String(promptText || '')
        .split('\n')
        .map((l) => l.trim())
        .find((l) => l.length > 0);
    if (first) return first.length > 72 ? first.slice(0, 69).trimEnd() + '…' : first;
    const list = Array.isArray(files) ? files : [];
    if (list.length === 1) return 'Update ' + splitRelPath(list[0].rel || list[0]).name;
    return 'Update ' + list.length + ' files';
}
