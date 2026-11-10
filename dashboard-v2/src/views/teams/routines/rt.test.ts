// The routine logic against the v1 code itself: each v1 function runs from its frozen copy in test/v1-routines.js on the same inputs.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import * as rt from './rt';

const V1 = readFileSync(fileURLToPath(new URL('../../../../test/v1-routines.js', import.meta.url)), 'utf8').split('\n');
// The top-level definition of each name: a one-statement const, or a function up to its closing brace at column 0.
function src(name: string): string {
  const i = V1.findIndex((l) => new RegExp(`^(const|function) ${name}\\b`).test(l));
  if (i < 0) throw new Error(`no v1 ${name}`);
  let j = i;
  if (V1[i]!.startsWith('function')) while (V1[j] !== '}') j++;
  else while (!V1[j]!.trimEnd().endsWith(';')) j++;
  return V1.slice(i, j + 1).join('\n');
}
const NAMES = ['REPO_RE', 'sentence', 'usd', 'RT_DAYS', 'RT_MODES', 'RT_FIELDS', 'RT_ZONES', 'rtDraft', 'rtRoutine', 'rtFromTpl', 'rtErrs', 'rtPr', 'rtSha7', 'rtPrN',
  'FIX_GUARD', 'rtResult', 'rtFixResult', 'rtFix', 'rtNextDays', 'rtSched', 'rtZoneName', 'textSize', 'rtLine'];
const v1 = new Function(`${NAMES.map(src).join('\n')}\nreturn { ${NAMES.join(', ')} };`)();

const depfix = { on: 'pr-label', channel: 'C0123ABCD', pr: { repo: 'example/app', label: 'agent-help' } };
const sched = { template: 'code-review', schedule: 'weekdays 09:00', zone: 'UTC', channel: '', mode: 'report' };
const fixRuns = [
  ...['ok', 'report', 'nochange', 'stopped', 'skipped', 'failed', 'missed', 'odd'].map((state) => ({ state, heads: { fix: { pr: 9, url: 'https://github.com/example/app/pull/9' } } })),
  { state: 'ok', heads: { fix: { pr: 9, new_sha: 'bbbbbbb2222222222222222222222222222222bb' } } },
  ...['moved', 'guard:lock', 'guard:tooling', 'guard:frozen', 'guard:pii', 'guard:other'].map((why) => ({ state: 'report', heads: { fix: { pr: 9, why } } })),
  ...['label', 'closed', 'merged', ''].map((why) => ({ state: 'stopped', heads: { fix: { pr: 9, why } } })),
  ...['new-commit', 'expired', 'not-red', 'used', 'no-write', 'fork', 'base', 'closed', 'merged', 'boot', 'target', 'other'].map((why) => ({ state: 'skipped', heads: { fix: { pr: 9, why } } })),
  { state: 'failed', reason: 'the sandbox did not start', heads: { fix: { pr: 'x' } } },
];
const schedRuns = [
  { state: 'ok', pr_url: 'https://github.com/example/app/pull/12' }, { state: 'ok', pr_url: 'https://example.com/x' }, { state: 'ok' },
  { state: 'report' }, { state: 'report', reason: 'too long' }, { state: 'nochange' }, { state: 'failed', reason: 'boom' }, { state: 'failed' },
  { state: 'missed', reason: 'no session started' }, { state: 'missed' }, { state: 'stopped' }, { state: 'queued', reason: '' }, {},
];

describe('rtResult and rtFixResult equal v1 in every state', () => {
  it.each(fixRuns.map((x) => [JSON.stringify(x), x]))('fix run %s', (_, x) => {
    expect(rt.rtResult(x, depfix)).toEqual(v1.rtResult(x, depfix));
  });
  it.each(schedRuns.flatMap((x) => [[JSON.stringify(x), x, sched], [`${JSON.stringify(x)} with a channel`, x, { ...sched, channel: 'C1' }]]))('schedule run %s', (_, x, d) => {
    expect(rt.rtResult(x, d)).toEqual(v1.rtResult(x, d));
  });
  it('maps each result to the tone of its word', () => {
    expect(rt.rtResult({ state: 'failed' }, sched).slice(0, 2)).toEqual(['Failed', 'bad']);
    expect(rt.rtResult({ state: 'ok', heads: { fix: { pr: 1 } } }, depfix).slice(0, 2)).toEqual(['Pushed', 'merged']);
  });
  it('gives the next step of a failed run whose reason is known', () => {
    for (const w of ['channel_not_found', 'not_in_channel', 'no session started', 'spend cap', 'other', undefined]) expect(rt.rtFix(w)).toBe(v1.rtFix(w));
  });
});

