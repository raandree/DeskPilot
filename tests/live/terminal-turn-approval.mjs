import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { en } from '../../source/web/assets/locales/en.js';

const root = fileURLToPath(new URL('../..', import.meta.url));
const runtime = process.argv[2] || join(process.env.LOCALAPPDATA, 'DeskPilot', 'browser');
process.env.PLAYWRIGHT_BROWSERS_PATH = join(runtime, 'browsers');
const { chromium } = await import(pathToFileURL(join(runtime, 'node_modules/playwright/index.mjs')).href);
const source = readFileSync(join(root, 'source/web/assets/app.js'), 'utf8');
const begin = source.indexOf('const APPROVAL_TITLES =');
const end = source.indexOf('\nfunction renderUsage(', begin);
assert.ok(begin >= 0 && end > begin);
const approvalCode = source.slice(begin, end);
const css = readFileSync(join(root, 'source/web/assets/styles.css'), 'utf8').replace(/^\uFEFF/, '');
const output = mkdtempSync(join(tmpdir(), 'deskpilot-turn-approval-ui-'));
const browser = await chromium.launch({ headless: true });
try {
    for (const width of [1440, 390]) {
        const page = await browser.newPage({ viewport: { width, height: 900 }, locale: 'en-US' });
        const requests = [];
        page.on('request', (request) => requests.push(request.url()));
        await page.setContent('<main style="max-width:700px;margin:auto;padding:16px"><h1>DeskPilot</h1><div id="approvals"></div></main>');
        await page.addStyleTag({ content: css });
        await page.addScriptTag({ content: `
            const catalog = ${JSON.stringify(en)};
            const t = (key) => catalog[key] || key;
            const el = (className, tag = 'div') => { const node = document.createElement(tag); node.className = className; return node; };
            const terminalExecutionRows = (execution) => [['Mode', execution?.mode || 'local']];
            const scrollThread = () => {};
            const errorText = (error) => error.message;
            window.answers = [];
            const api = async (method, path, body) => { window.answers.push({ method, path, body }); return { accepted: true }; };
            ${approvalCode}
            window.showApproval = (request) => renderApproval(document.getElementById('approvals'), request, 'conversation');
            showApproval({id:'terminal-turn',class:'Terminal',allowedScopes:['once','turn'],summary:{command:'npm test',workingDirectory:'C:/selected-project',project:'Selected Project',execution:{mode:'isolated'}}});
        ` });
        assert.equal(await page.getByRole('button', { name: 'Allow for this Turn', exact: true }).count(), 1);
        assert.equal(await page.getByRole('button', { name: 'Allow once', exact: true }).count(), 1);
        assert.equal(await page.locator('.approval-deny').evaluate((button) => button === document.activeElement), true);
        assert.match(await page.locator('.approval-turn-risk').textContent(), /Terminal/);
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
        assert.equal(overflow, false, `No approval overflow at ${width}px`);
        await page.screenshot({ path: join(output, `turn-approval-${width}.png`), fullPage: true });
        await page.getByRole('button', { name: 'Allow for this Turn', exact: true }).click();
        await page.waitForFunction(() => window.answers.length === 1);
        assert.equal((await page.evaluate(() => window.answers[0].body)).scope, 'turn');
        assert.equal(await page.locator('[data-approval-id="terminal-turn"] button:enabled').count(), 0);
        assert.match(await page.locator('.approval-status').textContent(), /Turn/);

        await page.evaluate(() => {
            showApproval({id:'terminal-once',class:'Terminal',allowedScopes:['once','turn'],summary:{command:'npm run build',workingDirectory:'C:/selected-project'}});
            showApproval({id:'browser',class:'BrowserAction',allowedScopes:['once','turn'],summary:{action:'click_button',host:'example.test',url:'https://example.test',control:'<img src="https://untrusted.example/leak">'}});
            showApproval({id:'legacy',class:'Terminal',summary:{command:'npm test'}});
        });
        assert.equal(await page.locator('[data-approval-id="browser"] .approval-turn').count(), 0);
        assert.equal(await page.locator('[data-approval-id="legacy"] .approval-turn').count(), 0);
        assert.equal(await page.locator('#approvals img').count(), 0);
        await page.locator('[data-approval-id="terminal-once"] .approval-approve').click();
        await page.waitForFunction(() => window.answers.length === 2);
        assert.equal((await page.evaluate(() => window.answers[1].body)).scope, 'once');
        await page.locator('[data-approval-id="browser"] .approval-deny').click();
        await page.waitForFunction(() => window.answers.length === 3);
        assert.deepEqual(await page.evaluate(() => ({ decision: window.answers[2].body.decision, scope: window.answers[2].body.scope })), { decision: 'deny', scope: 'once' });
        assert.equal(requests.some((url) => url.includes('untrusted.example')), false);
        await page.close();
    }
    console.log(JSON.stringify({ passed: true, widths: [1440, 390], output }));
} finally { await browser.close(); }