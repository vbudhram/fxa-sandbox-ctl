import { describe, expect, it } from 'vitest';
import { byTeam, capOf, headOf, metricOf, ovBudget, ovHours, ovLlm, ovWeek, overviewOf, prsWhy, quart, rangeOf, teamSpark, tileOf } from './model';
import { runBadge, statsNote } from '../shared/stats';

const NOW = new Date(2026, 10, 18, 14, 30).getTime();

const feed = (f: object) => ({ data: null, ageSeconds: null, interval: 0, error: null, refreshing: false, fetchedAt: null, ...f });

describe('the Overview model', () => {
  it('reads the range and the metric from the hash, 30 days and spend by default', () => {
    expect([rangeOf('7d'), rangeOf('bad'), rangeOf(undefined)]).toEqual(['7d', '30d', '30d']);
    expect([metricOf('median'), metricOf('x')]).toEqual(['median', 'spend']);
  });

  it('says why the stats may be wrong, with the age of the last good read', () => {
    expect(statsNote(undefined, NOW)).toBe('');
    expect(statsNote(feed({ error: 'the stats feed could not be read (HTTP 500)' }), NOW)).toBe('The stats feed could not be read (HTTP 500). The next poll tries again.');
    expect(statsNote(feed({ error: 'x failed', data: {}, fetchedAt: NOW / 1000 - 120 }), NOW)).toBe('X failed. These figures are from 2m ago; the next poll tries again.');
    expect(statsNote(feed({ ageSeconds: 400, interval: 60 }), NOW)).toBe('The stats feed is 7 min old.');
  });

  it('gives the prsWhy texts', () => {
    expect(prsWhy(null, NOW)).toBe('Loading the stats…');
    expect(prsWhy({ prs: null }, NOW)).toBe('the PR list is not read yet');
    expect(prsWhy({ prs: [], prs_at: NOW / 1000 - 3600 }, NOW)).toBe('the PR list is 1h old');
    expect(prsWhy({ prs: [], prs_at: NOW / 1000 - 60 }, NOW)).toBe('');
  });

  it('names who is at work, and says ? when the floor is unknown', () => {
    const tiles = [{ kind: 'pipe', alive: true }, { kind: 'pipe', alive: true }, { kind: 'slack', alive: true }, { kind: 'slack', alive: false }, { kind: 'free' }];
    expect(headOf({ tiles, atWork: 3 })).toEqual({ tag: '3 at work now', who: '2 agents and 1 session' });
    expect(headOf({ unknown: true, tiles: [], atWork: 0 })).toEqual({ tag: '? at work now', who: '' });
  });

  it('gives each floor tile a tone and a word', () => {
    expect([tileOf({ kind: 'free', slot: 'a-1', state: 'free' }), tileOf({ kind: 'free', slot: 'a-2', state: 'held' }), tileOf({ kind: 'free', slot: 'a-3', state: 'unknown' })]
      .map((t) => [t.tone, t.word])).toEqual([['dim', 'free'], ['warn', 'held'], [null, 'unknown']]);
    const p = tileOf({ kind: 'pipe', key: 'EX-1', slot: 'a-1', st: 2, alive: true, idle: 'idle 12 min', time: '15m', cost: 1.25, href: '#pipeline/belts/EX-1', out: 'Bash npm test' });
    expect([p.tone, p.word, p.stage, p.idle, p.cost, p.href, p.out]).toEqual(['info', 'running', 'stop 3 of 9', 'idle 12 min', '$1.25', '#pipeline/belts/EX-1', 'Bash npm test']);
    expect(tileOf({ kind: 'pipe', key: 'EX-2', fault: 'stalled' })).toMatchObject({ tone: 'bad', word: 'stalled' });
    expect(tileOf({ kind: 'slack', key: 'agent-ex0001', alive: false, waits: 'Sample Person', turns: 1 })).toMatchObject({ tone: 'dim', word: 'waits on Sample Person', stage: '1 turn' });
  });

  it('tags a run by its outcome, and links only a real GitHub PR', () => {
    expect(runBadge({ outcome: 'pr', pr_number: 7, pr_state: 'merged', pr_url: 'https://github.com/example/repo/pull/7' })).toEqual({ label: 'PR #7 merged', tone: 'ok', href: 'https://github.com/example/repo/pull/7' });
    expect(runBadge({ outcome: 'pr', pr_url: 'javascript:x' })).toEqual({ label: 'PR', tone: 'info', href: '' });
    expect(runBadge({ outcome: 'failed' })).toMatchObject({ label: 'failed', tone: 'bad' });
    expect(runBadge({ outcome: 'odd' })).toMatchObject({ label: 'odd', tone: 'dim' });
  });


  it('puts runs in 24 local hours ending now, without the passes', () => {
    const h = ovHours([{ src: 'pipeline', ms: NOW - 60000 }, { src: 'slack', ms: NOW - 120000 }, { src: 'pass', ms: NOW }, { src: 'slack', ms: NOW - 3 * 3600000 }, { src: 'slack', ms: NOW - 30 * 3600000 }], NOW);
    expect(h.b).toHaveLength(24);
    expect(h.tot).toBe(3);
    expect(h.b[23]!.n).toBe(2);
    expect(h.text).toMatch(/^Busiest: .+, 2 runs\. Passes are not counted\.$/);
    expect(ovHours([{ src: 'slack', ms: NOW }, { src: 'slack', ms: NOW - 3600000 }], NOW).text).toBe('At most 1 run in an hour. Passes are not counted.');
  });

  it('counts runs by weekday and hour over 4 weeks', () => {
    const w = ovWeek([{ src: 'slack', ms: NOW }, { src: 'slack', ms: NOW - 7 * 86400000 }, { src: 'pass', ms: NOW }, { src: 'slack', ms: NOW - 40 * 86400000 }], NOW);
    // 18 November 2026 is a Wednesday.
    expect(w[2]![14]).toBe(2);
    expect(w.flat().reduce((a, b) => a + b, 0)).toBe(2);
  });

  it('projects the month at the rate so far', () => {
    const b = ovBudget([{ usd: 10, ms: new Date(2026, 10, 1, 12).getTime() }, { usd: 30, ms: new Date(2026, 10, 2, 12).getTime() }, { usd: 99, ms: new Date(2026, 9, 31).getTime() }], NOW);
    expect(b.mtd).toBe(40);
    expect(b.days).toHaveLength(30);
    expect(b.end).toBeCloseTo(40 + (40 / b.el) * (30 - b.el));
    const last = b.pts[29]!;
    expect(last.spent).toBeNull();
    expect(last.proj).toBeCloseTo(b.end);
    const c = capOf({ budget: { month_usd: 40, month_cap: 50 } }, b.el, b.days);
    expect([c.tone, c.over, c.day != null]).toEqual(['warn', false, true]);
    expect(capOf({ budget: { month_usd: 60, month_cap: 50 } }, b.el, b.days)).toMatchObject({ tone: 'bad', over: true });
  });

  it('gives 14 UTC days with 0 for a missing day, the top 3 models and the rest', () => {
    const day = (n: number) => new Date(NOW - n * 86400000).toISOString().slice(0, 10);
    const L = { hour_usd: 0.5, days: [{ day: day(0), usd: 10 }, { day: day(2), usd: 4 }],
      models: [['a', 5], ['b', 3], ['c', 1], ['d', 0.5], ['e', 0.5]].map(([model, usd]) => ({ day: day(0), model, usd })) };
    const l = ovLlm(L, NOW);
    expect(l.days).toHaveLength(14);
    expect(l.days[12]!.usd).toBe(0);
    expect(l.top3).toEqual(['a', 'b', 'c']);
    expect(l.rest).toBe(1);
    expect(l.days[13]).toMatchObject({ m0: 5, m1: 3, m2: 1, other: 1 });
    expect(ovLlm({ days: [] }, NOW).days).toEqual([]);
  });

  it('gives each team 30 days of spend, a row with no profile as fxa', () => {
    const s = teamSpark([{ usd: 2, ms: NOW, profile: 'example' }, { usd: 1, ms: NOW }, { usd: 5, ms: NOW - 40 * 86400000, profile: 'example' }], NOW);
    expect(s.example).toHaveLength(30);
    expect(s.example![29]).toBe(2);
    expect(s.fxa![29]).toBe(1);
  });

  it('gives the 25th to 75th percentile of a day', () => {
    expect(quart([])).toBeNull();
    expect(quart([1, 2, 3, 4, 5])).toEqual([2, 4]);
  });

  it('reads the slim /api/overview answer as the stats shape', () => {
    expect(overviewOf({ cols: ['at', 'usd'], rows: [['2026-11-01T00:00:00Z', 1]], merged: ['2026-11-01T00:00:00Z'], llm: {} }))
      .toEqual({ rows: [{ at: '2026-11-01T00:00:00Z', usd: 1 }], prs: [{ merged: '2026-11-01T00:00:00Z' }], prs_at: undefined, llm: {}, slim: true });
    expect(overviewOf({ error: 'stats unavailable' })).toBeNull();
  });
  it('keeps one team: its rows, the PRs of its tickets, and no PR list from the slim slice', () => {
    const st = { rows: [{ key: 'A-1', profile: 'sync' }, { key: 'B-1' }, { key: 'B-2', profile: 'fxa' }], prs: [{ key: 'A-1', merged: 'x' }, { key: 'B-1', merged: 'y' }], llm: { hour_usd: 1 } };
    expect(byTeam(st, '')).toBe(st);
    expect(byTeam(st, 'fxa')).toEqual({ ...st, rows: [{ key: 'B-1' }, { key: 'B-2', profile: 'fxa' }], prs: [{ key: 'B-1', merged: 'y' }] });
    expect(byTeam(st, 'sync').rows).toEqual([{ key: 'A-1', profile: 'sync' }]);
    expect(byTeam({ ...st, prs: [{ merged: 'x' }] }, 'fxa').prs).toBeNull();
    expect(byTeam(null, 'fxa')).toBeNull();
    // A PR with a team counts for that team, even when its ticket key is in another team's rows.
    expect(byTeam({ ...st, prs: [{ key: 'B-1', merged: 'y', team: 'sync' }] }, 'sync').prs).toEqual([{ key: 'B-1', merged: 'y', team: 'sync' }]);
  });
});
