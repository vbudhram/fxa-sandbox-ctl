// The Memory tab of a team page: the team's facts from the memory repo's main branch (section 6.7).
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BarList } from '../../../charts';
import { postJson } from '../../../live/api';
import type { J } from '../../../model/base';
import { teamName } from '../../../model/teams';
import { readMemory, store, useApp } from '../../../store';
import { Card, EmptyBox, Tag } from '../../../ui';
import { Field, INPUT, Opt, bad, focusLater } from '../routines/parts';

export const MEM_KINDS = ['convention', 'trap', 'command', 'decision', 'owner-area'];
const MEM_ERR = /^(scope|kind|text|why|path|terms|cites|cite[123]|anchor[123]|entry): (.*)$/;
type Draft = { scope: string; kind: string; text: string; why: string; path: string; terms: string; cites: { cite: string; anchor: string }[] };
type MemForm = { id?: string; v?: string; d: Draft; errs: Record<string, string>; saving?: boolean };

// The form of one fact, from an entry or empty; a repo fact has one cite, a team fact up to three.
const memDraft = (e: J | null, t: J): Draft => e
  ? { scope: e.scope, kind: e.kind, text: e.text, why: e.why, path: e.path, terms: e.terms, cites: e.cites.map((c: J) => ({ ...c })) }
  : { scope: 'team', kind: 'system', text: '', why: '', path: '', terms: '', cites: [{ cite: `${(t.repos ?? [])[0]?.slug ?? 'owner/repo'}:path:1`, anchor: '' }] };
// The validator answers one "field: reason" line for each bad field; the rest is the summary.
export function memErrs(text: unknown) {
  const errs: Record<string, string> = {}, other: string[] = [];
  for (const l of String(text || '').split('\n').map((x) => x.replace(/^ERROR: /, '').trim()).filter(Boolean)) {
    const m = l.match(MEM_ERR);
    if (m) errs[m[1]!] ??= m[2]!; else other.push(l);
  }
  return { errs, other };
}
// INDEX.md lists only the facts confirmed in the last 90 days (lib/memory.sh _memory_index); fxa-mem still finds the rest.
export const memCut = (now: number) => new Date(now - 90 * 86400000).toISOString().slice(0, 10);
export const memMatch = (e: J, q: string) => !q || [e.text, e.why, e.kind, e.scope, ...e.cites.map((c: J) => c.cite)].join(' ').toLowerCase().includes(q.toLowerCase());
const memWhere = (sc: string) => (sc === 'team' ? 'Team' : sc);

export function MemoryTab({ team }: { team: J }) {
  const admin = useApp((s) => !!s.viewer.admin);
  // Q10: the server lets only a TEAM_ADMINS admin read team memory, so a team record admin sees this text.
  if (!admin) return <Card><p className="m-0">Only a dashboard admin (TEAM_ADMINS) can see and change team memory. A team record admin cannot.</p></Card>;
  return <Memory key={team.profile} team={team} />;
}
export default MemoryTab;

