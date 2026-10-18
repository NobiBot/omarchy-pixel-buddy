// Claude Code / Codex hook events → work status levels, grouped by session.
// Level order matches the indexes of dsh-pet's animations.events.workStatus / workStatusTexts:
//   0 thinking / 1 working / 2 result / 3 waiting / 4 success / 5 error
// Pure logic (no QML dependencies): QML imports it as "lib/work-status.mjs", and node can unit test it directly.

export const STATES = ['thinking', 'working', 'result', 'waiting', 'success', 'error'];

/** Which session to show when several are active: the more it needs a human, the higher it ranks */
const PRIORITY = { waiting: 6, error: 5, working: 4, thinking: 3, result: 2, success: 1 };

/** Final states (success / error) show only briefly, then give way to other sessions or the random animation chain */
export const TERMINAL_TTL_MS = 15 * 1000;
/** How long a non-final session can go without events before it counts as lost (closing the terminal sends no SessionEnd) */
export const STALE_TTL_MS = 10 * 60 * 1000;
/** A session waiting for you keeps showing for longer, so stepping away doesn't hide that the agent needs you */
export const WAITING_TTL_MS = 60 * 60 * 1000;

/** Tools where the model asks the user a question: count as waiting, not ordinary working */
const QUESTION_TOOLS = new Set(['AskUserQuestion', 'request_user_input', 'ask_user_question']);
/** Notification types the user must act on (idle_prompt follows Stop, so it isn't handled twice) */
const WAITING_NOTIFICATIONS = new Set(['permission_prompt', 'elicitation_dialog']);

/**
 * One hook event → an action.
 * Returns { state } to set the session's level; { clear: true } to end the session; null to ignore.
 */
export function classify(ev) {
  switch (ev.event) {
    case 'UserPromptSubmit':
      return { state: 'thinking' };
    case 'PreToolUse':
      return { state: QUESTION_TOOLS.has(ev.tool) ? 'waiting' : 'working' };
    case 'PostToolUse':
    case 'PostToolUseFailure': // Tool failures (non-zero exit etc.) are common and don't mean the turn failed
      return { state: 'result' };
    case 'PermissionRequest':
    case 'Elicitation':
      return { state: 'waiting' };
    case 'Notification':
      return WAITING_NOTIFICATIONS.has(ev.notificationType) ? { state: 'waiting' } : null;
    case 'Stop':
      return { state: 'success' };
    case 'StopFailure':
      return { state: 'error' };
    case 'SessionEnd':
      return { clear: true };
    default:
      return null;
  }
}

export const isTerminal = (state) => state === 'success' || state === 'error';

/** How many recent steps a step summary looks at */
export const MAX_STEPS = 8;

/** Session table: key = agent:session → { key, agent, session, cwd, state, at, tool, message, focused } */
export function createStore() {
  return { sessions: {} };
}

/**
 * Applies one event. Returns { changed, entered, entry }:
 * entered = the new level this session just entered (null when the level didn't change; used to dedupe notifications).
 */
export function applyEvent(store, ev, now) {
  const action = classify(ev);
  if (!action) return { changed: false, entered: null, entry: null };
  const key = (ev.agent || 'agent') + ':' + (ev.session || 'default');
  if (action.clear) {
    const had = key in store.sessions;
    delete store.sessions[key];
    return { changed: had, entered: null, entry: null };
  }
  const prev = store.sessions[key];
  const newTurn = ev.event === 'UserPromptSubmit';
  // The last few tool calls (input for step summaries); cleared on each new request
  const prevSteps = newTurn || !prev ? [] : prev.steps;
  const addStep = ev.event === 'PreToolUse' && ev.tool;
  const steps = addStep ? prevSteps.concat([{ tool: ev.tool, detail: ev.detail || '' }]).slice(-MAX_STEPS) : prevSteps;
  const entry = {
    key,
    agent: ev.agent || 'agent',
    session: ev.session || '',
    cwd: ev.cwd || (prev && prev.cwd) || '',
    state: action.state,
    at: now,
    tool: ev.tool || '',
    detail: ev.detail || '',
    message: ev.message || '',
    focused: ev.focused === true,
    prompt: newTurn ? ev.prompt || '' : (prev && prev.prompt) || '',
    steps,
    stepSeq: ((prev && prev.stepSeq) || 0) + (addStep ? 1 : 0),
    summary: newTurn || !prev ? '' : prev.summary,
    transcript: ev.transcript || (prev && prev.transcript) || '',
    // When this turn started: older transcript content is ignored
    turnAt: newTurn || !prev ? now : prev.turnAt,
  };
  store.sessions[key] = entry;
  const entered = !prev || prev.state !== action.state ? action.state : null;
  return { changed: true, entered, entry };
}

