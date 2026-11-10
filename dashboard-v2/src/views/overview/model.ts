// The Overview's own rules over the stats rows, the floor and the recent runs, ported from the retired v1 dashboard.
import type { ChartColor } from '../../charts';
import { ago, usd } from '../../format';
import { type J } from '../../model/base';
import { daysBack, localDay, median } from '../../model/stats';
import type { Tone } from '../../ui';

export const OV_RANGES = [['7d', '7 days'], ['30d', '30 days'], ['90d', '90 days']] as const;
export const OV_METRICS = [['spend', 'Spend'], ['runs', 'Runs'], ['merged', 'Merged PRs, 7 days'], ['rate', 'Runs that made a PR'], ['median', 'Median run']] as const;
export const OV_SRC: [string, ChartColor][] = [['pipeline', 'chart-1'], ['pass', 'chart-2'], ['slack', 'chart-3'], ['answer', 'chart-4'], ['depfix', 'chart-5']];
export const SRC_NAME: Record<string, string> = { pipeline: 'Pipeline runs', slack: 'Slack sessions', answer: 'Quick answers', pass: 'Passes and triage', depfix: 'Dependency fixes' };
export type Range = (typeof OV_RANGES)[number][0];
export type Metric = (typeof OV_METRICS)[number][0];

export const rangeOf = (q?: string): Range => (OV_RANGES.find(([k]) => k === q)?.[0] ?? '30d');
export const metricOf = (q?: string): Metric => (OV_METRICS.find(([k]) => k === q)?.[0] ?? 'spend');
export const rangeName = (r: Range) => OV_RANGES.find(([k]) => k === r)![1];
export const rowMs = (r: J): number => r.ms ?? Date.parse(r.at);
const HR = 3600000, DAY = 86400000;
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// v1 OV: the slim /api/overview answer, as the stats shape.
export const overviewOf = (j: J): J => (j && Array.isArray(j.cols) && Array.isArray(j.rows)
  ? { rows: j.rows.map((a: J[]) => Object.fromEntries(j.cols.map((k: string, i: number) => [k, a[i]]))), prs: j.merged == null ? null : j.merged.map((merged: string) => ({ merged })), prs_at: j.prs_at, llm: j.llm ?? {}, slim: true }
  : null);

// One team's stats: its rows, and the merged PRs of its tickets. The slim slice has no PR keys, so its PR list is unknown.
export function byTeam(st: J, team: string): J {
  if (!st || !team) return st;
  const rows = (st.rows ?? []).filter((r: J) => (r.profile || 'fxa') === team), keys = new Set(rows.map((r: J) => r.key));
  const prs = Array.isArray(st.prs) && st.prs.every((p: J) => p.key != null) ? st.prs.filter((p: J) => keys.has(p.key)) : null;
  return { ...st, rows, prs };
}

export function prsWhy(st: J, now = Date.now()): string {
  const at = st?.prs_at;
  return !st ? 'Loading the stats…' : st.prs == null ? 'the PR list is not read yet' : at && now / 1000 - at > 1800 ? `the PR list is ${ago(Math.round(now / 1000 - at)).replace(' ago', '')} old` : '';
}

// The head: the tag text and who is at work.
export function headOf(f: J): { tag: string; who: string } {
  const live = (f.tiles ?? []).filter((t: J) => t.kind !== 'free' && t.alive), np = live.filter((t: J) => t.kind === 'pipe').length, ns = live.length - np;
  const who = f.unknown || !live.length ? '' : [np && plural(np, 'agent'), ns && plural(ns, 'session')].filter(Boolean).join(' and ');
  return { tag: `${f.unknown ? '?' : f.atWork} at work now`, who };
}