function Memory({ team }: { team: J }) {
  const p: string = team.profile, base = `/api/teams/${encodeURIComponent(p)}/memory`;
  const d = useApp((s) => s.teamsUi.memory[p]) as J | undefined;
  const [err, setErr] = useState('');
  const [q, setQ] = useState('');
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null);
  const [form, setForm] = useState<MemForm | null>(null);
  const [formMsg, setFormMsg] = useState('');
  const [arm, setArm] = useState('');
  const [now] = useState(() => Date.now());
  const saving = useRef(false);

  const errOf = (g: Awaited<ReturnType<typeof readMemory>>) => ('error' in g ? g.error || 'the dashboard did not answer' : '');
  const load = useCallback(async () => setErr(errOf(await readMemory(p))), [p]);
  // Reload on demand, not on each poll: a fact changes only by a run or by a save here.
  useEffect(() => {
    let on = true;
    void readMemory(p).then((g) => on && setErr(errOf(g)));
    return () => { on = false; };
  }, [p]);
  const row = useCallback((id?: string) => ((store.getState().teamsUi.memory[p] as J | undefined)?.entries ?? []).find((e: J) => e.id === id), [p]);
  const say = useCallback((text: string, ok: boolean) => { setMsg({ text, ok }); focusLater('mem-msg'); }, []);

  // Stable while the form changes, so a keystroke in the form does not repaint the table.
  const del = useCallback(async (e: J) => {
    if (arm !== e.id) { setArm(e.id); return; }
    setArm('');
    const g = await postJson<J>(`${base}/${e.id}/delete`, { v: e.v, scope: e.scope });
    await load();
    say('data' in g ? `Deleted ${e.id}. ${warn(g.data?.out) ? 'The push to GitHub failed; the next save pushes it.' : ''}`.trim() : g.error || 'the delete did not go through', 'data' in g);
  }, [arm, base, load, say]);
  async function save() {
    if (!form || saving.current) return;
    saving.current = true;
    const f = form;
    setForm({ ...f, saving: true });
    const g = await postJson<J>(f.id ? `${base}/${f.id}` : base, { entry: f.d, ...(f.id ? { v: f.v } : {}) });
    saving.current = false;
    if ('data' in g) {
      setForm(null); setFormMsg('');
      await load();
      const out = String(g.data?.out ?? '');
      return say(`Saved ${out.match(/mem-[0-9a-f]{8}/)?.[0] ?? ''}. ${warn(out) ? 'The push to GitHub failed; the next save pushes it.' : 'New runners get it.'}`, true);
    }
    const { errs, other } = memErrs(g.error);
    // A 409: keep the draft and take the current version, so a second Save replaces their change on purpose.
    let v = f.v;
    if (g.status === 409) { await load(); v = row(f.id)?.v ?? v; }
    setForm({ ...f, v, errs, saving: false });
    setFormMsg([Object.keys(errs).length ? 'Fix the marked fields.' : '', ...other].filter(Boolean).join(' ') || `the save did not go through (${g.status || 'no answer'})`);
    const first = Object.keys(errs)[0];
    focusLater(first ? (first === 'cites' || first === 'entry' ? 'mem-cites' : `mem-${first}`) : 'mem-form-h');
  }
  const open = useCallback((e: J | null) => { setForm({ id: e?.id, v: e?.v, d: memDraft(e, team), errs: {} }); setFormMsg(''); setArm(''); focusLater('mem-form-h'); }, [team]);
  const edit = useCallback((id: string) => open(row(id)), [open, row]);
  const entries: J[] | undefined = d?.entries;
  const shown = useMemo(() => (entries ?? []).filter((e) => memMatch(e, q)), [entries, q]);
  const own = useMemo(() => shown.filter((e) => !e.dep), [shown]), dep = useMemo(() => shown.filter((e) => e.dep), [shown]);

  if (err && !d) return <Card><p className="m-0">The team memory did not load: {err}</p><p className="hint">It tries again when you press Reload.</p><button type="button" onClick={() => void load()}>Reload</button></Card>;
  if (!d) return <EmptyBox>Loading the team memory…</EmptyBox>;
  if (!d.on) return <Card><p className="m-0">Team memory is off on this host.</p></Card>;
  const all = entries ?? [], n = all.filter((e) => !e.dep).length;
  const tbl = (rows: J[]) => <MemTable rows={rows} cut={memCut(now)} busy={!!form} arm={arm} edit={edit} del={del} setArm={setArm} />;
  return (
    <div data-memory className="flex flex-col gap-s4">
      {form && <MemFormCard team={team} d={d} f={form} msg={formMsg} setForm={setForm} save={() => void save()} cancel={() => { setForm(null); setFormMsg(''); }} />}
      <Card>
        <div className="flex flex-col gap-s3">
          <div className="flex flex-wrap items-start gap-s3">
            <p className="hint m-0 flex-1">{n} fact{n === 1 ? '' : 's'} for this team and its repos, from main. A repo fact is shared by every team on that repo. Runners that start after a change get it; running sessions keep their copy.</p>
            <button type="button" onClick={() => void load()}>Reload</button>
            {!form && <button type="button" data-mem-new onClick={() => open(null)}>Add a fact</button>}
          </div>
          <p id="mem-msg" className={msg && !msg.ok ? 'm-0 text-sub font-semibold text-warn' : 'hint m-0'} data-mem-msg role="status" tabIndex={-1}>{msg?.text ?? ''}</p>
          {all.length > 0 && <input className={INPUT} data-mem-q aria-label="Filter the facts" placeholder="Filter by text, kind, repo or cite" value={q} onChange={(e) => setQ(e.target.value)} />}
          {n ? (own.length ? tbl(own) : <EmptyBox>No fact matches the filter.</EmptyBox>) : <EmptyBox>No team memory yet. A run adds a fact when its cites hold on main, or add one here.</EmptyBox>}
          {dep.length > 0 && (
            <details data-mem-dep open={q ? true : undefined}>
              <summary className="cursor-pointer text-link">From dependency repos <span className="n text-faint">{dep.length}</span></summary>
              <p className="hint">Agents on this team read these too. They are read-only here: the team that works on {[...new Set(dep.map((e) => e.scope))].join(', ')} keeps them.</p>
              {tbl(dep)}
            </details>
          )}
        </div>
      </Card>
      {all.length > 0 && <MemCharts entries={all} cut={now} />}
    </div>
  );
}

