// @vitest-environment jsdom
// The Sessions render budget: a live event repaints only the parts that read what it changes.
import { act, cleanup, render } from '@testing-library/react';
import { Profiler } from 'react';
import { afterAll, afterEach, beforeAll, expect, test, vi } from 'vitest';
import type { Frame } from '../../live/schema';
import { dispatch, store } from '../../store';
import * as data from './data';
import chunk from './index';

const calls = vi.hoisted(() => ({ tag: 0 }));
vi.mock('./data', async (orig) => {
  const m = await orig<typeof import('./data')>();
  return { ...m, threadItems: vi.fn(m.threadItems) };
});
vi.mock('../../ui', async (orig) => {
  const m = await orig<typeof import('../../ui')>();
  return { ...m, Tag: (p: Parameters<typeof m.Tag>[0]) => { calls.tag++; return m.Tag(p); } };
});

const NOW = 1793750400, iso = (t: number) => new Date(t * 1000).toISOString();
const sess = (i: number, more: Record<string, unknown> = {}) => ({ key: `agent-p${i}`, state: 'stopped', created: NOW - i * 60, owner: 'U1', owner_name: 'Sample Person', request: `ask ${i}`, ...more });
const delta = (rows: unknown[]) => dispatch({ event: 'delta', data: { tbl: 'sessions', rows, deleted: [] } } as Frame);
const route = (tab: string, sel = '') => act(() => store.setState({ route: { view: 'sessions', tab, sel, rid: '', query: {} } } as never));

beforeAll(() => {
  vi.useFakeTimers({ now: NOW * 1000, toFake: ['Date'] });
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  vi.stubGlobal('fetch', () => new Promise(() => {}));
  dispatch({ event: 'viewer', data: { user: 'user@example.com', admin: true, teams: [] } } as never);
  dispatch({ event: 'feed', data: { name: 'agents', age_seconds: 1, interval: 30, error: null, refreshing: false, fetched_at: NOW, data: { sessions: [] } } } as never);
  delta([sess(1), sess(2), sess(3, { state: 'active' })]);
  const rows = Array.from({ length: 5 }, (_, i) => ({ src: 'answer', key: `ans-${i}`, usd: 0.01, at: iso(NOW - i * 60), kind: 'answered', secs: 3, q: `q ${i}` }));
  dispatch({ event: 'stats-base', data: { stats: { rows }, etag: '"a"' } } as never);
  dispatch({ event: 'history', data: { key: 'agent-p1', rows: [{ key: 'agent-p1', role: 'person', at: NOW - 50, text: 'ask 1' }, { key: 'agent-p1', role: 'agent', at: NOW - 40, text: 'done' }] } } as never);
});
afterEach(cleanup);
afterAll(() => vi.useRealTimers());

test('the side list keeps its groups when an errors or a history delta repaints the shell', () => {
  route('stopped', 'agent-p1');
  const a = data.sideGroups(store.getState());
  dispatch({ event: 'delta', data: { tbl: 'errors', rows: [{ sig: 's1', status: 'open', keys: [] }], deleted: [] } } as Frame);
  dispatch({ event: 'delta', data: { tbl: 'history', rows: [{ key: 'agent-p9' }], deleted: [] } } as Frame);
  expect(data.sideGroups(store.getState())).toBe(a);
  act(() => delta([sess(2, { turns: 5 })]));
  expect(data.sideGroups(store.getState())).not.toBe(a);
});

test('the frame keeps its thread on a delta of another session, and a terminal line does not repaint it', () => {
  route('stopped', 'agent-p1');
  let n = 0;
  render(<Profiler id="m" onRender={() => n++}><chunk.Main /></Profiler>);
  vi.mocked(data.threadItems).mockClear();
  n = 0;
  act(() => dispatch({ event: 'tail', data: { key: 'agent-p1', start: 0, lines: ['a line'] } } as Frame));
  expect(n).toBe(0);
  act(() => delta([sess(3, { state: 'active', turns: 2 })]));
  expect(n).toBe(1);
  expect(data.threadItems).not.toHaveBeenCalled();
});

test('a session delta does not repaint the Answers rows', () => {
  route('answers');
  render(<chunk.Main />);
  calls.tag = 0;
  act(() => delta([sess(3, { state: 'active', turns: 3 })]));
  expect(calls.tag).toBe(0);
});
