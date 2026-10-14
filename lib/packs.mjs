// Sprite packs: which animation of a pack plays for each role the pet needs.
// Shared by Service.qml, the bar widget (import "lib/packs.mjs") and node tests.
//
// A pack's pack.json maps roles to the pack's own animation names:
//   { "roles": { "idle": ["Stand"], "workStatus": ["Think", "Type", …], … },
//     "behavior": { "playSec": {…}, "speed": {…}, "weight": {…} },
//     "facing": "left", "scale": 3, "feetY": 66, "hitBox": [x0, y0, x1, y1] }
// Roles missing from pack.json are guessed from the animation names.

// Every role the pet uses. `slot` = index into a 6-slot event pool; `multi` = several
// animations, one picked at random each time.
export const ROLES = [
  { key: 'idle', group: 'basics', label: 'idle', multi: true },
  { key: 'walk', group: 'basics', label: 'walk', multi: true },
  { key: 'turn', group: 'basics', label: 'turn around', multi: true },
  { key: 'drag', group: 'basics', label: 'held by mouse', multi: true },
  { key: 'clicks', group: 'basics', label: 'click reactions', multi: true },
  { key: 'actions', group: 'basics', label: 'random actions', multi: true },
  { key: 'whisper', group: 'basics', label: 'murmur', multi: true },
  { key: 'workStatus.0', group: 'work', label: 'thinking' },
  { key: 'workStatus.1', group: 'work', label: 'working' },
  { key: 'workStatus.2', group: 'work', label: 'reviewing' },
  { key: 'workStatus.3', group: 'work', label: 'waiting for you' },
  { key: 'workStatus.4', group: 'work', label: 'success' },
  { key: 'workStatus.5', group: 'work', label: 'error' },
  { key: 'balance.0', group: 'usage', label: '0–20% used' },
  { key: 'balance.1', group: 'usage', label: '20–40% used' },
  { key: 'balance.2', group: 'usage', label: '40–60% used' },
  { key: 'balance.3', group: 'usage', label: '60–80% used' },
  { key: 'balance.4', group: 'usage', label: '80–100% used' },
  { key: 'balance.5', group: 'usage', label: 'limit reached' },
];

export const GROUPS = [
  { key: 'basics', label: 'Basics' },
  { key: 'work', label: 'Work status' },
  { key: 'usage', label: 'Usage' },
];

// Names the guesser accepts for each role, best match first. The first entry is the
// name the stock config uses, so a pack drawn for the default config maps exactly.
const SYNONYMS = {
  idle: ['idle', 'stand', 'standing', 'breathe', 'breathing', 'rest', 'default', 'still'],
  walk: ['walk', 'walking', 'walk-cycle', 'walkcycle', 'run', 'running', 'move', 'moving', 'scoot', 'roll'],
  turn: ['turn', 'turnaround', 'turn-around', 'flip', 'spin', 'rotate'],
  drag: ['drag', 'dragged', 'grab', 'grabbed', 'held', 'hold', 'carry', 'carried', 'dangle', 'lifted', 'pickup'],
  clicks: ['click-hop', 'click-surprised', 'click', 'clicked', 'poke', 'poked', 'tap', 'boop', 'pet', 'hop', 'jump', 'surprised', 'react'],
  actions: ['sleep', 'stretch', 'nap', 'yawn', 'dance', 'sit', 'play', 'eat', 'look', 'blink', 'wave', 'bounce'],
  whisper: ['whisper', 'murmur', 'mumble', 'talk', 'talking', 'speak', 'chat', 'say'],
  'workStatus.0': ['work-thinking', 'thinking', 'think', 'ponder', 'pondering', 'hmm'],
  'workStatus.1': ['work-working', 'working', 'work', 'typing', 'type', 'code', 'coding', 'busy'],
  'workStatus.2': ['work-reviewing', 'reviewing', 'review', 'reading', 'read', 'check', 'checking'],
  'workStatus.3': ['work-waiting', 'waiting', 'wait', 'ask', 'question', 'attention', 'alert', 'notice'],
  'workStatus.4': ['work-success', 'success', 'done', 'yay', 'happy', 'celebrate', 'win', 'cheer'],
  'workStatus.5': ['work-error', 'error', 'fail', 'failed', 'oops', 'sad', 'angry', 'cry'],
  'balance.0': ['usage-plenty', 'plenty', 'full', 'rich'],
  'balance.1': ['usage-plenty', 'plenty', 'full', 'rich'],
  'balance.2': ['usage-ok', 'ok', 'okay', 'half', 'fine'],
  'balance.3': ['usage-ok', 'ok', 'okay', 'half', 'fine'],
  'balance.4': ['usage-low', 'low', 'tired', 'hungry'],
  'balance.5': ['usage-empty', 'empty', 'broke', 'exhausted', 'dead'],
};

