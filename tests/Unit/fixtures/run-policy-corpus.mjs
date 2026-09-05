// Runs the shared policy corpus through source/browser/policy.mjs and prints one
// JSON result per case, so the Pester conformance test can compare the Node
// verdicts against the PowerShell ones without reimplementing either.
//
// Usage: node run-policy-corpus.mjs <corpus.json>

import { readFileSync } from 'node:fs';
import { resolveUrlDecision, isResourceAllowed, isFieldFillable } from '../../../source/browser/policy.mjs';

const corpusPath = process.argv[2];
if (!corpusPath) {
    console.error('usage: run-policy-corpus.mjs <corpus.json>');
    process.exit(2);
}

const corpus = JSON.parse(readFileSync(corpusPath, 'utf8'));

const urlResults = corpus.urlCases.map((testCase) => ({
    url: testCase.url,
    actual: resolveUrlDecision(testCase.url, corpus.scope).decision
}));

const resourceResults = corpus.resourceCases.map((testCase) => ({
    url: testCase.url,
    type: testCase.type,
    actual: isResourceAllowed(testCase.url, testCase.type, corpus.scope)
}));

const fieldResults = (corpus.fieldCases ?? []).map((testCase, index) => ({
    index,
    actual: isFieldFillable(testCase.field).fillable
}));

process.stdout.write(JSON.stringify({ urlResults, resourceResults, fieldResults }));
