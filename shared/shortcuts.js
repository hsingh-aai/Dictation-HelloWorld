// Spoken-phrase shortcuts, applied on the client.
//
// These used to ride in `llm_instruction`, which was a mistake on two counts: it spent
// the 2048-character budget that the cleanup task needs, capping you at ~2 shortcuts,
// and it asked a language model to do a literal substitution — which it did
// unreliably, landing replacements in the wrong position until the clause was worded
// exactly right. Done here it is exact, deterministic, free, and unlimited.

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Case-insensitive, whole-phrase replacement.
 * Boundaries are only applied where the phrase actually starts/ends with a word
 * character, so a phrase like "c++" or "(aside)" still matches.
 */
function phraseRegex(phrase) {
  const body = escapeRegex(phrase);
  const left = /^\w/.test(phrase) ? '\\b' : '';
  const right = /\w$/.test(phrase) ? '\\b' : '';
  return new RegExp(`${left}${body}${right}`, 'gi');
}

/** Normalize the user's rows: trim, drop blanks, later rows win on duplicate phrases. */
function table(pairs) {
  const map = new Map();
  for (const { phrase, replacement } of pairs) {
    const p = phrase?.trim();
    const r = replacement?.trim();
    if (p && r) map.set(p.toLowerCase(), { phrase: p, replacement: r });
  }
  return [...map.values()];
}

/**
 * Apply every shortcut to `text` in ONE pass.
 *
 * Applying them one after another (the obvious reduce) has two bugs, both measured:
 *  - overlap: "email" listed before "personal email" rewrites the inner word first,
 *    so the longer phrase never matches ("personal e-mail").
 *  - cascade: a replacement gets re-scanned by later shortcuts, so "sign off" →
 *    "best regards" → "best Cheers" if "regards" is also a shortcut.
 * A single alternation, longest phrase first, fixes both: at each position the
 * longest phrase wins, and replaced text is never looked at again.
 */
export function applyShortcuts(text, pairs = []) {
  if (!text) return text;
  const rows = table(pairs);
  if (!rows.length) return text;

  const byKey = new Map(rows.map((r) => [r.phrase.toLowerCase(), r.replacement]));
  // Longest first: regex alternation takes the FIRST alternative that matches at a
  // position, so ordering by length is what makes it longest-match.
  const alternatives = rows
    .map((r) => r.phrase)
    .sort((a, b) => b.length - a.length)
    .map((p) => `(?:${phraseRegex(p).source})`);

  const combined = new RegExp(alternatives.join('|'), 'gi');
  return text.replace(combined, (match) => byKey.get(match.toLowerCase()) ?? match);
}

/** Which shortcuts actually fired — so the UI can say so. */
export function matchedShortcuts(text, pairs = []) {
  if (!text) return [];
  const rows = table(pairs);
  if (!rows.length) return [];
  // Report what the single pass would actually replace, not every phrase that merely
  // occurs — "email" is not reported when it only appears inside "personal email".
  const alternatives = rows
    .map((r) => r.phrase)
    .sort((a, b) => b.length - a.length)
    .map((p) => `(?:${phraseRegex(p).source})`);
  const combined = new RegExp(alternatives.join('|'), 'gi');
  const hits = new Set();
  for (const m of text.matchAll(combined)) hits.add(m[0].toLowerCase());
  return rows.filter((r) => hits.has(r.phrase.toLowerCase())).map((r) => r.phrase);
}
