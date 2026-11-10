// The routines list: the head, the scheduler warning, the tiles, the filter, the cards, and the next runs.
import { useState } from 'react';
import { Gantt } from '../../../charts';
import { ago, stamp, usd } from '../../../format';
import type { J } from '../../../model/base';
import { Meter, StatTile, Tag } from '../../../ui';

import { cx, FILL } from '../../../ui/tone';
import type { Ctl } from './index';
import { Glyph, Says } from './parts';
import { RT_DOT, RT_MODES, RT_STALE_S, RT_WITHIN_MIN, rtFailed, rtIn, rtResult, rtStarts, rtWhen, rtZoneName } from './rt';

// The live state of a routine: Running or Queued with its session, else Paused or On.
export function RtState({ r }: { r: J }) {
  const v = r.live;
  if (r.data.on === 'pr-label' && v) {
    const n = (r.lives ?? []).length, run = v.state !== 'queued';
    return <>
      <Tag label={run ? 'Running' : 'Queued'} tone="info" run={run} live={run} />
      {n > 1 && <> <Tag label={`${n} live runs`} tone="dim" /></>}
    </>;
  }
  if (v?.state === 'queued')
    return <><Tag label="Queued" tone="info" /> It starts when a runner is free, within {RT_WITHIN_MIN} min, and the result goes to {r.data.channel ? <span className="font-mono">{r.data.channel}</span> : 'History only'}.</>;
  if (v) return <><Tag label="Running" tone="info" run live />{v.session && <> <a className="font-mono text-link" href={`#sessions/live/${v.session}`}>{v.session}</a></>}</>;
  return r.paused ? <Tag label="Paused" tone="warn" /> : <Tag label="On" tone="ok" />;
}

export function Choices({ c }: { c: Ctl }) {
  return (
    <div className="grid gap-s3" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))' }} role="group" aria-label="Start from">
      {rtStarts(c.tpls).map((x) => (
        <button key={x.template} type="button" className="flex flex-col items-start gap-s2 text-left" data-rt-tpl={x.template} onClick={() => c.act('tpl', x.template)}>
          <Glyph tpl={x.template} />
          <span className="font-semibold">{x.name}</span>
          {x.about && <span className="hint font-normal">{x.about}</span>}
          <span className="flex flex-wrap gap-s1">
            {x.on ? <><Tag label="One fix commit" tone="merged" /><Tag label="on request" /></> : <>
              <Tag label={x.locked_mode ? 'Report or Jira tickets' : RT_MODES.find((m) => m[0] === x.mode)?.[1] ?? x.mode ?? ''} tone={x.locked_mode || x.mode === 'report' ? 'info' : 'merged'} />
              {x.skip_no_commits && <Tag label="skips with no new commits" />}
            </>}
          </span>
        </button>
      ))}
    </div>
  );
}

const Fact = ({ head, children }: { head: string; children: React.ReactNode }) => (
  <div className="fact flex min-w-0 flex-col gap-s1"><span className="text-label font-semibold uppercase tracking-wide text-dim">{head}</span><span className="text-sub">{children}</span></div>
);

