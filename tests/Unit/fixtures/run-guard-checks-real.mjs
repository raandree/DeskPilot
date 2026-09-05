// Runs the guard checks against the real guards.
//
// Usage: node run-guard-checks.mjs

import * as guards from '../../../source/browser/guards.mjs';
import { runChecks } from './guard-checks.mjs';

process.stdout.write(JSON.stringify({ checks: await runChecks(guards) }));
