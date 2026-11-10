// The Teams view's own state (v1's TED, TFORM, TTEST and the others) and its reads and writes.
// The state lives outside React, so a feed update or a tab change keeps the record and the form that is open.
import { create } from 'zustand';
import { getJson } from '../../live/api';
import { loadSummary, teamsAction } from '../../live/poll';
import type { J } from '../../model/base';
import { dispatch, store } from '../../store';
import { newTeamCheck, newTeamErrs, newTeamRecord, type NewTeam, teamApply, teamItemDraft, teamPatch, teamRetest } from './lib';

export type Rec = { name: string; ok: boolean; msg: string; rec?: J; gen?: string; tested?: J; secrets?: Record<string, string> };
export type Form = { team: string; item: string; d: J; msg?: string; ok?: boolean; busy?: boolean; warn?: string[] };
export type Test = { team: string; activate: boolean; busy?: boolean; data?: J; msg?: string; ok?: boolean; activated?: boolean };
export type Say = { team: string; ok: boolean; msg: string };
export type NewT = NewTeam & { errs: Record<string, string>; msg?: string; ok?: boolean; busy?: boolean };
export type People = { q: string; at: unknown; people: J[]; err: string };
// The People card: the rows as edited, the generation they loaded at, and the last save's Slack notes.
export type Ppl = { team: string; rows: J[]; gen: string; notes: J[]; msg: string; ok: boolean; busy?: boolean; canAdmin?: boolean; base: string; failed?: boolean };

type TS = {
  rec: Rec | null;
  loading: string;
  form: Form | null;
  test: Test | null;
  msg: Say | null;
  more: string[];
  audit: { team: string; rows: J[]; err: string } | null;
  arm: string;
  chans: { team: string; channels: J[] } | null;
  opts: J | null;
  people: People | null;
  ppl: Ppl | null;
  names: Record<string, J | null>;
  newt: NewT;
  json: { name: string; text: string; msg: string; ok: boolean } | null;
  // The team whose banner asked for Test and activate: the focus goes to Test once the record is in.
  tact: string;
  // The field that a failed create marks first: the form puts the focus on it.
  bad: string;
};

const NEWT0: NewT = { name: '', repo: '', stack: '', goal: '', errs: {} };
export const useTs = create<TS>(() => ({
  rec: null, loading: '', form: null, test: null, msg: null, more: [], audit: null, arm: '', chans: null,
  opts: null, people: null, ppl: null, names: {}, newt: NEWT0, json: null, tact: '', bad: '',
}));
const set = useTs.setState, get = useTs.getState;
const enc = encodeURIComponent;

// A write: the status and the JSON body, also on a failure, since the body carries error, out and warn.
export async function post(url: string, body: unknown): Promise<{ ok: boolean; status: number; j: J }> {
  try {
    const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return { ok: r.ok, status: r.status, j: await r.json().catch(() => ({})) };
  } catch {
    return { ok: false, status: 0, j: { error: 'the dashboard did not answer' } };
  }
}
const why = (r: { status: number; j: J }) => r.j?.error || String(r.status);

// After a write: the teams feed and the routines summary again, since the hub sends the feed only when it reads it.
export async function refreshTeams() {
  dispatch(teamsAction(await getJson('/api/teams')));
  await loadSummary({ dispatch, getState: store.getState, tails: () => [] });
}

export async function readRecord(n: string): Promise<Rec> {
  // Both reads at once: the secrets do not wait for the record.
  const [g, sr] = await Promise.all([getJson<J>(`/api/teams/${enc(n)}`), getJson<Record<string, string>>(`/api/teams/${enc(n)}/secrets`)]);
  if (!('data' in g)) return { name: n, ok: false, msg: g.error };
  const { generation, tested, ...rec } = g.data;
  delete rec.test_log;
  return { name: n, ok: true, msg: '', rec, gen: generation, tested, secrets: 'data' in sr ? sr.data : {} };
}
export async function loadRecord(n: string) {
  if (get().loading === n) return;
  set({ loading: n });
  const r = await readRecord(n);
  set((s) => (s.loading === n ? { loading: '', rec: r, json: s.json?.name === n ? { ...s.json, text: JSON.stringify(r.rec ?? {}, null, 2) } : s.json } : {}));
}

// A new team page, or another team: the open form, the message and the armed button go.
export function onTeam(team: string) {
  set((s) => ({
    form: s.form?.team === team ? s.form : null,
    msg: s.msg?.team === team ? s.msg : null,
    arm: s.arm.startsWith(`${team}:`) ? s.arm : '',
    people: s.form?.team === team ? s.people : null,
  }));
}

