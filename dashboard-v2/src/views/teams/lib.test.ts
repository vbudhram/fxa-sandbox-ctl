import { expect, test } from 'vitest';
import { budgetOf, newTeamCheck, newTeamErrs, newTeamRecord, teamApply, teamBanner, teamDays, teamDaysBy, teamItemDraft, teamPatch, teamRetest, teamTestState, textSize } from './lib';

const rec = { name: 'example', status: 'active', repos: [{ slug: 'example/app', role: 'work' }], caps: { launches_per_day: 40, usd_per_day: 5 },
  access: { open: false, users: ['UEXAMPLE1'], channels: [], jira_prefixes: [] }, jira: { project: 'EX', queue: true, board: '7' }, prompts: { goal_md: 'Example work.' } };
const save = (item: string, edit: (d: Record<string, unknown>) => void = () => {}) => {
  const d = teamItemDraft(item, rec);
  edit(d);
  return teamApply(rec, teamPatch({ item, d }, rec, 'example'));
};

test('a repo commits mode: append is saved, squash leaves no key, and neither needs a new test', () => {
  const set0 = (k: string, v: string) => (d: Record<string, unknown>) => { d.repos = (d.repos as Record<string, unknown>[]).map((r, i) => (i ? r : { ...r, [k]: v })); };
  const app = save('repos', set0('commits', 'append'));
  expect(app.repos).toEqual([{ slug: 'example/app', role: 'work', commits: 'append' }]);
  expect(teamRetest(rec, app)).toBe(false);
  expect(save('repos', set0('commits', 'squash')).repos).toEqual([{ slug: 'example/app', role: 'work' }]);
  expect(teamRetest(rec, save('repos', set0('role', 'dep')))).toBe(true);
});

test('an item form replaces its own keys only, and a key with no input survives', () => {
  expect(save('caps', (d) => { d.usd_per_day = ''; d.runners = '3'; }).caps).toEqual({ launches_per_day: 40, runners: 3 });
  expect(save('jira', (d) => { d.launches_per_day = ''; }).jira).toEqual({ project: 'EX', queue: true, board: '7' });
  expect(save('jira', (d) => { d.secret = true; }).access).toMatchObject({ open: false, jira_prefixes: [] });
  // The access form no longer lists people: Can start in People does; the stored list survives a save.
  expect(save('access', (d) => { d.uid = 'UEXAMPLE2'; }).access.users).toEqual(['UEXAMPLE1']);
  expect(save('tools', (d) => { d.dflt = true; })).not.toHaveProperty('mcp');
  expect(save('secrets', (d) => { d.jira = 'JIRA'; }).secrets).toEqual({ jira: 'fxa-team-example--JIRA' });
  expect(save('goal', (d) => { d.goal = 'New.'; }).prompts.goal_md).toBe('New.');
});

test('the PR rules save the admin rounds and the quiet window, and an empty input leaves no key', () => {
  const r = { ...rec, pr: { review_rounds: 2, admin_review_rounds: 10 } };
  const pr = (edit: (d: Record<string, unknown>) => void) => {
    const d = teamItemDraft('pr', r);
    edit(d);
    return teamApply(r, teamPatch({ item: 'pr', d }, r, 'example')).pr;
  };
  expect(pr((d) => { d.admin_review_rounds = '12'; d.review_quiet_minutes = '30'; })).toMatchObject({ review_rounds: 2, admin_review_rounds: 12, review_quiet_minutes: 30 });
  expect(pr((d) => { d.admin_review_rounds = ''; })).not.toHaveProperty('admin_review_rounds');
  expect(teamItemDraft('pr', r)).toMatchObject({ admin_review_rounds: 10, review_quiet_minutes: '' });
});

test('a change to a key that a runner reads needs a new test; the goal does not', () => {
  expect(teamRetest(rec, save('skills', (d) => { d.skills = ['fxa-verify']; }))).toBe(true);
  expect(teamRetest(rec, save('goal', (d) => { d.goal = 'New.'; }))).toBe(false);
});

test('the test state: running and failed win, a pass needs the tested generation or an active team', () => {
  expect(teamTestState({ test: null })).toBe('none');
  expect(teamTestState({ test: { result: 'running' } })).toBe('running');
  expect(teamTestState({ test: { tested: '5', generation: '5' } })).toBe('passed');
  expect(teamTestState({ test: { tested: '4', generation: '5' } })).toBe('none');
  expect(teamTestState({ test: { tested: '4', generation: '5' }, access: { status: 'active' } })).toBe('passed');
});

test('New team: the client rules, the record, and the server lines mapped to the fields', () => {
  expect(Object.keys(newTeamCheck({ name: 'Bad Name', repo: 'nope', stack: '', goal: '' }))).toEqual(['name', 'repo', 'stack']);
  expect(newTeamRecord({ name: 'new-one', repo: 'example/new', stack: 'fxa', goal: 'x' }).repos).toEqual([{ slug: 'example/new', role: 'work', default: true }, { slug: 'mozilla/fxa', role: 'dep' }]);
  expect(newTeamErrs('ERROR: new-one.json: repos[0]: no such repo\nERROR: something else')).toEqual({ errs: { repo: 'repos[0]: no such repo' }, summary: 'something else' });
  expect(newTeamErrs('ERROR: name is reserved').errs).toEqual({ name: 'name is reserved' });
});

test('the budget tones, the banner order with "and N more", the 30 days, and the byte count', () => {
  expect(budgetOf({ budget: { month_usd: 9.5, month_cap: 10 } })).toMatchObject({ kind: 'cap', tone: 'warn' });
  expect(budgetOf({ budget: { month_usd: 10, month_cap: 10 } })).toMatchObject({ tone: 'bad' });
  expect(budgetOf({ budget_error: 'x' })).toEqual({ kind: 'error' });
  const b = teamBanner({ profile: 'example', issues: [{ text: 'spend cap reached' }, { text: 'nobody can start it' }] }, true, { failed: 1 });
  expect(b).toMatchObject({ head: 'The team reached its spend cap', act: null, more: 2 });
  expect(teamBanner({ profile: 'example', issues: [] }, true, null)).toBeNull();
  const at = Date.UTC(2026, 10, 3, 12), ds = teamDays([{ profile: 'example', t0: at / 1000 - 60, usd: 2, src: 'slack' }, { profile: 'example', t0: at / 1000 - 86400 * 2, usd: 3, src: 'pass' }, { t0: at / 1000, usd: 1 }], 'example', at);
  expect(ds).toHaveLength(30);
  expect(ds.at(-1)).toMatchObject({ n: 1, slack: 2, pipe: 0 });
  expect(ds.at(-3)).toMatchObject({ n: 1, slack: 0, pipe: 3 });
  expect(textSize('é', 2560)).toBe('2 of 2560');
  expect(textSize('x'.repeat(2400), 2560)).toBe('2400 of 2560 bytes, 160 left');
});

test('teamDaysBy gives each team the counts of teamDays, in one pass over the rows', () => {
  const at = Date.UTC(2026, 10, 3, 12), s = at / 1000;
  const rows = [{ profile: 'a', t0: s - 60 }, { profile: 'a', t0: s - 86400 * 2 }, { profile: 'b', at: new Date(at - 86400000 * 29.5).toISOString() }, { t0: s - 10 }, { profile: 'a', t0: s - 86400 * 31 }, { profile: 'a', t0: s + 60 }];
  const by = teamDaysBy(rows, at);
  for (const p of ['a', 'b', 'fxa', 'none']) expect(by(p)).toEqual(teamDays(rows, p, at).map((d) => d.n));
});
