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

// An image Attachment is inlined into the Turn as a base64 data URI, so a camera
// photo goes on the wire ~4/3 larger again and the Copilot endpoint refuses the
// whole request with a bare 413. The long edge is the ceiling the Models
// downsample to anyway, so nothing readable is lost by getting there first.
export const VISION_LIMITS = { maxEdge: 1568, maxBytes: 1500000, quality: 0.82 };

// A canvas re-encode keeps one frame and throws the animation away. GIF is
// excluded outright; WebP and PNG carry animation under the same MIME type as
// their still forms, so the container is sniffed rather than trusted.
const REENCODABLE_TYPES = new Set(['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/bmp']);

const ANIMATION_MARKERS = { 'image/webp': 'ANIM', 'image/png': 'acTL' };

export function hasAnimationMarker(type, headBytes) {
    const marker = ANIMATION_MARKERS[String(type || '').toLowerCase()];
    if (!marker) return false;
    let ascii = '';
    for (const byte of headBytes || []) ascii += String.fromCharCode(byte);
    return ascii.includes(marker);
}

export function planVisionDownscale(image, limits = VISION_LIMITS) {
    const type = String(image && image.type || '').toLowerCase();
    if (!REENCODABLE_TYPES.has(type)) return null;

    const width = Math.floor(Number(image.width) || 0);
    const height = Math.floor(Number(image.height) || 0);
    if (width <= 0 || height <= 0) return null;

    const longEdge = Math.max(width, height);
    if (longEdge <= limits.maxEdge && (Number(image.size) || 0) <= limits.maxBytes) return null;

    const scale = Math.min(1, limits.maxEdge / longEdge);
    return {
        width: Math.max(1, Math.round(width * scale)),
        height: Math.max(1, Math.round(height * scale)),
        // A PNG stays a PNG: JPEG ringing is worst on the screenshot text that
        // is the main reason anyone attaches one.
        type: type === 'image/png' ? 'image/png' : 'image/jpeg',
        quality: limits.quality,
    };
}

export function getVisionFileName(name, type) {
    const base = String(name || '').replace(/\.[^./\\]*$/, '');
    return (base || 'image') + (type === 'image/png' ? '.png' : '.jpg');
}

export async function downscaleImageForVision(file, limits = VISION_LIMITS) {
    // Returning the original is always safe: the Host Server enforces the same
    // budget and answers with a message naming the file, so a browser that
    // cannot decode the image costs a clear refusal rather than a broken upload.
    const type = String(file && file.type || '').toLowerCase();
    if (!REENCODABLE_TYPES.has(type)) return file;
    if (typeof createImageBitmap !== 'function' || typeof document === 'undefined') return file;

    let bitmap = null;
    try {
        if (ANIMATION_MARKERS[type]) {
            // Both markers sit in the header, well inside this slice.
            const head = new Uint8Array(await file.slice(0, 4096).arrayBuffer());
            if (hasAnimationMarker(type, head)) return file;
        }

        // 'from-image' has only been the spec default since 2021; an older engine
        // still defaults to 'none', which would bake a portrait phone photo in
        // sideways and drop the EXIF tag that would have corrected it.
        bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
        const plan = planVisionDownscale(
            { type, size: file.size, width: bitmap.width, height: bitmap.height }, limits);
        if (!plan) return file;

        const canvas = document.createElement('canvas');
        canvas.width = plan.width;
        canvas.height = plan.height;
        const context = canvas.getContext('2d');
        if (!context) return file;
        context.drawImage(bitmap, 0, 0, plan.width, plan.height);

        const blob = await new Promise((resolve) => canvas.toBlob(resolve, plan.type, plan.quality));
        if (!blob || blob.size >= file.size) return file;
        return new File([blob], getVisionFileName(file.name, plan.type), { type: plan.type, lastModified: Date.now() });
    } catch {
        return file;
    } finally {
        if (bitmap && typeof bitmap.close === 'function') bitmap.close();
    }
}

export async function prepareVisionUploads(files, limits = VISION_LIMITS) {
    // Sequential on purpose: decoding several camera photos at once is exactly
    // the memory spike the caller is trying to avoid sending over the wire.
    const prepared = [];
    for (const file of Array.from(files || [])) prepared.push(await downscaleImageForVision(file, limits));
    return prepared;
}
