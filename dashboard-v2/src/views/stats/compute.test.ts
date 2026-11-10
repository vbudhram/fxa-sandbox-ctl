// The Stats figures: the filters each tab reads, the buckets, the PR lists and the cards, on hand-made rows.
import { expect, test } from 'vitest';
import type { J } from '../../model/base';
import { SF_DEFAULT } from '../../store/prefs';
import type { FeedState } from '../../store/types';
import { buckets, byModel, DAY, filterRows, leadBins, llmData, maxOf, med, minOf, pipelineData, prsData, runnerData } from './compute';
import { statsNote } from '../shared/stats';

const NOW = new Date(2026, 10, 3, 12).getTime();
const iso = (d: number) => new Date(NOW - d * DAY).toISOString();
const row = (d: number, x: Record<string, unknown> = {}) => ({ at: iso(d), ms: NOW - d * DAY, src: 'pipeline', key: `EX-${d}`, usd: 1, ...x });

test('a filter applies only on the tabs that read it; a model matches its priced parts; a row with no team is fxa', () => {
  const rows = [row(1, { src: 'slack', model: 'm1' }), row(2, { models: { m1: 1, m2: 2 } }), row(3, { profile: 'example', kind: 'fix' }), row(40)];
  const [lo, hi] = [NOW - 30 * DAY, Infinity];
  const f = (p: Partial<typeof SF_DEFAULT>, tab: 'spend' | 'prs' | 'runners' | 'pipeline' = 'spend') => filterRows(rows, { ...SF_DEFAULT, ...p }, tab, lo, hi).map((r) => r.key);
  expect(f({})).toEqual(['EX-1', 'EX-2', 'EX-3']);
  expect(f({ src: 'slack' })).toEqual(['EX-1']);
  expect(f({ src: 'slack' }, 'runners')).toEqual(['EX-1', 'EX-2', 'EX-3']);
  expect(f({ model: 'm2' })).toEqual(['EX-2']);
  expect(f({ model: 'm1' })).toEqual(['EX-1', 'EX-2']);
  expect(f({ team: 'fxa' }, 'runners')).toEqual(['EX-1', 'EX-2']);
  expect(f({ team: 'fxa' }, 'prs')).toEqual(['EX-1', 'EX-2', 'EX-3']);
  expect(f({ kind: 'fix' })).toEqual(['EX-3']);
  expect(f({ q: ' ex-2 ' })).toEqual(['EX-2']);
});

test('buckets: days up to 45 days, else Monday weeks; past 60 buckets the count of cut ones is kept', () => {
  const d = buckets([row(1), row(1, { usd: 2, src: 'slack' })], NOW - 29 * DAY, Infinity, NOW);
  expect(d.byDay).toBe(true);
  expect(d.list).toHaveLength(30);
  expect(d.list.at(-2)).toMatchObject({ runs: 2, spend: 3, src: { pipeline: 1, slack: 2 } });
  const w = buckets([row(100)], NOW - 89 * DAY, Infinity, NOW);
  expect(w.byDay).toBe(false);
  expect(w.list.every((b) => new Date(b.t).getDay() === 1 && new Date(b.t).getHours() === 0)).toBe(true);
  const all = buckets([row(700)], 0, Infinity, NOW);
  expect(all.list).toHaveLength(60);
  expect(all.cut).toBe(all.total - 60);
  expect(all.cut).toBeGreaterThan(0);
});

test('min and max over many rows do not spread them into a call', () => {
  const big = Array.from({ length: 300000 }, (_, i) => i);
  expect(minOf(big)).toBe(0);
  expect(maxOf(big)).toBe(299999);
  expect(maxOf([], 0)).toBe(0);
  expect(med([3, 1, null, 2, 4])).toBe(3);
});

test('PRs: Merged counts a PR opened before the range, Still open lists every open PR, Closed is newest first, cost once per PR', () => {
  const prs = [
    { n: 1, key: 'EX-1', state: 'MERGED', created: iso(10), merged: iso(1), add: 1, del: 0, src: 'pipeline', by: 'a' },
    { n: 2, key: 'EX-2', state: 'MERGED', created: iso(3), merged: iso(2), add: 1, del: 0, src: 'slack', by: 'a' },
    { n: 3, key: 'EX-3', state: 'OPEN', created: iso(20), src: 'pipeline' },
    { n: 4, key: 'EX-4', state: 'OPEN', created: iso(1), src: 'pipeline' },
    { n: 5, key: 'EX-5', state: 'CLOSED', created: iso(5), closed: iso(4), src: 'pipeline' },
    { n: 6, key: 'EX-6', state: 'CLOSED', created: iso(5), closed: iso(1), src: 'pipeline' },
  ];
  const runs = [row(1, { key: 'EX-1', usd: 2 }), row(1, { src: 'slack', key: 'agent-x', prn: 2, usd: 3, compute_usd: 1 })];
  const d = prsData(prs, runs, NOW - 6 * DAY, Infinity, 'all', '', 'example/repo', NOW);
  expect(d.merged.map((p) => p.n)).toEqual([1, 2]);
  expect(d.recent.map((p) => p.n)).toEqual([1, 2]);
  expect(d.openAll.map((p) => p.n)).toEqual([3, 4]);
  expect(d.openIn.map((p) => p.n)).toEqual([4]);
  expect(d.closed.map((p) => p.n)).toEqual([6, 5]);
  expect(d.cost(prs[1])).toBe(4);
  expect(d.who).toEqual([['a', 2]]);
  expect(prsData(prs, runs, NOW - 6 * DAY, Infinity, 'slack', '', '', NOW).merged.map((p) => p.n)).toEqual([2]);
  // The cost per merged PR reads all spend and all PRs, whatever the source filter.
  expect(prsData(prs, runs, NOW - 6 * DAY, Infinity, 'slack', '', '', NOW).mergedIn).toHaveLength(2);
});

