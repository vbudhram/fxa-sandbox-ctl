// The Sandboxes view logic that src/model does not hold, ported from the retired v1 dashboard (sbCards, renderSbList, sbDetails, renderSbDone).
import { ago, plural, usd } from '../../format';
import { AGENTS, LIVE_SESSION, STATE, STATS, TEAM_ADMIN, type J } from '../../model/base';
import { ovFloor, sbRows } from '../../model/floor';
import { SNAP } from '../../model/pipeline';
import type { Store } from '../../store/types';
import { statsNote } from '../shared/stats';

export type Tab = 'all' | 'pipeline' | 'slack' | 'routines';
export const tabOf = (t: string): Tab => (['pipeline', 'slack', 'routines'].includes(t) ? (t as Tab) : 'all');
export const tabHas = (tab: Tab, row: J) => tab === 'all' || (tab === 'pipeline' && row.src === 'pipeline') || (tab === 'slack' && row.src === 'slack') || (tab === 'routines' && row.src === 'routine');

const SRC: Record<string, string> = { pipeline: 'Pipeline', slack: 'Slack', routine: 'Routine' };
export const forTxt = (x: J, admin: boolean): string => x.depfix ? x.depfix : x.src === 'routine' ? (admin && x.routine_name ? x.routine_name : 'Routine · scheduled run') : `${SRC[x.src]} ${x.key}`;
export const whereTxt = (x: J): string => x.src === 'pipeline' ? (x.slot ? `${x.slot} · GCE slot` : x.where === 'firecracker' ? 'Firecracker' : 'GCE')
  : `session · ${x.where === 'gce' ? 'GCE' : x.where === 'firecracker' ? 'Firecracker' : 'starting'}`;

export const agentsMore = (intakeOff: boolean, g: J) => (intakeOff ? 'intake off, no new tickets launch' : g?.launchcap == null ? 'slots unknown' : `${g.launchcap} more may launch`);

export function hostState(g: J): string | null {
  const st = g?.infra?.fc_state, fcLive = (g?.sessions ?? []).some((x: J) => LIVE_SESSION.includes(x.state) && x.boot_backend === 'firecracker');
  if (st === 'none') return null;
  if (st === 'up') return 'Firecracker host up';
  if (st === 'down' && !fcLive) return 'Firecracker host stopped: it starts for the next session';
  return 'Firecracker host state unknown: the host did not answer';
}
// Hours the host ran sessions: the union of [t0, end or now] over firecracker rows, so parallel sessions count once.
export function hostHours(rows: J[], lo: number, now: number): number {
  // A row with no end that is not live has no known stop: leave it out, as the Stats load does.
  const sp = rows.filter((r) => r.src === 'slack' && r.backend === 'firecracker' && r.t0 != null && (r.end != null || r.live))
    .map((r) => [Math.max(r.t0, lo), Math.min(r.end ?? now, now)] as [number, number]).filter(([a, b]) => b > a).sort((a, b) => a[0] - b[0]);
  let tot = 0, cs: number | null = null, ce: number | null = null;
  for (const [a, b] of sp) {
    if (ce == null || a > ce) { if (ce != null) tot += ce - cs!; cs = a; ce = b; } else ce = Math.max(ce, b);
  }
  if (ce != null) tot += ce - cs!;
  return tot / 3600;
}

export type Seg = { cls: string; title: string };
export type Cards = {
  pipe: { unknown: true } | { unknown: false; busy: number; total: number; free: number; held: number; slotsUnk: boolean; segs: Seg[]; line: string; more: string };
  sess: { unknown: true } | { unknown: false; busy: number; cap: number; gce: number; segs: Seg[]; line: string; host: string | null };
  cost: { unknown: true } | { unknown: false; manager: string; host: string | null; hostUse: string | null; gceNow: string };
};

