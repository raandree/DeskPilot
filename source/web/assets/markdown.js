// Minimal, dependency-free, XSS-safe Markdown renderer.
// Strategy: escape all HTML first, then apply a safe Markdown subset. The model
// output is treated as untrusted text — no raw HTML is ever emitted from input.

function escapeHtml(s) {
    return s
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function safeUrl(url) {
    const u = url.trim();
    if (/^(https?:|mailto:)/i.test(u)) return u.replace(/"/g, '%22');
    if (/^[/.#]/.test(u)) return u.replace(/"/g, '%22');
    return '#';
}

function inline(text) {
    // text is already HTML-escaped. Protect inline code spans first.
    const codes = [];
    let t = text.replace(/`([^`]+)`/g, (_, c) => {
        codes.push(c);
        return `\u0000CODE${codes.length - 1}\u0000`;
    });

    // Links [label](url)
    t = t.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, url) =>
        `<a href="${safeUrl(url)}" target="_blank" rel="noopener noreferrer">${label}</a>`);

    // Bold then italic
    t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    t = t.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    t = t.replace(/(^|[^_])_([^_\n]+)_/g, '$1<em>$2</em>');

    // Restore code spans
    t = t.replace(/\u0000CODE(\d+)\u0000/g, (_, i) => `<code>${codes[+i]}</code>`);
    return t;
}

function renderTable(rows) {
    const cells = (line) => line.replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
    const header = cells(rows[0]);
    const body = rows.slice(2).map(cells);
    let html = '<table><thead><tr>';
    html += header.map((h) => `<th>${inline(h)}</th>`).join('');
    html += '</tr></thead><tbody>';
    for (const row of body) {
        html += '<tr>' + header.map((_, i) => `<td>${inline(row[i] || '')}</td>`).join('') + '</tr>';
    }
    return html + '</tbody></table>';
}

export function renderMarkdown(src) {
    // Normalize CRLF/CR first: a trailing \r defeats the $-anchored line patterns
    // below, so a Windows-authored file would fall through every branch.
    const escaped = escapeHtml((src || '').replace(/\r\n?/g, '\n'));
    const lines = escaped.split('\n');
    const out = [];
    let i = 0;

    while (i < lines.length) {
        const line = lines[i];

        // Fenced code block
        const fence = line.match(/^```(\w*)/);
        if (fence) {
            const lang = fence[1] || '';
            const buf = [];
            i++;
            while (i < lines.length && !/^```/.test(lines[i])) { buf.push(lines[i]); i++; }
            i++; // closing fence
            const code = buf.join('\n');
            out.push(
                `<pre data-lang="${lang}"><button class="copy-btn" type="button">Copy</button><code>${code}</code></pre>`
            );
            continue;
        }

        // Blank line
        if (/^\s*$/.test(line)) { i++; continue; }

        // Heading
        const h = line.match(/^(#{1,3})\s+(.*)$/);
        if (h) { out.push(`<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`); i++; continue; }

        // Horizontal rule
        if (/^(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) { out.push('<hr/>'); i++; continue; }

        // Table (header row + separator row)
        if (/\|/.test(line) && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]+$/.test(lines[i + 1])) {
            const rows = [line, lines[i + 1]];
            i += 2;
            while (i < lines.length && /\|/.test(lines[i]) && !/^\s*$/.test(lines[i])) { rows.push(lines[i]); i++; }
            out.push(renderTable(rows));
            continue;
        }

        // Blockquote
        if (/^>\s?/.test(line)) {
            const buf = [];
            while (i < lines.length && /^>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^>\s?/, '')); i++; }
            out.push(`<blockquote>${inline(buf.join(' '))}</blockquote>`);
            continue;
        }

        // Lists
        if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
            const ordered = /^\s*\d+\.\s+/.test(line);
            const tag = ordered ? 'ol' : 'ul';
            const items = [];
            while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
                items.push(lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, ''));
                i++;
            }
            out.push(`<${tag}>` + items.map((it) => `<li>${inline(it)}</li>`).join('') + `</${tag}>`);
            continue;
        }

        // Paragraph (gather consecutive non-blank, non-special lines)
        const para = [];
        while (
            i < lines.length &&
            !/^\s*$/.test(lines[i]) &&
            !/^```/.test(lines[i]) &&
            !/^(#{1,3})\s/.test(lines[i]) &&
            !/^>\s?/.test(lines[i]) &&
            !/^\s*([-*+]|\d+\.)\s+/.test(lines[i])
        ) {
            para.push(lines[i]); i++;
        }
        // A line no branch claimed must still be consumed, or the loop spins forever.
        if (!para.length) { para.push(lines[i]); i++; }
        out.push(`<p>${inline(para.join('<br/>'))}</p>`);
    }

    return out.join('\n');
}

// ===== Speech =====
// Markdown is punctuation to a screen reader: '## Setup' is spoken "hash hash
// Setup" and '| a | b |' is spoken "vertical bar". These strip it back to prose,
// mirroring the line grammar above so what the renderer treats as syntax is
// exactly what is never spoken.
const TABLE_SEPARATOR = /^\s*\|?[\s:|-]+\|[\s:|-]+$/;

function speakInline(text) {
    let t = String(text);
    t = t.replace(/`([^`]+)`/g, '$1');
    t = t.replace(/!\[([^\]]*)\]\([^)\s]*\)/g, '$1');
    t = t.replace(/\[([^\]]+)\]\([^)\s]*\)/g, '$1');
    t = t.replace(/\*\*\*([^*]+)\*\*\*/g, '$1');
    t = t.replace(/___([^_]+)___/g, '$1');
    t = t.replace(/\*\*([^*]+)\*\*/g, '$1');
    t = t.replace(/__([^_]+)__/g, '$1');
    t = t.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1$2');
    t = t.replace(/(^|[^_])_([^_\n]+)_/g, '$1$2');
    t = t.replace(/~~([^~]+)~~/g, '$1');
    return t.replace(/\s+/g, ' ').trim();
}

// A heading, list item or table row is a sentence to the ear; without a stop the
// reader runs each one into the next.
function speechSentence(text) {
    const t = text.trim();
    if (!t) return '';
    return /[.!?:;]$/.test(t) ? t : t + '.';
}

export function markdownToSpeech(src) {
    const lines = String(src || '').replace(/\r\n?/g, '\n').split('\n');
    const out = [];
    let i = 0;

    while (i < lines.length) {
        const line = lines[i];

        // Code is announced, never spelled out: it is punctuation soup aloud.
        if (/^\s*```/.test(line)) {
            i++;
            while (i < lines.length && !/^\s*```/.test(lines[i])) i++;
            i++;
            out.push('Code block.');
            continue;
        }

        if (/^\s*$/.test(line)) { out.push(''); i++; continue; }

        // A rule is a visual divider and says nothing out loud.
        if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) { i++; continue; }

        const h = line.match(/^\s*(#{1,6})\s+(.*?)\s*#*$/);
        if (h) { out.push(speechSentence(speakInline(h[2]))); i++; continue; }

        if (/\|/.test(line) && i + 1 < lines.length && TABLE_SEPARATOR.test(lines[i + 1])) {
            const rows = [line];
            i += 2; // header + separator; the separator is pure syntax
            while (i < lines.length && /\|/.test(lines[i]) && !/^\s*$/.test(lines[i])) { rows.push(lines[i]); i++; }
            for (const row of rows) {
                const cells = row.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|')
                    .map((c) => speakInline(c)).filter(Boolean);
                if (cells.length) out.push(speechSentence(cells.join(', ')));
            }
            continue;
        }

        if (/^\s*>\s?/.test(line)) {
            const buf = [];
            while (i < lines.length && /^\s*>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^\s*>\s?/, '')); i++; }
            out.push(speechSentence(speakInline(buf.join(' '))));
            continue;
        }

        if (/^\s*([-*+]|\d+[.)])\s+/.test(line)) {
            while (i < lines.length && /^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) {
                const item = lines[i]
                    .replace(/^\s*[-*+]\s+/, '')
                    .replace(/^\s*(\d+)[.)]\s+/, '$1. ')
                    .replace(/^\[[ xX]\]\s*/, '');
                out.push(speechSentence(speakInline(item)));
                i++;
            }
            continue;
        }

        const para = [];
        while (
            i < lines.length &&
            !/^\s*$/.test(lines[i]) &&
            !/^\s*```/.test(lines[i]) &&
            !/^\s*(#{1,6})\s/.test(lines[i]) &&
            !/^\s*>\s?/.test(lines[i]) &&
            !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i])
        ) {
            para.push(lines[i]); i++;
        }
        if (!para.length) { para.push(lines[i]); i++; }
        out.push(speakInline(para.join(' ')));
    }

    return out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
}
