// @vitest-environment jsdom
// The Teams render budget: a live event repaints only the parts that read what it changes.
import { act, cleanup, render } from '@testing-library/react';
import { afterEach, beforeAll, expect, test, vi } from 'vitest';
import type { Frame } from '../../live/schema';
import { teamsAction } from '../../live/poll';
import { dispatch } from '../../store';
import { AllTeams } from './AllTeams';
import * as lib from './lib';
import { Overview } from './Overview';
import { readRecord } from './state';

const calls = vi.hoisted(() => ({ spark: 0 }));
vi.mock('../../charts', async (orig) => {
  const m = await orig<typeof import('../../charts')>();
  return { ...m, Spark: (p: Parameters<typeof m.Spark>[0]) => { calls.spark++; return m.Spark(p); } };
});
vi.mock('./lib', async (orig) => {
  const m = await orig<typeof import('./lib')>();
  return { ...m, teamDays: vi.fn(m.teamDays), teamBurn: vi.fn(m.teamBurn) };
});

const NOW = 1793750400, iso = (t: number) => new Date(t * 1000).toISOString();
const teams = ['a', 'b', 'c'].map((p) => ({ profile: p, label: p, repos: [], issues: [], access: { record: true, status: 'active' }, budget: { month_usd: 1, month_cap: 10 } }));
let etag = '"0"';
const statsRow = (profile: string) => dispatch({ event: 'stats', data: { base: etag, etag: (etag = `"${Math.random()}"`), rows_add: [{ src: 'slack', key: 'agent-1', usd: 1, at: iso(NOW - 60), profile }] } } as Frame);

beforeAll(() => {
  vi.useFakeTimers({ now: NOW * 1000, toFake: ['Date'] });
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  vi.stubGlobal('fetch', () => new Promise(() => {}));
  dispatch({ event: 'viewer', data: { user: 'user@example.com', admin: true, teams: [] } } as never);
  dispatch(teamsAction({ data: { teams, age_seconds: 5 } } as never));
  dispatch({ event: 'stats-base', data: { stats: { rows: teams.map((t) => ({ src: 'slack', key: 'agent-0', usd: 1, at: iso(NOW - 3600), profile: t.profile })) }, etag } } as never);
});
afterEach(cleanup);

test('a stats row of one team repaints only the sparkline of that team on All teams', () => {
  render(<AllTeams />);
  calls.spark = 0;
  act(() => statsRow('b'));
  expect(calls.spark).toBe(1);
});

test('an errors delta repaints the Overview tiles, not the Activity and budget charts', () => {
  render(<Overview t={teams[0]} />);
  vi.mocked(lib.teamDays).mockClear();
  vi.mocked(lib.teamBurn).mockClear();
  act(() => dispatch({ event: 'delta', data: { tbl: 'errors', rows: [{ sig: 's1', status: 'open', keys: ['agent-0'] }], deleted: [] } } as Frame));
  expect(lib.teamDays).not.toHaveBeenCalled();
  expect(lib.teamBurn).not.toHaveBeenCalled();
});

test('readRecord asks for the record and its secrets at once', async () => {
  const urls: string[] = [];
  vi.stubGlobal('fetch', (u: string) => { urls.push(u); return new Promise(() => {}); });
  void readRecord('a');
  await Promise.resolve();
  expect(urls).toEqual(['/api/teams/a', '/api/teams/a/secrets']);
});
