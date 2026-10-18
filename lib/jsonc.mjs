// JSONC → JSON: strips // and /* */ comments and trailing commas, leaving strings untouched.
// Shared by the build scripts (node) and QML (import "lib/jsonc.mjs").

// Index just past the string that starts at `i` (a '"')
function stringEnd(src, i) {
  let j = i + 1;
  while (j < src.length && src[j] !== '"') j += src[j] === '\\' ? 2 : 1;
  return Math.min(j + 1, src.length);
}

export function stripJsonc(src) {
  // Comments first, so a comment between a comma and a bracket can't hide a trailing comma
  let noComments = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === '"') {
      const end = stringEnd(src, i);
      noComments += src.slice(i, end);
      i = end;
    } else if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') i++;
    } else if (c === '/' && src[i + 1] === '*') {
      const end = src.indexOf('*/', i + 2);
      i = end < 0 ? n : end + 2;
    } else {
      noComments += c;
      i++;
    }
  }
  // Then trailing commas, outside strings only
  let out = '';
  i = 0;
  const m = noComments.length;
  while (i < m) {
    const c = noComments[i];
    if (c === '"') {
      const end = stringEnd(noComments, i);
      out += noComments.slice(i, end);
      i = end;
    } else if (c === ',') {
      let k = i + 1;
      while (k < m && /\s/.test(noComments[k])) k++;
      if (noComments[k] !== '}' && noComments[k] !== ']') out += c;
      i++;
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

export function parseJsonc(src) {
  return JSON.parse(stripJsonc(src));
}
