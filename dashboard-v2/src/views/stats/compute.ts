// The Stats figures, ported from renderStats, prsTab and the cards of the retired v1 dashboard. Pure: no store, no DOM.
import type { J } from '../../model/base';
import { costPerMerged, inRange } from '../../model/stats';
import type { StatsFilter } from '../../store/types';
import { isOn, type Tab } from './filter';

export const DAY = 86400000;
export const rowMs = (r: J): number => r.ms ?? Date.parse(r.at);
export const sum = (a: J[]) => a.reduce((x: number, r: J) => x + (r.usd || 0), 0);
export const allUsd = (r: J) => (r.usd || 0) + (r.compute_usd || 0);
// v1 takes the upper middle value as the median.
export const med = (a: unknown[]): number | null => {
  const s = a.filter((v): v is number => typeof v === 'number').sort((x, y) => x - y);
  return s.length ? s[Math.floor(s.length / 2)]! : null;
};
// No Math.min(...rows) or Math.max(...rows): a spread of many thousands of rows can overflow the stack.
export const minOf = (a: number[], d = Infinity) => a.reduce((m, v) => (v < m ? v : m), d);
export const maxOf = (a: number[], d = -Infinity) => a.reduce((m, v) => (v > m ? v : m), d);
export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// A run row matches a model by its main model, or by a model in its priced parts.
export const hasModel = (r: J, m: string) => r.model === m || (r.models != null && typeof r.models === 'object' && Object.hasOwn(r.models, m));

export function filterRows(all: J[], sf: StatsFilter, tab: Tab, lo: number, hi: number): J[] {
  const on = isOn(tab, sf), q = sf.q.trim().toLowerCase();
  return all.filter((r) => {
    const t = rowMs(r);
    return t >= lo && t < hi && (!on('src') || r.src === sf.src) && (!on('kind') || r.kind === sf.kind) && (!on('model') || hasModel(r, sf.model))
      && (!on('team') || (r.profile || 'fxa') === sf.team) && (!on('q') || String(r.key ?? '').toLowerCase().includes(q));
  });
}

export type Bucket = { t: number; runs: number; spend: number; low: number; merged: number; src: Record<string, number>; model: Record<string, number> };
export const MAX_BUCKETS = 60;
const mondayOf = (t: number) => { const d = new Date(t); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return d.getTime(); };

// Days for a range of 45 days or less, else weeks from Monday. Only the last 60 show, and cut says how many did not.
export function buckets(rows: J[], lo: number, hi: number, now = Date.now()) {
  const first = rows.length ? minOf(rows.map(rowMs)) : now;
  const start = lo === 0 ? first : lo, end = Math.min(hi, now + 1), s0 = Math.min(start, end);
  const byDay = end - s0 <= 45 * DAY;
  const bucketOf = (t: number) => { if (!byDay) return mondayOf(t); const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };
  const map = new Map<number, Bucket>();
  // Calendar steps with setDate: a 24 h step lands at 23:00 or 01:00 across a DST change.
  for (const d = new Date(bucketOf(s0)); d.getTime() < end; d.setDate(d.getDate() + (byDay ? 1 : 7))) {
    map.set(d.getTime(), { t: d.getTime(), runs: 0, spend: 0, low: 0, merged: 0, src: {}, model: {} });
  }
  for (const r of rows) {
    const b = map.get(bucketOf(rowMs(r)));
    if (!b) continue;
    b.runs++; b.spend += r.usd || 0; b.src[r.src] = (b.src[r.src] ?? 0) + (r.usd || 0);
    if (r.src === 'pipeline' && r.main_only) b.low++;
    for (const [k, v] of Object.entries(r.models ?? (r.model ? { [r.model]: r.usd } : {}))) b.model[k] = (b.model[k] ?? 0) + (Number(v) || 0);
  }
  const all = [...map.values()];
  return { byDay, bucketOf, list: all.slice(-MAX_BUCKETS), cut: Math.max(0, all.length - MAX_BUCKETS), total: all.length };
}

