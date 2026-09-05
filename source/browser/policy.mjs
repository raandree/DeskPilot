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

    // Rebuilt without userinfo so a password in the URL cannot travel onward.
    const safeUrl = parsed.username || parsed.password
        ? `${parsed.protocol}//${parsed.host}${parsed.pathname}${parsed.search}`
        : rawUrl;

    if (parsed.username || parsed.password) return deny('userinfo', host, safeUrl);
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
const CREDENTIAL_NAME = /pass(word|wd|phrase)|\bpin\b|otp|mfa|2fa|totp|secret|token|api[-_\s]?key|cvv|cvc|security[-_\s]?(answer|question)|recovery[-_\s]?code/i;

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