function RtCard({ c, r }: { c: Ctl; r: J }) {
  const d = r.data, rec: J[] = r.recent ?? [], nx = r.paused ? null : (r.next ?? [])[0], last = r.last ? rtResult(r.last, d) : null, onpr = d.on === 'pr-label';
  const s = c.sum?.routines?.[r.id], runOff = (r.live && !onpr) || c.busy === r.id, p = c.team.profile;
  const per = s?.runs_30d ? s.cost_30d / s.runs_30d : null;
  return (
    <article className="rt rounded-lg border border-card-border bg-panel p-s4 shadow-card" data-rt-row={r.id}>
      <div className="flex flex-wrap items-start gap-s3">
        <Glyph tpl={onpr ? 'depfix' : d.template} />
        <div className="flex min-w-0 flex-1 flex-col gap-s1">
          <div className="flex flex-wrap items-center gap-s2">
            <a className="nm font-head text-heading font-bold text-link" href={`#teams/${p}/routines/${r.id}`} data-rt-sel={r.id}>{d.name}</a>
            {!r.live && <RtState r={r} />}
            {onpr ? <Tag label="dependency fix" sq /> : d.template === 'blank' ? <Tag label="custom prompt" sq /> : null}
          </div>
          <span className="says text-sub text-dim"><Says d={d} chName={r.channel_name} chans={c.chans} /></span>
        </div>
        <button type="button" data-rt-act="run" data-rt-id={r.id} aria-label={`Run now ${d.name}`} disabled={!!runOff}
          title={runOff ? (r.live && !onpr ? 'A run is in progress' : 'Working on it') : undefined} onClick={() => c.act('run', r.id)}>Run now</button>
        {r.live && !onpr && (
          <button type="button" data-rt-act="stop" data-rt-id={r.id} data-rt-run={r.live.id} aria-label={`Stop run ${d.name}`} disabled={c.busy === r.id}
            onClick={() => c.act('stop', r.id, String(r.live.id))}>Stop run</button>
        )}
        {/* The name stays "Routine X" and the switch state says on or off, so the visible word is not in the name. */}
        <button type="button" role="switch" data-rt-act={r.paused ? 'resume' : 'pause'} data-rt-id={r.id} aria-checked={!r.paused} disabled={c.busy === r.id}
          className={r.paused ? undefined : 'bg-okbg text-ok'} onClick={() => c.act(r.paused ? 'resume' : 'pause', r.id)}>
          <span aria-hidden="true">{r.paused ? 'Off' : 'On'}</span><span className="vh">Routine {d.name}</span>
        </button>
      </div>
      {c.ask?.id === r.id && <AskPr c={c} r={r} />}
      <div className="facts mt-s3 grid gap-s3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))' }}>
        <Fact head="Last run">{r.live ? <RtState r={r} /> : last ? <><Tag label={last[0]} tone={last[1]} title={last[2]} /> {r.last.ended_at ? stamp(r.last.ended_at) : ''}</> : <span className="text-faint">no run yet</span>}</Fact>
        <Fact head="Next run">{r.paused ? <span className="text-faint">paused</span> : onpr ? 'on request' : nx ? <>{rtWhen(nx, d.zone, true)} <span className="text-faint">· {rtIn(nx, c.now)}</span></> : 'none'}</Fact>
        <Fact head={`Last ${rec.length || ''} runs`}>
          {rec.length ? (
            <span className="runs inline-flex gap-s1" role="img" aria-label={`Oldest first: ${rec.map((x) => rtResult(x, d)[0].toLowerCase()).join(', ')}`}>
              {rec.map((x, i) => <span key={i} className={cx('inline-block size-s2 rounded-pill', RT_DOT[x.state] ? FILL[RT_DOT[x.state]!] : 'bg-line2')} />)}
            </span>
          ) : <span className="text-faint">none yet</span>}
        </Fact>
        <Fact head="Cost, 30 days">
          {s ? usd(s.cost_30d) : '—'} <span className="text-faint">· {s?.runs_30d ?? 0} run{s?.runs_30d === 1 ? '' : 's'} · limit {usd(d.max_usd)} a run</span>
          {per != null && d.max_usd > 0 && (
            <span className="mt-s1 block"><Meter pct={(per / d.max_usd) * 100} tone={per > d.max_usd ? 'bad' : 'info'} label={`${usd(per)} a run of the ${usd(d.max_usd)} limit`} /></span>
          )}
        </Fact>
      </div>
    </article>
  );
}

