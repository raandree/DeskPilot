// Runs the guard checks against the real modules.
//
// Usage: node run-guard-checks-real.mjs

import * as guards from '../../../source/browser/guards.mjs';
import * as policy from '../../../source/browser/policy.mjs';
import { runChecks } from './guard-checks.mjs';

process.stdout.write(JSON.stringify({ checks: await runChecks({ ...guards, ...policy }) }));
