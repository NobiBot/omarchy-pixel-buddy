// omarchy.agents usage records (~/.local/state/omarchy/agents/usage/<agent>.json) → usage animation level + bubble text.
// limits[].percent is a 0–1 fraction (same as omarchy agents Panel.qml).

import { t } from './i18n.mjs';

/** Levels match dsh-pet's events.balance: 0–4 in 20% steps, fully used (≥100%) is its own level 5 */
export function tierOf(p) {
  if (!(p >= 0)) return -1;
  if (p >= 1) return 5;
  return Math.min(4, Math.floor(p * 5));
}

const SHORT_LABELS = [
  [/5-?h|session/i, () => '5h'],
  [/week|7-day/i, () => t('usageWeek')],
];

/** 5-hour window: countdown to the minute; everything else (weekly quota etc.) to the hour */
const isSessionWindow = (label) => /5-?h|session/i.test(label);

function shortLabel(label) {
  for (const [re, short] of SHORT_LABELS) if (re.test(label)) return label.match(/fable|opus|sonnet/i) ? label : short();
  return label;
}

/** Time left until reset: byMinute = to the minute (rounded up), otherwise to the hour (rounded up); '' when expired / invalid */
export function formatResetIn(resetsAt, now, byMinute) {
  const unit = (key, n) => (n ? t(key, { n }) : '');
  const ts = Date.parse(resetsAt);
  if (!Number.isFinite(ts) || ts <= now) return '';
  const ms = ts - now;
  if (byMinute) {
    const total = Math.ceil(ms / 60000);
    const d = Math.floor(total / 1440);
    const h = Math.floor((total % 1440) / 60);
    const m = total % 60;
    return (unit('timeDay', d) + unit('timeHour', h) + unit('timeMinute', m)).trim();
  }
  const total = Math.ceil(ms / 3600000);
  const d = Math.floor(total / 24);
  const h = total % 24;
  return (unit('timeDay', d) + unit('timeHour', h)).trim();
}

/**
 * Parses one usage record. Returns null when the record can't be used (missing / not logged in / no limit windows).
 * { agent, name, percent, tier, text }: percent / tier come from the tightest window; text has one line per window, with its reset countdown.
 */
export function summarize(record, now) {
  if (!record || !Array.isArray(record.limits)) return null;
  const windows = record.limits
    .map((l) => ({ label: String(l.label || ''), percent: Number(l.percent), resetsAt: l.resetsAt || '' }))
    .filter((w) => w.percent >= 0);
  if (!windows.length) return null;
  let worst = windows[0];
  for (const w of windows) if (w.percent > worst.percent) worst = w;
  const lines = windows.map((w) => {
    const reset = formatResetIn(w.resetsAt, now, isSessionWindow(w.label));
    return shortLabel(w.label) + ' ' + Math.round(w.percent * 100) + '%' + (reset ? ' · ' + t('usageResets', { time: reset }) : '');
  });
  // Note when the data is more than 5 minutes old (a failed refresh can only show old data)
  const updated = Date.parse(record.updatedAt);
  const ageMin = Number.isFinite(updated) ? Math.floor((now - updated) / 60000) : 0;
  if (ageMin >= 5) lines.push(ageMin < 120 ? t('usageStaleMin', { n: ageMin }) : t('usageStaleHour', { n: Math.floor(ageMin / 60) }));
  return {
    agent: record.id || '',
    name: record.name || record.id || '',
    percent: worst.percent,
    tier: tierOf(worst.percent),
    text: [record.name || record.id].concat(lines).join('\n'),
  };
}
