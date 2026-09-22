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

/** Apply every shortcut to `text`. Blank rows are ignored. */
export function applyShortcuts(text, pairs = []) {
  if (!text) return text;
  return pairs.reduce((acc, { phrase, replacement }) => {
    const p = phrase?.trim();
    const r = replacement?.trim();
    if (!p || !r) return acc;
    return acc.replace(phraseRegex(p), r);
  }, text);
}

/** Which shortcuts actually fired — so the UI can say so. */
export function matchedShortcuts(text, pairs = []) {
  if (!text) return [];
  return pairs
    .filter(({ phrase, replacement }) => {
      const p = phrase?.trim();
      return p && replacement?.trim() && phraseRegex(p).test(text);
    })
    .map(({ phrase }) => phrase.trim());
}
