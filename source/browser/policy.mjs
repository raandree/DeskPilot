// URL policy for contained browser automation (decision 0003).
//
// This is a deliberate second implementation of
// source/Private/Resolve-DpBrowserUrlDecision.ps1, and the duplication is the
// point rather than an accident. PowerShell decides before a navigation so the
// approval card can be raised before anything happens; this decides inside the
// request path, where it can see redirect chains, nested frames, pop-ups and
// sub-resources that PowerShell never hears about.
//
// Two enforcement points for one boundary can drift, and a drifted boundary is
// the failure mode this repository keeps re-learning. So both are held to a
// shared corpus (tests/Unit/fixtures/browser-policy-corpus.json) that asserts
// identical verdicts, and to one invariant: this implementation may never be
// more permissive than the PowerShell one.

const MAX_URL_LENGTH = 4096;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;
const HOST_LABELS = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

// The page controls these and the page knows no secrets, so off-origin they
// leak nothing. Everything else off-origin is refused; see the PowerShell
// counterpart Test-DpBrowserResourceAllowed for why each class differs.
const PASSIVE_RESOURCE_TYPES = new Set(['image', 'stylesheet', 'font', 'media']);

function deny(reason, host = '', url = '') {
    return { decision: 'deny', reason, host, url };
}

// Broader than a strict address parser on purpose: an IP literal can never
// match a name-based allow-list, so over-matching here only ever denies more.
function isAddressLiteral(host) {
    if (host.includes(':')) return true;
    if (/^[0-9.]+$/.test(host)) return true;
    if (/^0x[0-9a-f]+$/i.test(host)) return true;
    return false;
}

