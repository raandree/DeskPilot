// Evaluates policy.mjs on the exact strings PowerShell rebuilt and handed to the
// browser, rather than on the strings the Model typed.
//
// This is the property the approval card actually depends on. The generated
// corpus asserted it about the *pre-rebuild* URL, so the change that introduced
// the rebuild was covered by nothing but a source-text grep (B4-3, 2026-09-05).
//
// Usage: node run-rebuilt-urls.mjs <urls.json> <scope-json>
//   urls.json: ["https://host/path", ...]

import { readFileSync } from 'node:fs';
import { resolveUrlDecision } from '../../../source/browser/policy.mjs';

const urls = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const scope = JSON.parse(process.argv[3] ?? '["weathercity.com"]');

const results = urls.map((url) => {
    let decision;
    try { decision = resolveUrlDecision(url, scope); }
    catch (error) { decision = { decision: 'threw', reason: String(error?.message ?? error), host: '' }; }
    return { url, decision: decision.decision, reason: decision.reason, host: decision.host };
});

process.stdout.write(JSON.stringify({ results }));
