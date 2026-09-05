import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const runtime = process.argv[2] || join(process.env.LOCALAPPDATA, 'DeskPilot', 'browser');
process.env.PLAYWRIGHT_BROWSERS_PATH = join(runtime, 'browsers');
const { chromium } = await import(pathToFileURL(join(runtime, 'node_modules/playwright/index.mjs')).href);
const source = readFileSync(join(root, 'source/web/assets/app.js'), 'utf8');
const css = readFileSync(join(root, 'source/web/assets/styles.css'), 'utf8');
function definition(name, optional = false) {
    const start = source.indexOf(`function ${name}(`);
    if (start < 0 && optional) return '';
    assert.ok(start >= 0, `${name} must exist`);
    const opening = source.indexOf('{', start);
    let depth = 0;
    for (let index = opening; index < source.length; index++) {
        if (source[index] === '{') depth++;
        if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1);
    }
    throw new Error(`Unbalanced ${name}`);
}
const pieces = ['terminalExecutionLabel', 'terminalExecutionRows', 'renderTerminalSettings'].map((name) => definition(name, true)).join('\n');
const output = mkdtempSync(join(tmpdir(), 'deskpilot-terminal-ui-'));
const browser = await chromium.launch({ headless: true });
try {
    for (const width of [1440, 390]) {
        const page = await browser.newPage({ viewport: { width, height: 900 }, locale: 'en-US' });
        page.on('dialog', (dialog) => dialog.accept());
        await page.setContent('<main style="max-width:640px;margin:auto;padding:16px"><h1 style="font-size:20px">DeskPilot</h1><div id="terminal-settings"></div></main>');
        await page.addStyleTag({ content: css });
        await page.addScriptTag({ content: `
            const state = { settings: { permissions: {terminal:true,userTools:true}, terminalExecution: {
                mode:'local',projectAccess:'read-only',network:'off',allowedHosts:[],environment:[],
                timeoutSeconds:120,cpuCount:1,memoryMB:1024,processLimit:64,outputBytes:1048576,tempMB:128
            } } };
            const $ = (id) => document.getElementById(id);
            const el = (className, tag='div') => {const node=document.createElement(tag);node.className=className;return node;};
            const toast = (message) => { window.lastError=message; };
            const updatePermDot = () => {};
            const buildPermList = () => {};
            const api = async (method, path, body) => {
                if (method==='PUT') {window.saved=body;state.settings={...state.settings,...body};return state.settings;}
                return {ready:true,state:'healthy',powerShellVersion:'7.6.5',dockerVersion:'29.7.2',orphanCount:0,issues:[],preparing:false};
            };
            ${pieces}
            if (typeof renderTerminalSettings==='function') renderTerminalSettings($('terminal-settings'));
        ` });
        assert.equal(await page.locator('#terminal-mode-isolated').count(), 1, 'Settings must offer Isolated execution');
        await page.locator('#terminal-mode-isolated').check();
        await page.locator('#terminal-network').selectOption('allow-list');
        await page.locator('#terminal-hosts').fill('example.com');
        await page.locator('#terminal-add-variable').click();
        await page.locator('[data-terminal-variable]').fill('DP_TOKEN');
        await page.locator('#terminal-save').click();
        await page.waitForFunction(() => window.saved?.terminalExecution?.mode === 'isolated');
        const saved = await page.evaluate(() => window.saved.terminalExecution);
        assert.deepEqual(saved.allowedHosts, ['example.com']);
        assert.equal(saved.environment[0].name, 'DP_TOKEN');
        assert.equal(saved.environment[0].secret, true);
        assert.ok(!Object.hasOwn(saved.environment[0], 'value'));
        assert.equal(await page.locator('input[type=password]').count(), 0);
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
        assert.equal(overflow, false, `No horizontal overflow at ${width}px`);
        await page.screenshot({ path: join(output, `terminal-${width}.png`), fullPage: true });
        await page.evaluate(() => { state.settings = null; renderTerminalSettings(document.getElementById('terminal-settings')); });
        assert.equal(await page.locator('#terminal-mode-local').isChecked(), true);
        await page.close();
    }
    console.log(JSON.stringify({ passed: true, output }));
} finally {
    await browser.close();
}
