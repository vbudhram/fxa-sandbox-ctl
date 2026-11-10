// @vitest-environment jsdom
// The Overview render budget: a live event repaints only the rows that read what it changes.
import { readFileSync } from 'node:fs';
import { act, cleanup, render } from '@testing-library/react';
import { afterAll, beforeAll, expect, test, vi } from 'vitest';
import { teamsAction } from '../../live/poll';
import type { Frame } from '../../live/schema';
import { dispatch } from '../../store';
import view from './index';

// runBadge runs once per Activity row and teamAccess once per Teams row, so they count the row repaints.
const calls = vi.hoisted(() => ({ run: 0, team: 0 }));
vi.mock('../shared/stats', async (orig) => {
  const m = await orig<typeof import('../shared/stats')>();
  return { ...m, runBadge: (r: Parameters<typeof m.runBadge>[0]) => { calls.run++; return m.runBadge(r); } };
});
vi.mock('../../model/teams', async (orig) => {
  const m = await orig<typeof import('../../model/teams')>();
  return { ...m, teamAccess: (t: Parameters<typeof m.teamAccess>[0]) => { calls.team++; return m.teamAccess(t); } };
});

const NOW = 1793750400;
// The fixture time rule: "@iso-600" is 10 min before NOW.
const rel = (v: unknown): unknown => {
  if (Array.isArray(v)) return v.map(rel);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, rel(x)]));
  const m = typeof v === 'string' ? /^@(iso|epoch)([+-]\d+)$/.exec(v) : null;
  return !m ? v : m[1] === 'epoch' ? NOW + Number(m[2]) : new Date((NOW + Number(m[2])) * 1000).toISOString();
};
const FX = rel(JSON.parse(readFileSync(`${process.cwd()}/../skills/fxa-ctl-dev/page-fixture-overview.json`, 'utf8'))) as Record<string, Record<string, unknown>>;
const session = (key: string, state: string) => ({ event: 'delta', data: { tbl: 'sessions', rows: [{ key, state, agent_alive: state === 'active', created: NOW - 600 }], deleted: [] } }) as Frame;
let etag = '"0"';
const flush = () => act(async () => { for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0)); });

beforeAll(async () => {
  vi.useFakeTimers({ now: NOW * 1000, toFake: ['Date'] });
  vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener() {}, removeEventListener() {} }));
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  vi.stubGlobal('fetch', (u: string) => (u.startsWith('/api/runs/recent')
    ? Promise.resolve({ ok: true, status: 200, json: async () => FX['/api/runs/recent'], headers: { get: () => null } })
    : new Promise(() => {})));
  dispatch({ event: 'viewer', data: { user: 'user@example.com', admin: true, teams: [] } } as never);
  dispatch(teamsAction({ data: FX['/api/teams'], etag: null } as never));
  dispatch({ event: 'stats-base', data: { stats: FX['/api/stats'], etag } } as never);
  render(<view.Main />);
  await flush();
});
afterAll(() => {
  cleanup();
  vi.useRealTimers();
});

test('a session delta repaints no Activity or Teams row when the session is not in them', () => {
  expect(document.querySelectorAll('.ovrun').length).toBeGreaterThan(0);
  calls.run = calls.team = 0;
  act(() => dispatch(session('agent-ex0009', 'active')));
  expect(calls).toEqual({ run: 0, team: 0 });
});

test('a session delta repaints the Activity row of that session, and its link follows the tab', () => {
  const link = () => document.querySelector('[data-run="agent-ex0001"] a.key')!.getAttribute('href');
  act(() => dispatch(session('agent-ex0001', 'active')));
  expect(link()).toBe('#sessions/live/agent-ex0001');
  calls.run = 0;
  act(() => dispatch(session('agent-ex0001', 'paused')));
  expect(calls.run).toBe(1);
  expect(link()).toBe('#sessions/paused/agent-ex0001');
});

test('a stats frame repaints no Activity row and builds no date formatter per day', () => {
  const day = vi.spyOn(Date.prototype, 'toLocaleDateString'), time = vi.spyOn(Date.prototype, 'toLocaleTimeString');
  calls.run = 0;
  act(() => dispatch({ event: 'stats', data: { base: etag, etag: (etag = '"1"'), rows_add: [{ src: 'slack', key: 'agent-ex0099', usd: 1, at: new Date(NOW * 1000).toISOString(), profile: 'example' }] } } as Frame));
  expect(calls.run).toBe(0);
  // The month names of the Budget card only, not one call per day of a chart or per hour.
  expect(day.mock.calls.length + time.mock.calls.length).toBeLessThanOrEqual(2);
  day.mockRestore();
  time.mockRestore();
});
