// One routine's page: what it does, its actions, its runs, its setup and Delete.
import type { ReactNode } from 'react';
import { Tracker } from '../../../charts';
import { sentence, stamp, usd } from '../../../format';
import type { J } from '../../../model/base';
import { useApp } from '../../../store';
import { Card, EmptyBox, Kv, StatTile, Tag } from '../../../ui';
import { Bars } from './Bars';
import type { Ctl } from './index';
import { AskPr, RtState } from './List';
import { Glyph, Says } from './parts';
import {
  RT_MODES, RT_PROMPT_MAX, rtChName, rtFailed, rtFix, rtIn, rtLine, rtPicks, rtPr, rtPrN, rtResult, rtSched, rtSha7, rtWhen, sessHref, textSize,
} from './rt';

const H2 = ({ children }: { children: ReactNode }) => <h2 className="m-0 mb-s2 flex flex-wrap items-baseline gap-s2 text-heading">{children}</h2>;
const Note = ({ children }: { children: ReactNode }) => <span className="text-sub font-normal text-faint">{children}</span>;

// Each run, newest first: the result, the trigger, the time, the cost, the session, the PR and the SHAs.
function Runs({ rows, d }: { rows: J[]; d: J }) {
  if (!rows.length) return <p className="empty m-0">No runs yet.</p>;
  return <div className="flex flex-col">{rows.map((x) => {
    const [t, tone, title, next] = rtResult(x, d), at = x.started_at ?? x.ended_at, fix = ['failed', 'missed'].includes(x.state) && !next ? rtFix(x.reason) : '';
    const day = at ? new Date(at * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) : '';
    const time = at ? new Date(at * 1000).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) : '';
    // A fix run names its trigger as Sessions and Sandboxes do, links its PR, and shows the PR head it started on and the commit it pushed.
    const fx = x.heads?.fix, who = String(x.actor ?? '').slice(0, 60), pr = fx ? rtPr(fx.url) : rtPr(x.pr_url);
    const by = fx ? ({ blender: 'BLEnder', label: who ? `label by ${who}` : 'label', manual: who ? `Run now by ${who.split('@')[0]}` : 'Run now' } as Record<string, string>)[x.trigger] ?? 'Dependency fix'
      : x.trigger === 'manual' ? `Run now${x.actor ? ` by ${String(x.actor).split('@')[0]}` : ''}` : 'Schedule';
    const h = fx ? rtSha7(fx.head_sha) : '', n = fx ? rtSha7(fx.new_sha) : '', sh = sessHref(x.session);
    return (
      <div key={x.id} className="item flex flex-col gap-s1 border-t border-line py-s2 first:border-t-0">
        <div className="line1 flex flex-wrap items-baseline gap-s2">
          <span className="font-mono text-sub text-faint">{day}</span><span className="title min-w-0 flex-1 font-semibold">{title}</span><Tag label={t} tone={tone} />
        </div>
        <div className="line2 text-sub text-dim">
          {by} · {time} · {x.cost_usd == null ? 'no cost' : usd(x.cost_usd)}
          {x.session && <> · {sh ? <a className="font-mono text-link" href={sh}>{x.session}</a> : <span className="font-mono">{x.session}</span>}</>}
          {pr && <> · <a className="key text-link" href={pr} target="_blank" rel="noopener">#{pr.split('/').pop()}</a></>}
          {h && <> · <span className="font-mono" title={n ? 'The PR head it started on, and the commit it pushed' : 'The PR head it started on'}>{h}{n ? ` → ${n}` : ''}</span></>}
        </div>
        {next && <p className="hint next m-0">{next}</p>}
        {fix && <div className="rounded-md border border-warn bg-warnbg px-s3 py-s1 text-sub font-semibold text-warn">{fix}</div>}
        {/* No open prop: React keeps a report the person opened open through each update. */}
        {x.report && <details data-rt-run={x.id}><summary className="cursor-pointer text-link">Report</summary><pre className="m-0 whitespace-pre-wrap text-sub">{x.report}</pre></details>}
      </div>
    );
  })}</div>;
}

