/** Normalized for comparison so punctuation/case changes don't register as edits. */
const key = (w) => w.toLowerCase().replace(/[^\w']/g, '');

/**
 * Word-level LCS diff.
 * Returns ops: {t:'='|'-'|'+', a?, b?} — '-' only in `a`, '+' only in `b`.
 */
export function diff(a, b) {
  const m = a.length, n = b.length;
  const dp = Array.from({ length: m + 1 }, () => new Uint32Array(n + 1));
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = key(a[i]) === key(b[j])
        ? dp[i + 1][j + 1] + 1
        : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0, j = 0;
  while (i < m && j < n) {
    if (key(a[i]) === key(b[j])) ops.push({ t: '=', a: a[i++], b: b[j++] });
    else if (dp[i + 1][j] >= dp[i][j + 1]) ops.push({ t: '-', a: a[i++] });
    else ops.push({ t: '+', b: b[j++] });
  }
  while (i < m) ops.push({ t: '-', a: a[i++] });
  while (j < n) ops.push({ t: '+', b: b[j++] });
  return ops;
}

export const words = (s) => s.split(/\s+/).filter(Boolean);