test('PRs: a cost reads only the rows of its PR, and equals a full scan of the rows', () => {
  const prs = Array.from({ length: 50 }, (_, i) => ({ n: i, key: `EX-${i % 20}`, state: 'MERGED', created: iso(3), merged: iso(2), src: 'pipeline' }));
  const runs: J[] = Array.from({ length: 400 }, (_, i) => row(1, { src: i % 3 ? 'slack' : 'pipeline', key: `EX-${i % 25}`, prn: i % 60, prr: i % 4 ? undefined : i % 8 ? 'other/repo' : 'example/repo', usd: (i % 7) / 10, compute_usd: 0.01 }));
  let reads = 0;
  const counted = new Proxy(runs, { get: (t, k) => { if (typeof k === 'string' && /^\d+$/.test(k)) reads++; return Reflect.get(t, k); } });
  const d = prsData(prs, counted, NOW - 6 * DAY, Infinity, 'all', '', 'example/repo', NOW);
  const scan = (p: (typeof prs)[number]) => runs.reduce((x, r) => x + ((r.prn === p.n && (!r.prr || r.prr === 'example/repo')) || (r.src === 'pipeline' && r.key === p.key) ? r.usd + r.compute_usd : 0), 0);
  expect(d.mergedCosts).toEqual(prs.map(scan));
  // A few passes over the rows, not one pass per merged PR.
  expect(reads).toBeLessThan(10 * runs.length);
});

test('PRs: the last 4 weeks are full weeks from Monday, oldest first, and leave out the week now', () => {
  const mon = new Date(NOW); mon.setHours(0, 0, 0, 0); mon.setDate(mon.getDate() - ((mon.getDay() + 6) % 7));
  const at = (t: number) => new Date(t).toISOString();
  const prs = [{ n: 1, state: 'MERGED', created: at(mon.getTime() - 9 * DAY), merged: at(mon.getTime() - 6 * DAY) }, { n: 2, state: 'MERGED', created: at(mon.getTime()), merged: at(mon.getTime() + 3600000) }];
  const runs = [{ at: at(mon.getTime() - 5 * DAY), usd: 8 }, { at: at(mon.getTime() + 60000), usd: 100 }];
  expect(prsData(prs, runs, 0, Infinity, 'all', '', '', NOW).weeks).toEqual([null, null, null, 8]);
});

test('lead bins, model shares, runner time and the pipeline card', () => {
  expect(leadBins([0.5, 3, 30, 200]).map((b) => b.n)).toEqual([1, 1, 0, 1, 0, 1]);
  const m = byModel([row(1, { models: { a: 3, b: 1 } }), row(1, { model: 'a', usd: 4, main_only: true }), row(1)]);
  expect(m.list).toEqual([{ model: 'a', usd: 7, pct: 88 }, { model: 'b', usd: 1, pct: 13 }]);
  expect([m.main, m.none]).toEqual([1, 1]);
  expect(runnerData([row(1)])).toBeNull();
  const r = runnerData([row(1, { runner_s: 7200, busy_s: 3600, backend: 'gce', boot_s: 30, stop: 'idle' }), row(1, { runner_s: 3600, backend: 'gce', boot_s: 50 })])!;
  expect([r.up, r.busy, r.boots[0]?.median, r.stops]).toEqual([10800, 3600, 50, [['idle', 1], ['not recorded', 1]]]);
  expect(pipelineData({ days: [{ day: '2026-11-03', passes: 1 }] }, 0, Infinity)?.retried).toBe('—');
  expect(pipelineData({ waits: [{ hours: 2 }], retried: 1, tickets: 4 }, 0, Infinity)?.retried).toBe('1 of 4');
  expect(pipelineData({}, 0, Infinity)).toBeNull();
});

test('LLM days are newest first, and the token chart days oldest first', () => {
  const l = { days: [{ day: '2026-11-01', usd: 1, calls: 2 }, { day: '2026-11-02', usd: 2, calls: 3 }], models: [{ day: '2026-11-02', model: 'a', usd: 2, output: 5 }, { day: '2026-11-01', model: 'a', usd: 1, output: 1 }] };
  const d = llmData(l, 0, Infinity)!;
  expect(d.days.map((x) => x.day)).toEqual(['2026-11-02', '2026-11-01']);
  expect(d.tokens.map((x) => x.day)).toEqual(['2026-11-01', '2026-11-02']);
  expect([d.usd, d.calls, d.models[0]?.usd]).toEqual([3, 5, 3]);
});

test('statsNote: a failed read with and without figures, and an old feed', () => {
  const f = (x: Partial<FeedState>): FeedState => ({ data: null, ageSeconds: null, interval: 60, error: null, refreshing: false, fetchedAt: null, ...x });
  expect(statsNote(f({ error: 'the stats feed could not be read (HTTP 502)' }), NOW)).toBe('The stats feed could not be read (HTTP 502). The next poll tries again.');
  expect(statsNote(f({ error: 'x failed', data: {}, fetchedAt: NOW / 1000 - 120 }), NOW)).toBe('X failed. These figures are from 2m ago; the next poll tries again.');
  expect(statsNote(f({ ageSeconds: 600 }), NOW)).toBe('The stats feed is 10 min old.');
  expect(statsNote(f({ ageSeconds: 100 }), NOW)).toBe('');
});