export type Group = { name: string; rs: J[]; usd: number };
export function group(rows: J[], key: string | ((r: J) => unknown)): Group[] {
  const f = typeof key === 'function' ? key : (r: J) => r[key];
  const m = new Map<unknown, J[]>();
  for (const r of rows) { const k = f(r); (m.get(k) ?? m.set(k, []).get(k)!).push(r); }
  return [...m].map(([name, rs]) => ({ name: name as string, rs, usd: sum(rs) }));
}
export const conv = (r: J) => r.conv ?? r.key;

// Spend by model: subagents count where the proxy priced the run, else the run's main model only.
export function byModel(rows: J[]) {
  const m = new Map<string, number>();
  for (const r of rows) for (const [k, v] of Object.entries(r.models ?? (r.model ? { [r.model]: r.usd } : {}))) m.set(k, (m.get(k) ?? 0) + (Number(v) || 0));
  const total = [...m.values()].reduce((a, b) => a + b, 0) || 1;
  return { list: [...m].sort((a, b) => b[1] - a[1]).map(([k, v]) => ({ model: k, usd: v, pct: Math.round(v / total * 100) })),
    main: rows.filter((r) => r.main_only).length, none: rows.filter((r) => !r.models && !r.model).length };
}

// The PRs tab: PRs opened in the range, and PRs merged or closed in it whenever they were opened.
export function prsData(all: J[], rows: J[], lo: number, hi: number, src: string, q: string, repo: string, now = Date.now()) {
  const match = (p: J) => (src === 'all' || p.src === src) && (!q || `${p.key} ${p.title} ${p.n}`.toLowerCase().includes(q));
  const opened = all.filter((p) => { const t = Date.parse(p.created); return t >= lo && t < hi && match(p); });
  // All-in cost reads every PR and run, so a source filter does not divide all spend by fewer PRs.
  const { mergedIn, spentIn } = costPerMerged(lo, hi, all, rows);
  const merged = mergedIn.filter(match);
  // A session's PR number counts only in this repo's list: a team repo has its own #123.
  // The row indexes per PR number and per pipeline key, so a PR's cost does not scan every row.
  const byN = new Map<unknown, number[]>(), byKey = new Map<unknown, number[]>();
  rows.forEach((r, i) => {
    if (!r.prr || r.prr === repo) (byN.get(r.prn) ?? byN.set(r.prn, []).get(r.prn)!).push(i);
    if (r.src === 'pipeline') (byKey.get(r.key) ?? byKey.set(r.key, []).get(r.key)!).push(i);
  });
  const costs = new Map<J, number>();
  const cost = (p: J): number => {
    if (!costs.has(p)) {
      // Both lists are in row order: the merge adds each row once, in the order of a full scan, so the sum is the same.
      const a = byN.get(p.n) ?? [], b = byKey.get(p.key) ?? [];
      let x = 0, i = 0, j = 0;
      while (i < a.length || j < b.length) {
        const k = j >= b.length || (i < a.length && a[i]! < b[j]!) ? a[i]! : b[j]!;
        if (a[i] === k) i++;
        if (b[j] === k) j++;
        x += allUsd(rows[k]!);
      }
      costs.set(p, x);
    }
    return costs.get(p)!;
  };
  const hrs = (p: J) => (Date.parse(p.merged) - Date.parse(p.created)) / 3600000;
  const openIn = opened.filter((p) => p.state === 'OPEN');
  // Still open lists every open PR, also one opened before the range.
  const openAll = all.filter((p) => match(p) && p.state === 'OPEN').sort((a, b) => Date.parse(a.created) - Date.parse(b.created));
  const closed = all.filter((p) => match(p) && p.state === 'CLOSED' && Date.parse(p.closed) >= lo && Date.parse(p.closed) < hi)
    .sort((a, b) => Date.parse(b.closed) - Date.parse(a.closed));
  // The last 4 full weeks from Monday, oldest first: the week now is partial, so it is left out.
  const WK = 7 * DAY, mon = mondayOf(now);
  const weeks = [4, 3, 2, 1].map((i) => {
    const a = mon - i * WK, b = a + WK, m = all.filter((p) => p.merged && Date.parse(p.merged) >= a && Date.parse(p.merged) < b).length;
    return m ? rows.filter((r) => { const t = rowMs(r); return t >= a && t < b; }).reduce((x: number, r: J) => x + allUsd(r), 0) / m : null;
  });
  const who = [...merged.reduce((m: Map<string, number>, p: J) => m.set(p.by || '?', (m.get(p.by || '?') ?? 0) + 1), new Map<string, number>())].sort((a, b) => b[1] - a[1]);
  const bySrc = (['pipeline', 'slack'] as const).map((v) => {
    const a = opened.filter((p) => p.src === v), m = a.filter((p) => p.state === 'MERGED');
    return { src: v, opened: a.length, merged: m.length, closed: a.filter((p) => p.state === 'CLOSED').length, median: med(m.map(hrs)),
      add: m.reduce((x: number, p: J) => x + (p.add || 0), 0), del: m.reduce((x: number, p: J) => x + (p.del || 0), 0) };
  }).filter((x) => x.opened);
  return {
    opened, merged, mergedIn, spentIn, openIn, openAll, closed, cost, hrs, weeks, who, bySrc,
    empty: !opened.length && !mergedIn.filter(match).length,
    recent: merged.slice().sort((a, b) => Date.parse(b.merged) - Date.parse(a.merged)),
    costliest: merged.slice().sort((a, b) => cost(b) - cost(a)),
    mergedCosts: merged.map(cost),
  };
}
export const dur = (h: number) => (h < 48 ? `${Math.round(h)} h` : `${Math.round(h / 24)} d`);
export const rate = (m: number, c: number) => (m + c ? `${Math.round(m / (m + c) * 100)}%` : '—');

