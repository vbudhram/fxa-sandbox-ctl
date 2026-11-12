// The pass warnings respect the pass hours: an old last pass at night is the schedule, not a stall.
import { expect, test } from 'vitest';
import { snapshotActions } from '../live/poll';
import { apply, initial } from '../live/reducers';
import { SF_DEFAULT } from '../store/prefs';
import { alerts, passQuiet } from './status';

const NOW = Date.now() / 1000;
const passAlerts = (health: object) => {
  let st = initial({ theme: 'system', keys: false, pipeTeam: '', sowner: '', panelW: {}, noside: false, noright: false, sx: { term: true }, statsFilter: SF_DEFAULT });
  const snap = { inflight: [], review: [], blocked: [], open_prs: [], merged_prs: [], health };
  snapshotActions({ snapshot: snap }).forEach((a) => { st = apply(st, a); });
  return alerts(st).filter((a) => a.subject === 'pass').map((a) => a.what);
};

test('a last pass 2 h ago with the next pass in 8 h gives no pass warning', () => {
  expect(passQuiet({ pass_timer: 'on', next_pass_epoch: NOW + 8 * 3600 }, NOW)).toBe(true);
  expect(passAlerts({ seconds_since_pass: 7300, pass_timer: 'on', next_pass_epoch: NOW + 8 * 3600 })).toEqual([]);
});
test('with the next pass near, the timer off, or no next pass time, an old last pass still warns', () => {
  for (const h of [{ pass_timer: 'on', next_pass_epoch: NOW + 300 }, { pass_timer: 'off', next_pass_epoch: NOW + 8 * 3600 }, { pass_timer: 'on' }]) {
    expect(passAlerts({ seconds_since_pass: 7300, ...h })).toHaveLength(1);
    expect(passAlerts({ seconds_since_pass: 1800, ...h })).toEqual([expect.stringContaining('the cron fires every 20 minutes')]);
  }
});