export function resolveUrlDecision(rawUrl, scope) {
    if (typeof rawUrl !== 'string' || rawUrl.trim() === '') return deny('empty');
    if (rawUrl.length > MAX_URL_LENGTH) return deny('too-long');
    // Checked before parsing: the URL parser silently strips a newline and
    // hands back something that looks harmless.
    if (CONTROL_CHARACTERS.test(rawUrl)) return deny('control-character');

    let parsed;
    try {
        parsed = new URL(rawUrl);
    } catch {
        return deny('unparseable');
    }

    if (parsed.protocol !== 'https:') return deny('scheme');

    const host = parsed.hostname.replace(/^\[|\]$/g, '').replace(/\.$/, '').toLowerCase();
    if (!host) return deny('no-host');

    // Empty credentials still carry an '@', and reading username/password as
    // truthiness misses 'https://:@host' - a form built to split two parsers.
    const hasUserinfo = parsed.username !== '' || parsed.password !== ''
        || /^[a-z][a-z0-9+.-]*:\/\/[^/?#]*@/i.test(rawUrl);

    // Rebuilt without userinfo so a password in the URL cannot travel onward.
    const safeUrl = hasUserinfo
        ? `${parsed.protocol}//${parsed.host}${parsed.pathname}${parsed.search}`
        : rawUrl;

    if (hasUserinfo) return deny('userinfo', host, safeUrl);
    if (isAddressLiteral(host)) return deny('ip-literal', host, safeUrl);
    if (!host.includes('.')) return deny('single-label-host', host, safeUrl);
    if (host.endsWith('.localhost') || host.endsWith('.local')) return deny('private-host', host, safeUrl);

    for (const entry of scope ?? []) {
        if (typeof entry !== 'string') continue;
        const allowed = entry.trim().replace(/\.$/, '').toLowerCase();
        if (!allowed) continue;
        // Label boundary, never a plain suffix: weathercity.com must not
        // authorise evilweathercity.com or weathercity.com.evil.test.
        if (host === allowed || host.endsWith(`.${allowed}`)) {
            return { decision: 'allow', reason: 'in-scope', host, url: safeUrl };
        }
    }

    return { decision: 'ask', reason: 'off-scope', host, url: safeUrl };
}

export function isResourceAllowed(rawUrl, resourceType, scope) {
    const decision = resolveUrlDecision(rawUrl, scope);
    if (decision.decision === 'allow') return true;
    if (decision.decision === 'deny') return false;
    return PASSIVE_RESOURCE_TYPES.has(String(resourceType ?? '').trim().toLowerCase());
}

export function normalizeScopeEntry(candidate) {
    if (typeof candidate !== 'string') return null;
    const name = candidate.trim().replace(/\.$/, '').toLowerCase();
    return HOST_LABELS.test(name) ? name : null;
}

// Credential fields the model must never type into. The authoritative signal is
// the live input's own type and autocomplete, which is why this takes a
// descriptor read from the DOM rather than a field name the model chose - a name
// is what an attacker controls, and a heuristic over it would be confidence
// rather than a control.
//
// The name pattern below is a second refusal layer only. It can add a refusal
// and can never grant one, so being wrong about it costs a filled field, not a
// leaked secret.
const CREDENTIAL_AUTOCOMPLETE = new Set([
    'current-password', 'new-password', 'one-time-code',
    'cc-number', 'cc-csc', 'cc-exp', 'cc-exp-month', 'cc-exp-year'
]);
const CREDENTIAL_NAME = /pass(word|wd|phrase)|\bpin\b|otp|mfa|2fa|totp|secret|token|api[-_\s]?key|cvv|cvc|security[-_\s]?(answer|question)|(recovery|verification|sms|auth|access|login|one[-_\s]?time)[-_\s]?code|\bcode\b/i;

// Ranges a browser DeskPilot drives has no business reaching. Checked against
// the address the connection actually landed on, because a name with a public
// A record can point inward and a pre-flight resolve is a TOCTOU against
// rebinding - the peer address is the load-bearing check.
export function isInternalAddress(address) {
    const text = String(address ?? '').trim().replace(/^\[|\]$/g, '').toLowerCase();
    if (!text) return false;

    if (text.includes(':')) {
        if (text === '::1' || text === '::') return true;
        const mapped = text.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
        if (mapped) return isInternalAddress(mapped[1]);
        const head = parseInt(text.split(':')[0] || '0', 16);
        if ((head & 0xfe00) === 0xfc00) return true;       // fc00::/7 unique local
        if ((head & 0xffc0) === 0xfe80) return true;       // fe80::/10 link local
        return false;
    }

    const parts = text.split('.').map(Number);
    if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
    const [a, b] = parts;
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true;               // link local + metadata
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;     // CGNAT
    if (a === 198 && (b === 18 || b === 19)) return true;  // benchmarking
    if (a === 192 && b === 0) return true;
    return false;
}

export function isFieldFillable(descriptor) {
    const field = descriptor ?? {};
    const type = String(field.type ?? '').trim().toLowerCase();
    const autocomplete = String(field.autocomplete ?? '').trim().toLowerCase();
    const name = `${field.name ?? ''} ${field.id ?? ''} ${field.label ?? ''}`;

    // A password box is refused outright rather than masked. The user is told to
    // sign in themselves; there is no value the model may put here.
    if (type === 'password') return { fillable: false, reason: 'credential-field' };
    if (CREDENTIAL_AUTOCOMPLETE.has(autocomplete)) return { fillable: false, reason: 'credential-field' };
    if (CREDENTIAL_NAME.test(name)) return { fillable: false, reason: 'credential-field' };

    // A file input is a different capability with a different approval.
    if (type === 'file') return { fillable: false, reason: 'file-input' };

    // Invisible to the person approving, so it cannot be part of what they
    // approved. Page-controlled by definition.
    if (type === 'hidden') return { fillable: false, reason: 'hidden-field' };
    if (field.visible === false) return { fillable: false, reason: 'not-visible' };

    if (field.disabled === true || field.readOnly === true) return { fillable: false, reason: 'not-editable' };

    return { fillable: true, reason: 'ok' };
}
