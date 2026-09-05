// Runs the shared policy corpus through source/browser/policy.mjs and prints one
// JSON result per case, so the Pester conformance test can compare the Node
// verdicts against the PowerShell ones without reimplementing either.
//
// Usage: node run-policy-corpus.mjs <corpus.json>

import { readFileSync } from 'node:fs';
import { resolveUrlDecision, isResourceAllowed, isFieldFillable, isInternalAddress } from '../../../source/browser/policy.mjs';

const corpusPath = process.argv[2];
if (!corpusPath) {
    console.error('usage: run-policy-corpus.mjs <corpus.json>');
    process.exit(2);
}

const corpus = JSON.parse(readFileSync(corpusPath, 'utf8'));

const urlResults = corpus.urlCases.map((testCase, index) => ({
    index,
    actual: resolveUrlDecision(testCase.url, corpus.scope).decision
}));

const resourceResults = corpus.resourceCases.map((testCase, index) => ({
    index,
    actual: isResourceAllowed(testCase.url, testCase.type, corpus.scope)
}));

const fieldResults = (corpus.fieldCases ?? []).map((testCase, index) => ({
    index,
    actual: isFieldFillable(testCase.field).fillable
}));

const addressResults = (corpus.addressCases ?? []).map((testCase, index) => ({
    index,
    actual: isInternalAddress(testCase.address)
}));

process.stdout.write(JSON.stringify({ urlResults, resourceResults, fieldResults, addressResults }));
