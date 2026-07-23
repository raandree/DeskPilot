export function getClipboardFiles(clipboardData) {
    if (!clipboardData) return [];

    const files = Array.from(clipboardData.files || []).filter(Boolean);
    if (files.length) return files;

    return Array.from(clipboardData.items || [])
        .filter((item) => item && item.kind === 'file' && typeof item.getAsFile === 'function')
        .map((item) => item.getAsFile())
        .filter(Boolean);
}

export function wireClipboardAttachments(target, uploadFiles) {
    if (!target || typeof target.addEventListener !== 'function' || typeof uploadFiles !== 'function') return;

    target.addEventListener('paste', (event) => {
        const files = getClipboardFiles(event.clipboardData);
        if (!files.length) return;

        event.preventDefault();
        uploadFiles(files);
    });
}

export function getImagePaths(attachments) {
    return Array.from(attachments || [])
        .filter((attachment) => String(attachment && attachment.contentType || '').toLowerCase().startsWith('image/'))
        .map((attachment) => String(attachment.path || '').trim())
        .filter(Boolean);
}