describe('the draft and the routine', () => {
  const routines = [
    { ...sched, name: 'A', prompt: 'p', repos: ['example/app'], branch: 'dev', max_usd: 5, skip_no_commits: false, draft: false, env: 'dev' },
    { ...sched, schedule: 'weekly fri 17:30', zone: 'Europe/Berlin', name: 'B', prompt: '', repos: ['a/b', 'c/d'], branch: 'x', max_usd: 3, skip_no_commits: true, mode: 'pr' },
    { ...depfix, name: 'D', template: 'blank', repos: ['example/app'], max_usd: 10, mode: 'pr', env: 'dev',
      pr: { repo: 'example/app', authors: ['dependabot[bot]'], label: 'agent-help', blender_login: 'example-blender[bot]', sweep_min: 5, blender_mention: '@example' } },
  ];
  it.each(routines.map((r) => [r.name, r]))('rtDraft and rtRoutine equal v1 for %s, and keep env and the hidden pr keys', (_, r) => {
    expect(rt.rtDraft(r)).toEqual(v1.rtDraft(r));
    expect(rt.rtRoutine(rt.rtDraft(r))).toEqual(v1.rtRoutine(v1.rtDraft(r)));
  });
  it('a pr-label edit keeps blender_login and sweep_min, and drops an empty mention', () => {
    const d = { ...rt.rtDraft(routines[2]), pr_mention: ' ' };
    expect(rt.rtRoutine(d).pr).toEqual({ repo: 'example/app', authors: ['dependabot[bot]'], label: 'agent-help', blender_login: 'example-blender[bot]', sweep_min: 5 });
  });
  it('rtDraft with no routine equals v1', () => expect(rt.rtDraft()).toEqual(v1.rtDraft()));
  it('a Codex pick sends its runtime and has no Max effort; Claude sends no runtime', () => {
    const r = rt.rtDraft({ name: 'n', schedule: 'weekdays 09:00', repos: [], mode: 'report', max_usd: 5 });
    expect(rt.rtRoutine({ ...r, runtime: 'codex', model: 'gpt-6-astra', effort: 'high' })).toMatchObject({ runtime: 'codex', model: 'gpt-6-astra', effort: 'high' });
    expect('runtime' in rt.rtRoutine({ ...r, runtime: 'claude' })).toBe(false);
    expect(rt.rtPicks({ runtime: 'codex' }).efforts.map(([v]) => v)).not.toContain('max');
    expect(rt.rtPicks({}).models).toBe(rt.RT_MODELS);
  });
  it('an edit keeps the model and effort on both branches, and an empty pick sends neither', () => {
    for (const r of [routines[0], routines[2]]) {
      expect(rt.rtRoutine(rt.rtDraft({ ...r, model: 'claude-sonnet-5-5', effort: 'low' }))).toMatchObject({ model: 'claude-sonnet-5-5', effort: 'low' });
      const out = rt.rtRoutine({ ...rt.rtDraft(r), model: '', effort: '' });
      expect('model' in out || 'effort' in out).toBe(false);
    }
  });
  it('an edit keeps the watch repo, as v1 does, and drops one that is also a routine repo', () => {
    const r = { ...sched, name: 'W', prompt: 'p', repos: ['a/docs'], watch: 'a/app', max_usd: 5, skip_no_commits: true, mode: 'pr' };
    expect(rt.rtRoutine(rt.rtDraft(r)).watch).toBe('a/app');
    expect(rt.rtRoutine(rt.rtDraft(r))).toEqual(v1.rtRoutine(v1.rtDraft(r)));
    expect(rt.rtRoutine({ ...rt.rtDraft(r), repos: ['a/docs', 'a/app'] }).watch).toBeUndefined();
  });
  const repos = [[{ slug: 'example/app', role: 'work' }], [{ slug: 'a/b', role: 'work' }, { slug: 'c/d', role: 'dep' }], []];
  const starts = [rt.RT_BLANK, rt.RT_DEPFIX, { template: 'security-review', name: 'Security review', prompt: 'x', mode: 'report', locked_mode: 'report', skip_no_commits: true }];
  it.each(starts.flatMap((x) => repos.map((rs, i) => [`${x.template} with repo set ${i}`, x, rs])))('rtFromTpl equals v1: %s', (_, x, rs) => {
    expect(rt.rtFromTpl(x as rt.Start, rs as never[])).toEqual(v1.rtFromTpl(x, rs));
  });
});