const warn = (out: unknown) => /WARN/.test(String(out ?? ''));

type TableProps = { rows: J[]; cut: string; busy: boolean; arm: string; edit: (id: string) => void; del: (e: J) => Promise<void>; setArm: (id: string) => void };
// The facts table; memo: it repaints only when its rows, the form's presence or the armed Delete change.
const MemTable = memo(function MemTable({ rows, cut, busy, arm, edit, del, setArm }: TableProps) {
  return (
    <div className="overflow-x-auto">
      <table className="mtab w-full border-collapse text-sub">
        <thead><tr>{['Where', 'Kind', 'Fact', 'Cite', 'Confirmed'].map((h) => <th key={h} scope="col" className="border-b border-line px-s2 py-s1 text-left font-semibold text-dim">{h}</th>)}<th scope="col" className="border-b border-line"><span className="vh">Actions</span></th></tr></thead>
        <tbody>{rows.map((e) => (
          <tr key={e.id} data-mem={e.id} className="align-top">
            <td className="border-b border-line px-s2 py-s1">{e.scope === 'team' ? 'Team' : <span className="font-mono">{e.scope}</span>}</td>
            <td className="border-b border-line px-s2 py-s1"><Tag label={e.kind} sq /></td>
            <td className="border-b border-line px-s2 py-s1">
              <div className="mtext">{e.text}</div>{e.why && <div className="hint">{e.why}</div>}
              <div className="mt-s1 flex flex-wrap gap-s1">
                {e.person && <Tag label="person" tone="info" />}
                {e.confirmed < cut && <Tag label="not in index" tone="warn" title="Not confirmed in 90 days: fxa-mem ranks it last" />}
                {e.taint && <Tag label="tainted run" tone="warn" />}
              </div>
            </td>
            <td className="border-b border-line px-s2 py-s1">{e.cites.map((c: J) => <div key={c.cite} className="font-mono">{c.cite}</div>)}</td>
            <td className="border-b border-line px-s2 py-s1 whitespace-nowrap">{e.confirmed || '—'}</td>
            <td className="border-b border-line px-s2 py-s1 whitespace-nowrap">{!e.dep && <span className="flex gap-s1">
              <button type="button" data-mem-edit={e.id} aria-label={`Edit ${e.id}`} disabled={busy} onClick={() => edit(e.id)}>Edit</button>
              <button type="button" data-mem-del={e.id} aria-label={arm === e.id ? `Delete ${e.id}? Click again` : `Delete ${e.id}`} disabled={busy}
                className={arm === e.id ? 'text-bad' : undefined} onClick={() => void del(e)} onBlur={() => arm === e.id && setArm('')}>{arm === e.id ? 'Delete it?' : 'Delete'}</button>
            </span>}</td>
          </tr>
        ))}</tbody>
      </table>
    </div>
  );
});

