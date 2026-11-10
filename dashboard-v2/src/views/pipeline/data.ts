// The pipeline view's pure parts: v1 doneRows, beltTone and the belt phases, and the data of the new charts.
import { days } from '../../format';
import type { J } from '../../model/base';
import type { Tone } from '../../ui';

// The status tag of a belt: a PR that waits on review 3 days or more needs a look, so it is amber.
export const beltTone = (r: J): Tone | undefined =>
  (({ 'k-live': 'info', 'k-bad': 'bad', 'k-warn': 'warn', 'k-ok': r.group === 'review' && r.age >= 3 ? 'warn' : 'ok' }) as Record<string, Tone>)[r.tone];

// The belt groups, top to bottom: the live runs, then what a person must do, then what the agent retries.
export const BELT_SUBS: [string, string, string, (r: J) => boolean][] = [
  ['working', 'Agent', 'Working now', () => true],
  ['review', 'You', 'Review and merge', () => true],
  ['needs', 'You', 'Fix it', (r) => r.tone === 'k-bad'],
  ['needs', 'You', 'Decide', (r) => r.tone !== 'k-bad'],
  ['fixes', 'Agent', 'The agent fixes it, next pass', () => true],
];
export const BELT_HINT: Record<string, string> = {
  'Review and merge': 'CI passed. A person reviews and merges each PR.',
  'Fix it': 'Something broke that the agent cannot fix.',
  Decide: 'Only a person can clear the reason under each ticket.',
  'The agent fixes it, next pass': 'The next pass tries again.',
  'Working now': 'An agent works in a sandbox.',
};
export const GROUPS = ['working', 'needs', 'fixes', 'review'] as const;
export const GROUP_NAME: Record<string, string> = { working: 'Working now', needs: 'Needs you', fixes: 'The agent fixes it', review: 'Waits on review' };

const DAY = 86400000;
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;

// Merged pipeline PRs, newest first.
export function doneRows(snap: J): J[] {
  return (snap?.merged_prs ?? []).filter((p: J) => p.key).map((p: J) => {
    const ago = Math.round(days(p.merged) ?? 0), took = (Date.parse(p.merged) - Date.parse(p.created)) / DAY;
    return {
      t: { key: p.key, pr: p.number, summary: p.title, created: p.created }, st: 8, kind: 'done',
      l1: ago === 0 ? 'Merged today' : `Merged ${plural(ago, 'day')} ago`,
      l2: `${Math.round(took)}d to merge${p.merged_by ? ` · by ${p.merged_by}` : ''}`, merged: p.merged, by: p.merged_by ?? null, ago, took,
    };
  }).sort((x: J, y: J) => Date.parse(y.merged) - Date.parse(x.merged));
}

// The true median: the mean of the two middle values for an even count.
export function median(xs: number[]): number | null {
  const s = xs.filter(Number.isFinite).sort((a, b) => a - b), m = s.length >> 1;
  return s.length === 0 ? null : s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}

// A row's age with its unit word: a run counts minutes or hours, a wait counts days.
export function ageWords(r: J): string {
  if (r.ageText == null && r.age != null) return plural(r.age, 'day');
  const secs = r.ageText != null ? r.item?.age : r.t.elapsed_seconds;
  if (secs == null) return '';
  return secs >= 2 * 86400 ? plural(Math.round(secs / 86400), 'day') : secs >= 3600 ? `${(secs / 3600).toFixed(1)} h` : `${Math.max(0, Math.round(secs / 60))} min`;
}
export const ageSecs = (r: J): number | null => (r.ageText != null ? r.item?.age ?? null : r.age != null ? r.age * 86400 : r.t.elapsed_seconds ?? null);

// The pipeline flow of one snapshot. Each ticket counts once where it is now; a link carries the tickets that got past it.
export function flowGraph(g: J, snap: J, done: J[], now = Date.now()) {
  const belts = GROUPS.flatMap((k) => (g[k] as J[]) ?? []);
  const at = (lo: number, hi: number) => belts.filter((r) => r.st >= lo && r.st <= hi).length;
  const skipped: J[] = snap?.queue?.skipped ?? [];
  const n = {
    ready: (snap?.queue?.ready ?? []).length,
    held: skipped.filter((k) => k.in_queue !== false && k.held_by).length,
    skipped: skipped.filter((k) => k.in_queue !== false && !k.held_by).length,
    run: at(1, 4),
    pr: at(5, 7),
    merged: done.filter((r) => now - Date.parse(r.merged) < 7 * DAY).length,
    closed: (snap?.review ?? []).filter((r: J) => r.state === 'CLOSED').length,
  };
  const pastPr = n.merged + n.closed, pastRun = n.pr + pastPr;
  const nodes = [
    { id: 'queue', label: 'Queue' }, { id: 'ready', label: 'Ready' }, { id: 'held', label: 'Held' }, { id: 'skipped', label: 'Skipped' },
    { id: 'run', label: 'Agent run' }, { id: 'pr', label: 'PR' }, { id: 'merged', label: 'Merged, 7 days' }, { id: 'closed', label: 'Closed' },
  ];
  const links = [
    { source: 'queue', target: 'ready', value: n.ready }, { source: 'queue', target: 'held', value: n.held },
    { source: 'queue', target: 'skipped', value: n.skipped }, { source: 'queue', target: 'run', value: n.run + pastRun },
    { source: 'run', target: 'pr', value: pastRun }, { source: 'pr', target: 'merged', value: n.merged }, { source: 'pr', target: 'closed', value: n.closed },
  ];
  const summary = `Pipeline now: ${n.ready + n.held + n.skipped} in the queue (${n.ready} ready, ${n.held} held, ${n.skipped} skipped), ${n.run} in an agent run, ${n.pr} at a PR, ${n.merged} merged in 7 days, ${n.closed} closed.`;
  return { nodes, links, n, summary };
}



// How long a review row has waited: since the last human review, else since the PR opened.
// The review lines of an open ticket: the admin rounds against their cap, and the quiet window a reviewer holds.
export function reviewHold(t: J, lim: J): string[] {
  const out: string[] = [];
  if (t.admin_rounds > 0) out.push(`admin rounds ${t.admin_rounds} of ${lim?.admin_rounds ?? 10}`);
  if (typeof t.review_waiting === 'number') out.push(`waiting for a reviewer, ${Math.max(1, Math.ceil(t.review_waiting / 60))} min left`);
  return out;
}
export const waitDays = (r: J): number | null => days(r.last_human_review?.at ?? r.created ?? r.updated);
export const WAIT_BINS: [string, number, number][] = [['under 1 day', 0, 1], ['1 to 3 days', 1, 3], ['3 to 7 days', 3, 7], ['7 days or more', 7, Infinity]];

// Monday of the local week of an ISO time, as "Oct 13".
// One formatter: toLocaleDateString with options builds a new one each call, about 25 µs a row.
const WEEK_FMT = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' });
export function weekOf(iso: string): { at: number; label: string } {
  const d = new Date(Date.parse(iso));
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  return { at: d.getTime(), label: WEEK_FMT.format(d) };
}

// Merges per local day for the last n days, oldest first.
export function mergesPerDay(done: J[], n = 14, now = Date.now()): number[] {
  const d0 = new Date(now);
  d0.setHours(0, 0, 0, 0);
  const out = Array<number>(n).fill(0);
  for (const r of done) {
    // round, not floor: a day with a clock change is not 24 h long.
    const i = n - 1 - Math.round((d0.getTime() - new Date(Date.parse(r.merged)).setHours(0, 0, 0, 0)) / DAY);
    if (i >= 0 && i < n) out[i]! += 1;
  }
  return out;
}