// Run now on a pr-label routine asks which PR: a labelled field, ctl's refusal tied to it, and a busy text while ctl checks it.
export function AskPr({ c, r }: { c: Ctl; r: J }) {
  const a = c.ask!, id = `rt-ask-${r.id}`, repo = r.data.pr?.repo ?? (r.data.repos ?? [])[0] ?? 'owner/repo';
  return (
    <div className="rtask mt-s3 flex flex-col gap-s1">
      <label htmlFor={id} className="text-sub font-semibold">PR URL</label>
      <div className="flex flex-wrap items-center gap-s2">
        <input id={id} className="w-full max-w-md rounded-md border border-line2 bg-panel px-s3 py-s1 text-body text-ink aria-invalid:border-bad" type="url" data-rt-ask={r.id}
          placeholder={`https://github.com/${repo}/pull/123`} value={a.url} onChange={(e) => c.setAskUrl(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); c.act('runpr', r.id); } }}
          aria-invalid={a.err ? true : undefined} aria-describedby={a.err ? `${id}-err` : `${id}-hint`} />
        <button type="button" data-rt-act="runpr" data-rt-id={r.id} disabled={a.asking} onClick={() => c.act('runpr', r.id)}>{a.asking ? 'Checking the PR…' : 'Run'}</button>
        <button type="button" data-rt-act="askcancel" data-rt-id={r.id} onClick={() => c.act('askcancel', r.id)}>Cancel</button>
      </div>
      {a.err ? <p className="m-0 text-sub font-semibold text-warn" id={`${id}-err`}>{a.err}</p>
        : <p className="hint m-0" id={`${id}-hint`}>An open PR of {repo} by one of the routine's authors. The run fixes its current head.</p>}
    </div>
  );
}

// The next runs of the schedule routines in the next 7 days, one row per routine.
function NextWeek({ c }: { c: Ctl }) {
  const t0 = c.now / 1000, t1 = t0 + 7 * 86400;
  const rows = c.list.filter((r) => !r.paused && r.data.on !== 'pr-label').map((r) => ({
    id: String(r.id), label: r.data.name as string, bars: [],
    marks: (r.next ?? []).map((x: string) => ({ at: Date.parse(x) / 1000, label: rtWhen(x, r.data.zone) })).filter((m: { at: number }) => m.at >= t0 && m.at <= t1),
  })).filter((r) => r.marks.length);
  if (!rows.length) return null;
  const n = rows.reduce((k, r) => k + r.marks.length, 0);
  const first = rows.flatMap((r) => r.marks.map((m: { at: number; label: string }) => ({ ...m, who: r.label }))).sort((a, b) => a.at - b.at)[0]!;
  return (
    <Gantt title="Next runs, 7 days" summary={`${n} run${n === 1 ? '' : 's'} of ${rows.length} routine${rows.length === 1 ? '' : 's'} in the next 7 days. First: ${first.who}, ${first.label}.`}
      table={{ head: ['Routine', 'Next run'], rows: rows.flatMap((r) => r.marks.map((m: { label: string }) => [r.label, m.label])) }}
      rows={rows} start={t0} end={t1} now={t0} />
  );
}

