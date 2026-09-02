// Localization for the DeskPilot SPA.
//
// Build-free by construction: catalogs are ES modules imported directly, so
// there is no fetch, no CDN, no bundler and no runtime download. Everything
// formatting-related delegates to the browser's own Intl APIs.
//
// Two rules the rest of the app depends on:
//
//   1. English is the source locale AND the fallback. A key missing from a
//      translation renders the English string, never the raw key, and reports
//      it once through onMissing so the gap is visible in development.
//   2. Interpolated values are text. They are substituted into a string that
//      callers write with textContent; nothing here produces or accepts HTML,
//      so a conversation title containing `<img onerror=...>` is a title.

import { en } from './locales/en.js';
import { de } from './locales/de.js';

export const CATALOGS = { en, de };
export const SOURCE_LOCALE = 'en';

/**
 * Picks the locale to use.
 *
 * A stored preference wins outright - a user who chose Deutsch on an English
 * Windows meant it. 'auto' (or no preference at all, which is first run) walks
 * the browser's ordered language list and takes the first whose base tag we
 * ship, so `de-AT` resolves to `de` rather than falling back to English.
 */
export function resolveLocale(preferred, systemLanguages, available) {
    const supported = available || Object.keys(CATALOGS);
    const stored = (preferred || '').trim();
    if (stored && stored !== 'auto' && supported.includes(stored)) return stored;
    for (const tag of systemLanguages || []) {
        const base = String(tag || '').split('-')[0].toLowerCase();
        if (supported.includes(base)) return base;
    }
    return SOURCE_LOCALE;
}

function lookup(catalog, key) {
    if (!catalog) return undefined;
    return Object.prototype.hasOwnProperty.call(catalog, key) ? catalog[key] : undefined;
}

function interpolate(template, params) {
    if (!params) return template;
    return String(template).replace(/\{(\w+)\}/g, (match, name) => (
        Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : match
    ));
}

/**
 * Builds a translator bound to one locale.
 *
 * A plural key is stored as `key.one` / `key.other` (and the extra CLDR
 * categories where a language needs them); the caller passes `{ count }` and
 * Intl.PluralRules picks the form. German needs `one`/`other` like English, but
 * routing through PluralRules is what makes a language that needs `few`/`many`
 * a data change rather than a code change.
 */
export function createTranslator(locale, options) {
    const opts = options || {};
    const catalog = CATALOGS[locale] || CATALOGS[SOURCE_LOCALE];
    const fallback = CATALOGS[SOURCE_LOCALE];
    const onMissing = typeof opts.onMissing === 'function' ? opts.onMissing : null;
    const reported = new Set();
    let plurals = null;
    try { plurals = new Intl.PluralRules(locale); } catch { plurals = null; }

    const report = (key) => {
        if (!onMissing || reported.has(key)) return;
        reported.add(key);
        onMissing(key, locale);
    };

    return function t(key, params) {
        let template;
        if (params && Object.prototype.hasOwnProperty.call(params, 'count')) {
            const category = plurals ? plurals.select(Number(params.count)) : (Number(params.count) === 1 ? 'one' : 'other');
            template = lookup(catalog, `${key}.${category}`);
            if (template === undefined) template = lookup(catalog, `${key}.other`);
            if (template === undefined) {
                report(key);
                template = lookup(fallback, `${key}.${category}`);
                if (template === undefined) template = lookup(fallback, `${key}.other`);
            }
        }
        else {
            template = lookup(catalog, key);
            if (template === undefined) {
                report(key);
                template = lookup(fallback, key);
            }
        }
        if (template === undefined) return key;
        return interpolate(template, params);
    };
}

export function formatNumber(locale, value, options) {
    try { return new Intl.NumberFormat(locale, options).format(value); }
    catch { return String(value); }
}

export function formatCurrency(locale, value, currency) {
    return formatNumber(locale, value, { style: 'currency', currency: currency || 'USD' });
}

export function formatDateTime(locale, value, options) {
    const when = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(when.getTime())) return '';
    try { return new Intl.DateTimeFormat(locale, options || { dateStyle: 'medium', timeStyle: 'short' }).format(when); }
    catch { return when.toISOString(); }
}

/** Relative time in whole units, largest unit that fits ("vor 3 Stunden"). */
export function formatRelativeTime(locale, value, now) {
    const when = value instanceof Date ? value : new Date(value);
    const reference = now instanceof Date ? now : new Date(now || Date.now());
    if (Number.isNaN(when.getTime())) return '';
    const seconds = Math.round((when.getTime() - reference.getTime()) / 1000);
    const units = [
        ['year', 31536000],
        ['month', 2592000],
        ['week', 604800],
        ['day', 86400],
        ['hour', 3600],
        ['minute', 60],
        ['second', 1],
    ];
    try {
        const rtf = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
        for (const [unit, size] of units) {
            if (Math.abs(seconds) >= size || unit === 'second') {
                return rtf.format(Math.trunc(seconds / size), unit);
            }
        }
    } catch { /* fall through */ }
    return formatDateTime(locale, when);
}

export function formatList(locale, items, options) {
    const values = (items || []).map((v) => String(v));
    try { return new Intl.ListFormat(locale, options || { style: 'long', type: 'conjunction' }).format(values); }
    catch { return values.join(', '); }
}

/**
 * Applies translations to static markup.
 *
 * `data-i18n` sets textContent; `data-i18n-attr="title:key,aria-label:key"`
 * sets attributes. Both write through DOM APIs, so a translated string is never
 * parsed as HTML.
 */
export function applyTranslations(root, t) {
    if (!root) return 0;
    let applied = 0;
    for (const node of root.querySelectorAll('[data-i18n]')) {
        node.textContent = t(node.getAttribute('data-i18n'));
        applied++;
    }
    for (const node of root.querySelectorAll('[data-i18n-attr]')) {
        for (const pair of node.getAttribute('data-i18n-attr').split(',')) {
            const [attr, key] = pair.split(':').map((s) => (s || '').trim());
            if (!attr || !key) continue;
            node.setAttribute(attr, t(key));
            applied++;
        }
    }
    return applied;
}

/** Every key a catalog declares, including plural forms. */
export function catalogKeys(locale) {
    return Object.keys(CATALOGS[locale] || {}).sort();
}
