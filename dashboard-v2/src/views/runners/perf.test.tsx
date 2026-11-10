// @vitest-environment jsdom
// The Sandboxes render budget: a change to one runner repaints its list row, not the other rows or the timeline.
import { act, cleanup, render } from '@testing-library/react';
import { readFileSync } from 'node:fs';
import { afterAll, beforeAll, beforeEach, expect, test, vi } from 'vitest';
import { snapshotActions, viewerAction } from '../../live/poll';
import { dispatch, store } from '../../store';
import chunk from './index';

const calls = vi.hoisted(() => ({ gantt: 0, meter: 0 }));
vi.mock('../../charts', async (orig) => {
  const m = await orig<typeof import('../../charts')>();
  return { ...m, Gantt: (p: Parameters<typeof m.Gantt>[0]) => { calls.gantt++; return m.Gantt(p); } };
});
// Each live list row draws one time meter.
vi.mock('../../ui', async (orig) => {
  const m = await orig<typeof import('../../ui')>();
  return { ...m, Meter: (p: Parameters<typeof m.Meter>[0]) => { calls.meter++; return m.Meter(p); } };
});

type J = ReturnType<typeof JSON.parse>;
const NOW = 1793750400;
const rel = (v: unknown): unknown => {
  if (Array.isArray(v)) return v.map(rel);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, rel(x)]));
  const m = typeof v === 'string' ? /^@(iso|epoch)([+-]\d+)$/.exec(v) : null;
  if (!m) return v;
  const t = NOW + Number(m[2]);
  return m[1] === 'epoch' ? t : new Date(t * 1000).toISOString().replace(/\.\d+Z$/, 'Z');
};
const F = rel(JSON.parse(readFileSync(`${process.cwd()}/../skills/fxa-ctl-dev/page-fixture-sandboxes.json`, 'utf8'))) as J;
const agents = (f: (a: J) => void) => act(() => {
  const snap = structuredClone(F['/api/snapshot']);
  f(snap.agents);
  dispatch(snapshotActions(snap)[1]!);
});

beforeAll(() => {
  vi.useFakeTimers({ now: NOW * 1000, toFake: ['Date'] });
  vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener() {}, removeEventListener() {} }));
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  vi.stubGlobal('fetch', () => new Promise(() => {}));
  dispatch(viewerAction({ data: F['/api/team-admin'], etag: null }));
  snapshotActions(F['/api/snapshot']).forEach(dispatch);
  store.setState((s) => ({ route: { ...s.route, view: 'runners', tab: '', sel: '' } }));
  render(<chunk.Main />);
});
beforeEach(() => { calls.gantt = 0; calls.meter = 0; });
afterAll(() => { cleanup(); vi.useRealTimers(); });

test('an agents frame that changes the cost of one runner repaints only its list row', () => {
  agents(() => {});
  expect(calls).toMatchObject({ gantt: 0, meter: 0 });
  agents((a) => { a.runners[0].agent.cost_so_far += 1; });
  expect(calls).toMatchObject({ gantt: 0, meter: 1 });
});

test('a runner whose start moves repaints the timeline', () => {
  agents((a) => { a.runners[0].elapsed_seconds += 600; });
  expect(calls.gantt).toBe(1);
});

test('a stats frame for no shown run repaints no list row and not the timeline', () => {
  act(() => dispatch({ event: 'stats-base', data: { stats: { rows: [{ src: 'slack', key: 'agent-zz', usd: 1, at: new Date(NOW * 1000).toISOString() }] }, etag: '"1"' } } as never));
  expect(calls).toMatchObject({ gantt: 0, meter: 0 });
});
