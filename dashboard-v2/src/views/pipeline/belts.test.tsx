// @vitest-environment jsdom
// The belt rows repaint only when their data or the rows above them change.
import { act, cleanup, render } from '@testing-library/react';
import { readFileSync } from 'node:fs';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { snapshotActions, viewerAction } from '../../live/poll';
import { type Action, apply } from '../../live/reducers';
import { store } from '../../store';
import { Belts } from './belts';

// Each row calls laneTitle once per repaint.
const title = vi.hoisted(() => ({ n: 0 }));
vi.mock('../../model/pipeline', async (orig) => {
  const m = await orig<typeof import('../../model/pipeline')>();
  return { ...m, laneTitle: (x: unknown) => (title.n++, m.laneTitle(x)) };
});

type J = ReturnType<typeof JSON.parse>;
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
Element.prototype.scrollIntoView ??= () => {};
const fixture = JSON.parse(readFileSync(`${process.cwd()}/../skills/fxa-ctl-dev/page-fixture-pipeline.json`, 'utf8'));
const d = (a: Action) => store.setState((s) => apply(s, a), true);
const start = store.getState();

beforeEach(() => {
  vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener() {}, removeEventListener() {} }));
  store.setState(start, true);
  d(viewerAction({ data: fixture['/api/team-admin'], etag: null }));
  snapshotActions(fixture['/api/snapshot']).forEach(d);
  store.setState((s) => ({ route: { ...s.route, view: 'pipeline', tab: 'belts', sel: '' } }));
  render(<Belts />);
  title.n = 0;
});
afterEach(cleanup);

const agents = (f: (a: J) => void) => act(() => {
  const a = structuredClone(store.getState().feeds.agents!.data) as J;
  f(a);
  store.setState((s) => ({ feeds: { ...s.feeds, agents: { ...s.feeds.agents!, data: a } } }));
});

it('repaints no row for a stats frame, and only the changed row for an agents frame', () => {
  act(() => store.setState((s) => ({ feeds: { ...s.feeds, stats: { ...s.feeds.stats, data: { tickets: {} } } as never } })));
  expect(title.n).toBe(0);
  agents(() => {});
  expect(title.n).toBe(0);
  agents((a) => { a.runners[0].agent.turns += 1; });
  expect(title.n).toBe(1);
});

it('repaints every row when the open row changes, so motion moves the rows below it', () => {
  const rows = document.querySelectorAll('[data-belt]').length;
  act(() => store.setState((s) => ({ route: { ...s.route, sel: 'FXA-20' } })));
  expect(title.n).toBe(rows);
});
