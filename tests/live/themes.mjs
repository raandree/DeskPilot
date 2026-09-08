import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { extname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../..', import.meta.url));
const webRoot = join(root, 'source/web');
const runtime = process.argv[2] || join(process.env.LOCALAPPDATA, 'DeskPilot', 'browser');
process.env.PLAYWRIGHT_BROWSERS_PATH = join(runtime, 'browsers');
const { chromium } = await import(pathToFileURL(join(runtime, 'node_modules/playwright/index.mjs')).href);
const output = process.argv[3] || mkdtempSync(join(tmpdir(), 'deskpilot-themes-'));
mkdirSync(output, { recursive: true });

const conversation = {
    id: 'theme-fixture',
    title: 'System readiness',
    model: 'gpt-5',
    messages: [
        { role: 'user', text: 'Check the project and show the next steps.' },
        {
            role: 'assistant',
            text: '## Project status\n\nThe project is ready. All **24 checks passed**, with no pending changes.\n\n'
                + '| Component | Status |\n| --- | --- |\n| Host Server | Ready |\n| Files | Unchanged |\n\n'
                + '### Next steps\n\n1. Review the configuration.\n2. Run the focused tests.\n\n'
                + '```powershell\nGet-ChildItem -Path ./source\nInvoke-Pester -Path ./tests/Unit\n```\n\n'
                + 'Keep `README.md` with the project. Umlauts: \u00c4 \u00d6 \u00dc \u00e4 \u00f6 \u00fc \u00df.',
        },
    ],
};
const responses = {
    '/api/health': { authenticated: true, version: 'theme-fixture' },
    '/api/settings': {
        model: 'gpt-5', projects: [], permissions: {}, skillRoots: [], instructionRoots: [],
        promptRoots: [], referenceFiles: [], intercom: { enabled: false },
    },
    '/api/models': { models: [{ id: 'gpt-5' }], default: 'gpt-5' },
    '/api/agents': { agents: [] },
    '/api/conversations': { conversations: [conversation] },
    '/api/conversations/theme-fixture': conversation,
    '/api/usage': { session: {}, lifetime: {} },
    '/api/intercom': { enabled: false, events: [] },
    '/api/intercom/turn': { active: false },
    '/api/update': { updateAvailable: false },
    '/api/mcp': { servers: [], configured: [], running: [] },
};
const contentTypes = {
    '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
    '.png': 'image/png', '.woff2': 'font/woff2',
};

function luminance(channels) {
    const linear = channels.map((channel) => {
        const value = channel / 255;
        return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
    });
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}

function contrast(foreground, background) {
    const levels = [luminance(foreground), luminance(background)].sort((left, right) => right - left);
    return (levels[0] + 0.05) / (levels[1] + 0.05);
}

async function paletteOf(page) {
    return page.evaluate(() => {
        const probe = document.createElement('span');
        probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none';
        document.body.appendChild(probe);
        const palette = {};
        for (const name of ['bg', 'surface', 'surface-2', 'text', 'muted', 'accent', 'on-accent', 'danger', 'ok', 'changed']) {
            probe.style.color = `var(--${name})`;
            palette[name] = getComputedStyle(probe).color.match(/[\d.]+/g).slice(0, 3).map(Number);
        }
        probe.remove();
        return palette;
    });
}

async function openSettings(page) {
    const sidebarButton = page.locator('#btn-sidebar');
    const sidebarOpen = await page.locator('#sidebar').evaluate((sidebar) => sidebar.classList.contains('open'));
    if (await sidebarButton.isVisible() && !sidebarOpen) await sidebarButton.click();
    await page.locator('#btn-settings').click();
    await page.locator('#set-color-theme').scrollIntoViewIfNeeded();
}

async function closeSettings(page) {
    await page.locator('#settings-close').click();
    if (await page.locator('#btn-sidebar').isVisible()) {
        await page.locator('#conversation-list').getByText(conversation.title, { exact: true }).click();
        await page.waitForFunction(() => !document.getElementById('sidebar').classList.contains('open'));
    }
}

async function checkLayout(page, width) {
    const layout = await page.evaluate(() => {
        const drawer = document.getElementById('settings-drawer').getBoundingClientRect();
        const fields = ['set-color-theme', 'set-theme'].map((id) => {
            const select = document.getElementById(id);
            const control = select.getBoundingClientRect();
            const label = select.labels[0].getBoundingClientRect();
            return control.left >= drawer.left && control.right <= drawer.right && label.bottom <= control.top;
        });
        return { overflow: document.documentElement.scrollWidth > innerWidth + 1, fields };
    });
    assert.equal(layout.overflow, false, `No page overflow at ${width}px`);
    assert.ok(layout.fields.every(Boolean), `Theme controls must fit without overlap at ${width}px`);
}

async function checkConversationLayout(page, width) {
    const issues = await page.evaluate(() => {
        const issues = [];
        for (const toolbar of document.querySelectorAll('.topbar, .composer')) {
            const bounds = toolbar.getBoundingClientRect();
            for (const control of toolbar.querySelectorAll('button, input, select, textarea')) {
                const rect = control.getBoundingClientRect();
                if (!rect.width || !rect.height) continue;
                if (rect.left < bounds.left - 1 || rect.right > bounds.right + 1 || rect.bottom > bounds.bottom + 1) {
                    issues.push(`${control.id} is clipped by its toolbar`);
                }
                if (!getComputedStyle(control).fontFamily.includes('3270')) {
                    issues.push(`${control.id} does not use the terminal font`);
                }
            }
        }
        return issues;
    });
    assert.deepEqual(issues, [], `Terminal controls must fit and use the selected font at ${width}px`);
}

const browser = await chromium.launch({ headless: true });
const measurements = [];
try {
    for (const width of [1440, 390]) {
        const context = await browser.newContext({
            viewport: { width, height: 960 }, locale: 'en-US', colorScheme: 'dark', reducedMotion: 'reduce',
        });
        const errors = [];
        const writes = [];
        const fontRequests = [];
        const page = await context.newPage();
        page.on('pageerror', (error) => errors.push(error.message));
        page.on('console', (message) => {
            if (message.type() === 'error') errors.push(message.text());
        });
        await context.route('**/*', async (route) => {
            const url = new URL(route.request().url());
            assert.equal(url.origin, 'http://deskpilot.test', 'The theme must not request an external asset');
            if (url.pathname.startsWith('/api/')) {
                if (route.request().method() !== 'GET') writes.push(url.pathname);
                await route.fulfill({ json: responses[url.pathname] || {} });
                return;
            }
            const file = resolve(webRoot, '.' + (url.pathname === '/' ? '/index.html' : url.pathname));
            assert.ok(file.startsWith(webRoot + '\\') || file.startsWith(webRoot + '/'));
            if (file.endsWith('.woff2')) fontRequests.push(url.pathname);
            await route.fulfill({ body: readFileSync(file), contentType: contentTypes[extname(file)] || 'application/octet-stream' });
        });
        await page.goto('http://deskpilot.test');
        await page.waitForSelector('.msg-assistant pre code');
        await openSettings(page);
        await page.locator('#set-theme').selectOption('dark');
        const originalDark = await paletteOf(page);

        for (const theme of ['terminal-amber', 'terminal-green']) {
            await page.locator('#set-color-theme').selectOption(theme);
            await page.evaluate(() => document.fonts.ready);
            assert.match(await page.locator('body').evaluate((body) => getComputedStyle(body).fontFamily), /3270/);
            assert.equal(await page.evaluate(async () => (await document.fonts.load('16px "3270"')).length), 1);
            assert.match(await page.locator('.msg-assistant pre code').first().evaluate((code) => getComputedStyle(code).fontFamily), /3270/);

            for (const mode of ['dark', 'light']) {
                await page.locator('#set-theme').selectOption(mode);
                const palette = await paletteOf(page);
                assert.equal(await page.locator('html').getAttribute('data-theme'), mode);
                assert.equal(await page.locator('html').getAttribute('data-color-theme'), theme);
                if (mode === 'dark') {
                    assert.ok(Math.max(...palette.bg) <= 16, `${theme} must have a near-black background`);
                    const [red, green, blue] = palette.text;
                    assert.ok(theme === 'terminal-amber' ? red > green && green > blue : green > red && green > blue);
                } else {
                    assert.ok(Math.min(...palette.bg) >= 240, `${theme} must have a light background in light mode`);
                }
                for (const background of ['bg', 'surface', 'surface-2']) {
                    for (const foreground of ['text', 'muted', 'accent', 'danger', 'ok', 'changed']) {
                        const ratio = contrast(palette[foreground], palette[background]);
                        assert.ok(ratio >= 4.5, `${theme}/${mode}: ${foreground} on ${background} contrast is ${ratio.toFixed(2)}`);
                    }
                }
                assert.ok(contrast(palette['on-accent'], palette.accent) >= 4.5);
                await checkLayout(page, width);
                await page.screenshot({ path: join(output, `${theme}-${mode}-settings-${width}.png`) });
                await closeSettings(page);
                await checkConversationLayout(page, width);
                await page.screenshot({ path: join(output, `${theme}-${mode}-${width}.png`) });
                await openSettings(page);
                measurements.push({ width, theme, mode, textContrast: contrast(palette.text, palette.bg) });
            }

            await page.locator('#set-theme').selectOption('system');
            await page.emulateMedia({ colorScheme: 'light' });
            assert.ok(Math.min(...(await paletteOf(page)).bg) >= 240);
            await page.emulateMedia({ colorScheme: 'dark' });
            assert.ok(Math.max(...(await paletteOf(page)).bg) <= 16);
            await closeSettings(page);
            await page.locator('#btn-theme').click();
            assert.equal(await page.locator('html').getAttribute('data-theme'), 'light');
            assert.equal(await page.locator('html').getAttribute('data-color-theme'), theme);
            await page.reload();
            await page.waitForSelector('.msg-assistant pre code');
            assert.equal(await page.locator('html').getAttribute('data-theme'), 'light');
            assert.equal(await page.locator('html').getAttribute('data-color-theme'), theme);
            await openSettings(page);
            assert.equal(await page.locator('#set-color-theme').inputValue(), theme);
            assert.equal(await page.locator('#set-theme').inputValue(), 'light');
        }

        await page.locator('#set-language').selectOption('de');
        assert.equal(await page.locator('label[for="set-color-theme"]').textContent(), 'Farbschema');
        assert.equal(await page.locator('#set-color-theme option:checked').textContent(), 'Terminal Gr\u00fcn');
        await page.locator('#set-color-theme').scrollIntoViewIfNeeded();
        await checkLayout(page, width);
        await page.screenshot({ path: join(output, `terminal-green-settings-de-${width}.png`) });
        await page.locator('#set-language').selectOption('en');
        await page.locator('#set-color-theme').selectOption('deskpilot');
        await page.locator('#set-theme').selectOption('dark');
        assert.deepEqual(await paletteOf(page), originalDark, 'Returning to DeskPilot must remove every palette override');
        assert.doesNotMatch(await page.locator('body').evaluate((body) => getComputedStyle(body).fontFamily), /3270/);
        assert.ok(fontRequests.length > 0, 'The bundled font must actually load');
        assert.deepEqual(writes, [], 'Appearance preferences must never write Host Server data');
        assert.deepEqual(errors, [], 'The real frontend must not report browser errors');
        await context.close();
    }
    console.log(JSON.stringify({ passed: true, output, measurements }, null, 2));
} finally {
    await browser.close();
}