// Each live run of a pr-label routine with its PR: Running, Queued, In line behind #m, or Waiting: the gate.
function Lives({ c, r }: { c: Ctl; r: J }) {
  const line = rtLine(r);
  if (!line.length) return <EmptyBox>No run is live. A run starts when a dependency PR asks for help.</EmptyBox>;
  return <ul className="m-0 flex list-none flex-col gap-s2 p-0">{line.map((x, i) => {
    const f = x.fix ?? {}, pr = rtPr(f.url), ahead = line[i - 1];
    const st = x.state !== 'queued' ? <><Tag label="Running" tone="info" run live />{x.session && <> <a className="font-mono text-link" href={`#sessions/live/${x.session}`}>{x.session}</a></>}</>
      : f.wait && f.wait !== 'another run of this routine is in progress' ? <Tag label={`Waiting: ${f.wait}`} tone="warn" />
        : ahead ? <Tag label={`In line behind ${rtPrN(ahead.fix)}`} tone="dim" /> : <Tag label="Queued" tone="info" />;
    return (
      <li key={x.id} data-rt-live={x.id} className="flex flex-wrap items-center gap-s2">
        {pr ? <a className="key text-link" href={pr} target="_blank" rel="noopener">{rtPrN(f)}</a> : <span className="key">{rtPrN(f)}</span>} {st}
        <button type="button" data-rt-act="stop" data-rt-id={r.id} data-rt-run={x.id} aria-label={`Stop run for ${rtPrN(f)}`} disabled={c.busy === r.id}
          onClick={() => c.act('stop', r.id, String(x.id))}>Stop run</button>
      </li>
    );
  })}</ul>;
}

