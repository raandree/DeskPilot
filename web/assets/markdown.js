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
    const escaped = escapeHtml(src || '');
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
        out.push(`<p>${inline(para.join('<br/>'))}</p>`);
    }

    return out.join('\n');
}
