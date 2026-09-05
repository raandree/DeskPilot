// Screenshots a local fixture at several viewport widths.
//
// Deliberately NOT routed through supervisor.mjs. The supervisor exists to
// constrain what the model can reach on the open web, and it refuses file: URLs
// for good reason; adding a bypass so a screenshot tool could use it would put a
// hole in the boundary to serve a convenience. This is a developer tool that
// pictures DeskPilot's own markup, so it drives Playwright directly.
//
// Usage: node ui-screenshot.mjs <fixture.html> <outDir> <width,width,...>

import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

const [fixture, outDir, widthList] = process.argv.slice(2);
if (!fixture || !outDir || !widthList) {
    console.error('usage: ui-screenshot.mjs <fixture.html> <outDir> <widths>');
    process.exit(2);
}

const widths = widthList.split(',').map(Number).filter((n) => Number.isFinite(n) && n > 0);
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch({ headless: true });
const captured = [];

try {
    for (const width of widths) {
        const context = await browser.newContext({ viewport: { width, height: 1400 }, deviceScaleFactor: 1 });
        const page = await context.newPage();

        // A fixture that fails silently would produce a blank screenshot that
        // looks like a pass, so its errors are surfaced.
        const problems = [];
        page.on('pageerror', (error) => problems.push(String(error?.message ?? error)));
        page.on('console', (message) => {
            if (message.type() === 'error') problems.push(message.text());
        });

        await page.goto(pathToFileURL(fixture).href, { waitUntil: 'load' });
        try {
            await page.waitForSelector('body[data-ready="1"]', { timeout: 15000 });
        }
        catch (error) {
            throw new Error(`The fixture never finished rendering. Page errors: ${problems.join(' | ') || '(none reported)'}`);
        }

        const target = join(outDir, `approval-${width}px.png`);
        await page.screenshot({ path: target, fullPage: true });
        captured.push({ width, path: target });
        await context.close();
    }
}
finally {
    await browser.close();
}

process.stdout.write(JSON.stringify({ captured }));