// What the memory holds: facts by kind and by scope, and how long ago each was confirmed, against the 90-day index cutoff.
const MemCharts = memo(function MemCharts({ entries, cut }: { entries: J[]; cut: number }) {
  const count = (k: (e: J) => string) => Object.entries(entries.reduce<Record<string, number>>((a, e) => { a[k(e)] = (a[k(e)] ?? 0) + 1; return a; }, {}))
    .sort((a, b) => b[1] - a[1]).map(([name, value]) => ({ name, value }));
  const age = (e: J) => {
    const t = Date.parse(e.confirmed);
    if (!(t > 0)) return 'no date';
    const dd = (cut - t) / 86400000;
    return dd < 30 ? 'under 30 days' : dd < 60 ? '30 to 60 days' : dd <= 90 ? '60 to 90 days' : 'over 90 days: not in the index';
  };
  const order = ['under 30 days', '30 to 60 days', '60 to 90 days', 'over 90 days: not in the index', 'no date'];
  const ages = count(age).sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name));
  return (
    <Card>
      <h3 className="m-0 mb-s3">What the memory holds</h3>
      <div className="grid gap-s4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))' }}>
        <div><h4 className="m-0 mb-s2 text-sub">By kind</h4><BarList label="Facts by kind" items={count((e) => e.kind)} /></div>
        <div><h4 className="m-0 mb-s2 text-sub">By scope</h4><BarList label="Facts by scope" items={count((e) => memWhere(e.scope))} color="chart-2" /></div>
        <div><h4 className="m-0 mb-s2 text-sub">Last confirmed</h4><BarList label="Facts by the age of their last confirmation; the index keeps only the last 90 days" items={ages} color="chart-3" /></div>
      </div>
    </Card>
  );
});