// Time to merge in fixed bins, for the lead-time histogram.
export const LEAD_BINS: [string, number][] = [['under 1 h', 1], ['1 to 6 h', 6], ['6 to 24 h', 24], ['1 to 2 d', 48], ['2 to 7 d', 168], ['over 7 d', Infinity]];
export function leadBins(hours: number[]) {
  const n = LEAD_BINS.map(() => 0);
  for (const h of hours) n[LEAD_BINS.findIndex(([, top]) => h < top)]! += 1;
  return LEAD_BINS.map(([label], i) => ({ label, n: n[i]! }));
}

// Runner time of the Slack sessions in this view: only those stopped since the controller records it.
export function runnerData(rows: J[]) {
  const rs = rows.filter((r) => r.runner_s != null);
  if (!rs.length) return null;
  const up = rs.reduce((x: number, r: J) => x + r.runner_s, 0), busy = rs.reduce((x: number, r: J) => x + (r.busy_s || 0), 0);
  const boots = ['firecracker', 'gce'].map((b) => ({ backend: b, median: med(rs.filter((r) => r.backend === b).map((r) => r.boot_s)), all: rs.filter((r) => r.backend === b && typeof r.boot_s === 'number') }))
    .filter((b) => b.median != null);
  const stops = Object.entries(rs.reduce((m: Record<string, number>, r: J) => { const k = r.stop || 'not recorded'; m[k] = (m[k] || 0) + 1; return m; }, {})).sort((a, b) => b[1] - a[1]);
  const peak = (k: string) => maxOf(rs.map((r) => r.peak?.[k] ?? 0), 0);
  const backends = [...new Set(rs.map((r) => r.backend || 'not recorded'))].sort().map((b) => {
    const x = rs.filter((r) => (r.backend || 'not recorded') === b), u = x.reduce((n: number, r: J) => n + r.runner_s, 0), y = x.reduce((n: number, r: J) => n + (r.busy_s || 0), 0);
    return { backend: b, busy: y / 3600, idle: Math.max(0, u - y) / 3600 };
  });
  const v = rows.filter((r) => r.verify_runs != null), s = rows.filter((r) => r.stack_starts), sn = s.reduce((x: number, r: J) => x + r.stack_starts, 0);
  return {
    n: rs.length, up, busy, boots, stops, backends,
    mem: peak('mem_mb'), load: peak('load1'), disk: peak('disk_pct'), compute: rs.reduce((x: number, r: J) => x + (r.compute_usd || 0), 0),
    verify: v.length ? { runs: v.reduce((x: number, r: J) => x + r.verify_runs, 0), sessions: v.length, full: v.reduce((x: number, r: J) => x + (r.verify_full || 0), 0),
      min: Math.round(v.reduce((x: number, r: J) => x + (r.verify_s || 0), 0) / 60), fail: v.reduce((x: number, r: J) => x + (r.verify_fail_runs || 0), 0) } : null,
    stack: s.length ? { n: sn, avg: Math.round(s.reduce((x: number, r: J) => x + (r.stack_s || 0), 0) / sn), fails: s.reduce((x: number, r: J) => x + (r.stack_fails || 0), 0) } : null,
  };
}

