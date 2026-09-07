export function childStartRequest({ prompt, paths, consent, writable = false }) {
    if (consent !== true || typeof prompt !== 'string' || !prompt.trim()) throw new Error('Explicit consent and a task are required.');
    const selectedPaths = String(paths || '').split(/\r?\n/).map((path) => path.trim()).filter(Boolean);
    if (!selectedPaths.length || selectedPaths.length > 4000) throw new Error('Select at least one Project file.');
    const seen = new Set();
    for (const path of selectedPaths) {
        const parts = path.replaceAll('\\', '/').split('/');
        if (path.length > 2048 || /^[\\/]/.test(path) || /[:\0]/.test(path) || parts.some((part) => !part || part === '.' || part === '..') || seen.has(path.toLowerCase())) {
            throw new Error('Selected files must have distinct Project-relative paths.');
        }
        seen.add(path.toLowerCase());
    }
    return { consent: true, prompt, selectedPaths, profile: 'single-child-v3', budgetMode: 'provider-estimate', projectAccess: writable ? 'read-write' : 'read-only' };
}

export function childUsageText(usage) {
    if (!usage) return 'Reported Usage: unknown';
    const reported = usage.UsageKnown === true
        ? `Reported: ${usage.PromptTokens ?? '?'} input / ${usage.CompletionTokens ?? '?'} output tokens; USD ${Number(usage.CostUSD || 0).toFixed(6)}`
        : 'Reported totals: unknown; known partial Usage is retained';
    return `${reported}. Estimated reservations: ${usage.ReservedTokens ?? '?'} tokens; USD ${usage.ReservedCostUSD ?? '?'}.`;
}

export function childProposalText(file) {
    if (!Number.isInteger(file.size) || file.size < 0 || file.size > 50331648) throw new Error('Proposal exceeds its byte limit.');
    if (file.operation === 'delete') return '(Proposed deletion)';
    if (typeof file.contentBase64 !== 'string' || file.contentBase64.length > Math.ceil(file.size / 3) * 4 + 4) throw new Error('Invalid proposal bytes.');
    const bytes = Uint8Array.from(atob(file.contentBase64), (character) => character.charCodeAt(0));
    if (bytes.length !== file.size) throw new Error('Proposal byte count mismatch.');
    try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
    catch { return `(Binary proposal, ${bytes.length} bytes)`; }
}

