// All teams joins each team's lists; two teams on one repo must not show a PR twice.
import { expect, test } from 'vitest';
import { snapshotActions } from '../live/poll';
import { apply, initial } from '../live/reducers';
import { SF_DEFAULT } from '../store/prefs';
import { beltGroups, pipeSnap } from './index';
import { queueOnly } from './pipeline';

test('a PR that two teams list shows once in All teams', () => {
  const pr = { key: 'FXA-1', number: 7, title: 'fix: x', created: new Date().toISOString() };
  const snap = { inflight: [], review: [], blocked: [{ key: 'FXA-1', why: 'needs a decision', kind: 'needs_decision' }], open_prs: [pr], merged_prs: [] };
  let st = initial({ theme: 'system', keys: false, pipeTeam: '', sowner: '', panelW: {}, noside: false, noright: false, sx: { term: true }, statsFilter: SF_DEFAULT });
  snapshotActions({ snapshot: snap, teams: { fxa: { snapshot: snap }, entitlements: { snapshot: snap } } }).forEach((a) => { st = apply(st, a); });
  const s = pipeSnap(st) as { open_prs: unknown[]; blocked: unknown[] };
  expect(s.open_prs).toHaveLength(1);
  expect(s.blocked).toHaveLength(1);
  const keys = Object.values(beltGroups(st)).flatMap((g) => (Array.isArray(g) ? g.map((r: { t: { key: string } }) => r.t.key) : []));
  expect(keys.filter((k) => k === 'FXA-1')).toHaveLength(1);
});

test('a skip with a Decide belt shows on Queue while Belts is unknown, and on Belts only when Belts is known', () => {
  const skip = { key: 'FXA-2', summary: 'x', reason: 'needs a decision', passes: 2 };
  const snap = { inflight: [], review: [], blocked: [{ key: 'FXA-2', why: 'needs a decision', kind: 'needs_decision' }], open_prs: [], merged_prs: [], queue: { ready: [], skipped: [skip] } };
  const at = (ageSeconds: number) => {
    let st = initial({ theme: 'system', keys: false, pipeTeam: '', sowner: '', panelW: {}, noside: false, noright: false, sx: { term: true }, statsFilter: SF_DEFAULT });
    snapshotActions({ snapshot: snap, teams: { fxa: { snapshot: snap } } }).forEach((a) => { st = apply(st, a); });
    return { ...st, feeds: { ...st.feeds, full: { ...st.feeds.full, ageSeconds, interval: 300 } } } as typeof st;
  };
  expect(queueOnly(at(10)).map((k) => k.key)).toEqual([]);
  // An old snapshot makes Belts' Needs you '?', so no tab would list the skip.
  expect(queueOnly(at(3600)).map((k) => k.key)).toEqual(['FXA-2']);
});