const norm = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const tokens = (s) => norm(s).split('-').filter(Boolean);
// The shell's JS engine has no Array.prototype.flat / flatMap.
const concatAll = (lists) => [].concat.apply([], lists);

/** How well `name` matches role synonyms: 0 = no match, higher = better. */
function score(name, synonyms) {
  const n = norm(name);
  const toks = tokens(name);
  let best = 0;
  synonyms.forEach((syn, i) => {
    const weight = synonyms.length - i;
    if (n === syn) best = Math.max(best, 1000 + weight);
    else if (toks.includes(syn)) best = Math.max(best, 100 + weight);
    else if (syn.length >= 4 && n.includes(syn)) best = Math.max(best, 10 + weight);
  });
  return best;
}

/** Guess every role from a pack's animation names. Multi roles take all matches. */
export function guessRoles(names) {
  const out = {};
  const used = new Set();
  // Single-slot roles first, strongest matches first, so "work-waiting" doesn't end up as idle.
  for (const role of ROLES) {
    const syn = SYNONYMS[role.key] || [];
    const ranked = names
      .map((n) => ({ n, s: score(n, syn) }))
      .filter((r) => r.s > 0)
      .sort((a, b) => b.s - a.s);
    if (!ranked.length) {
      out[role.key] = [];
      continue;
    }
    if (role.multi) {
      // Exact names win outright; otherwise every animation that mentions the role.
      const top = ranked[0].s >= 1000 ? ranked.filter((r) => r.s >= 1000) : ranked;
      out[role.key] = top.map((r) => r.n).filter((n) => role.key === 'actions' ? !used.has(n) : true);
    } else {
      out[role.key] = [ranked[0].n];
    }
    out[role.key].forEach((n) => used.add(n));
  }
  // Basic roles took names before "actions" in ROLES order, but random actions must not
  // repeat what idle/walk/… already play.
  const basics = ['idle', 'walk', 'turn', 'drag', 'clicks', 'whisper'];
  const taken = new Set(concatAll(basics.map((k) => out[k])));
  out.actions = out.actions.filter((n) => !taken.has(n));
  if (!out.idle.length && names.length) out.idle = [names[0]];
  return out;
}

/** Stored roles use the config's shape (workStatus/balance as 6-slot arrays). Flatten to role keys. */
export function flattenRoles(stored) {
  const out = {};
  if (!stored || typeof stored !== 'object') return out;
  for (const role of ROLES) {
    const [base, idx] = role.key.split('.');
    let v = stored[base];
    if (idx !== undefined) v = Array.isArray(v) ? v[Number(idx)] : undefined;
    if (v === undefined || v === null) continue;
    out[role.key] = (Array.isArray(v) ? v : [v]).filter((n) => typeof n === 'string' && n !== '');
  }
  return out;
}

/**
 * Inverse of flattenRoles, for the keys present in `flat` only: roles the user never set stay
 * out of pack.json (slots as null) so they keep following the guesser.
 */
export function nestRoles(flat) {
  const out = {};
  for (const role of ROLES) {
    if (!Object.prototype.hasOwnProperty.call(flat, role.key)) continue;
    const [base, idx] = role.key.split('.');
    const v = flat[role.key] || [];
    if (idx === undefined) out[base] = v.slice();
    else {
      if (!out[base]) out[base] = [null, null, null, null, null, null];
      out[base][Number(idx)] = v.length > 1 ? v.slice() : (v[0] || '');
    }
  }
  return out;
}

/** pack.json roles after setting one role (names = [] means "play nothing / idle"). */
export function setRole(storedRoles, key, names) {
  // An explicit "" slot flattens to [] and stays set; only null / missing slots fall back to guesses.
  const flat = flattenRoles(storedRoles);
  flat[key] = names.slice();
  return nestRoles(flat);
}

/**
 * Effective roles of a pack: pack.json wins per role, guesses fill the rest.
 * Returns { roles: {key: [names]}, source: {key: "pack"|"guess"|"none"}, missing: [names in pack.json
 * that the pack doesn't have], unused: [animations no role plays], mapped, total }.
 */