// The three cards: a feed that failed or is old gives '?' or 'unknown', never a 0.
export function sbCards(s: Store, now = Date.now() / 1000): Cards {
  const g = AGENTS(s), f = ovFloor(s), lo = now - 7 * 86400, st = s.feeds.stats, data = STATS(s), loading = !data && !st?.error;
  const note = loading ? '' : statsNote(s.feeds.stats, now * 1000) || (data ? '' : 'the stats feed could not be read'), statsOk = !!data && !note;
  const rows: J[] = statsOk ? (data.rows ?? []).filter((r: J) => r.at && (r.ms ?? Date.parse(r.at)) / 1000 >= lo) : [];
  const unk = loading ? 'Loading the stats…' : `unknown: ${note.replace(/\.$/, '')}`, hrs = (h: number) => `${+h.toFixed(1)} h`;
  let pipe: Cards['pipe'] = { unknown: true }, sess: Cards['sess'] = { unknown: true }, cost: Cards['cost'] = { unknown: true };
  if (!f.unknown) {
    const pt: J[] = f.tiles.filter((t: J) => t.kind === 'pipe' || t.slot), busy = pt.filter((t) => t.kind === 'pipe').length;
    const pr = rows.filter((r) => r.src === 'pipeline');
    pipe = { unknown: false, busy, total: pt.length, free: pt.filter((t) => t.state === 'free').length, held: pt.filter((t) => t.state === 'held').length,
      slotsUnk: pt.some((t) => t.state === 'unknown'), segs: pt.map((t) => ({ cls: t.kind === 'pipe' ? 'busy' : t.state, title: `${t.slot || t.key}: ${t.kind === 'pipe' ? t.key : t.state}` })),
      line: statsOk ? `7 days: ${plural(pr.length, 'run')}, ${hrs(pr.reduce((n, r) => n + (r.min || 0), 0) / 60)}` : `7 days: ${unk}`, more: agentsMore(SNAP(s)?.mode?.newtickets === 'off', g) };
  }
  const cap = g?.session_cap, live: J[] = (g?.sessions ?? []).filter((x: J) => LIVE_SESSION.includes(x.state)), gce = live.filter((x) => x.boot_backend === 'gce').length;
  if (!f.unknown && cap != null) {
    const sl = rows.filter((r) => r.src === 'slack'), boots = sl.map((r) => r.boot_s).filter((x) => x != null).sort((a, b) => a - b);
    // A UTC day bucket counts when it ends inside the window; no known peak gives '?', never 0.
    const peaks = statsOk ? (data.load?.days ?? []).filter((d: J) => Date.parse(d.day) / 1000 + 86400 > lo && Number.isFinite(d.peak)).map((d: J) => d.peak) : [];
    const peak = peaks.length ? Math.max(...peaks) : '?';
    sess = { unknown: false, busy: live.length, cap, gce, host: hostState(g),
      segs: Array.from({ length: Math.max(cap, live.length) }, (_, i) => (i < live.length ? (live[i].boot_backend === 'gce' ? { cls: 'busy gce', title: 'on GCE' } : { cls: 'busy', title: 'busy' }) : { cls: 'free', title: 'free' })),
      line: statsOk ? `7 days: ${plural(sl.length, 'session')}, peak ${peak} of ${data.load?.cap ?? cap ?? '?'}${boots.length ? ` · boot median ${Math.round(boots[Math.floor(boots.length / 2)])} s` : ''}` : `7 days: ${unk}` };
  }
  if (!f.unknown) {
    // The manager is always on; the host has a rate only while up, and no 7 day total (no up-time record).
    const mgr = g?.infra?.manager, fc = g?.infra?.firecracker_host, host = hostState(g), hh = statsOk ? hostHours(rows, lo, now) : null;
    cost = { unknown: false, manager: mgr ? `${usd(mgr)}/h · $${Math.round(mgr * 168)} in 7 days, always on` : 'rate not set',
      host: host ? (fc > 0 ? `${usd(fc)}/h while up · up now` : host.replace(/^Firecracker host /, '')) : null,
      hostUse: host ? (hh == null ? unk : `Sessions used the host ${hrs(hh)} in 7 days`) : null,
      gceNow: g?.runner_hourly_usd == null ? '?' : `${usd(g.runner_hourly_usd)}/h` };
  }
  return { pipe, sess, cost };
}

// The free line under the list: free and held slots, unknown slots, and free session slots.
export function freeLine(r: J, tab: Tab, slotList: (l: unknown[]) => string): string {
  if (r.stale) return '';
  const pool = tab === 'all' || tab === 'pipeline', free = r.free.filter((x: J) => !x.held), held = r.free.filter((x: J) => x.held);
  return [pool && free.length ? slotList(free.map((x: J) => x.slot)) : '', pool && held.length ? `held for a run in flight: ${held.map((x: J) => `${x.slot} (${x.held})`).join(', ')}` : '',
    ...(pool ? r.unknown.map((u: J) => u.why) : []), r.sessionFree != null && (tab === 'all' || tab === 'slack') ? `${r.sessionFree} session slot${r.sessionFree === 1 ? '' : 's'}` : ''].filter(Boolean).join(' · ');
}
export function ageLine(s: Store): string {
  const st = STATE(s), a = st.agents_age_seconds, i = st.agents_interval;
  return a != null ? `Agents read ${ago(a)}${i ? ` · the next read in about ${Math.max(0, Math.round(i - a))} s` : ''}` : '';
}

