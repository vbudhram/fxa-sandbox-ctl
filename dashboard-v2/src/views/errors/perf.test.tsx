// @vitest-environment jsdom
// The Errors render budget: a live event repaints only the rows that it changes.
import { act, cleanup, render } from '@testing-library/react';
import { afterEach, beforeAll, expect, test, vi } from 'vitest';
import type { Frame } from '../../live/schema';
import { dispatch, store } from '../../store';
import chunk from '.';

const calls = vi.hoisted(() => ({ meter: 0, heat: 0 }));
vi.mock('../../ui', async (orig) => {
  const m = await orig<typeof import('../../ui')>();
  return { ...m, Meter: (p: Parameters<typeof m.Meter>[0]) => { calls.meter++; return m.Meter(p); } };
});
vi.mock('../../charts', async (orig) => {
  const m = await orig<typeof import('../../charts')>();
  return { ...m, Heatmap: (p: Parameters<typeof m.Heatmap>[0]) => { calls.heat++; return m.Heatmap(p); } };
});

const NOW = 1793750400;
const err = (i: number, count = 1) => ({ sig: `s${i}`, source: 'ctl', kind: 'boot_failed', status: 'open', message: `m${i}`, count, last: '2026-11-03T23:50:00Z', keys: [`agent-ex000${i}`] });
const errors = (rows: object[]) => dispatch({ event: 'delta', data: { tbl: 'errors', rows, deleted: [] } } as Frame);
const session = (key: string, state: string) => dispatch({ event: 'delta', data: { tbl: 'sessions', rows: [{ key, state, last_activity: NOW }], deleted: [] } } as Frame);
const reset = () => { calls.meter = 0; calls.heat = 0; };

beforeAll(() => {
  vi.useFakeTimers({ now: NOW * 1000, toFake: ['Date'] });
  vi.stubGlobal('matchMedia', () => ({ matches: false }));
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  store.setState((s) => ({ route: { ...s.route, view: 'errors', tab: 'open', sel: '' } }));
  errors([1, 2, 3].map((i) => err(i)));
  session('agent-ex0001', 'active');
});
afterEach(cleanup);

test('an errors delta repaints only the row that it changes, and the heatmap', () => {
  render(<chunk.Main />);
  reset();
  act(() => errors([err(2, 1)].map((e) => ({ ...e, message: 'm2 again' }))));
  expect(calls).toEqual({ meter: 1, heat: 1 });
});

test('a session delta repaints no row, until a session moves to another tab', () => {
  const { container } = render(<chunk.Main />);
  reset();
  act(() => session('agent-ex0001', 'active'));
  act(() => session('agent-ex0009', 'paused'));
  expect(calls).toEqual({ meter: 0, heat: 0 });
  act(() => session('agent-ex0001', 'paused'));
  expect(container.querySelector('a[href="#sessions/paused/agent-ex0001"]')).not.toBeNull();
});

test('the frame: the list card and the chart card are two cards side by side in .err-page', () => {
  const { container } = render(<chunk.Main />);
  const cards = [...container.querySelectorAll('.err-page > section.err-card')];
  expect(cards.map((c) => c.id || c.className)).toEqual(['s-errors', 'err-card err-chart']);
  expect(cards[0].querySelector('.err-heat')).toBeNull();
});