export function initializeChildPanel({ api, getContext, settingsChanged, finished, notify }) {
    const dialog = document.createElement('dialog');
    dialog.id = 'child-dialog';
    dialog.className = 'child-dialog';
    dialog.setAttribute('aria-labelledby', 'child-heading');
    dialog.innerHTML = `
        <header class="child-header"><h2 id="child-heading">Private child</h2><button class="icon-btn" id="child-close" title="Close" aria-label="Close">&#215;</button></header>
        <div class="child-body">
            <section class="child-setup" aria-label="Child task">
                <p id="child-profile" class="muted tiny">single-child-v3 / provider-estimate</p>
                <label class="field">Execution profile<select id="child-profile-select"><option value="single-child-v2">V2: verified budgets</option><option value="single-child-v3">V3: estimated budgets</option></select></label>
                <div class="child-controls"><button class="btn" id="child-check">Check runtime</button><button class="btn" id="child-prepare">Prepare runtime</button><button class="btn" id="child-cleanup">Clean up</button><button class="btn" id="child-remove">Remove runtime</button></div>
                <output id="child-readiness" aria-live="polite"></output>
                <label class="child-toggle"><input id="child-enabled" type="checkbox">Enable single-child V3</label>
                <label class="field">Task<textarea id="child-task" rows="3" maxlength="262144"></textarea></label>
                <label class="field">Selected Project files<textarea id="child-files" rows="4" spellcheck="false"></textarea></label>
                <label class="child-toggle"><input id="child-writable" type="checkbox">Allow private proposed changes</label>
                <div id="child-limits" class="child-limits"></div>
                <label class="child-consent"><input id="child-consent" type="checkbox"><span>I consent to send the task, selected context, Tool schemas, and Tool results to Copilot for counting and generation. Token and cost budgets are estimates; actual charges may exceed them.</span></label>
                <button class="btn btn-primary" id="child-start">Start private child</button>
            </section>
            <section class="child-result" aria-label="Child result">
                <div class="child-controls"><h3 id="child-state">No child run</h3><button class="btn" id="child-stop" hidden>Stop child</button></div>
                <p id="child-usage" class="muted tiny"></p>
                <section id="child-approval" class="child-approval" hidden><h3>Pending approval</h3><pre id="child-approval-facts"></pre><div class="child-controls"><button class="btn" id="child-deny">Deny</button><button class="btn btn-primary" id="child-approve">Approve once</button></div></section>
                <pre id="child-content" class="child-text"></pre>
                <div id="child-activity" class="child-activity"></div>
                <section id="child-proposals" hidden><h3>Private proposals</h3><select id="child-proposal-file" aria-label="Proposed file"></select><pre id="child-proposal-content" class="child-text"></pre></section>
                <output id="child-error" class="error-text" aria-live="polite"></output>
            </section>
        </div>`;
    document.body.append(dialog);
    const byId = (id) => dialog.querySelector(`#${id}`);
    let readiness = null;
    let run = null;
    let conversationId = '';
    let timer = null;
    let working = false;
    let proposalId = '';
    let proposals = [];
    const active = () => run && ['starting', 'running', 'awaiting-approval', 'stopping'].includes(run.status);
    const path = (suffix = '') => `/api/conversations/${encodeURIComponent(conversationId)}/child-runs/${encodeURIComponent(run.id)}${suffix}`;
    const error = (failure) => { byId('child-error').textContent = failure.message || 'Child operation failed.'; };
    const refreshButtons = () => {
        byId('child-start').disabled = working || active() || !readiness?.ready || !byId('child-enabled').checked || !byId('child-consent').checked || !byId('child-task').value.trim() || !byId('child-files').value.trim();
        byId('child-stop').hidden = !active();
        byId('child-enabled').disabled = working || active() || !readiness?.ready;
        for (const id of ['child-profile-select', 'child-prepare', 'child-check', 'child-cleanup', 'child-remove', 'child-task', 'child-files', 'child-writable']) byId(id).disabled = working || active();
    };
    const schedule = () => {
        clearTimeout(timer);
        if (dialog.open || active()) timer = setTimeout(poll, 1200);
    };
    const showRun = () => {
        byId('child-state').textContent = run ? `${run.status}${run.phase ? ': ' + run.phase : ''}` : 'No child run';
        byId('child-usage').textContent = run ? childUsageText(run.usage) : '';
        byId('child-content').textContent = run?.content || '';
        byId('child-approval').hidden = !run?.approval;
        byId('child-approval-facts').textContent = run?.approval ? JSON.stringify(run.approval, null, 2) : '';
        byId('child-activity').replaceChildren();
        for (const event of (run?.events || [])) {
            const row = document.createElement('p');
            row.textContent = `${event.sequence}. ${event.operation}: ${event.status}${event.path ? ' - ' + event.path : ''}`;
            byId('child-activity').append(row);
        }
        if (run?.code) byId('child-error').textContent = run.code;
        refreshButtons();
    };
    async function loadReadiness() {
        readiness = await api('GET', '/api/diagnostics/child');
        byId('child-readiness').textContent = readiness.preparing ? 'Preparing runtime...' : `${readiness.state}${readiness.missingContracts?.length ? ': ' + readiness.missingContracts.join(', ') : ''}${readiness.operationError ? ': ' + readiness.operationError : ''}`;
        const limits = readiness.effectiveLimits || {};
        byId('child-limits').textContent = `Estimated budgets: ${limits.inputTokens ?? '?'} input/request, ${limits.totalTokens ?? '?'} cumulative tokens, USD ${limits.costUSD ?? '?'}. Local limits: ${limits.iterations ?? '?'} generation attempts, ${limits.durationSeconds ?? '?'} seconds, ${Math.round((limits.storageBytes || 0) / 1048576)} MiB storage. Model: ${limits.model || 'claude-haiku-4.5'}.`;
        refreshButtons();
    }
    async function poll() {
        try {
            if (run && active()) {
                const wasActive = active();
                run = await api('GET', path());
                showRun();
                if (wasActive && !active()) await finished();
            } else if (dialog.open) await loadReadiness();
            if (run?.hasProposal && run.cleanupSucceeded && proposalId !== run.id) {
                const result = await api('GET', path('/proposal'));
                proposals = result.files || [];
                proposalId = run.id;
                byId('child-proposal-file').replaceChildren();
                for (const [index, file] of proposals.entries()) {
                    const option = document.createElement('option');
                    option.value = String(index);
                    option.textContent = `${file.operation}: ${file.path} (${file.size} bytes)`;
                    byId('child-proposal-file').append(option);
                }
                byId('child-proposals').hidden = !proposals.length;
                byId('child-proposal-content').textContent = proposals.length ? childProposalText(proposals[0]) : '';
            }
        } catch (failure) { error(failure); }
        finally { schedule(); }
    }
    async function perform(operation) {
        working = true;
        byId('child-error').textContent = '';
        refreshButtons();
        try { await operation(); }
        catch (failure) { error(failure); }
        finally { working = false; refreshButtons(); schedule(); }
    }
    for (const action of ['check', 'prepare', 'cleanup', 'remove']) {
        byId(`child-${action}`).onclick = () => perform(async () => {
            if (action === 'prepare' && !confirm('Prepare separate child images using the selected Engine? This does not enable child execution or replace profile proof.')) return;
            if (action === 'remove' && !confirm('Disable private children and remove their prepared runtime and private proposals? The real Project, Docker, WSL2, and Terminal-only runtime stay unchanged.')) return;
            await api('POST', `/api/diagnostics/child/${action}`, {});
            await loadReadiness();
        });
    }
    byId('child-enabled').onchange = () => perform(async () => {
        const settings = await api('PUT', '/api/settings', { childExecution: { enabled: byId('child-enabled').checked, profile: 'single-child-v3', budgetMode: 'provider-estimate' } });
        settingsChanged(settings);
    });
    byId('child-profile-select').onchange = () => perform(async () => {
        const profile = byId('child-profile-select').value;
        const budgetMode = profile === 'single-child-v3' ? 'provider-estimate' : 'verified';
        const settings = await api('PUT', '/api/settings', { childExecution: { enabled: false, profile, budgetMode } });
        settingsChanged(settings);
        byId('child-enabled').checked = false;
        byId('child-profile').textContent = `${profile} / ${budgetMode}`;
        await loadReadiness();
    });
    for (const id of ['child-consent', 'child-task', 'child-files']) byId(id).addEventListener('input', refreshButtons);
    byId('child-start').onclick = () => perform(async () => {
        const context = getContext();
        if (context.streaming) throw new Error('An ordinary Turn is already running.');
        if ((context.conversation.model || context.settings.model) !== 'claude-haiku-4.5') throw new Error('Select claude-haiku-4.5 explicitly before starting this profile.');
        const body = childStartRequest({ prompt: byId('child-task').value, paths: byId('child-files').value, consent: byId('child-consent').checked, writable: byId('child-writable').checked });
        if (body.projectAccess === 'read-write' && context.settings.childExecution.projectAccess !== 'read-write') {
            const settings = await api('PUT', '/api/settings', { childExecution: { projectAccess: 'read-write' } });
            settingsChanged(settings);
        }
        run = await api('POST', `/api/conversations/${encodeURIComponent(conversationId)}/child-runs`, body);
        byId('child-consent').checked = false;
        proposals = [];
        proposalId = '';
        byId('child-proposals').hidden = true;
        showRun();
    });
    byId('child-stop').onclick = () => perform(async () => { await api('POST', path('/stop'), {}); run.status = 'stopping'; showRun(); });
    for (const decision of ['approve', 'deny']) {
        byId(`child-${decision}`).onclick = () => perform(async () => {
            if (!run?.approval) return;
            const approval = run.approval;
            await api('POST', path('/approval'), { approvalId: approval.id, fingerprint: approval.fingerprint, decision });
            run.approval = null;
            showRun();
        });
    }
    byId('child-proposal-file').onchange = () => {
        try { byId('child-proposal-content').textContent = childProposalText(proposals[Number(byId('child-proposal-file').value)]); }
        catch (failure) { error(failure); }
    };
    byId('child-close').onclick = () => dialog.close();
    dialog.addEventListener('close', schedule);
    return {
        active,
        async open(id = 'current') {
            const context = getContext();
            if (!context.conversation) { notify('Open a Conversation first.'); return; }
            if (!active()) {
                conversationId = context.conversation.id;
                run = null;
                byId('child-task').value = context.prompt || '';
                byId('child-enabled').checked = context.settings?.childExecution?.enabled === true && context.settings.childExecution.profile === 'single-child-v3';
                byId('child-profile-select').value = context.settings?.childExecution?.profile || 'single-child-v2';
                byId('child-profile').textContent = `${byId('child-profile-select').value} / ${context.settings?.childExecution?.budgetMode || 'verified'}`;
                byId('child-consent').checked = false;
                try { run = await api('GET', `/api/conversations/${encodeURIComponent(conversationId)}/child-runs/${encodeURIComponent(id)}`); }
                catch (failure) { if (failure.status !== 404) error(failure); }
            }
            if (!dialog.open) dialog.showModal();
            showRun();
            try { await loadReadiness(); } catch (failure) { error(failure); }
            schedule();
        },
    };
}
