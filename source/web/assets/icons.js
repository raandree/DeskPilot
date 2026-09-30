// DeskPilot's interface icons: 16px line drawings on one grid, drawn for this
// project, so there is no icon font, no network request and no third-party
// licence. Every drawing is a fixed string stroked with currentColor, so each
// theme and mode colours it like the text beside it. Callers pass a name, never
// markup; anything unknown draws the generic Tool icon.

const DOT = 'fill="currentColor" stroke="none"';
const PAGE = 'M4.5 1.75h4.5l3.5 3.5v8a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-10.5a1 1 0 0 1 1-1z';
const FOLD = 'M9 1.75v2.5a1 1 0 0 0 1 1h2.5';
const FOLDER = 'M1.75 4.5A1.25 1.25 0 0 1 3 3.25h2.9l1.5 1.5H13a1.25 1.25 0 0 1 1.25 1.25v5.75A1.25 1.25 0 0 1 13 13H3a1.25 1.25 0 0 1-1.25-1.25z';
const BUBBLE = 'M3 2.75h10A1.25 1.25 0 0 1 14.25 4v6.5A1.25 1.25 0 0 1 13 11.75H8.25L5 14.25v-2.5H3a1.25 1.25 0 0 1-1.25-1.25V4A1.25 1.25 0 0 1 3 2.75z';

const DRAWINGS = {
    // A thought: a cloud trailing two small bubbles. The bubbles carry their own
    // class so a live run can make them pulse.
    thinking: `<path d="M4.75 9.5h7a2.5 2.5 0 0 0 .4-4.97 3.5 3.5 0 0 0-6.86-.47A2.75 2.75 0 0 0 4.75 9.5z"/>` +
        `<circle class="icon-bubble" cx="3.4" cy="12.5" r=".95"/>` +
        `<circle class="icon-bubble" cx="1.6" cy="14.6" r=".7" ${DOT}/>`,
    terminal: '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2"/><path d="m4.5 6.25 2 1.75-2 1.75M8.25 10.25h3.25"/>',
    file: `<path d="${PAGE}"/><path d="${FOLD}M6 8.25h4M6 10.75h2.75"/>`,
    folder: `<path d="${FOLDER}"/>`,
    'folder-plus': `<path d="${FOLDER}"/><path d="M8 7.25v3.5M6.25 9h3.5"/>`,
    edit: '<path d="M10.25 2.75a1.77 1.77 0 0 1 2.5 2.5L5.5 12.5l-3.25.75.75-3.25z"/><path d="m9 4 3 3"/>',
    globe: '<circle cx="8" cy="8" r="6.25"/><path d="M1.75 8h12.5M8 1.75c1.65 1.8 2.5 3.85 2.5 6.25s-.85 4.45-2.5 6.25C6.35 12.45 5.5 10.4 5.5 8S6.35 3.55 8 1.75z"/>',
    browser: `<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="1.75"/><path d="M1.75 6h12.5"/>` +
        `<circle cx="4" cy="4.4" r=".65" ${DOT}/><circle cx="5.9" cy="4.4" r=".65" ${DOT}/>`,
    search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.4 10.4 3.85 3.85"/>',
    question: `<path d="${BUBBLE}"/><path d="M6.55 5.9a1.45 1.45 0 1 1 2.1 1.3c-.4.2-.65.5-.65.95v.2"/><circle cx="8" cy="10" r=".65" ${DOT}/>`,
    book: '<path d="M8 4.25c-1.25-1-3-1.5-5.75-1.5v9.5c2.75 0 4.5.5 5.75 1.5 1.25-1 3-1.5 5.75-1.5v-9.5c-2.75 0-4.5.5-5.75 1.5zM8 4.25v9.5"/>',
    plug: '<path d="M6 1.75v3M10 1.75v3M4 4.75h8V7a4 4 0 0 1-8 0zM8 11v3.25"/>',
    shield: '<path d="M8 1.75 13.25 3.5v4.25c0 3.05-2.15 5.35-5.25 6.5-3.1-1.15-5.25-3.45-5.25-6.5V3.5z"/><path d="m5.6 8 1.65 1.65L10.4 6.4"/>',
    tool: '<path d="M10.6 1.9a3.4 3.4 0 0 0-3.95 4.4L2.2 10.75a1.45 1.45 0 0 0 2.05 2.05L8.7 8.35a3.4 3.4 0 0 0 4.4-3.95l-2.05 2.05-1.95-.45-.45-1.95z"/>',
    activity: '<path d="M1.75 8.5h2.5L6 3.75l3.5 8.5 1.75-3.75h3"/>',
    diff: `<path d="${PAGE}"/><path d="${FOLD}M8 6.75v3M6.5 8.25h3M6.5 11.25h3"/>`,
    checklist: '<path d="m2.25 4.1 1.15 1.15L5.5 2.9M2.25 8.6l1.15 1.15L5.5 7.4M7.75 4.1H14M7.75 8.6H14M7.75 12.85H14"/><circle cx="3.85" cy="12.85" r="1.2"/>',
    steps: `<path d="${BUBBLE}"/><path d="M5 5.75h6M5 8.5h4"/>`,
    more: `<circle cx="4" cy="8" r="1.1" ${DOT}/><circle cx="8" cy="8" r="1.1" ${DOT}/><circle cx="12" cy="8" r="1.1" ${DOT}/>`,
};

export const ICON_NAMES = Object.freeze(Object.keys(DRAWINGS));

export function iconKey(name) {
    return Object.hasOwn(DRAWINGS, name) ? name : 'tool';
}

export function iconSvg(name) {
    const key = iconKey(name);
    return `<svg class="icon" data-icon="${key}" viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" ` +
        `stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${DRAWINGS[key]}</svg>`;
}