// One floor tile: tone null is unknown (hatched). Each tile says its state in a word.
export type Tile = { id: string; tone: Tone | null; word: string; name: string; kind: string; stage: string; idle: string; time: string; cost: string; out: string; href: string; title: string; team: string };
export function tileOf(t: J): Tile {
  const base = { stage: '', idle: '', time: '', cost: '', out: '', href: '', title: '', team: '' };
  if (t.kind === 'free') {
    const [tone, word]: [Tone | null, string] = t.state === 'free' ? ['dim', 'free'] : t.state === 'held' ? ['warn', 'held'] : [null, 'unknown'];
    return { ...base, id: `slot:${t.slot}`, tone, word, name: t.slot || 'slot', kind: 'Pool slot' };
  }
  const cost = typeof t.cost === 'number' ? usd(t.cost) : '';
  const common = { ...base, time: t.time || '', cost, out: t.out || '', href: t.href || '', title: t.title || '', team: t.team || '' };
  if (t.kind === 'pipe') {
    const [tone, word]: [Tone, string] = t.fault ? ['bad', t.fault] : t.alive ? ['info', 'running'] : ['dim', 'waiting'];
    return { ...common, id: `pipe:${t.slot || t.key}`, tone, word, name: t.key || t.name, kind: t.slot ? `Pipeline, ${t.slot}` : 'Pipeline', stage: `stop ${(t.st ?? 2) + 1} of 9`, idle: t.idle || '' };
  }
  const kind = t.depfix || (t.kind === 'routine' ? 'Routine run' : 'Slack session');
  return { ...common, id: `sess:${t.key}`, tone: t.alive ? 'info' : 'dim', word: t.alive ? 'working' : `waits on ${t.waits}`, name: t.key, kind, stage: t.turns != null ? plural(Number(t.turns), 'turn') : '' };
}

export const RUN_KIND: Record<string, string> = { pipeline: 'pipeline run', slack: 'Slack session', answer: 'quick answer', pass: 'pass', depfix: 'dependency fix' };

// Runs started in each of the last 24 local hours; passes are the scheduler's, not counted.
const HOUR_FMT = new Intl.DateTimeFormat(undefined, { hour: 'numeric' });
export function ovHours(rows: J[], now = Date.now()) {
  const h0 = new Date(now); h0.setMinutes(0, 0, 0);
  const end = h0.getTime() + HR, start = end - 24 * HR;
  const b = [...Array(24)].map((_, i) => ({ t: start + i * HR, n: 0, lbl: HOUR_FMT.format(start + i * HR) }));
  rows.forEach((r) => { if (r.src === 'pass') return; const t = rowMs(r); if (t >= start && t < end) b[Math.floor((t - start) / HR)]!.n++; });
  const tot = b.reduce((a, x) => a + x.n, 0), pk = b.reduce((a, x) => (x.n > a.n ? x : a), b[0]!), one = b.filter((x) => x.n === pk.n).length === 1;
  const text = `${one ? `Busiest: ${pk.lbl}, ` : 'At most '}${plural(pk.n, 'run')}${one ? '' : ' in an hour'}. Passes are not counted.`;
  return { b, tot, text };
}

// Runs by local weekday and hour over the last 28 days (4 of each weekday), passes not counted.
export const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
export function ovWeek(rows: J[], now = Date.now()) {
  const lo = daysBack(now, 28)[27]!, n = WEEKDAYS.map(() => Array<number>(24).fill(0));
  rows.forEach((r) => { if (r.src === 'pass') return; const t = rowMs(r); if (!(t >= lo && t <= now)) return; const d = new Date(t); n[(d.getDay() + 6) % 7]![d.getHours()]!++; });
  return n;
}