// A team's people (email, Slack user, GitHub username): that team's admins read and save them.
export async function loadPpl(team: string) {
  const g = await getJson<J>(`/api/teams/${enc(team)}/people`);
  set({ ppl: 'data' in g && Array.isArray(g.data.people) ? { team, rows: g.data.people, base: JSON.stringify(g.data.people ?? []), gen: String(g.data.generation ?? ''), notes: [], msg: '', ok: true, canAdmin: g.data.can_admin === true }
    : { team, rows: [], base: '[]', gen: '', notes: [], msg: 'data' in g ? '' : g.error, ok: false, failed: true } });
}
export const editPpl = (f: (rows: J[]) => J[]) => set((s) => (s.ppl ? { ppl: { ...s.ppl, rows: f(s.ppl.rows) } } : {}));
// The server fills slack from the email, so the client sends only the email, the GitHub username and the admin mark.
export async function savePpl() {
  const P = get().ppl;
  if (!P || P.busy) return;
  set({ ppl: { ...P, busy: true, msg: '' } });
  const rows = P.rows.filter((r) => String(r.email ?? '').trim() || r.slack).map((r) => ({ email: String(r.email ?? '').trim(), github: String(r.github ?? '').trim(), ...(r.email ? {} : { slack: r.slack }),
    ...Object.fromEntries(['admin', 'start', 'pr'].filter((k) => r[k]).map((k) => [k, true])) }));
  const r = await post(`/api/teams/${enc(P.team)}/people`, { people: rows, generation: P.gen });
  if (!r.ok) {
    return set((s) => ({ ppl: s.ppl && { ...s.ppl, busy: false, ok: false,
      msg: r.status === 409 ? 'Someone changed this team after you loaded it. Load the people again and redo your edit.' : why(r) } }));
  }
  const notes: J[] = r.j.notes ?? [];
  await loadPpl(P.team);
  set((s) => ({ ppl: s.ppl && { ...s.ppl, notes, ok: true, msg: notes.length ? 'Saved. Some rows have no Slack user:' : 'Saved.' } }));
  if (get().rec?.name === P.team) set({ rec: await readRecord(P.team) });
}

// The choices of the forms, the bot's channels and the names of people: each loads once.
export function loadOpts() {
  if (get().opts) return;
  set({ opts: { loading: true } });
  void getJson<J>('/api/teams/options').then((g) => set({ opts: 'data' in g ? g.data : { err: g.error } }));
}
export function loadChans(team: string) {
  if (get().chans?.team === team) return;
  set({ chans: { team, channels: [] } });
  void getJson<J>(`/api/teams/${enc(team)}/routine-channels`).then((g) => {
    if (get().chans?.team === team) set({ chans: { team, channels: 'data' in g && Array.isArray(g.data.channels) ? g.data.channels : [] } });
  });
}
export function loadNames(ids: string[]) {
  const miss = ids.filter((x) => /^[UW][A-Z0-9]{6,}$/.test(x) && !(x in get().names));
  if (!miss.length) return;
  set((s) => ({ names: { ...s.names, ...Object.fromEntries(miss.map((x) => [x, null])) } }));
  void getJson<J>(`/api/teams/people/${miss.slice(0, 200).join(',')}`).then((g) => {
    if ('data' in g) set((s) => ({ names: { ...s.names, ...Object.fromEntries((g.data.people ?? []).map((p: J) => [p.id, p])) } }));
  });
}
let pq = 0 as unknown as ReturnType<typeof setTimeout>;
export function searchPeople(q: string) {
  clearTimeout(pq);
  set((s) => ({ people: s.people ? { ...s.people, q } : { q, at: 0, people: [], err: '' } }));
  if (q.trim().length < 2) {
    set({ people: q ? { q, at: 0, people: [], err: '' } : null });
    return;
  }
  pq = setTimeout(async () => {
    const g = await getJson<J>(`/api/teams/people/${enc(q.trim())}`);
    if (get().people?.q !== q) return;
    const people: J[] = 'data' in g ? g.data.people ?? [] : [];
    set((s) => ({ people: { q, at: 'data' in g ? g.data.at ?? null : null, people, err: 'data' in g ? '' : g.error },
      names: { ...s.names, ...Object.fromEntries(people.map((p) => [p.id, p])) } }));
  }, 250);
}
export const personLabel = (names: Record<string, J | null>, id: string) => {
  const p = names[id];
  return p ? `${p.name}${p.handle && p.handle !== p.name ? ` (@${p.handle})` : ''}` : id;
};

