import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const runtime = process.argv[2] || join(process.env.LOCALAPPDATA, 'DeskPilot', 'browser');
process.env.PLAYWRIGHT_BROWSERS_PATH = join(runtime, 'browsers');
const { chromium } = await import(pathToFileURL(join(runtime, 'node_modules/playwright/index.mjs')).href);
const source = readFileSync(join(root, 'source/web/assets/child.js'), 'utf8').replaceAll('export function ', 'function ');
const css = readFileSync(join(root, 'source/web/assets/styles.css'), 'utf8').replace(/^\uFEFF/, '');
const output = mkdtempSync(join(tmpdir(), 'deskpilot-child-ui-'));
const browser = await chromium.launch({ headless: true });
try {
    for (const width of [1440, 390]) {
        const page = await browser.newPage({ viewport: { width, height: 900 } });
        const requests = [];
        page.on('request', (request) => requests.push(request.url()));
        await page.setContent('<main><h1>DeskPilot</h1><button id="open">Private child</button></main>');
        await page.addStyleTag({ content: css });
        await page.addScriptTag({ content: `
            ${source}
            const settings = {model:'claude-haiku-4.5',childExecution:{enabled:false,profile:'single-child-v2',projectAccess:'read-only'}};
            const run = {id:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',status:'awaiting-approval',phase:'terminal',profile:'single-child-v3',budgetMode:'provider-estimate',content:'<img src="https://untrusted.example/leak">',usage:{UsageKnown:false,ReservedTokens:132,ReservedCostUSD:0.25},approval:{id:'approval',fingerprint:'b'.repeat(64),operation:'terminal',action:{command:'Write-Output contained'}},events:[]};
            window.decisions=[];
            const api = async (method,path,body) => {
                if(method==='PUT' && path==='/api/settings') {settings.childExecution={...settings.childExecution,...body.childExecution};return settings;}
                if(path.endsWith('/diagnostics/child')) return {ready:true,state:'ready',effectiveLimits:{inputTokens:16384,totalTokens:32768,costUSD:0.25,iterations:8,durationSeconds:300,storageBytes:134217728,model:'claude-haiku-4.5'}};
                if(path.endsWith('/current')) {const error=new Error('not found');error.status=404;throw error;}
                if(method==='POST' && path.endsWith('/child-runs')) {window.started=body;return {...run};}
                if(path.endsWith('/approval')) {window.decisions.push(body);run.approval=null;run.status='completed';run.cleanupSucceeded=true;run.hasProposal=true;return {accepted:true};}
                if(path.endsWith('/proposal')) {const content='<img src="https://untrusted.example/proposal">';return {files:[{path:'result.html',operation:'add',size:content.length,contentBase64:btoa(content)}]};}
                return {...run};
            };
            const panel=initializeChildPanel({api,getContext:()=>({conversation:{id:'conversation'},settings,prompt:'Read selected input.',streaming:false}),settingsChanged:()=>{},finished:async()=>{},notify:()=>{}});
            document.getElementById('open').onclick=()=>panel.open();
        ` });
        await page.locator('#open').click();
        assert.equal(await page.locator('#child-profile-select').count(), 1, 'The operator can explicitly select V3 from a V2 installation');
        await page.locator('#child-profile-select').selectOption('single-child-v3');
        await page.locator('#child-enabled').check();
        await page.locator('#child-files').fill('input.txt');
        assert.equal(await page.locator('#child-start').isDisabled(), true);
        await page.locator('#child-consent').check();
        await page.locator('#child-start').click();
        await page.waitForFunction(() => window.started?.budgetMode === 'provider-estimate');
        await page.locator('#child-approve').click();
        await page.waitForFunction(() => window.decisions.length === 1);
        await page.locator('#child-proposals').waitFor({ state: 'visible' });
        assert.equal(await page.locator('#child-content img, #child-proposal-content img').count(), 0);
        assert.ok((await page.locator('#child-content').textContent()).includes('<img'));
        assert.ok((await page.locator('#child-proposal-content').textContent()).includes('<img'));
        assert.match(await page.locator('#child-usage').textContent(), /unknown/);
        assert.equal(requests.some((url) => url.includes('untrusted.example')), false);
        const overflow = await page.evaluate(() => {
            const dialog = document.getElementById('child-dialog');
            return dialog.scrollWidth > dialog.clientWidth + 1 || dialog.getBoundingClientRect().right > innerWidth + 1;
        });
        assert.equal(overflow, false, `No child panel overflow at ${width}px`);
        await page.locator('#child-dialog').evaluate((dialog) => { dialog.scrollTop = 0; });
        await page.screenshot({ path: join(output, `child-${width}.png`), fullPage: true });
        await page.close();
    }
    console.log(JSON.stringify({ passed: true, output }));
} finally { await browser.close(); }