// The selected row in the tab, or why it is missing: 'gone' clears the selection, 'unknown' keeps the last panel.
export function selRow(s: Store, id: string, tab: Tab): { row: J } | 'gone' | 'unknown' {
  const rs = sbRows(s), r = [...rs.live, ...rs.fix].find((x: J) => x.id === id && tabHas(tab, x));
  if (r) return { row: r };
  // Only a known row list clears a selection: before the first agents read, on a failed read, or on a stale feed with no rows.
  return AGENTS(s) != null && !rs.err && !(rs.stale && !(rs.live.length || rs.fix.length)) ? 'gone' : 'unknown';
}


// The server filters by the tab's source, so runs held for another tab never stand in for this one.
export const doneSrc = (tab: Tab) => ({ pipeline: 'pipeline', slack: 'slack', routines: 'routine' } as Record<string, string>)[tab] ?? '';
export const doneRows = (runs: J[] | null, tab: Tab) => (runs ?? []).filter((r) => tabHas(tab, { ...r, src: r.routine ? 'routine' : r.src })).slice(0, 20);
export const isAdmin = (s: Store) => !!TEAM_ADMIN(s).admin;
export const num = (v: unknown) => (v == null || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
// How long a sandbox has run: from its start when known, else its age.
export const upFor = (r: J, now = Date.now() / 1000) => (num(r.started) != null ? Math.max(0, Math.round(now - num(r.started)!)) : num(r.age));

// "14:05" today, else "Mar 3, 14:05"; a run with no end gives a dash.
export function endedTxt(end: unknown): string {
  const e = Number(end);
  if (!(e > 0)) return '—';
  const d = new Date(e * 1000);
  return d.toDateString() === new Date().toDateString() ? d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
    : d.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

// The runner timeline: one row per sandbox with a known start. now0 is when the rows were read, for rows that give only an age.
// ponytail: a fixed 6 h window; an older run starts at the left edge.
export const WINDOW = 6 * 3600;
export type TlRow = { id: string; label: string; t0: number; cap: number | null; fix: boolean; state: string };
export function timelineRows(rows: J[], admin: boolean, now0 = Date.now() / 1000): TlRow[] {
  return rows.flatMap((r) => {
    const t0 = r.started != null && Number.isFinite(Number(r.started)) ? Number(r.started) : r.age != null ? now0 - r.age : null;
    if (t0 == null || !Number.isFinite(t0)) return [];
    return [{ id: r.id, label: forTxt(r, admin), t0, cap: r.fix || !r.cap ? null : t0 + r.cap, fix: !!r.fix, state: r.fix ? 'needs a fix' : r.state }];
  });
}

// The slot grid: pool slots and session slots as tiles with a word; null when the feed cannot tell.
export type Word = 'free' | 'held' | 'running' | 'fix' | 'unknown';
export type Tile = { id: string; name: string; word: Word; gce?: boolean; title: string };
export function slotGrid(s: Store): { pool: Tile[] | null; sess: Tile[] | null } {
  const f = ovFloor(s), r = sbRows(s), g = AGENTS(s);
  if (f.unknown || r.err) return { pool: null, sess: null };
  const fix = new Set(r.fix.map((x: J) => x.slot).filter(Boolean)), unk = new Set(r.unknown.map((u: J) => u.slot));
  const pool: Tile[] = f.tiles.filter((t: J) => t.kind === 'pipe' || t.slot).map((t: J) => {
    const name = t.slot || t.key, word: Word = fix.has(t.slot) || t.fault ? 'fix' : t.kind === 'pipe' ? 'running' : unk.has(t.slot) ? 'unknown' : t.state;
    return { id: `pool:${name}`, name, word, title: `${name}: ${t.kind === 'pipe' ? `${word}, ${t.key}` : word}` };
  });
  const cap = g?.session_cap, live: J[] = (g?.sessions ?? []).filter((x: J) => LIVE_SESSION.includes(x.state));
  const sess: Tile[] | null = cap == null ? null : Array.from({ length: Math.max(cap, live.length) }, (_, i) => {
    const x = live[i], gce = x?.boot_backend === 'gce';
    return x ? { id: `sess:${i}`, name: `Slot ${i + 1}`, word: 'running', gce, title: `Session slot ${i + 1}: running${gce ? ' on GCE' : ''}` }
      : { id: `sess:${i}`, name: `Slot ${i + 1}`, word: 'free', title: `Session slot ${i + 1}: free` };
  });
  return { pool, sess };
}