// One form at a time: it opens with the record's values and loads what it offers.
export function openForm(team: string, item: string) {
  const rec = get().rec;
  if (!rec?.rec) return;
  const d = teamItemDraft(item, rec.rec);
  set({ form: { team, item, d }, people: null });
  if (item === 'access') loadChans(team);
  if (item === 'admins') loadNames(d.admins.map((a: J) => a.slack));
  if (['tools', 'caps', 'skills', 'boot', 'egress'].includes(item)) loadOpts();
}
export const editForm = (f: (d: J) => J) => set((s) => (s.form ? { form: { ...s.form, d: f(s.form.d) } } : {}));
export const closeForm = () => set({ form: null, people: null });

// Save one item: the record as loaded with only this item replaced, plus the generation. A runner change on
// an active team saves as a draft and starts a test that turns the team on again when it passes.
export async function saveForm() {
  const { form: f, rec: R, opts } = get();
  if (!f || f.busy || R?.name !== f.team || !R.rec) return;
  const rec = teamApply(R.rec, teamPatch(f, R.rec, f.team, opts)), retest = R.rec.status === 'active' && teamRetest(R.rec, rec);
  if (retest) rec.status = 'draft';
  set({ form: { ...f, busy: true, msg: '' } });
  const r = await post(`/api/teams/${enc(f.team)}`, { record: rec, generation: R.gen });
  if (!r.ok) {
    set((s) => ({ form: s.form && { ...s.form, busy: false, ok: false, warn: r.j.warn,
      msg: r.status === 409 ? 'Someone changed this team after you loaded it. Cancel, then redo your edit.' : why(r) } }));
    return;
  }
  set({ form: null, people: null, rec: await readRecord(f.team) });
  if (retest) await startTest(f.team, true);
  await refreshTeams();
}
// Check again: the validator's answer on the record with the draft repos, with its WARN lines.
export async function checkRepos() {
  const { form: f, rec: R, opts } = get();
  if (!f || !R?.rec) return;
  const r = await post('/api/teams/validate', { record: teamApply(R.rec, teamPatch(f, R.rec, f.team, opts)) });
  set((s) => ({ form: s.form && { ...s.form, ok: r.ok, msg: r.ok ? 'The repos pass their checks.' : why(r),
    warn: [...(r.j.warn ?? []), ...String(r.j.out ?? '').split('\n').filter((l) => l.startsWith('WARN: '))] } }));
}

// The test of a team: started here, followed by the team-test frames, or by a read every 10 s while polling.
export async function readTest(team: string) {
  const g = await getJson<J>(`/api/teams/${enc(team)}/test`);
  set((s) => ({ test: s.test?.team === team ? { ...s.test, data: 'data' in g ? g.data : s.test.data } : { team, activate: false, data: 'data' in g ? g.data : undefined } }));
}
export async function startTest(team: string, activate: boolean) {
  set((s) => ({ test: { team, activate, busy: true, data: s.test?.team === team ? s.test.data : undefined } }));
  const r = await post(`/api/teams/${enc(team)}/test`, {});
  // 409: a test runs already, which is fine.
  if (!r.ok && r.status !== 409) {
    set((s) => ({ test: s.test && { ...s.test, busy: false, ok: false, msg: why(r) } }));
    return;
  }
  set((s) => ({ test: s.test && { ...s.test, busy: false } }));
  await readTest(team);
}
export async function stopTest(team: string) {
  set((s) => ({ test: s.test && { ...s.test, busy: true } }));
  const r = await post(`/api/teams/${enc(team)}/test/stop`, {});
  set((s) => ({ test: { ...(s.test ?? { team, activate: false }), busy: false, ok: r.ok, msg: r.ok ? r.j.out : why(r) } }));
}
// A pass activates the team once, when the admin asked for it.
export async function activateOnPass(team: string) {
  const t = get().test;
  if (t?.team !== team || !t.activate || t.activated || get().rec?.name !== team || get().rec?.rec?.status === 'active') return;
  set({ test: { ...t, activated: true } });
  const r = await post(`/api/teams/${enc(team)}/status`, { status: 'active' });
  set((s) => ({ test: s.test && { ...s.test, ok: r.ok, msg: r.ok ? 'Passed, and the team is active.' : `Passed, but Activate did not work: ${why(r)}` } }));
  set({ rec: await readRecord(team) });
  await refreshTeams();
}