describe('rtErrs', () => {
  it('equals v1 on the fields v1 knows', () => {
    const t = 'ERROR: name: Name is too long\nprompt: Prompt is empty\nname: second\nsomething else\nfoo: not a field';
    expect(rt.rtErrs(t)).toEqual(v1.rtErrs(t));
  });
  it('maps each pr error to its own field (v1 put them all on the pr fieldset)', () => {
    const t = 'pr: repo must be a repo slug, such as mozilla/fxa\npr: authors must be 1 to 10 GitHub logins\npr: label must be a label name\npr: blender_mention must be an @login\npr: sweep_min must be a whole number';
    expect(rt.rtErrs(t).errs).toEqual({
      pr_repo: 'repo must be a repo slug, such as mozilla/fxa', pr_authors: 'authors must be 1 to 10 GitHub logins', pr_label: 'label must be a label name',
      pr_mention: 'blender_mention must be an @login', pr: 'sweep_min must be a whole number',
    });
    expect(rt.rtFirstErr(rt.rtErrs(t).errs)).toBe('pr_repo');
  });
});

describe('the time and text helpers', () => {
  const now = Date.UTC(2026, 10, 3, 8, 0);
  it.each([
    [{ kind: 'weekdays', time: '09:00', zone: 'UTC' }], [{ kind: 'weekdays', time: '07:00', zone: 'UTC' }], [{ kind: 'daily', time: '23:30', zone: 'Asia/Tokyo' }],
    [{ kind: 'weekly', day: 'sat', time: '10:00', zone: 'America/New_York' }], [{ kind: 'weekly', day: 'tue', time: '08:00', zone: 'UTC' }], [{ kind: 'daily', time: '25:00', zone: 'UTC' }],
    [{ kind: 'daily', time: '09:00', zone: 'Not/AZone' }],
  ])('rtNextDays equals v1 for %j', (d) => expect(rt.rtNextDays(d, 3, now)).toEqual(v1.rtNextDays(d, 3, now)));
  it('gives the next weekdays from a Tuesday morning', () => expect(rt.rtNextText({ kind: 'weekdays', time: '09:00', zone: 'UTC' }, now)).toBe('Next runs: Tue 3 Nov, Wed 4 Nov and Thu 5 Nov, at 09:00.'));
  it.each([['daily 10:30'], ['weekdays 09:00'], ['weekly fri 17:30'], ['weekly xyz 1:00']])('rtSched equals v1 for %s', (schedule) => expect(rt.rtSched({ schedule })).toBe(v1.rtSched({ schedule })));
  it.each([[''], ['a'.repeat(3700)], ['é'.repeat(2000)]])('textSize counts bytes as v1 does', (s) => expect(rt.textSize(s, 4096)).toBe(v1.textSize(s, 4096)));
  it('rtIn says how long until a run, and nothing for a past or bad time', () => {
    expect([rt.rtIn(new Date(now + 600e3).toISOString(), now), rt.rtIn(new Date(now + 5 * 3600e3).toISOString(), now), rt.rtIn(new Date(now + 3 * 86400e3).toISOString(), now), rt.rtIn(new Date(now - 1).toISOString(), now), rt.rtIn('x', now)])
      .toEqual(['in 10m', 'in 5h', 'in 3d', '', '']);
  });
  it('rtLine puts the running run first, then the queued ones, oldest first', () => {
    const r = { lives: [{ id: 13, state: 'queued' }, { id: 11, state: 'started' }, { id: 12, state: 'queued' }] };
    expect(rt.rtLine(r).map((x) => x.id)).toEqual(v1.rtLine(r).map((x: { id: number }) => x.id));
  });
  it('rtList takes the limit from the server when it sends one', () => {
    expect(rt.rtList(null)).toEqual({ list: null, limit: 8 });
    expect(rt.rtList([{ id: 1 }]).limit).toBe(8);
    expect(rt.rtList({ routines: [{ id: 1 }], limits: { routines: 12 } })).toEqual({ list: [{ id: 1 }], limit: 12 });
  });
  it('rtCostHint names the start and the cost range of this team only', () => {
    const sum = { routines: { 1: { team: 'example', template: 'code-review', cost_min_30d: 0.5, cost_max_30d: 2 }, 2: { team: 'other', template: 'code-review', cost_min_30d: 0.1, cost_max_30d: 9 } } };
    expect(rt.rtCostHint(sum, 'example', { template: 'code-review' }, [{ template: 'code-review', name: 'Code review' }])).toBe('Code review runs on this team cost $0.50 to $2.00 a run in the last 30 days.');
    expect(rt.rtCostHint(sum, 'example', { template: 'blank' }, null)).toBe('');
  });
});
