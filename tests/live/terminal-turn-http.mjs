import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../..', import.meta.url));
const engine = process.argv[2] || process.env.DESKPILOT_CHILD_ENGINE_MODULE;
assert.ok(engine, 'An explicitly approved Engine manifest is required.');
const output = mkdtempSync(join(tmpdir(), 'deskpilot-turn-http-'));
const project = join(output, 'project');
const data = join(output, 'data');
mkdirSync(project);
mkdirSync(data);
const server = spawn('pwsh', ['-NoLogo', '-NoProfile', '-File', join(root, 'tests/live/Start-DpTurnApprovalSmoke.ps1'), '-DataDirectory', data, '-ProjectDirectory', project, '-EngineModulePath', engine], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
try {
    const address = await new Promise((resolveReady, reject) => {
        let outputText = '';
        const timer = setTimeout(() => reject(new Error('Approval proof Host Server did not become ready.')), 30000);
        server.stdout.on('data', (chunk) => {
            outputText = (outputText + chunk.toString()).slice(-32768);
            const match = outputText.match(/http:\/\/127\.0\.0\.1:\d+\/\?t=[a-f0-9]+/);
            if (match) { clearTimeout(timer); resolveReady(new URL(match[0])); }
        });
        server.stderr.on('data', () => {});
        server.once('exit', (code) => { clearTimeout(timer); reject(new Error(`Approval proof Host Server exited: ${code}.`)); });
    });
    const headers = { 'X-DeskPilot-Token': address.searchParams.get('t'), Origin: address.origin, 'Content-Type': 'application/json' };
    const api = async (method, path, body) => {
        const response = await fetch(address.origin + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000) });
        assert.ok(response.ok, `Proof operation ${path} returned ${response.status}.`);
        return response.json();
    };
    const conversation = await api('POST', '/api/conversations', { title: 'Turn approval proof', model: 'gpt-4.1' });
    const turns = [];
    for (const scope of ['turn', 'once']) {
        const response = await fetch(`${address.origin}/api/conversations/${conversation.id}/messages`, {
            method: 'POST', headers, body: JSON.stringify({ prompt: 'Exercise the two fixed harmless fixture commands.' }), signal: AbortSignal.timeout(60000),
        });
        assert.ok(response.ok);
        let buffer = '';
        let approvals = 0;
        let completed;
        const activity = [];
        const decoder = new TextDecoder();
        for await (const chunk of response.body) {
            buffer += decoder.decode(chunk, { stream: true });
            let boundary;
            while ((boundary = buffer.search(/\r?\n\r?\n/)) >= 0) {
                const block = buffer.slice(0, boundary);
                buffer = buffer.slice(boundary).replace(/^\r?\n\r?\n/, '');
                const lines = block.split(/\r?\n/);
                const event = lines.find((line) => line.startsWith('event:'))?.slice(6).trim();
                const json = lines.filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n');
                if (!json) continue;
                const value = JSON.parse(json);
                if (event === 'error') throw new Error(value.message);
                if (event === 'approval') {
                    approvals++;
                    assert.deepEqual(value.allowedScopes, ['once', 'turn']);
                    assert.match(value.summary.command, /^Set-Content -LiteralPath proof-[12]\.txt -Value approved-[12]$/);
                    if (scope === 'turn' && approvals === 1) {
                        assert.equal(existsSync(join(project, 'proof-1.txt')), false);
                        assert.equal(existsSync(join(project, 'proof-2.txt')), false);
                    }
                    const reloaded = await api('GET', `/api/conversations/${conversation.id}/approval`);
                    assert.equal(reloaded.id, value.id);
                    assert.deepEqual(reloaded.allowedScopes, ['once', 'turn']);
                    await api('POST', `/api/conversations/${conversation.id}/approval`, { requestId: value.id, decision: 'approve', scope });
                }
                if (event === 'activity' && value.kind === 'approval') activity.push(value);
                if (event === 'done') completed = value;
            }
        }
        assert.equal(approvals, scope === 'turn' ? 1 : 2);
        assert.ok(completed);
        assert.equal(readFileSync(join(project, 'proof-1.txt'), 'utf8').trim(), 'approved-1');
        assert.equal(readFileSync(join(project, 'proof-2.txt'), 'utf8').trim(), 'approved-2');
        const approved = activity.filter((entry) => entry.status === 'approved');
        assert.equal(approved.length, 2);
        assert.deepEqual(approved.map((entry) => entry.scope), [scope, scope]);
        assert.equal(approved[1].source, scope === 'turn' ? 'turn-grant' : 'prompt');
        const stored = await api('GET', `/api/conversations/${conversation.id}`);
        const last = stored.messages.at(-1);
        assert.equal(last.activity.actions.filter((entry) => entry.kind === 'approval' && entry.status === 'approved').length, 2);
        turns.push({ scope, approvals, approvedActivity: approved.length });
    }
    const report = { passed: true, provider: 'scripted fixture; no live Model requests', turns, output };
    writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 4) + '\n');
    console.log(JSON.stringify(report));
} finally {
    if (server.exitCode === null) {
        server.kill();
        await once(server, 'exit');
    }
}