export function answerData(rows: J[]) {
  const a = rows.filter((r) => r.src === 'answer'), n = (k: string) => a.filter((r) => r.kind === k).length;
  if (!a.length) return null;
  const secs = a.filter((r) => r.kind !== 'failed').map((r) => r.secs).filter((v) => v != null).sort((x, y) => x - y);
  return { n: a.length, answered: n('answered'), upgraded: n('upgraded'), failed: n('failed'), secs, usd: sum(a) };
}

// LLM spend from the proxy's per-call log: the days of the range, newest first, and the spend by model over them.
export function llmData(l: J, lo: number, hi: number) {
  const days = inRange(l?.days, lo, hi).reverse();
  if (!days.length) return null;
  const models = Object.values(inRange(l.models, lo, hi).reduce((m: Record<string, J>, r: J) => {
    const x = m[r.model] ??= { model: r.model, calls: 0, usd: 0, input: 0, cache_read: 0, cache_write: 0, output: 0 };
    for (const k of ['calls', 'usd', 'input', 'cache_read', 'cache_write', 'output']) x[k] += r[k] || 0;
    return m;
  }, {})).sort((a: J, b: J) => b.usd - a.usd);
  // Token types per day over all models, oldest first, for the chart.
  const tokens = inRange(l.models, lo, hi).reduce((m: Record<string, J>, r: J) => {
    const x = m[r.day] ??= { day: r.day, input: 0, cache_read: 0, cache_write: 0, output: 0 };
    for (const k of ['input', 'cache_read', 'cache_write', 'output']) x[k] += r[k] || 0;
    return m;
  }, {});
  return { days, models, all: models.reduce((x: number, r: J) => x + r.usd, 0) || 1, gap: l.gap_usd ?? 0,
    usd: days.reduce((x: number, d: J) => x + (d.usd || 0), 0), calls: days.reduce((x: number, d: J) => x + (d.calls || 0), 0),
    tokens: Object.values(tokens).sort((a: J, b: J) => (a.day < b.day ? -1 : 1)) };
}

export const loadDays = (l: J, lo: number, hi: number) => inRange(l?.days, lo, hi).reverse();
export const mins = (s: number) => (s >= 60 ? `${Math.round(s / 60)} min` : `${s} s`);

// The pipeline's passes in the range, and its waits and retries over all time.
export function pipelineData(p: J, lo: number, hi: number) {
  const days = inRange(p?.days, lo, hi).reverse(), w = (p?.waits ?? []).map((x: J) => x.hours).filter((x: unknown) => x != null).sort((a: number, b: number) => a - b);
  const medOf = (k: string) => { const v = (p?.waits ?? []).map((x: J) => x[k]).filter((x: unknown) => x != null).sort((a: number, b: number) => a - b); return v.length ? `median ${v[Math.floor(v.length / 2)]} h · ${v.length} tickets` : 'none yet'; };
  if (!days.length && !w.length) return null;
  const known = (x: unknown) => typeof x === 'number';
  return { days, waits: w.length ? { first: `median ${w[Math.floor(w.length / 2)]} h · ${w.length} tickets`, pr: medOf('pr_hours'), merge: medOf('merge_hours') } : null,
    retried: known(p.retried) && known(p.tickets) ? `${p.retried} of ${p.tickets}` : '—' };
}
