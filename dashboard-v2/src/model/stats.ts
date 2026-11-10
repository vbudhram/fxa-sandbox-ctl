// Stats ranges and the figures the Overview reads from the stats rows, ported from the retired v1 dashboard.
import type { Store } from '../store/types';
import { type J, STATS, TEAMS } from './base';
import { ovFloor } from './floor';
import { teamName } from './teams';

export const STATS_RANGES = [['today', 'Today'], ['yesterday', 'Yesterday'], ['7d', '7 days'], ['30d', '30 days'], ['90d', '90 days'], ['month', 'This month'], ['lastmonth', 'Last month'], ['all', 'All time'], ['custom', 'Custom']];
export const localDay = (t: number) => { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };
const rowMs = (r: J): number => r.ms ?? Date.parse(r.at);

// [lo, hi) in epoch ms of local calendar days: across a DST change a 24 h step lands at 23:00 or 01:00.
export function statsBounds(range: string, now = Date.now(), custom?: { from: string; to: string }): [number, number] {
  const DAY = 86400000, d = new Date(now); d.setHours(0, 0, 0, 0); const t = d.getTime(), y = d.getFullYear(), m = d.getMonth();
  const back = (n: number) => new Date(y, m, d.getDate() - n).getTime();
  switch (range) {
    case 'today': return [t, Infinity];
    case 'yesterday': return [back(1), t];
    case '7d': return [back(6), Infinity];
    case '30d': return [back(29), Infinity];
    case '90d': return [back(89), Infinity];
    case 'month': return [new Date(y, m, 1).getTime(), Infinity];
    case 'lastmonth': return [new Date(y, m - 1, 1).getTime(), new Date(y, m, 1).getTime()];
    case 'custom': return [custom?.from ? new Date(custom.from + 'T00:00').getTime() : 0, custom?.to ? new Date(custom.to + 'T00:00').getTime() + DAY : Infinity];
    default: return [0, Infinity];
  }
}
// Day rows ({day: "YYYY-MM-DD"}) inside a range.
export const inRange = (ds: J[] | null | undefined, lo: number, hi: number) => (ds ?? []).filter((d) => { const t = Date.parse(d.day + 'T00:00'); return t >= lo && t < hi; });

// All-in cost per merged PR: every run in [lo, hi), any source, over the PRs merged in it.
export function costPerMerged(lo: number, hi: number, prs: J[] | null | undefined, rows: J[] | null | undefined) {
  const inR = (t: number) => t >= lo && t < hi;
  const mergedIn = (prs ?? []).filter((p) => p.merged && inR(Date.parse(p.merged)));
  const spentIn = (rows ?? []).filter((r) => inR(rowMs(r))).reduce((x: number, r) => x + (r.usd || 0) + (r.compute_usd || 0), 0);
  return { mergedIn, spentIn, per: mergedIn.length ? spentIn / mergedIn.length : null };
}

