import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { once } from 'node:events';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const temporary = mkdtempSync(join(tmpdir(), 'deskpilot-http-isolation-'));
const project = join(temporary, 'project');
const data = join(temporary, 'data');
const scriptedProvider = process.argv.includes('--scripted-provider');
mkdirSync(project); mkdirSync(data);
const git = (...args) => {
    const result = spawnSync('git', ['-C', project, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
};
git('init', '-q');
git('config', 'user.name', 'DeskPilot fixture');
git('config', 'user.email', 'fixture@example.invalid');
git('config', 'commit.gpgsign', 'false');
writeFileSync(join(project, 'proof.txt'), 'committed-original\n');
git('add', 'proof.txt'); git('commit', '-qm', 'fixture');
writeFileSync(join(project, 'proof.txt'), 'user-edit-before-turn\n');
const server = spawn('pwsh', ['-NoLogo', '-NoProfile', '-File', join(root, 'tests/live/Start-DpIsolationSmoke.ps1'), '-DataDirectory', data, '-ProjectDirectory', project, ...(scriptedProvider ? ['-ScriptedProvider'] : [])], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
let browser;
let base;
let sessionToken;
const report = { project, data, provider: scriptedProvider ? 'scripted fixture (not a live Model)' : 'live Copilot', passed: false };
try {
    const address = await new Promise((resolveReady, reject) => {
        let output = '';
        const timer = setTimeout(() => reject(new Error('Smoke Host Server did not become ready.')), 120000);
        server.stdout.on('data', (chunk) => {
            output = (output + chunk.toString()).slice(-65536);
            const match = output.match(/http:\/\/127\.0\.0\.1:\d+\/\?t=[a-f0-9]+/);
            if (match) { clearTimeout(timer); resolveReady(new URL(match[0])); }
        });
        server.stderr.on('data', () => {});
        server.once('exit', (code) => { clearTimeout(timer); reject(new Error(`Smoke Host Server exited with code ${code}.`)); });
    });
    base = address.origin;
    sessionToken = address.searchParams.get('t');
    const headers = { 'X-DeskPilot-Token': sessionToken, 'Content-Type': 'application/json', Origin: base };
    const api = async (method, path, body) => {
        const response = await fetch(base + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
        const value = await response.json();
        assert.ok(response.ok, `${path}: ${JSON.stringify(value)}`);
        return value;
    };
    assert.equal((await fetch(base + '/api/diagnostics/terminal')).status, 401);
    const health = await api('GET', '/api/health');
    assert.equal(health.engineImported, true, health.engineError || 'The real Engine must be imported.');
    const runtime = await api('POST', '/api/diagnostics/terminal/check', {});
    assert.equal(runtime.ready, true, JSON.stringify(runtime));
    const modelResult = await api('GET', '/api/models');
    const available = modelResult.models.map((item) => item.id);
    const model = ['gpt-4.1', 'gpt-5-mini', 'gpt-4o'].find((candidate) => available.includes(candidate));
    assert.ok(model, `A supported small test Model is required: ${JSON.stringify(modelResult)}`);
    await api('PUT', '/api/settings', { model, agentsRoot: null, selectedAgent: null, skillRoots: [], instructionRoots: [], promptRoots: [] });
    const conversation = await api('POST', '/api/conversations', { title: 'Isolation acceptance', model });
    const command = "Set-Content -Path /project/proof.txt -Value 'isolated-proof'; Write-Output $IsLinux";
    const response = await fetch(base + `/api/conversations/${conversation.id}/messages`, {
        method: 'POST', headers,
        body: JSON.stringify({ prompt: `Acceptance test in a disposable Project. Call run_terminal_command exactly once with command exactly: ${command}\nDo not use other Tools or change this command. Wait for approval. Then report the returned operating-system flag.` }),
        signal: AbortSignal.timeout(180000),
    });
    assert.equal(response.ok, true);
    let buffer = '';
    let completed;
    let approved = 0;
    let runActivity = 0;
    const decoder = new TextDecoder();
    for await (const chunk of response.body) {
        buffer += decoder.decode(chunk, { stream: true });
        let boundary;
        while ((boundary = buffer.search(/\r?\n\r?\n/)) >= 0) {
            const block = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary).replace(/^\r?\n\r?\n/, '');
            const lines = block.split(/\r?\n/);
            const event = lines.find((line) => line.startsWith('event:'))?.slice(6).trim();
            const payload = lines.filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n');
            if (!payload) continue;
            const value = JSON.parse(payload);
            if (event === 'error') throw new Error(value.message);
            if (event === 'start') assert.equal(value.terminalExecution.mode, 'isolated');
            if (event === 'approval') {
                assert.equal(value.summary.execution.mode, 'isolated');
                assert.equal(value.summary.command, command, 'Only the exact harmless fixture command may be approved.');
                assert.equal(readFileSync(join(project, 'proof.txt'), 'utf8').trim(), 'user-edit-before-turn');
                await api('POST', `/api/conversations/${conversation.id}/approval`, { requestId: value.id, decision: 'approve' });
                approved++;
            }
            if (event === 'activity' && value.kind === 'run') { assert.equal(value.execution.mode, 'isolated'); runActivity++; }
            if (event === 'done') completed = value;
        }
    }
    assert.equal(approved, 1);
    assert.equal(runActivity, 1);
    assert.ok(completed, 'The Engine Turn must complete.');
    assert.ok(completed.usage.totalTokens > 0, 'Usage must be mapped from the Engine result.');
    assert.ok(completed.activity.filesWritten.includes('proof.txt'));
    assert.equal(readFileSync(join(project, 'proof.txt'), 'utf8').trim(), 'isolated-proof');
    const pending = await api('GET', '/api/changes');
    assert.ok(JSON.stringify(pending).includes('proof.txt'));
    await api('POST', '/api/changes/undo', { paths: ['proof.txt'] });
    assert.equal(readFileSync(join(project, 'proof.txt'), 'utf8').trim(), 'user-edit-before-turn');

    const browserRoot = join(process.env.LOCALAPPDATA, 'DeskPilot', 'browser');
    process.env.PLAYWRIGHT_BROWSERS_PATH = join(browserRoot, 'browsers');
    const { chromium } = await import(pathToFileURL(join(browserRoot, 'node_modules/playwright/index.mjs')).href);
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.goto(address.href);
    await page.locator('#project-chip-label').filter({ hasText: /^project$/ }).waitFor();
    await page.locator('#btn-settings').click();
    await page.locator('#stab-permissions').click();
    await page.locator('#terminal-mode-isolated').waitFor();
    assert.equal(await page.locator('#terminal-mode-isolated').isChecked(), true);
    await page.screenshot({ path: join(temporary, 'host-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false);
    await page.screenshot({ path: join(temporary, 'host-mobile.png'), fullPage: true });
    assert.deepEqual(errors, []);
    Object.assign(report, { passed: true, model, approved, runActivity, totalTokens: completed.usage.totalTokens, undoPreservedUserEdit: true });
    writeFileSync(join(temporary, 'report.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report));
} finally {
    if (browser) await browser.close();
    if (server.exitCode === null) {
        server.kill();
        await once(server, 'exit');
    }
}
