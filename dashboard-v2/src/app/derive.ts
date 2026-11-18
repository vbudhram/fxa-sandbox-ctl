// The shell's own rules over the store and the selectors: rail badges, tab counts, the tab title.
import type { Alert, Needs } from '../model';
import { LIVE_STATES, SESS_STATES } from '../router';
import type { ViewId } from '../router/types';
import type { Session, Store } from '../store/types';
import { safe, type Sel } from './store';

type Row = Record<string, unknown>;
export const snapOf = (s: Store) => (s.feeds.full?.data ?? null) as Row | null;
export const agentsOf = (s: Store) => (s.feeds.agents?.data ?? null) as Row | null;
export const errorsOf = (s: Store) => (s.feeds.errors?.data ?? null) as Row[] | null;
export const teamsOf = (s: Store) => {
  const d = s.feeds.teams?.data as Row | Row[] | null | undefined;
  return d == null ? null : Array.isArray(d) ? d : ((d.teams as Row[] | undefined) ?? []);
};
export const sessionList = (s: Store): Session[] =>
  s.sessions.order.map((k) => s.sessions.byKey[k]).filter((x): x is Session => !!x && !x.deleted);
export const errOpen = (e: Row) => e.status === 'open' || e.status === 'reopened';

export type RailBadge = { n: string; tone: string; label?: string };

export function railBadges(s: Store, sel: Sel, alerts: Alert[]): Record<ViewId, RailBadge> {
  const bad = alerts.some((a) => a.tone === 'bad');
  const snap = safe(() => sel.pipeSnap(s));
  const review = snap?.review as Row[] | null | undefined;
  let waiting: number | null = null;
  if (snap && Array.isArray(review)) {
    const outside = (safe(() => sel.beltGroups(s))?.outside ?? []) as { t?: Row; age?: number }[];
    waiting = review.filter((r) => sel.isWaitingOnHuman(r)).length + outside.filter((r) => r.t?.slack && (r.age ?? 0) >= 3).length;
  }
  const wl = waiting ? `${waiting === 1 ? '1 PR waits' : `${waiting} PRs wait`} on a review` : undefined;
  const sb = safe(() => sel.sbBadge(s));
  const errs = errorsOf(s), errErr = s.feeds.errors?.error;
  const open = errs?.filter(errOpen).length ?? 0;
  const teams = teamsOf(s);
  const tb = teams ? (safe(() => sel.teamBadge(s, teams)) ?? '') : '';
  return {
    // Overview has no Needs you card, so its badge only flags a page alert.
    overview: { n: alerts.length ? '!' : '', tone: bad ? 'bad' : 'warn' },
    // A snapshot with no review list is unknown, never 0.
    pipeline: { n: !snap ? '' : waiting == null ? '?' : waiting ? String(waiting) : '', tone: 'info', label: waiting == null && snap ? 'Reviews unknown: the review list did not load' : wl },
    sessions: { n: String(sessionList(s).filter((x) => LIVE_STATES.includes(x.state ?? '')).length || ''), tone: 'info' },
    stats: { n: '', tone: '' },
    errors: { n: errErr ? '?' : open ? String(open) : '', tone: errErr ? 'warn' : open ? 'bad' : '' },
    runners: { n: sb ? String(sb.n) : '', tone: sb?.tone ?? '', label: sb?.label || undefined },
    teams: { n: teams?.length ? String(teams.length) : '', tone: tb },
  };
}

// '' shows no count, '?' an unknown one.
export function tabCount(s: Store, sel: Sel, tab: string): string {
  const v = s.route.view;
  const n = (x: number | null | undefined) => (x == null ? '' : String(x));
  if (v === 'sessions') {
    if (tab === 'answers') return s.feeds.stats?.data ? n(safe(() => sel.answerRows(s))?.length) : '';
    if (!agentsOf(s)) return '';
    return n(safe(() => sel.sessHeads(sessionList(s)))?.filter((x) => SESS_STATES[tab]?.includes(x.state ?? '')).length);
  }
  if (v === 'errors') {
    const e = errorsOf(s);
    return e ? String(e.filter((x) => tab === 'all' || errOpen(x)).length) : '';
  }
  if (v === 'pipeline') {
    const snap = safe(() => sel.pipeSnap(s));
    if (!snap) return '';
    if (tab === 'belts') {
      const g = safe(() => sel.beltGroups(s));
      return g ? String(safe(() => sel.beltCount(g)) ?? '?') : '?';
    }
    if (tab === 'done') return String(((snap.merged_prs ?? []) as Row[]).filter((p) => p.key).length);
    const q = snap.queue as Row | undefined;
    if (q?.fetch_failed) return '?';
    // A skip with a belt counts on Belts, so the Queue tab counts only the rest, as it lists them.
    const g = safe(() => sel.beltGroups(s)) as (Record<string, { t: Row }[]> & { unknown?: Record<string, string> }) | null;
    const on = new Set(g?.unknown?.needs ? [] : ['working', 'needs', 'fixes', 'review'].flatMap((k) => (g?.[k] ?? []).map((r) => r.t.key)));
    const waits = safe(() => sel.queueWaits(s))?.filter((k) => !on.has(k.key));
    return waits == null ? '?' : String(((q?.ready ?? []) as Row[]).length + waits.length);
  }
  return '';
}

export function docTitle(needs: Needs | null, alerts: Alert[]) {
  const n = needs && !needs.unknown ? needs.total : 0;
  return `${n ? `(${n}) ` : ''}${alerts.some((a) => a.tone === 'bad') ? '⚠ ' : ''}FxA Agent`;
}

// The status bar word for each connection mode (design 4.5), with its dot tone.
export function connWord(s: Store): { tone: string; word: string; live?: boolean } {
  switch (s.conn.mode) {
    case 'live': return { tone: 'info', word: 'live', live: true };
    case 'polling': return { tone: 'warn', word: 'polling every 15 s' };
    case 'offline': return { tone: 'bad', word: 'offline' };
    case 'signin': return { tone: 'bad', word: 'signed out' };
    default: return { tone: 'dim', word: s.conn.lastEventAt ? 'reconnecting' : 'connecting' };
  }
}

// The pipeline team picker: fxa first, then each team feed. Shown with 2 or more.
export function pipeTeams(s: Store) {
  const out: { key: string; snap: Row | null; error: string | null }[] = [];
  if (s.feeds.full) out.push({ key: 'fxa', snap: snapOf(s), error: s.feeds.full.error });
  for (const [k, f] of Object.entries(s.feeds)) {
    if (k.startsWith('team:') && f) out.push({ key: k.slice(5), snap: (f.data ?? null) as Row | null, error: f.error });
  }
  return out;
}