// The Overview's stats: the full stats once they are in, else the slim overview slice.
export const ovStats = (s: Store): J => STATS(s) ?? s.feeds.overview?.data ?? null;
// Local calendar days, stepped with setDate: a 24 h step skips or repeats a day at a DST change.
export const daysBack = (from: number, n: number) => [...Array(n)].map((_, i) => { const d = new Date(from); d.setDate(d.getDate() - i); return localDay(d.getTime()); });
// The time of the first stats row of each source.
export const ovFirstRow = (s: Store): Record<string, number> => { const f: Record<string, number> = {}; (ovStats(s)?.rows ?? []).forEach((r: J) => { const t = rowMs(r); if (!((f[r.src] ?? NaN) <= t)) f[r.src] = t; }); return f; };
// Spend by local day and source in a range, with the Stats rules (usd, every row).
export function ovSpend(s: Store, range: string) {
  const [lo] = statsBounds(range), today = localDay(Date.now()), dayMap = new Map<number, J>();
  for (const d = new Date(localDay(lo)); d.getTime() <= today; d.setDate(d.getDate() + 1)) dayMap.set(d.getTime(), { t: d.getTime(), by: {}, n: {}, usd: 0, merged: 0, pipe: 0, pr: 0, mins: [] });
  const by: Record<string, number> = {}, nby: Record<string, number> = {}; let total = 0;
  (ovStats(s)?.rows ?? []).forEach((r: J) => {
    const t = rowMs(r); if (!(t >= lo)) return; const d = dayMap.get(localDay(t)); if (!d) return;
    const u = r.usd || 0; d.by[r.src] = (d.by[r.src] ?? 0) + u; d.n[r.src] = (d.n[r.src] ?? 0) + 1; d.usd += u; by[r.src] = (by[r.src] ?? 0) + u; nby[r.src] = (nby[r.src] ?? 0) + 1; total += u;
    if (r.src === 'pipeline') { d.pipe++; if (r.pr) d.pr++; if (typeof r.min === 'number') d.mins.push(r.min); }
  });
  (ovStats(s)?.prs ?? []).forEach((p: J) => { const d = p.merged && dayMap.get(localDay(Date.parse(p.merged))); if (d) d.merged++; });
  const list = [...dayMap.values()], peak = list.reduce((a: J, d: J) => (d.usd > (a?.usd ?? 0) ? d : a), null), t0 = localDay(Math.min(...Object.values(ovFirstRow(s))));
  // The days before the log starts have no data, so they do not count in the average.
  return { total, by, nby, days: list, peak, perDay: total / Math.max(1, list.filter((d) => d.t >= t0).length) };
}
export const median = (a: unknown[]) => { const v = a.filter((x): x is number => typeof x === 'number').sort((x, y) => x - y), m = v.length >> 1; return !v.length ? null : v.length % 2 ? v[m]! : (v[m - 1]! + v[m]!) / 2; };
// Merged and Cost keep the Stats '7 days' window, so each equals Stats PRs.
export function ovKpis(s: Store, range: string, now = Date.now()) {
  const rows: J[] = ovStats(s)?.rows ?? [], prs: J[] = ovStats(s)?.prs ?? [], [lo] = statsBounds(range), len = now - lo, [lo7] = statsBounds('7d'), len7 = now - lo7;
  const at = (a: number, b: number) => rows.filter((r) => { const t = rowMs(r); return t >= a && t < b; });
  const spend = (rs: J[]) => rs.reduce((x: number, r) => x + (r.usd || 0), 0), pipeR = (rs: J[]) => rs.filter((r) => r.src === 'pipeline');
  const rate = (rs: J[]) => { const p = pipeR(rs); return p.length ? p.filter((r) => r.pr).length / p.length : null; };
  const med = (rs: J[]) => median(pipeR(rs).map((r) => r.min));
  const c7 = costPerMerged(lo7, Infinity, prs, rows), p7 = costPerMerged(lo7 - len7, lo7, prs, rows), first = ovFirstRow(s);
  const cur = at(lo, Infinity), prev = at(lo - len, lo);
  // A source whose log starts after the period before began would show its start as growth: no change then.
  const whole = !cur.some((r) => (first[r.src] ?? 0) > lo - len);
  return {
    spend: { v: spend(cur), p: whole ? spend(prev) : null },
    runs: { v: cur.length, p: whole ? prev.length : null },
    merged: { v: c7.mergedIn.length, p: p7.mergedIn.length },
    cost: { v: c7.per, p: p7.per, spent: c7.spentIn },
    rate: { v: rate(cur), p: rate(prev), n: pipeR(cur).length },
    med: { v: med(cur), p: med(prev) },
  };
}
// The change text and whether it is good: per cent for money and counts, points for a share, minutes for a time.
export function kpiChange(k: { v: number | null; p: number | null }, how: 'pct' | 'pts' | 'min', lowerIsGood: boolean) {
  if (k.v == null || k.p == null || (how === 'pct' && !k.p)) return { t: '', c: '' };
  const d = how === 'pct' ? Math.round((k.v - k.p) / k.p * 100) : how === 'pts' ? Math.round((k.v - k.p) * 100) : Math.round(k.v - k.p);
  const t = `${d > 0 ? '+' : d < 0 ? '−' : '±'}${Math.abs(d)}${how === 'pct' ? '%' : how === 'pts' ? ' pts' : ' min'}`;
  return { t, c: !d ? '' : (d < 0) === lowerIsGood ? 'good' : 'bad' };
}
// One row per team: the work on the floor now, its runs, PRs and spend in the range (a row with no profile is fxa).
export function ovTeams(s: Store, range: string) {
  const [lo] = statsBounds(range), by: Record<string, { runs: number; prs: number; usd: number }> = {}, f = ovFloor(s);
  (ovStats(s)?.rows ?? []).forEach((r: J) => {
    if (!(rowMs(r) >= lo)) return; const x = by[r.profile || 'fxa'] ??= { runs: 0, prs: 0, usd: 0 };
    x.runs++; x.usd += r.usd || 0; if (r.src === 'pipeline' && r.pr) x.prs++;
  });
  const now: Record<string, number> = {};
  f.tiles.filter((t: J) => t.kind !== 'free' && t.team).forEach((t: J) => { now[t.team] = (now[t.team] ?? 0) + 1; });
  return (TEAMS(s)?.teams ?? []).filter((t: J) => !t.load_error).map((t: J) => ({ t, u: by[t.profile] ?? { runs: 0, prs: 0, usd: 0 }, now: f.unknown ? null : now[t.profile] ?? 0 }))
    .sort((a: J, b: J) => b.u.usd - a.u.usd || teamName(a.t).localeCompare(teamName(b.t)));
}
