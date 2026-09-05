// Mutates a seed set into URL forms that split parsers, and reports both
// implementations' verdicts. The curated corpus can only ever contain the
// divergence classes somebody already thought of; this generates the inputs so a
// *new* class is found by the test rather than by the next review.
//
// Deterministic: the mutation table is fixed, so a failure is reproducible and a
// green run means the same thing twice.
//
// Usage: node mutate-policy-corpus.mjs <scope-json>

import { resolveUrlDecision } from '../../../source/browser/policy.mjs';

const scope = JSON.parse(process.argv[2] ?? '["weathercity.com"]');

// Seeds include the near-misses around the label boundary, because that boundary
// is what the security property is about and the first version of this generator
// never produced one: it mutated only the first '.' of four fixed hosts, so a
// green run said nothing about `evilweathercity.com` or
// `weathercity.com.evil.test` (B3-4 process finding, 2026-09-05).
const hosts = [
    'weathercity.com',
    'sub.weathercity.com',
    'evilweathercity.com',
    'weathercity.com.evil.test',
    'weathercity.com-evil.test',
    'weathercity.co',
    'xn--weathercity-9db.com',
    'weather\u00ADcity.com',
    'example.test',
    '127.0.0.1',
    '169.254.169.254',
    'localhost'
];

// Each entry rewrites a host or a whole URL into a form some parser reads
// differently. Percent-encoding, alternate separators, confusable slashes,
// credential markers, empty labels and scheme oddities.
const hostMutations = [
    (h) => h,
    (h) => h.replace('.', '\u3002'),
    (h) => h.replace('.', '\uFF0E'),
    (h) => h.replace('.', '\uFF61'),
    (h) => h.replace(/\.([^.]*)$/, '\u3002$1'),
    (h) => h.toUpperCase(),
    (h) => h.replace(/[a-z]/, (c) => String.fromCharCode(c.charCodeAt(0) + 0xFEE0)),
    (h) => h.replace('.', '%2e'),
    (h) => h.replace(/\.([^.]*)$/, '%2e$1'),
    (h) => h.replace(/^./, (c) => `%${c.charCodeAt(0).toString(16)}`),
    (h) => `${h}.`,
    (h) => `.${h}`,
    (h) => `a..${h}`,
    (h) => `${h}\u2044evil.test`,
    (h) => `${h}\\evil.test`,
    (h) => `${h}@evil.test`,
    (h) => `evil.test@${h}`,
    (h) => `:@${h}`,
    (h) => `@${h}`,
    (h) => ` ${h}`,
    (h) => `${h}\t`,
    (h) => `${h}:443`,
    (h) => `${h}:0`,
    (h) => `[${h}]`
];

const tails = [
    '',
    '/',
    '/path',
    '/path?q=1#frag',
    '/%2e%2e/admin',
    '/..%2fadmin',
    '/%66orecast',
    '/a%00b',
    '?@evil.test',
    '#@evil.test'
];

const urlShapes = [
    (h, t) => `https://${h}${t || '/'}`,
    (h, t) => `https://${h}${t}`,
    (h, t) => `https:${h}${t || '/'}`,
    (h, t) => `https:/${h}${t || '/'}`,
    (h, t) => `https:///${h}${t || '/'}`,
    (h, t) => `https:\\\\${h}${t.replace(/\//g, '\\') || '\\'}`,
    (h, t) => `HTTPS://${h}${t || '/'}`,
    (h, t) => `//${h}${t || '/'}`
];

const results = [];
for (const host of hosts) {
    for (const mutate of hostMutations) {
        let mutated;
        try { mutated = mutate(host); } catch { continue; }
        for (const tail of tails) {
            for (const shape of urlShapes) {
                const url = shape(mutated, tail);
                let decision;
                try { decision = resolveUrlDecision(url, scope); }
                catch (error) { decision = { decision: 'threw', reason: String(error?.message ?? error), host: '' }; }
                results.push({ url, decision: decision.decision, reason: decision.reason, host: decision.host });
            }
        }
    }
}

process.stdout.write(JSON.stringify({ results }));