// Turn off and Delete arm on the first click; the arm goes after 10 s or when the button loses the focus.
let armT = 0 as unknown as ReturnType<typeof setTimeout>;
export function arm(k: string) {
  clearTimeout(armT);
  set({ arm: k });
  if (k) armT = setTimeout(() => set({ arm: '' }), 10000);
}
export async function setStatus(team: string, status: 'active' | 'disabled') {
  if (status === 'disabled' && get().arm !== `${team}:disabled`) return arm(`${team}:disabled`);
  arm('');
  const r = await post(`/api/teams/${enc(team)}/status`, { status });
  set({ msg: { team, ok: r.ok, msg: r.ok ? (status === 'active' ? 'The team is active.' : 'The team is off.') : why(r) }, rec: await readRecord(team) });
  await refreshTeams();
}
export async function deleteTeam(team: string) {
  if (get().arm !== `${team}:delete`) return arm(`${team}:delete`);
  arm('');
  const r = await post(`/api/teams/${enc(team)}/delete`, {});
  if (!r.ok) return set({ msg: { team, ok: false, msg: why(r) } });
  set({ rec: null, form: null });
  location.hash = '#teams';
  await refreshTeams();
}
export async function setSecret(team: string, secret: string, value: string) {
  if (!value) return false;
  const r = await post(`/api/teams/${enc(team)}/secret`, { secret, value });
  set({ msg: { team, ok: r.ok, msg: r.ok ? r.j.out : why(r) }, rec: await readRecord(team) });
  return true;
}
export async function loadAudit(team: string) {
  const g = await getJson<J[]>(`/api/teams/${enc(team)}/audit`);
  set({ audit: { team, rows: 'data' in g && Array.isArray(g.data) ? g.data : [], err: 'data' in g ? '' : g.error } });
}
export const toggleMore = (k: string, open: boolean) => set((s) => ({ more: open ? [...new Set([...s.more, k])] : s.more.filter((x) => x !== k) }));

// The JSON editor: every field at once, for an expert. Save checks the generation that loaded.
export function openJson(name: string) {
  const r = get().rec;
  set({ json: { name, text: JSON.stringify(r?.name === name ? r.rec ?? {} : {}, null, 2), msg: '', ok: true } });
}
export async function jsonAct(act: 'validate' | 'save') {
  const e = get().json, R = get().rec;
  if (!e) return;
  let record: J;
  try {
    record = JSON.parse(e.text);
  } catch (err) {
    return set({ json: { ...e, msg: `Not JSON: ${(err as Error).message}`, ok: false } });
  }
  const r = act === 'validate' ? await post('/api/teams/validate', { record }) : await post(`/api/teams/${enc(e.name)}`, { record, generation: R?.name === e.name ? R.gen : '' });
  if (!r.ok) {
    return set((s) => ({ json: s.json && { ...s.json, ok: false,
      msg: (r.status === 409 ? 'Someone changed this team after you loaded it. Load the record again and redo your edit.\n' : '') + why(r) } }));
  }
  if (act === 'validate') return set((s) => ({ json: s.json && { ...s.json, ok: true, msg: r.j.out || 'valid' } }));
  const rec = await readRecord(e.name);
  set({ rec, json: { name: e.name, text: JSON.stringify(rec.rec ?? {}, null, 2), msg: r.j.out ?? '', ok: true } });
  await refreshTeams();
}

// New team: the client checks first, then the server judges every rule; its lines go to their fields.
export const editNew = (p: Partial<NewT>) => set((s) => ({ newt: { ...s.newt, ...p, errs: { ...s.newt.errs, ...Object.fromEntries(Object.keys(p).map((k) => [k, ''])) } } }));
export async function createTeam() {
  const d = get().newt;
  if (d.busy) return;
  const errs = newTeamCheck(d);
  if (Object.keys(errs).length) return set({ newt: { ...d, errs, msg: 'Check the marked fields.', ok: false }, bad: Object.keys(errs)[0]! });
  set({ newt: { ...d, busy: true, errs: {}, msg: '' } });
  const rec = newTeamRecord(d), r = await post('/api/teams', { record: rec });
  if (!r.ok) {
    const x = r.status === 409 ? { errs: { name: 'A team with this name already exists.' }, summary: '' } : newTeamErrs(why(r));
    return set({ newt: { ...d, busy: false, errs: x.errs, msg: x.summary || 'Check the marked fields.', ok: false }, bad: Object.keys(x.errs)[0] ?? 'name' });
  }
  set({ newt: NEWT0, rec: await readRecord(rec.name) });
  location.hash = `#teams/${rec.name}/settings`;
  await refreshTeams();
}
export const clearBad = () => set({ bad: '' });