export function List({ c, gone }: { c: Ctl; gone: boolean }) {
  const [show, setShow] = useState<'all' | 'failed' | 'paused'>('all');
  const L = c.list, t = c.team, now = c.now / 1000;
  // The oldest heartbeat of the envs these routines use: a fresh dev tick does not hide a live one that stopped.
  const tick = L.some((r) => r.tick == null) ? null : Math.min(...L.map((r) => r.tick)), age = tick == null ? null : Math.max(0, Math.round(now - tick));
  const late = !!L.length && (age == null || age > RT_STALE_S);
  const ts = c.sum?.teams?.[t.profile], paused = L.filter((r) => r.paused).length, failed = L.filter((r) => rtFailed(r, c.sum)).length;
  const rows = L.filter((r) => show === 'all' || (show === 'failed' ? rtFailed(r, c.sum) : !!r.paused));
  const goneNote = gone && <p className="m-0 text-sub text-faint">The routine from the link is no longer here.</p>;
  const head = (
    <div className="rt-head flex flex-wrap items-start gap-s3">
      <div className="flex min-w-0 flex-1 flex-col gap-s1">
        <h3 className="m-0 text-heading">Routines <span className="n font-normal text-faint">{L.length} of {c.limit} allowed</span></h3>
        <p className="hint m-0">A routine runs a prompt on a schedule against the team's repos, then posts the result in Slack. Each run is a normal session with the team's budget.</p>
      </div>
      <button type="button" data-rt-new disabled={L.length >= c.limit} title={L.length >= c.limit ? `A team has at most ${c.limit} routines` : undefined} onClick={() => c.act('new')}>New routine</button>
    </div>
  );
  if (!L.length)
    return <>{head}<div data-routine-list>{goneNote}
      <div className="emptybox flex flex-col gap-s3"><h3 className="m-0">No routines yet</h3><p className="hint m-0">Pick a start to make one in two steps.</p><Choices c={c} /></div>
    </div></>;
  const pr = L.some((r) => r.data.on === 'pr-label');
  const key: [string, string][] = pr
    ? [['merged', 'Draft PR or Pushed'], ['info', 'Report, Branch moved or Not pushed'], ['', 'Nothing to change, No fix found or Not started'], ['bad', 'Failed'], ['warn', 'Stopped']]
    : [['merged', 'Draft PR'], ['info', 'Report'], ['', 'Nothing to change'], ['bad', 'Failed'], ['warn', 'Stopped']];
  return (
    <>
      {head}
      <div data-routine-list className="flex flex-col gap-s4">
        {goneNote}
        {late && (
          <div className="rounded-md border border-warn bg-warnbg px-s4 py-s2 text-sub font-semibold text-warn">
            {age == null ? 'The scheduler has not run yet.' : `The scheduler last ran ${Math.round(age / 60)} min ago.`} Routines are not running.
          </div>
        )}
        <div className="rtkpis grid gap-s3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))' }}>
          <StatTile label="Routines" value={L.length} sub={`${L.length - paused} on · ${paused} paused`} />
          <StatTile label="Runs, 30 days" value={ts?.runs_30d ?? '—'} sub={failed ? `${failed} need${failed === 1 ? 's' : ''} attention` : 'none needs attention'} tone={failed ? 'warn' : undefined} />
          <StatTile label="Cost, 30 days" value={usd(ts?.cost_30d)} sub={ts?.runs_30d ? `${usd(ts.cost_30d / ts.runs_30d)} a run` : 'no run yet'} />
          <StatTile label="Scheduler" value={late ? 'Stopped' : 'Running'} sub={age == null ? 'it has not run' : `checked ${ago(age)}`} tone={late ? 'bad' : undefined} />
        </div>
        <div className="flex flex-wrap gap-s1" role="group" aria-label="Show">
          {([['all', 'All', L.length], ['failed', 'Needs attention', failed], ['paused', 'Paused', paused]] as const).map(([k, l, n]) => (
            <button key={k} type="button" data-rt-show={k} aria-pressed={show === k} className={show === k ? 'bg-sunk' : undefined} onClick={() => setShow(k)}>{l} {n}</button>
          ))}
        </div>
        {rows.length ? rows.map((r) => <RtCard key={r.id} c={c} r={r} />)
          : <p className="empty m-0">No {show === 'failed' ? 'routine needs attention' : 'routine is paused'}.</p>}
        <p className="rtkey hint m-0 flex flex-wrap items-center gap-s2">
          {key.map(([tone, w]) => <span key={w} className="inline-flex items-center gap-s1"><span className={cx('inline-block size-s2 rounded-pill', tone ? FILL[tone as 'ok'] : 'bg-line2')} aria-hidden="true" />{w}</span>)}
        </p>
        <NextWeek c={c} />
        <p className="hint m-0">Next run times are in each routine's zone ({[...new Set(L.map((r) => rtZoneName(r.data.zone ?? 'UTC')))].join(', ')}); past runs are in your browser's zone, {Intl.DateTimeFormat().resolvedOptions().timeZone}.</p>
      </div>
    </>
  );
}
