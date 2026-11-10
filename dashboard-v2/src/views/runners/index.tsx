// Sandboxes (#runners): the cards, the runner timeline and slot grid, the list, Needs a fix, Recently completed and the details.
import { memo, useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { Boundary } from '../../app/parts';
import { MODEL, useParts, useStore } from '../../app/store';
import type { ViewChunk } from '../../app/views';
import { jiraHref, plainMd, prHref, short, usd } from '../../format';
import { getJson } from '../../live/api';
import { AGENTS, KEY_RE, SS, TEAM_RE, type J } from '../../model/base';
import { sbRows, slotList } from '../../model/floor';
import { jiraSite } from '../../model/pipeline';
import { sessHref, sessTabOf } from '../../model/sessions';
import { teamLabel } from '../../model/teams';
import { format } from '../../router';
import type { Store } from '../../store/types';
import { Card, EmptyBox, Kv, Meter, Tag } from '../../ui';
import { cx } from '../../ui/tone';
import { BootSteps, DoneScatter, SlotGrid, Timeline } from './charts';
import {
  ageLine, doneRows, doneSrc, endedTxt, forTxt, freeLine, isAdmin, num as n, sbCards, selRow, slotGrid, tabHas, tabOf, upFor, whereTxt, type Tab,
} from './model';
import { runBadge } from '../shared/stats';
import './runners.css';

const ADMIN_ONLY = 'Only a team admin can see routine runs.';

// A row button sets the selection in the hash; below 1280 px the details open as a drawer, as in v1.
function pick(s: Store, id: string) {
  location.hash = format({ ...s.route, sel: id, rid: '' });
  const b = document.getElementById('tright');
  if (matchMedia('(max-width:1280px)').matches && b?.getAttribute('aria-pressed') !== 'true') b?.click();
}
// A row that skips its repaint keeps its first onPick, so the pick reads the latest store.
function usePick() {
  const st = useStore();
  return useCallback((id: string) => pick(st.getState(), id), [st]);
}

function Cards({ s }: { s: Store }) {
  const c = sbCards(s);
  const box = (lbl: string, body: ReactNode) => <Card sm className="sb-card"><div className="lbl">{lbl}</div>{body}</Card>;
  const strip = (label: string, segs: { cls: string; title: string }[]) => (
    <div className="sbstrip" role="img" aria-label={label}>{segs.map((g, i) => <i key={i} className={g.cls} title={g.title} />)}</div>
  );
  const p = c.pipe, q = c.sess, k = c.cost;
  return (
    <div id="sb-cards">
      {box('Pipeline slots · GCE', p.unknown ? <><div className="big">?</div><div className="sub">Slots unknown: the agents feed is not current.</div></> : <>
        <div className="big">{p.busy} of {p.total} busy</div>
        <div className="sub">{p.slotsUnk ? 'free slots unknown' : `${p.free} free${p.held ? ` · ${p.held} held` : ''}`}</div>
        {strip(`${p.busy} busy, ${p.slotsUnk ? 'free slots unknown' : `${p.free} free, ${p.held} held`}`, p.segs)}
        <div className="sub">{p.line}</div><div className="sub">{p.more}</div>
      </>)}
      {box('Session slots', q.unknown ? <><div className="big">?</div><div className="sub">Session slots unknown: the agents feed is not current.</div></> : <>
        <div className="big">{q.busy} of {q.cap} busy</div>
        {strip(`${q.busy} of ${q.cap} session slots busy${q.gce ? `, ${q.gce} on GCE` : ''}`, q.segs)}
        {q.gce ? <div className="sub">{q.gce} on GCE</div> : null}<div className="sub">{q.line}</div>{q.host && <div className="sub">{q.host}</div>}
      </>)}
      {box('Cost', k.unknown ? <><div className="big">?</div><div className="sub">Cost unknown: the agents feed is not current.</div></> : <>
        <Kv label="Manager" value={k.manager} />
        {k.host && <><Kv label="Firecracker host" value={k.host} /><Kv label="Host use" value={k.hostUse} /></>}
        <Kv label="GCE sandboxes now" value={k.gceNow} />
        <div className="sub"><a href="#stats/spend">LLM spend is on Stats ›</a></div>
      </>)}
    </div>
  );
}

function Live({ s, tab }: { s: Store; tab: Tab }) {
  const r = sbRows(s), admin = isAdmin(s), onPick = usePick();
  if (!AGENTS(s) || r.err || (tab === 'routines' && !admin)) return null;
  const g = slotGrid(s), rows = [...r.live, ...r.fix].filter((x: J) => tabHas(tab, x));
  return (
    <Card>
      <Timeline rows={rows} admin={admin} sel={s.route.sel} onPick={onPick} />
      <SlotGrid pool={g.pool} sess={g.sess} showPool={tab === 'all' || tab === 'pipeline'} showSess={tab === 'all' || tab === 'slack'} />
    </Card>
  );
}

const bar = (x: J) => {
  if (x.age == null || !x.cap) return null;
  const over = x.age >= x.cap, txt = `${short(x.age)} of ${short(x.cap)}${over ? ' · over cap' : ''}`;
  return <span className={cx(over && 'over')}><span className="mt"><Meter pct={(x.age / x.cap) * 100} tone={over ? 'bad' : 'info'} label={txt} /></span>{txt}</span>;
};
type RowProps = { x: J; admin: boolean; on: boolean; stale: boolean; team: string; onPick: (id: string) => void };
// The model builds new row objects on each feed frame, so the row data is compared by value.
const sameRow = (a: RowProps, b: RowProps) =>
  a.admin === b.admin && a.on === b.on && a.stale === b.stale && a.team === b.team && a.onPick === b.onPick && (a.x === b.x || JSON.stringify(a.x) === JSON.stringify(b.x));
const Row = memo(function Row({ x, admin, on, stale, team, onPick }: RowProps) {
  const f = forTxt(x, admin);
  return (
    <tr className={cx(x.fix && 'fixr', !x.fix && x.fault && 'bad', on && 'sel')} aria-current={on ? 'true' : undefined}>
      <td><button type="button" data-sbsel={x.id} aria-label={`${f}, details`} onClick={() => onPick(x.id)}>{f}</button></td>
      <td className="what">{plainMd(x.title)}</td>
      <td>{x.fix ? x.fix.why : x.state}{x.fix?.cmd ? <code>{x.fix.cmd}</code> : x.fix?.steps && !stale ? <span className="steps">{x.fix.steps}</span> : null}</td>
      <td>{team}</td><td>{whereTxt(x)}</td><td>{x.fix ? null : bar(x)}</td><td className="num">{x.cost != null ? usd(x.cost) : ''}</td>
    </tr>
  );
}, sameRow);

function List({ s, tab }: { s: Store; tab: Tab }) {
  const g = AGENTS(s), onPick = usePick();
  if (!g) return <div id="sb-list" tabIndex={-1}><EmptyBox>Loading…</EmptyBox></div>;
  const r = sbRows(s), admin = isAdmin(s), sel = s.route.sel;
  if (r.err) return <div id="sb-list" tabIndex={-1}><EmptyBox>Sandboxes unknown: the agents feed could not be read.</EmptyBox></div>;
  if (tab === 'routines' && !admin) return <div id="sb-list" tabIndex={-1}><EmptyBox>{ADMIN_ONLY}</EmptyBox></div>;
  const row = (x: J) => <Row key={x.id} x={x} admin={admin} on={x.id === sel} stale={!!r.stale} team={x.team ? teamLabel(s, x.team) : ''} onPick={onPick} />;
  const list = (xs: J[], cap: string) => (
    <div className="sbl">
      <table className="sbt">
        <caption className="vh">{cap}</caption>
        <thead><tr>{['For', 'What', 'Now', 'Team', 'Where', 'Time'].map((h) => <th key={h} scope="col">{h}</th>)}<th scope="col" className="num">LLM cost</th></tr></thead>
        <tbody>{xs.map(row)}</tbody>
      </table>
    </div>
  );
  const live = r.live.filter((x: J) => tabHas(tab, x)), fix = r.fix.filter((x: J) => tabHas(tab, x));
  const none = !(g.pool ?? []).length && !(g.free_slots ?? []).length && !r.live.length ? 'No sandbox slot is set up, and no Slack session is live.' : 'No sandbox runs now.';
  const free = freeLine(r, tab, slotList), a = s.feeds.agents?.ageSeconds, age = ageLine(s);
  return (
    <div id="sb-list" tabIndex={-1}>
      {r.stale && <p className="sbstale">The agents feed is {Math.round((a ?? 0) / 60)} min old: these rows may be out of date.</p>}
      {live.length ? list(live, 'Sandboxes that run now') : r.stale ? null : <EmptyBox>{none}</EmptyBox>}
      {fix.length > 0 && <><h3 className="sbh">Needs a fix · {fix.length}</h3>{list(fix, 'Sandboxes that need a fix')}</>}
      {free && <><h3 className="sbh">Free slots</h3><p className="sbfree">{free}</p></>}
      {age && <p className="sbage">{age}</p>}
    </div>
  );
}

// The last Recently completed answer per view visit; a failed read keeps the runs of the same source.
type DoneState = { runs: J[] | null; err: string | null; at: number | null; src: string };
let DONE: DoneState | null = null, SEQ = 0;
async function loadDone(src: string): Promise<DoneState | null> {
  const seq = ++SEQ;
  const g = await getJson<{ runs?: J[]; error?: string }>(`/api/runs/recent?ended=1&limit=100${src ? `&src=${src}` : ''}`);
  const err = !('data' in g) ? g.error : !g.data || !Array.isArray(g.data.runs) ? 'the answer has no runs' : g.data.error || null;
  // An older answer that comes after a newer one is dropped.
  if (seq !== SEQ) return null;
  const same = DONE?.src === src;
  DONE = !err && 'data' in g ? { runs: g.data.runs!, err: null, at: Date.now(), src } : { runs: same ? DONE!.runs : null, err, at: same ? DONE!.at : null, src };
  return DONE;
}
const agoMs = (at: number | null) => short(Math.round((Date.now() - (at ?? Date.now())) / 1000));

function Done({ s, tab }: { s: Store; tab: Tab }) {
  const src = doneSrc(tab), admin = isAdmin(s);
  const [d, setD] = useState(DONE);
  const pending = useRef<ReturnType<typeof setTimeout> | null>(null);
  // A session that starts or ends, or a new agents read, reads the runs again, at most once in 5 s.
  const sessKey = SS(s).map((x) => `${x.key}:${x.state}`).join(), at = s.feeds.agents?.fetchedAt;
  useEffect(() => {
    let on = true;
    void loadDone(src).then((x) => { if (on && x) setD(x); });
    return () => { on = false; };
  }, [src]);
  useEffect(() => {
    if (pending.current) return;
    pending.current = setTimeout(() => {
      pending.current = null;
      void loadDone(src).then((x) => { if (x) setD(x); });
    }, 5000);
  }, [sessKey, at, src]);
  useEffect(() => () => { if (pending.current) clearTimeout(pending.current); }, []);
  const h = <h2>Recently completed</h2>;
  if (tab === 'routines' && !admin) return <Card><div id="sb-done">{h}<EmptyBox>{ADMIN_ONLY}</EmptyBox></div></Card>;
  if (!d || d.src !== src) return <Card><div id="sb-done">{h}<EmptyBox>Loading the recent runs…</EmptyBox></div></Card>;
  if (!d.runs) return <Card><div id="sb-done">{h}<EmptyBox>Recently completed unknown: {d.err}. The next poll tries again.</EmptyBox></div></Card>;
  const rows = doneRows(d.runs, tab), na = <span title="not recorded for pipeline runs">—</span>;
  const note = d.err ? `Recently completed may be out of date: ${d.err}. These rows are from ${agoMs(d.at)} ago; the next poll tries again.` : '';
  // The server sends a non-admin only that a routine or a dependency fix ran.
  const gated = (r: J) => (r.routine && !r.key ? (r.src === 'depfix' ? 'Dependency fix' : 'Routine · scheduled run') : '');
  const name = (r: J) => gated(r) || `${r.key ? `${r.key} ` : ''}${plainMd(r.title || '')}`;
  const row = (r: J, i: number) => {
    const pipe = r.src === 'pipeline', href = pipe ? jiraHref(r.key, jiraSite(s, r.key)) : sessHref(r.key), b = runBadge(r);
    const key = !r.key ? null : href ? <a className="key" href={href} {...(pipe ? { target: '_blank', rel: 'noreferrer' } : {})}>{r.key}</a> : <span className="key">{r.key}</span>;
    const mem = Number.isFinite(r.mem_mb) ? `${(r.mem_mb / 1024).toFixed(1)} GB` : '—';
    return (
      <tr key={`${r.key}:${r.end}:${i}`} data-sbdone={r.key}>
        <td>{endedTxt(r.end)}</td><td>{pipe ? 'pipeline' : r.routine ? 'routine' : 'Slack'}</td>
        <td className="sbd-for" title={name(r)}>{gated(r) || <>{key} {plainMd(r.title || '')}</>}</td>
        <td>{r.team ? teamLabel(s, r.team) : '—'}</td><td>{pipe ? 'GCE' : ({ firecracker: 'Firecracker', gce: 'GCE' } as Record<string, string>)[r.where] ?? '—'}</td>
        <td className="num">{pipe ? na : Number.isFinite(r.boot_s) ? `${Math.round(r.boot_s)} s` : '—'}</td><td className="num">{pipe ? na : mem}</td>
        <td className="num">{r.min != null ? `${Number(r.min)} min` : '—'}</td><td className="num">{r.usd == null ? '—' : usd(r.usd)}</td>
        <td><Tag label={b.label} tone={b.tone ?? 'dim'} href={b.href || undefined} />{r.stop && r.outcome !== 'pr' ? <> <span className="sbd-stop">{r.stop}</span></> : null}</td>
      </tr>
    );
  };
  const cols = ['Ended', 'Source', 'For', 'Team', 'Where', 'Boot', 'Peak memory', 'Time', 'LLM cost', 'Result'];
  return (
    <Card>
      <div id="sb-done">
        {h}
        {note && <p className="sbknote">{note}</p>}
        {rows.length ? (
          <div className="sbd-scroll">
            <table className="sbt">
              <caption className="vh">Recently completed runs</caption>
              <thead><tr>{cols.map((c, i) => <th key={c} scope="col" className={i >= 5 && i <= 8 ? 'num' : undefined}>{c}</th>)}</tr></thead>
              <tbody>{rows.map(row)}</tbody>
            </table>
          </div>
        ) : <EmptyBox>No run has ended yet.</EmptyBox>}
        <div className="sbd-more"><a href="#sessions">All sessions ›</a><a href="#stats">Stats ›</a></div>
        {rows.length > 0 && <DoneScatter rows={rows} name={name} />}
      </div>
    </Card>
  );
}

function Main() {
  const s = useParts(MODEL);
  const tab = tabOf(s.route.tab), sel = s.route.view === 'runners' ? s.route.sel : '';
  const [said, setSaid] = useState('');
  // A selected row that left the tab: clear it, and put the focus in the list when it was in the panel.
  const gone = !!sel && selRow(s, sel, tab) === 'gone';
  useEffect(() => {
    if (!gone) return;
    location.replace(format({ ...s.route, sel: '' }));
    const a = document.activeElement, right = document.getElementById('right');
    if (!a || a === document.body || right?.contains(a)) document.getElementById('sb-list')?.focus();
    // Not cleared on the route change that the replace makes: the message must still come.
    setTimeout(() => setSaid('The selected sandbox left the list.'), 0);
  }, [gone, s.route]);
  return (
    <div className="sbv">
      <Boundary><Cards s={s} /></Boundary>
      <Boundary><Live s={s} tab={tab} /></Boundary>
      <Boundary><List s={s} tab={tab} /></Boundary>
      <Boundary><Done s={s} tab={tab} /></Boundary>
      <p className="vh" aria-live="polite">{said}</p>
    </div>
  );
}

// The panel keeps its last row, so a deep link survives a feed that is unknown for a while.
let LAST: { id: string; row: J } | null = null;

function Details({ s, row, stale }: { s: Store; row: J; stale: boolean }) {
  const r = row, admin = isAdmin(s), g = AGENTS(s), up = upFor(r);
  if (r.fix) return (
    <>
      <h2 className="rh">{r.key || r.slot || r.id}<small>Needs a fix</small></h2>
      <div className="sb-panel"><h3>Why</h3><p>{r.fix.why}</p>
        {r.fix.cmd && !stale ? <><h3>Fix</h3><p><code>{r.fix.cmd}</code></p></>
          : r.fix.cmd ? <p className="na">The agents feed is stale, so no command shows. It shows again when the feed is fresh.</p>
            : r.fix.steps ? <><h3>Read first</h3><p>{r.fix.steps}</p></> : null}
      </div>
    </>
  );
  if (r.src === 'pipeline') {
    const cap = n(r.max_seconds), href = KEY_RE.test(r.key || '') ? `#pipeline/belts/${r.key}` : '';
    return (
      <>
        <h2 className="rh">{href ? <a href={href}>{r.key}</a> : r.key || 'pipeline run'}<small>Pipeline run</small></h2>
        <div className="sb-panel"><h3>Sandbox</h3>
          <Kv label="Slot" value={r.slot || 'unknown'} /><Kv label="Stop" value={r.state || 'unknown'} />
          {up != null && <Kv label="Time" value={`${short(up)}${cap ? ` of the ${short(cap)} cap` : ''}`} />}
          {n(r.usd) != null && <Kv label="Cost" value={usd(n(r.usd))} />}
          {r.title && <Kv label="Ticket" value={plainMd(r.title)} />}
          {TEAM_RE.test(r.team || '') && <Kv label="Team" value={<a href={`#teams/${r.team}`}>{r.team}</a>} />}
          <p className="na">Boot steps and peak memory are not recorded for pipeline runs.</p>
        </div>
      </>
    );
  }
  const routine = r.src === 'routine' || !!r.routine_run, open = !routine || admin;
  const name = r.depfix ? r.depfix : !open ? 'Routine · scheduled run' : routine ? `Routine ${r.routine_name || `run ${r.routine_run}`}` : plainMd(r.title) || r.key;
  const json = (v: unknown) => { try { return typeof v === 'string' ? JSON.parse(v) : v ?? null; } catch { return null; } };
  const sj = json(r.boot_steps), pj = json(r.res_peak), cap = n(g?.session_max_run_seconds);
  const steps = Array.isArray(sj) ? sj.filter((x) => x && typeof x === 'object').map((x) => ({ step: String(x.step ?? ''), s: n(x.s) })) : [];
  const peak = pj && typeof pj === 'object' && !Array.isArray(pj) && (n(pj.load1) != null || n(pj.mem_mb) != null) ? pj : null;
  // The Sessions tab from the session record: the row's state is display text ('working', 'stopping').
  const sk = r.session || r.key, sx = SS(s).find((x) => x.key === sk);
  const sh = open && sessHref(sk) ? `#sessions/${sx ? sessTabOf(sx) : 'stopped'}/${sk}` : '', pr = open ? prHref(r.pr) : '';
  return (
    <>
      <h2 className="rh">{name}<small>{routine ? 'Routine run' : 'Slack session'}</small></h2>
      <div className="sb-panel"><h3>Sandbox</h3>
        <Kv label="State" value={r.state || 'unknown'} /><Kv label="Where" value={r.where || 'unknown'} />
        {up != null && <Kv label="Up for" value={`${short(up)}${cap ? ` of ${short(cap)}` : ''}`} />}
        {n(r.boot_s) != null ? <Kv label="Boot" value={`${Math.round(n(r.boot_s)!)} s${r.where ? ` · ${r.where}` : ''}`} /> : <Kv label="Boot" value="not recorded yet" na />}
        {steps.length > 0 && <BootSteps steps={steps} />}
        {peak ? <Kv label="Peak load, memory, disk" value={`${peak.load1} · ${n(peak.mem_mb) != null ? (n(peak.mem_mb)! / 1024).toFixed(1) : '?'} GB · ${peak.disk_pct}%`} />
          : <Kv label="Peak load, memory, disk" value="not recorded yet" na />}
        {open && TEAM_RE.test(r.team || '') && <Kv label="Team" value={<a href={`#teams/${routine ? 'routines/' : ''}${r.team}`}>{r.team}</a>} />}
      </div>
      {(sh || pr) && (
        <div className="sb-panel"><h3>Links</h3>
          {sh && <p><a href={sh}>Open the session</a></p>}
          {pr && <p><a href={pr} target="_blank" rel="noopener noreferrer">{pr.split('/').slice(-3).join('/')}</a></p>}
        </div>
      )}
    </>
  );
}

function right(s: Store): ReactNode | null {
  const id = s.route.sel;
  if (s.route.view !== 'runners' || !id) return null;
  const got = selRow(s, id, tabOf(s.route.tab));
  if (got === 'gone') return null;
  if (got === 'unknown') return (
    <div className="sbp">
      <p className="na">The agents feed is unknown: this panel may be out of date.</p>
      {LAST?.id === id && <Details s={s} row={LAST.row} stale />}
    </div>
  );
  LAST = { id, row: got.row };
  return <div className="sbp"><Details s={s} row={got.row} stale={sbRows(s).stale} /></div>;
}

const chunk: ViewChunk = { Main, right };
export default chunk;
