// @vitest-environment jsdom
// The Stats render budget: a session event repaints the cards that name a session, not the charts or the PR figures.
import { act, cleanup, render } from '@testing-library/react';
import { afterEach, beforeAll, expect, test, vi } from 'vitest';
import type { Frame } from '../../live/schema';
import { dispatch, setRoute, store } from '../../store';
import * as compute from './compute';
import { Main } from './Main';

const calls = vi.hoisted(() => ({ bars: 0, scatter: 0 }));
vi.mock('./charts', async (orig) => {
  const m = await orig<typeof import('./charts')>();
  return {
    Bars: (p: Parameters<typeof m.Bars>[0]) => { calls.bars++; return m.Bars(p); },
    Scatter: (p: Parameters<typeof m.Scatter>[0]) => { calls.scatter++; return m.Scatter(p); },
  };
});
vi.mock('./compute', async (orig) => {
  const m = await orig<typeof import('./compute')>();
  return { ...m, prsData: vi.fn(m.prsData), runnerData: vi.fn(m.runnerData) };
});

const NOW = 1793750400, iso = (t: number) => new Date(t * 1000).toISOString();
const rows = [
  { src: 'pipeline', key: 'EX-1', usd: 2, min: 8, at: iso(NOW - 3600) },
  { src: 'slack', key: 'agent-1', usd: 1, min: 4, at: iso(NOW - 7200), runner_s: 600, busy_s: 60, backend: 'gce', boot_s: 20 },
];
const prs = [{ n: 1, key: 'EX-1', state: 'MERGED', created: iso(NOW - 86400), merged: iso(NOW - 3600), add: 1, del: 1, src: 'pipeline' }];
const session = () => act(() => dispatch({ event: 'delta', data: { tbl: 'sessions', rows: [{ key: 'agent-1', state: 'running', updated: NOW }], deleted: [] } } as Frame));

beforeAll(() => {
  vi.useFakeTimers({ now: NOW * 1000, toFake: ['Date'] });
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  vi.stubGlobal('fetch', () => new Promise(() => {}));
  dispatch({ event: 'viewer', data: { user: 'user@example.com', admin: true, teams: [] } } as never);
  dispatch({ event: 'stats-base', data: { stats: { rows, prs }, etag: '"0"' } } as never);
});
afterEach(cleanup);

// The charts load in their own chunk: wait for it, so the count starts with the charts drawn.
async function show(tab: string) {
  act(() => setRoute({ ...store.getState().route, view: 'stats', tab, query: {} } as never));
  const v = render(<Main />);
  await act(async () => { await import('./charts'); await new Promise((r) => setTimeout(r, 0)); });
  calls.bars = calls.scatter = 0;
  vi.mocked(compute.prsData).mockClear();
  vi.mocked(compute.runnerData).mockClear();
  return v;
}

test('a session event on Spend redraws no chart', async () => {
  const { container } = await show('spend');
  expect(container.querySelector('#st-runs figure')).toBeTruthy();
  session();
  expect([calls.bars, calls.scatter]).toEqual([0, 0]);
});

test('a session event on PRs does not recount the PR figures or redraw the PR charts', async () => {
  await show('prs');
  session();
  expect(compute.prsData).not.toHaveBeenCalled();
  expect(calls.scatter).toBe(0);
});

test('a session event on Runners and LLM does not redraw the cards', async () => {
  await show('runners');
  session();
  expect(compute.runnerData).not.toHaveBeenCalled();
});