function MemFormCard({ team, d, f, msg, setForm, save, cancel }: { team: J; d: J; f: MemForm; msg: string; setForm: (f: (x: MemForm | null) => MemForm | null) => void; save: () => void; cancel: () => void }) {
  const x = f.d, e = f.errs, team1 = x.scope === 'team', kinds = team1 ? [...MEM_KINDS, 'system'] : MEM_KINDS, max = team1 ? 3 : 1;
  const scopes = ['team', ...(team.repos ?? []).map((r: J) => r.slug).filter((s: string) => !(d.dep ?? []).includes(s))];
  const set = (patch: Partial<Draft>) => setForm((y) => {
    if (!y) return y;
    const n = { ...y.d, ...patch };
    // A repo fact takes one cite in that repo, and no "system" kind.
    if (patch.scope && patch.scope !== 'team') { n.cites = n.cites.slice(0, 1); if (n.kind === 'system') n.kind = 'trap'; }
    return { ...y, d: n };
  });
  const setCite = (i: number, k: 'cite' | 'anchor', v: string) => set({ cites: x.cites.map((c, j) => (j === i ? { ...c, [k]: v } : c)) });
  const inp = (k: 'text' | 'why' | 'path' | 'terms', label: React.ReactNode, hint: string, maxLength: number) => (
    <Field id={`mem-${k}`} label={label} hint={hint || undefined} err={e[k]}>
      <input id={`mem-${k}`} className={INPUT} data-mem-f={k} maxLength={maxLength} value={x[k] ?? ''} onChange={(ev) => set({ [k]: ev.target.value })} {...bad(`mem-${k}`, e[k])} />
    </Field>
  );
  const grid = { gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' };
  return (
    <Card>
      <div data-mem-form className="flex flex-col gap-s3">
        <h3 id="mem-form-h" tabIndex={-1} className="m-0">{f.id ? 'Edit a fact' : 'Add a fact'}</h3>
        <p className="hint m-0">Agents read this before they work on {team1 ? `any repo of ${teamName(team)}` : <span className="font-mono">{x.scope}</span>}{team1 ? '' : ', in every team that has it'}. Write one fact about the code, and cite the line that shows it.</p>
        <div className="grid gap-s3" style={grid}>
          <Field id="mem-scope" label="Where" err={e.scope}>
            <select id="mem-scope" className={INPUT} data-mem-f="scope" disabled={!!f.id} value={x.scope} onChange={(ev) => set({ scope: ev.target.value })} {...bad('mem-scope', e.scope)}>
              {[...new Set([...scopes, x.scope])].map((sc) => <option key={sc} value={sc}>{memWhere(sc)}</option>)}
            </select>
          </Field>
          <Field id="mem-kind" label="Kind" err={e.kind}>
            <select id="mem-kind" className={INPUT} data-mem-f="kind" value={x.kind} onChange={(ev) => set({ kind: ev.target.value })} {...bad('mem-kind', e.kind)}>
              {kinds.map((k) => <option key={k}>{k}</option>)}
            </select>
          </Field>
        </div>
        {inp('text', 'Fact', 'One line, 300 characters at most.', 300)}
        {inp('why', <>Why <Opt /></>, 'What went wrong without it.', 300)}
        <div className="grid gap-s3" style={grid}>
          {inp('path', <>Paths <Opt /></>, 'A glob, such as packages/fxa-settings/*.', 200)}
          {inp('terms', <>Search terms <Opt /></>, '', 200)}
        </div>
        <fieldset id="mem-cites" tabIndex={-1} className="m-0 flex flex-col gap-s2 border-0 p-0" {...bad('mem-cites', e.cites || e.entry)}>
          <legend className="mb-s2 text-sub font-semibold">{max === 1 ? 'Cite' : 'Cites'}</legend>
          {x.cites.map((c, i) => (
            <div key={i} className="grid gap-s3" style={grid}>
              <Field id={`mem-cite${i + 1}`} label="owner/repo:path:line" err={e[`cite${i + 1}`]}>
                <input id={`mem-cite${i + 1}`} className={`${INPUT} font-mono`} data-mem-cite={i} data-part="cite" value={c.cite} onChange={(ev) => setCite(i, 'cite', ev.target.value)} {...bad(`mem-cite${i + 1}`, e[`cite${i + 1}`])} />
              </Field>
              <Field id={`mem-anchor${i + 1}`} label="Code at that line" err={e[`anchor${i + 1}`]}>
                <input id={`mem-anchor${i + 1}`} className={`${INPUT} font-mono`} data-mem-cite={i} data-part="anchor" maxLength={120} value={c.anchor} onChange={(ev) => setCite(i, 'anchor', ev.target.value)} {...bad(`mem-anchor${i + 1}`, e[`anchor${i + 1}`])} />
              </Field>
            </div>
          ))}
          <p className="hint m-0">The save checks that this code is within 3 lines of the cite on the repo's default branch.</p>
          {x.cites.length < max && <button type="button" className="self-start" data-mem-addcite onClick={() => set({ cites: [...x.cites, { cite: '', anchor: '' }] })}>Add a cite</button>}
          {(e.cites || e.entry) && <p className="m-0 text-sub font-semibold text-warn" id="mem-cites-err">{e.cites || e.entry}</p>}
        </fieldset>
        {msg && <p className="m-0 text-sub font-semibold text-warn" role="alert">{msg}</p>}
        <div className="flex flex-wrap gap-s2">
          <button type="button" data-mem-save disabled={!!f.saving} onClick={save}>{f.saving ? 'Saving…' : f.id ? 'Save' : 'Add'}</button>
          <button type="button" data-mem-cancel onClick={cancel}>Cancel</button>
        </div>
      </div>
    </Card>
  );
}