/** Drops expired sessions; returns whether any were removed */
export function prune(store, now) {
  let removed = false;
  for (const key of Object.keys(store.sessions)) {
    const s = store.sessions[key];
    const ttl = isTerminal(s.state) ? TERMINAL_TTL_MS : s.state === 'waiting' ? WAITING_TTL_MS : STALE_TTL_MS;
    if (now - s.at > ttl) {
      delete store.sessions[key];
      removed = true;
    }
  }
  return removed;
}

/** The session to show now (highest priority, newest among equals); null when no session is active */
export function current(store) {
  let best = null;
  for (const key of Object.keys(store.sessions)) {
    const s = store.sessions[key];
    if (!best || PRIORITY[s.state] > PRIORITY[best.state] || (PRIORITY[s.state] === PRIORITY[best.state] && s.at > best.at))
      best = s;
  }
  return best;
}

/** Whether any non-final session exists (timed murmurs skip then, so they don't compete with a working agent for quota) */
export function anyBusy(store) {
  return Object.keys(store.sessions).some((k) => !isTerminal(store.sessions[k].state));
}

export const stateIndex = (state) => STATES.indexOf(state);

/** cwd → project name (bubble prefix) */
export function projectName(cwd) {
  if (!cwd) return '';
  const parts = String(cwd).replace(/\/+$/, '').split('/');
  return parts[parts.length - 1] || '';
}

/** Stores a session's step summary (dropped if the session has ended); returns whether it was stored */
export function setSummary(store, key, text) {
  const s = store.sessions[key];
  if (!s) return false;
  s.summary = text;
  return true;
}

/**
 * Tool arguments → one short line for the bubble: strips shell wrappers, makes in-project paths relative, collapses whitespace, truncates if too long.
 * Example: ("Bash", "npm run build") → "Bash · npm run build"
 */
export function formatDetail(tool, detail, cwd, max = 48) {
  let d = String(detail || '')
    .replace(/^(\/usr)?(\/bin\/)?(ba|z)?sh\s+-l?c\s+/, '')
    .replace(/\s+/g, ' ')
    .trim()
    // The quotes around a `sh -c '…'` script
    .replace(/^(['"])(.*)\1$/, '$2');
  if (cwd && d.indexOf(cwd + '/') === 0) d = d.slice(cwd.length + 1);
  if (d.length > max) d = d.slice(0, max - 1) + '…';
  if (!tool) return d;
  return d ? tool + ' · ' + d : tool;
}

/**
 * A paragraph the agent wrote → one line for the bubble: takes the first paragraph, strips Markdown, collapses whitespace, truncates if too long.
 */
export function formatNarration(text, max = 60) {
  let t = String(text || '').trim().split(/\n\s*\n/)[0];
  t = t
    .replace(/```[\s\S]*?```/g, ' ')
    // Heading and quote markers at line starts; a "#" or ">" elsewhere is text ("issue #12", "a > b")
    .replace(/^[ \t]*(#+|>+)[ \t]*/gm, '')
    .replace(/[`*]/g, '')
    // _emphasis_ only: underscores inside names (my_file.py) stay
    .replace(/(^|[^\w])_+([^_]+?)_+(?![\w])/g, '$1$2')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
  if (t.length > max) t = t.slice(0, max - 1) + '…';
  return t;
}