export function Detail({ c, r }: { c: Ctl; r: J }) {
  const d = r.data, n: string = d.name, p = c.team.profile, sum = c.sum?.routines?.[r.id], onpr = d.on === 'pr-label';
  const hist = useApp((s) => s.teamsUi.routineHist[String(r.id)]) as J[] | undefined, histErr = c.histErr[String(r.id)];
  const runOff = (r.live && !onpr) || c.busy === r.id, offTitle = r.live && !onpr ? 'A run is in progress' : 'Working on it';
  const next: string[] = r.paused ? [] : r.next ?? [], ch = d.channel ? rtChName(d.channel, r.channel_name, c.chans) : '';
  const b = (act: 'run' | 'pause' | 'resume' | 'edit' | 'delete', label: string, off = false) => (
    <button type="button" data-rt-act={act} data-rt-id={r.id} aria-label={`${label} ${n}`} disabled={off} title={off ? offTitle : undefined} onClick={() => c.act(act, r.id)}>{label}</button>
  );
  const old = [...(hist ?? [])].reverse(), word = (x: J) => rtResult(x, d);
  return (
    <div className="rtd flex flex-col gap-s4" data-rt-row={r.id}>
      <a className="rtback self-start text-link" href={`#teams/${p}/routines`} data-rt-list>← Routines</a>
      <div className="rt flex flex-wrap items-start gap-s3">
        <Glyph tpl={onpr ? 'depfix' : d.template} />
        <div className="flex min-w-0 flex-1 flex-col gap-s1">
          <h3 className="nm m-0 flex flex-wrap items-center gap-s2 text-heading">{n} <RtState r={r} /></h3>
          <span className="says text-sub text-dim"><Says d={d} chName={r.channel_name} chans={c.chans} /></span>
        </div>
        {b('run', r.live && !onpr ? 'A run is in progress' : 'Run now', !!runOff)}
        {r.live && !onpr && (
          <button type="button" data-rt-act="stop" data-rt-id={r.id} data-rt-run={r.live.id} aria-label={`Stop run ${n}`} disabled={c.busy === r.id} onClick={() => c.act('stop', r.id, String(r.live.id))}>Stop run</button>
        )}
        {b(r.paused ? 'resume' : 'pause', r.paused ? 'Resume' : 'Pause', c.busy === r.id)}
        {b('edit', 'Edit')}
      </div>
      {c.ask?.id === r.id && <AskPr c={c} r={r} />}
      <div className="rtkpis grid gap-s3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))' }}>
        <StatTile label="Runs, 30 days" value={sum?.runs_30d ?? '—'} sub={hist ? `${hist.filter((x) => ['failed', 'missed'].includes(x.state)).length} failed of the last ${hist.length}` : ''} />
        <StatTile label="Cost, 30 days" value={usd(sum?.cost_30d)} sub={sum?.runs_30d ? `${usd(sum.cost_30d / sum.runs_30d)} a run · limit ${usd(d.max_usd)}` : `limit ${usd(d.max_usd)} a run`} />
        <StatTile label="Last result" value={r.last ? rtResult(r.last, d)[0] : 'none'} sub={r.last?.ended_at ? stamp(r.last.ended_at) : 'no run yet'} tone={rtFailed(r, c.sum) ? 'bad' : undefined} />
        {onpr ? <StatTile label="Next run" value="on request" sub={r.paused ? 'paused' : 'when a dependency PR asks for help'} />
          : <StatTile label="Next run" value={next[0] ? rtIn(next[0], c.now) || 'now' : 'none'} sub={r.paused ? 'paused' : next[0] ? `${rtWhen(next[0], d.zone, true)} ${d.zone}` : ''} />}
      </div>
      <div className="grid gap-s4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))' }}>
        <section className="rounded-lg border border-card-border bg-panel p-s4 shadow-card">
          <H2>Runs{hist && <><span className="n font-normal text-faint">{hist.length}</span><Note>newest first, times in {Intl.DateTimeFormat().resolvedOptions().timeZone}</Note></>}</H2>
          {hist ? <>
            {old.length > 0 && (
              <div className="mb-s4 flex flex-col gap-s4">
                <Tracker label="Results, oldest first" items={old.map((x) => ({ tone: word(x)[1], label: word(x)[0] }))} />
                <Bars title="Cost per run" unit="cost" fmt={usd} limit={Number(d.max_usd) || undefined}
                  bars={old.map((x) => ({ label: x.started_at ? stamp(x.started_at) : `run ${x.id}`, value: x.cost_usd ?? null, tone: word(x)[1], word: word(x)[0] }))} />
                <Bars title="Run time" unit="minutes" fmt={(m) => `${Math.round(m)} min`}
                  bars={old.map((x) => ({ label: x.started_at ? stamp(x.started_at) : `run ${x.id}`, value: x.started_at && x.ended_at ? (x.ended_at - x.started_at) / 60 : null, tone: word(x)[1], word: word(x)[0] }))} />
              </div>
            )}
            <Runs rows={hist} d={d} />
          </> : histErr ? (
            <p className="m-0 text-sub font-semibold text-warn">Runs did not load: {histErr} <button type="button" data-rt-act="hist" data-rt-id={r.id} onClick={() => c.act('hist', r.id)}>Retry</button></p>
          ) : <p className="empty m-0">loading runs…</p>}
        </section>
        <div className="flex flex-col gap-s4">
          <Card>
            <H2>Setup <Note><button type="button" data-rt-act="edit" data-rt-id={r.id} aria-label={`Edit ${n}`} onClick={() => c.act('edit', r.id)}>Edit</button></Note></H2>
            {onpr ? <>
              <Kv label="When" value="A dependency PR asks for help" />
              <Kv label="Repo" value={d.pr?.repo ?? 'none'} na={!d.pr?.repo} />
              <Kv label="Authors" value={(d.pr?.authors ?? []).join(', ') || 'none'} na={!(d.pr?.authors ?? []).length} />
              <Kv label="Label" value={d.pr?.label || 'agent-help'} />
              <Kv label="Result" value="One fix commit on the PR branch" />
            </> : <>
              <Kv label="Starts from" value={(c.tpls ?? []).find((x) => x.template === d.template)?.name ?? 'Custom prompt'} />
              <Kv label="Schedule" value={sentence(rtSched(d))} />
              <Kv label="Time zone" value={d.zone} />
              <Kv label="Repos" value={(d.repos ?? []).join(', ') || 'none'} na={!(d.repos ?? []).length} />
              <Kv label="Branch" value={d.branch || 'the default'} na={!d.branch} />
              <Kv label="Result" value={(RT_MODES.find((m) => m[0] === d.mode)?.[1] ?? d.mode) + ((d.mode === 'pr' || d.mode === 'pr+notes') && d.draft === false ? ', opened as a regular PR' : '')} />
            </>}
            <Kv label="Slack" value={ch || 'none, History only'} na={!ch} />
            <Kv label="Cost limit" value={`${usd(d.max_usd)} a run`} />
            <Kv label="Model" value={rtPicks(d).models.find(([v]) => v === (d.model ?? ''))?.[1] ?? d.model} />
            <Kv label="Effort" value={rtPicks(d).efforts.find(([v]) => v === (d.effort ?? ''))?.[1] ?? d.effort} />
            {!onpr && <Kv label="No new commits" value={d.skip_no_commits ? 'skip the run' : 'run anyway'} />}
          </Card>
          {onpr ? (
            <Card><H2>Live runs <span className="n font-normal text-faint">{(r.lives ?? []).length}</span></H2><Lives c={c} r={r} /></Card>
          ) : (
            <Card>
              <H2>Next runs <Note>{d.zone}</Note></H2>
              {next.length ? next.map((x) => { const w = rtWhen(x, d.zone, true); return <Kv key={x} label={w.replace(/, \d\d:\d\d$/, '')} value={w.slice(-5)} />; })
                : <p className="empty m-0">{r.paused ? 'Paused: no run is due.' : 'No run is due.'}</p>}
            </Card>
          )}
          {!onpr && (
            <Card>
              <H2>Prompt <Note>{textSize(d.prompt, RT_PROMPT_MAX)}</Note></H2>
              <details><summary className="cursor-pointer text-link">Show the whole prompt</summary><pre className="m-0 whitespace-pre-wrap text-sub">{d.prompt}</pre></details>
            </Card>
          )}
          <Card flat>
            <h3 className="m-0">Delete this routine</h3>
            <p className="hint">{onpr ? 'No new run starts after this.' : 'The schedule stops at once.'} You cannot undo this.</p>
            {b('delete', c.arm === r.id ? 'Delete: click again' : 'Delete', !!runOff)}
          </Card>
        </div>
      </div>
    </div>
  );
}
