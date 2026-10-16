// Speech-bubble lines with a chance each (the bar widget's Phrases tab).
// A line is a plain string or { text, chance } with chance in percent. Lines without a chance
// share what the others leave of 100% equally; when every line has one and they add up to less
// than 100%, the rest is silence. Over 100% in total is scaled down to fit.
// Pure logic: QML imports it as "lib/phrases.mjs", and node can test it directly.

export function lineText(line) {
  return typeof line === 'string' ? line : String((line && line.text) || '');
}

/** The chance a line was given, or null when it shares the rest */
export function lineChance(line) {
  const c = line && typeof line === 'object' ? Number(line.chance) : NaN;
  return Number.isFinite(c) ? Math.max(0, Math.min(100, c)) : null;
}

/** Stored form: a plain string unless the line has its own chance */
export function makeLine(text, chance) {
  return chance === null || chance === undefined ? text : { text, chance: Math.max(0, Math.min(100, Math.round(chance))) };
}

/** Each line's real chance in percent, after sharing out and scaling */
export function chances(lines) {
  const set = lines.map(lineChance);
  const total = set.reduce((sum, c) => sum + (c === null ? 0 : c), 0);
  const unset = set.filter((c) => c === null).length;
  if (total > 100) return set.map((c) => (c === null ? 0 : (c * 100) / total));
  return set.map((c) => (c === null ? (100 - total) / unset : c));
}

/** Percent of the time no line is said */
export function silence(lines) {
  return Math.max(0, 100 - chances(lines).reduce((sum, c) => sum + c, 0));
}

/** A random line by chance, or "" for silence. `rand` in [0, 1) is for tests. */
export function pickLine(lines, rand) {
  if (!lines || !lines.length) return '';
  const all = chances(lines);
  let x = (rand === undefined ? Math.random() : rand) * 100;
  for (let i = 0; i < lines.length; i++) {
    if (x < all[i]) return lineText(lines[i]);
    x -= all[i];
  }
  return '';
}
