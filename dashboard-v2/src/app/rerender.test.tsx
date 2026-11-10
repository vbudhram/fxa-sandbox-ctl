// @vitest-environment jsdom
// The jsdom import.meta.url is not a file URL, so the paths start at dashboard-v2, where npm test runs.
// The render count budget: one event repaints only the views that read what it changes.
import { readFileSync } from 'node:fs';
import { act, cleanup, render } from '@testing-library/react';
import { Profiler, type ComponentType } from 'react';
import { afterAll, beforeAll, expect, test, vi } from 'vitest';
import { parseFrame, type Frame } from '../live/schema';
import { dispatch, store } from '../store';
import type { ViewId } from '../router/types';
import { App } from './App';
import { modelSel } from './store';
import { VIEWS } from './views';

const NOW = 1793750400;
const frames = (name: string): Frame[] =>
  readFileSync(`${process.cwd()}/fixtures/live/${name}.ndjson`, 'utf8').split('\n').filter(Boolean).map(parseFrame);
const BASIC = frames('basic');
const at = (id: string) => BASIC.find((f) => f.id === id)!;
// The fixture time rule of the v1 stats fixture: "@iso-3600" is an hour before NOW.
const rel = (v: unknown): unknown => {
  if (Array.isArray(v)) return v.map(rel);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, rel(x)]));
  const m = typeof v === 'string' ? /^@(iso|epoch|day)([+-]\d+)$/.exec(v) : null;
  if (!m) return v;
  const t = NOW + Number(m[2]);
  return m[1] === 'epoch' ? t : m[1] === 'day' ? new Date((NOW + Number(m[2]) * 86400) * 1000).toISOString().slice(0, 10) : new Date(t * 1000).toISOString().replace(/\.\d+Z$/, 'Z');
};
const STATS = rel(JSON.parse(readFileSync(`${process.cwd()}/../skills/fxa-ctl-dev/page-fixture-stats.json`, 'utf8'))['/api/stats']) as Record<string, unknown>;

const counts: Partial<Record<ViewId, number>> = {};
const mains: Partial<Record<ViewId, ComponentType>> = {};

beforeAll(async () => {
  vi.useFakeTimers({ now: NOW * 1000, toFake: ['Date'] });
  vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener() {}, removeEventListener() {} }));
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  // The reads that a view starts never answer, so only the events below change the store.
  vi.stubGlobal('fetch', () => new Promise(() => {}));
  // No hello: a stream id would make Belts open a stream.
  dispatch({ event: 'viewer', data: { user: 'user@example.com', admin: true, teams: ['example'] } });
  dispatch(at('e5a17c0d-41'));
  dispatch({ event: 'stats-base', data: { stats: STATS, etag: '"base"' } });
  for (const v of VIEWS) mains[v.id] = (await v.load!()).default.Main;
  render(
    <>
      {VIEWS.map((v) => {
        const Main = mains[v.id]!;
        return <Profiler key={v.id} id={v.id} onRender={() => (counts[v.id] = (counts[v.id] ?? 0) + 1)}><Main /></Profiler>;
      })}
    </>,
  );
});
afterAll(() => {
  cleanup();
  vi.useRealTimers();
});

// The views that commit for one event.
function repaints(f: Frame): ViewId[] {
  for (const v of VIEWS) counts[v.id] = 0;
  act(() => dispatch(f));
  return VIEWS.map((v) => v.id).filter((id) => counts[id]);
}

test('a ping repaints no view', () => {
  expect(repaints({ event: 'ping', data: {} } as Frame)).toEqual([]);
});

test('a delta that only marks a routine or a history row repaints no view', () => {
  expect(repaints(at('e5a17c0d-45'))).toEqual([]);
  expect(repaints(at('e5a17c0d-47'))).toEqual([]);
});

test('a terminal line repaints only the views that show its terminal', () => {
  expect(repaints(at('e5a17c0d-43'))).toEqual([]);
  // A belt's terminal opens in its own window, so a line of it repaints no view of the shell.
  expect(repaints({ id: 'e5a17c0d-61', event: 'tail', data: { key: 'EX-101', start: 0, lines: ['a line of a live belt'] } } as Frame)).toEqual([]);
});

test('an errors delta repaints Errors, and not the views without errors', () => {
  const r = repaints(at('e5a17c0d-46'));
  expect(r).toContain('errors');
  for (const v of ['pipeline', 'sessions', 'stats', 'runners'] as const) expect(r).not.toContain(v);
});

test('a stats frame repaints Stats, and not Errors', () => {
  const r = repaints({ id: 'e5a17c0d-60', event: 'stats', data: { base: '"base"', etag: '"next"', rows_add: [{ src: 'slack', key: 'agent-ex0009', usd: 1, at: new Date(NOW * 1000).toISOString() }] } } as Frame);
  expect(r).toContain('stats');
  expect(r).not.toContain('errors');
});

test('a flow point repaints no view: no view draws the flow points now', () => {
  expect(repaints(at('e5a17c0d-51'))).toEqual([]);
});

test('a session delta repaints Sessions', () => {
  expect(repaints(at('e5a17c0d-52'))).toContain('sessions');
});

test('a session delta repaints no row of the Teams side list', async () => {
  location.hash = '#teams';
  const { container, unmount } = render(<App store={store} sel={modelSel} />);
  await act(async () => { await vi.waitFor(() => expect(container.querySelectorAll('#side .si').length).toBeGreaterThan(1)); });
  // React gives a host node new props only when its component renders again.
  const props = () => [...container.querySelectorAll('#side .si')].map((el) => Object.entries(el).find(([k]) => k.startsWith('__reactProps$'))![1]);
  const before = props();
  act(() => dispatch({ id: 'e5a17c0d-62', event: 'delta', data: { tbl: 'sessions', rows: [{ key: 'agent-ex0002', state: 'active', last_activity: NOW + 5 }], deleted: [] } } as Frame));
  expect(props().filter((p, i) => p !== before[i])).toEqual([]);
  unmount();
});

test('a store change that the view does not read gives no repaint of the view in the shell', async () => {
  const errs = VIEWS.find((v) => v.id === 'errors')!, load = errs.load;
  let n = 0;
  errs.load = async () => ({ default: { Main: () => <Profiler id="m" onRender={() => n++}><p>the errors main</p></Profiler> } });
  location.hash = '#errors/open';
  let shell = 0;
  const { findByText } = render(<Profiler id="app" onRender={() => shell++}><App store={store} sel={modelSel} /></Profiler>);
  await act(async () => { await findByText('the errors main'); });
  n = 0;
  shell = 0;
  act(() => dispatch({ event: 'ping', data: {} } as Frame));
  act(() => dispatch(at('e5a17c0d-43')));
  act(() => dispatch(at('e5a17c0d-51')));
  expect(n).toBe(0);
  // The shell shows no terminal line, flow point or event clock.
  expect(shell).toBe(0);
  errs.load = load;
});