export function resolveRoles(packJson, names) {
  const stored = flattenRoles(packJson && packJson.roles);
  const guess = guessRoles(names);
  const have = new Set(names);
  const roles = {};
  const source = {};
  const missing = [];
  for (const role of ROLES) {
    if (Object.prototype.hasOwnProperty.call(stored, role.key)) {
      const list = stored[role.key];
      list.forEach((n) => { if (!have.has(n) && !missing.includes(n)) missing.push(n); });
      roles[role.key] = list.filter((n) => have.has(n));
      source[role.key] = roles[role.key].length ? 'pack' : 'none';
    } else {
      roles[role.key] = guess[role.key] || [];
      source[role.key] = roles[role.key].length ? 'guess' : 'none';
    }
  }
  const played = new Set(concatAll(Object.keys(roles).map((k) => roles[k])));
  const unused = names.filter((n) => !played.has(n));
  const mapped = ROLES.filter((r) => roles[r.key].length).length;
  return { roles, source, missing, unused, mapped, total: ROLES.length };
}

/**
 * The pet's `animations` config for a pack: the stock config (moves.default, category weight, …)
 * with every pool swapped for the pack's role mapping. Unmapped work / usage slots are "": the
 * pet keeps doing its usual thing instead of looping idle (the bubble still shows the state).
 */
export function buildAnimations(base, roles, behavior) {
  const b = base || {};
  const beh = behavior || {};
  const idle = roles.idle.length ? roles.idle.slice() : [];
  const slots = (prefix) => [0, 1, 2, 3, 4, 5].map((i) => {
    const v = roles[prefix + '.' + i] || [];
    return v.length > 1 ? v.slice() : (v[0] || '');
  });
  const baseMoves = b.moves || {};
  const baseParams = {};
  (baseMoves.actions || []).forEach((a) => { if (a && a.name) baseParams[a.name] = a.params || {}; });
  const speeds = beh.speed || {};
  const weights = beh.weight || {};
  // A category picks its actions uniformly, so an action's weight is how often it is listed.
  const actions = [];
  roles.actions.forEach((n) => {
    const w = Math.max(1, Math.min(10, Math.round(Number(weights[n]) || 1)));
    for (let i = 0; i < w; i++) actions.push(n);
  });
  const baseCat = (b.categories || [])[0] || {};
  return {
    idle,
    turn: roles.turn.slice(),
    drag: roles.drag.slice(),
    clicks: roles.clicks.slice(),
    moves: {
      default: Object.assign({}, baseMoves.default || {}),
      actions: roles.walk.map((n) => {
        const params = Object.assign({}, baseParams[n] || {});
        if (Number(speeds[n]) > 0) params.speed = Number(speeds[n]);
        return { name: n, params };
      }),
    },
    categories: actions.length ? [{ id: baseCat.id || 'actions', weight: Number(baseCat.weight) || 20, actions }] : [],
    events: {
      workStatus: slots('workStatus'),
      balance: slots('balance'),
      whisper: roles.whisper.slice(),
    },
  };
}

/** Random-roll weights: drop turn / move when the pack has nothing to play for them. */
export function buildWeights(base, roles) {
  const w = Object.assign({ idle: 55, turn: 15, move: 15 }, base || {});
  if (!roles.turn.length) w.turn = 0;
  if (!roles.walk.length) w.move = 0;
  return w;
}

/**
 * Canvas geometry of a pack in canvas pixels. pack.json wins, then the bounds the builder
 * measured on the idle animation (so an off-centre drawing gets a hitbox around the drawing),
 * then the old global config.sprite block (only if the canvas size matches what it was written for).
 */
export function resolveGeometry(packJson, manifest, spriteCfg, idleName) {
  const p = packJson || {};
  const canvas = (manifest && manifest.canvas) || [128, 72];
  const [w, h] = canvas;
  const sp = spriteCfg || {};
  const spMatches = (Number(sp.width) || 128) === w && (Number(sp.height) || 72) === h;
  const bounds = manifest && manifest.animations && manifest.animations[idleName]
    ? manifest.animations[idleName].bounds : null;
  let hitBox = Array.isArray(p.hitBox) && p.hitBox.length === 4 ? p.hitBox.map(Number) : null;
  if (!hitBox && bounds) hitBox = bounds.slice();
  if (!hitBox && spMatches && Array.isArray(sp.hitBox) && sp.hitBox.length === 4) hitBox = sp.hitBox.map(Number);
  if (!hitBox) hitBox = [w * 0.3125, h * 0.14, w * 0.6875, h * 0.93];
  let feetY = Number(p.feetY);
  if (!(feetY > 0) && bounds) feetY = bounds[3];
  if (!(feetY > 0) && spMatches && Number(sp.feetY) > 0) feetY = Number(sp.feetY);
  if (!(feetY > 0)) feetY = Math.round(h * 0.92);
  return {
    width: w,
    height: h,
    hitBox,
    feetY,
    facing: p.facing === 'right' ? 'right' : 'left',
    scale: Number(p.scale) > 0 ? Number(p.scale) : 0,
  };
}

/** Folder-safe id from a display name. */
export function slugify(name) {
  return norm(name).slice(0, 40) || 'pack';
}
