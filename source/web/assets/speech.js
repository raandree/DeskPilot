// Choosing a voice, and preparing text a speech engine reads well.
//
// The browser's default voice for a language is whichever one the OS lists
// first, which on Windows is the 2010-era SAPI "… Desktop" set — that is what
// makes read-aloud sound a decade old. The modern voices are the neural ones
// (Edge exposes "… Online (Natural)", Chrome exposes Google voices); both report
// localService === false because they synthesise over the network.

const NATURAL = /\b(natural|neural|online|premium|enhanced)\b/i;
const LEGACY = /\bdesktop\b/i;
const GOOGLE = /^google\s/i;

function normalizeLang(value) {
    return String(value || '').toLowerCase().replace('_', '-');
}

function qualityScore(voice) {
    const name = String((voice && voice.name) || '');
    let score = 0;
    if (NATURAL.test(name)) score += 4;
    if (GOOGLE.test(name)) score += 3;
    if (voice && voice.localService === false) score += 2;
    if (LEGACY.test(name)) score -= 3;
    return score;
}

// preferredName wins only while it still speaks the requested language, so a
// voice chosen for German is not left reading English.
export function pickVoice(voices, lang, preferredName) {
    const want = normalizeLang(lang);
    const base = want.split('-')[0];
    if (!base) return null;
    const candidates = (voices || []).filter((v) => normalizeLang(v && v.lang).split('-')[0] === base);
    if (!candidates.length) return null;
    if (preferredName) {
        const saved = candidates.find((v) => v && v.name === preferredName);
        if (saved) return saved;
    }
    // Exact tag first: a user who asked for en-GB must not be answered in en-US,
    // however much better the American voice sounds.
    return candidates
        .map((v, i) => ({ v, i, exact: normalizeLang(v.lang) === want ? 1 : 0, q: qualityScore(v) }))
        .sort((a, b) => (b.exact - a.exact) || (b.q - a.q) || (a.i - b.i))[0].v;
}

// ===== Numbers =====
// The Web Speech API has no SSML, so a year cannot be marked up as one: engines
// read "1945" as "one thousand nine hundred forty-five". Rewriting it in words
// is the only lever. Only a number that follows a year cue is rewritten, so a
// port, a count or a size is left exactly as written.
const YEAR_CUES = {
    en: new Set(['in', 'since', 'until', 'till', 'from', 'to', 'by', 'circa', 'around', 'year', 'years']),
    de: new Set(['im', 'in', 'seit', 'bis', 'ab', 'von', 'vom', 'um', 'jahr', 'jahre', 'jahren']),
};

const EN_ONES = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
    'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
const EN_TENS = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
const DE_ONES = ['null', 'eins', 'zwei', 'drei', 'vier', 'fünf', 'sechs', 'sieben', 'acht', 'neun', 'zehn',
    'elf', 'zwölf', 'dreizehn', 'vierzehn', 'fünfzehn', 'sechzehn', 'siebzehn', 'achtzehn', 'neunzehn'];
const DE_TENS = ['', '', 'zwanzig', 'dreißig', 'vierzig', 'fünfzig', 'sechzig', 'siebzig', 'achtzig', 'neunzig'];

function enTwo(n) {
    if (n < 20) return EN_ONES[n];
    const ones = n % 10;
    return ones ? `${EN_TENS[Math.floor(n / 10)]}-${EN_ONES[ones]}` : EN_TENS[Math.floor(n / 10)];
}

function deTwo(n) {
    if (n < 20) return DE_ONES[n];
    const ones = n % 10;
    const tens = DE_TENS[Math.floor(n / 10)];
    return ones ? `${ones === 1 ? 'ein' : DE_ONES[ones]}und${tens}` : tens;
}

function yearWords(year, base) {
    const hundreds = Math.floor(year / 100);
    const rest = year % 100;
    if (base === 'de') {
        if (year >= 2000) return `zweitausend${rest ? deTwo(rest) : ''}`;
        return `${deTwo(hundreds)}hundert${rest ? deTwo(rest) : ''}`;
    }
    if (year >= 2000 && year < 2010) return rest ? `two thousand ${enTwo(rest)}` : 'two thousand';
    if (!rest) return `${enTwo(hundreds)} hundred`;
    if (rest < 10) return `${enTwo(hundreds)} oh ${enTwo(rest)}`;
    return `${enTwo(hundreds)} ${enTwo(rest)}`;
}

export function numbersToSpeech(text, lang) {
    const base = normalizeLang(lang).split('-')[0];
    const cues = YEAR_CUES[base];
    if (!cues) return String(text || '');
    return String(text || '').replace(/(\b\p{L}+\s+)(\d{4})(?!\d)/gu, (match, cue, digits) => {
        const year = Number(digits);
        if (year < 1100 || year > 2099) return match;
        return cues.has(cue.trim().toLowerCase()) ? cue + yearWords(year, base) : match;
    });
}