// This month's spend of every team by local day, and the projection at the rate so far.
export function ovBudget(rows: J[], now = Date.now()) {
  const d0 = new Date(now), mo = d0.getMonth(), days: { t: number; usd: number; cum: number }[] = [];
  for (const d = new Date(d0.getFullYear(), mo, 1); d.getMonth() === mo; d.setDate(d.getDate() + 1)) days.push({ t: d.getTime(), usd: 0, cum: 0 });
  const idx = new Map(days.map((d, i) => [d.t, i])), today = idx.get(localDay(now)) ?? days.length - 1;
  rows.forEach((r) => { const i = idx.get(localDay(rowMs(r))); if (i != null) days[i]!.usd += r.usd || 0; });
  let c = 0; days.forEach((d) => { c += d.usd; d.cum = c; });
  // The rate uses the days elapsed to now, not whole days; at least one, so a run early on the 1st does not project a huge month.
  const el = Math.max(1, (now - days[0]!.t) / DAY), mtd = days[today]!.cum, rate = mtd / el, end = mtd + rate * (days.length - el);
  // No min-max band: the busiest day times the days left set the y-axis, and the real spend sat flat at the bottom.
  const pts = days.map((d, i) => ({ t: d.t, spent: i <= today ? d.cum : null, proj: i >= today ? (i === today ? mtd : mtd + rate * (i + 1 - el)) : null }));
  return { name: d0.toLocaleDateString(undefined, { month: 'long' }), days, el, mtd, end, pts };
}
// One capped team: its meter and its sentence.
export function capOf(t: J, el: number, days: { t: number }[]) {
  const b = t.budget, d = b.month_usd / el, e = b.month_usd + d * (days.length - el), over = b.month_usd >= b.month_cap;
  const day = e > b.month_cap && d > 0 ? days[Math.min(days.length - 1, Math.floor(el + (b.month_cap - b.month_usd) / d))] : null;
  return { pct: (100 * b.month_usd) / b.month_cap, tone: over ? 'bad' as const : e > b.month_cap ? 'warn' as const : undefined, over, day: day?.t ?? null, end: e };
}

// LLM spend from the proxy log: 14 UTC dates, 0 when absent, by the top 3 models and the rest.
export function ovLlm(L: J, now = Date.now()) {
  const keys = [...Array(14)].map((_, i) => new Date(now - (13 - i) * DAY).toISOString().slice(0, 10)), by = new Map<string, number>((L.days ?? []).map((d: J) => [d.day, d.usd || 0]));
  const perDay = Array.isArray(L.models) && L.models.some((x: J) => x.day);
  const models: Record<string, number> = Array.isArray(L.models)
    ? L.models.filter((x: J) => keys.includes(x.day)).reduce((a: Record<string, number>, x: J) => { a[x.model || ''] = (a[x.model || ''] ?? 0) + (x.usd || 0); return a; }, {})
    : L.models ?? {};
  const top = Object.entries(models).sort((a, b) => b[1] - a[1]), rest = top.slice(3).reduce((a, [, v]) => a + v, 0), top3 = top.slice(0, 3).map(([m]) => m);
  const has = (L.days ?? []).some((d: J) => keys.includes(d.day));
  const days = !has ? [] : keys.map((k) => {
    const row: Record<string, number | string> = { day: k, usd: by.get(k) ?? 0 };
    if (perDay) {
      let other = by.get(k) ?? 0;
      for (const [i, m] of top3.entries()) { const v = L.models.filter((x: J) => x.day === k && (x.model || '') === m).reduce((a: number, x: J) => a + (x.usd || 0), 0); row[`m${i}`] = v; other -= v; }
      row.other = Math.max(0, other);
    }
    return row;
  });
  return { days, top, rest, perDay, top3, hr: L.hour_usd };
}

// Per team, the spend of each of the last 30 local days, oldest first.
export function teamSpark(rows: J[], now = Date.now()): Record<string, number[]> {
  const ds = daysBack(now, 30).reverse(), at = new Map(ds.map((t, i) => [t, i])), out: Record<string, number[]> = {};
  rows.forEach((r) => { const i = at.get(localDay(rowMs(r))); if (i == null) return; (out[r.profile || 'fxa'] ??= Array<number>(30).fill(0))[i]! += r.usd || 0; });
  return out;
}

// The day's pipeline median and its 25th to 75th percentile band.
export function quart(a: number[]): [number, number] | null {
  const v = [...a].sort((x, y) => x - y);
  if (!v.length) return null;
  const q = (p: number) => { const i = (v.length - 1) * p, l = Math.floor(i); return v[l]! + (v[Math.min(v.length - 1, l + 1)]! - v[l]!) * (i - l); };
  return [q(0.25), q(0.75)];
}
export { median };
