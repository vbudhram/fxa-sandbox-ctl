// The Runners and LLM tab, and the Pipeline tab: the v1 cards, with a chart next to each day table.
import { memo } from 'react';
import { StripPlot } from '../../charts';
import { modelName, tokn, usd } from '../../format';
import type { J } from '../../model/base';
import { Bars } from './lazy';
import { answerData, llmData, loadDays, mins, pipelineData, runnerData } from './compute';
import { Box, DayTable, Empty, Row, shortDay, Sub } from './parts';

// A session's stop_reason (lib/session.sh), as a person reads it.
const STOP_WHY: Record<string, string> = { inactive: 'Paused a day, then closed', idle: 'Idle: runner stopped, session paused', stopped: 'Stopped', 'runner gone': 'Runner gone' };
const h1 = (s: number) => (s / 3600).toFixed(1);
const oldest = <T,>(a: T[]) => a.slice().reverse();

// memo: the cards read the stats feed and the rows only, so a session or team event does not redraw them.
export const Runners = memo(function Runners({ st, rows, lo, hi }: { st: J; rows: J[]; lo: number; hi: number }) {
  return (
    <div className="st-cols">
      <LoadCard l={st.load} lo={lo} hi={hi} />
      <AnswerCard rows={rows} />
      <RunnerCard rows={rows} />
      <LlmCard l={st.llm} lo={lo} hi={hi} />
    </div>
  );
});

function LoadCard({ l, lo, hi }: { l: J; lo: number; hi: number }) {
  const days = loadDays(l, lo, hi);
  if (!days.length) return <Box title="Sessions at once" note={`cap ${l?.cap ?? '?'}`}><Empty>No session with a stop time yet.</Empty></Box>;
  const o = oldest(days);
  return (
    <Box title="Sessions at once" note={`Slack, peak per day, cap ${l.cap}`}>
      <DayTable label="Sessions at once per day" head={['Peak', 'Waited', 'Dropped']} rows={days.map((d: J) => [d.day,
        d.peak >= l.cap ? <span className="warnt">{d.peak} of {l.cap}</span> : `${d.peak} of ${l.cap}`,
        d.queued ? `${d.queued}, up to ${mins(d.wait_max_s)}` : '', d.dropped || ''])} />
      <div data-new>
        <Bars title="Peak against cap" what="Peak sessions at once per day, against the cap" labels={o.map((d: J) => shortDay(d.day))} format={(v) => String(Math.round(v))}
          cap={typeof l.cap === 'number' ? { v: l.cap, label: `cap ${l.cap}` } : undefined} height={160} grouped
          series={[{ name: 'Peak', color: 'chart-1', values: o.map((d: J) => d.peak || 0) }, { name: 'Waited', color: 'chart-4', values: o.map((d: J) => d.queued || 0) },
            { name: 'Dropped', color: 'chart-2', values: o.map((d: J) => d.dropped || 0) }]} />
      </div>
    </Box>
  );
}

function AnswerCard({ rows }: { rows: J[] }) {
  const a = answerData(rows);
  if (!a) return <Box title="Quick answers" note="read-only, no sandbox"><Empty>No quick answer in this range.</Empty></Box>;
  return (
    <Box title="Quick answers" note="read-only, no sandbox">
      <Row k={<b>Answered</b>} v={`${a.answered} of ${a.n}`} />
      <Row k={<b>Upgraded to a sandbox</b>} v={a.upgraded} />
      {a.failed > 0 && <Row k={<b>Failed, then a session</b>} v={a.failed} />}
      {a.secs.length > 0 && <Row k={<b>Time</b>} v={`median ${a.secs[Math.floor(a.secs.length / 2)]} s · slowest ${a.secs[a.secs.length - 1]} s`} />}
      <Row k={<b>Cost</b>} v={`${usd(a.usd)} · ${usd(a.usd / a.n)} each`} />
    </Box>
  );
}

function RunnerCard({ rows }: { rows: J[] }) {
  const r = runnerData(rows);
  if (!r) return <Box title="Runner time" note="Slack sessions"><Empty>No stopped session in this view has runner times yet.</Empty></Box>;
  return (
    <Box title="Runner time" note={`${r.n} stopped sessions`}>
      <Row k={<b>Runner hours</b>} v={`${h1(r.up)} h`} />
      <Row k={<b>Busy (turns running)</b>} v={`${h1(r.busy)} h · ${Math.round(r.busy / Math.max(r.up, 1) * 100)}%`} />
      <Row k={<b>Idle</b>} v={`${h1(r.up - r.busy)} h`} />
      {r.boots.map((b) => <Row key={b.backend} k={<b>Median boot, {b.backend}</b>} v={`${b.median!.toFixed(0)} s`} />)}
      <Row k={<b>Peak memory, load, disk</b>} v={`${(r.mem / 1024).toFixed(1)} GB · ${r.load} · ${r.disk}%`} />
      <Row k={<b>Compute, estimated</b>} v={usd(r.compute)} />
      {r.verify && <Row k={<b>Verify runs</b>} v={`${r.verify.runs} in ${r.verify.sessions} sessions · ${r.verify.full} full · ${r.verify.min} min · ${r.verify.fail} with a FAIL`} />}
      {r.stack && <Row k={<b>Stack starts</b>} v={`${r.stack.n} · avg ${r.stack.avg} s · ${r.stack.fails} failed`} />}
      <Sub title="Why they stopped" />
      {r.stops.map(([k, n]) => <Row key={k} k={<b>{STOP_WHY[k] ?? k}</b>} v={n} />)}
      <div data-new>
        <Bars title="Busy and idle hours by backend" what="Runner hours by backend, busy and idle" labels={r.backends.map((b) => b.backend)} height={160}
          format={(v) => `${+v.toFixed(1)} h`} series={[{ name: 'Busy', color: 'chart-1', values: r.backends.map((b) => b.busy) }, { name: 'Idle', color: 'chart-muted', values: r.backends.map((b) => b.idle) }]} />
        {r.boots.length > 0 && (
          <StripPlot title="Boot time" summary={`Boot time per session: ${r.boots.map((b) => `${b.backend} median ${b.median} s`).join(', ')}.`} unit="s"
            table={{ head: ['Backend', 'Session', 'Boot s'], rows: r.boots.flatMap((b) => b.all.map((x: J) => [b.backend, String(x.key ?? ''), x.boot_s])) }}
            groups={r.boots.map((b) => ({ label: b.backend, median: b.median!, points: b.all.map((x: J) => ({ value: x.boot_s, label: String(x.key ?? '') })) }))} />
        )}
      </div>
    </Box>
  );
}

function LlmCard({ l, lo, hi }: { l: J; lo: number; hi: number }) {
  const d = llmData(l, lo, hi);
  if (!d) return <Box title="LLM spend" note="proxy log"><Empty>No proxy log yet.</Empty></Box>;
  const TOK: [string, string, 'chart-1' | 'chart-2' | 'chart-3' | 'chart-4'][] = [['input', 'Input', 'chart-1'], ['cache_read', 'Cache read', 'chart-2'], ['cache_write', 'Cache written', 'chart-3'], ['output', 'Output', 'chart-4']];
  return (
    <Box title="LLM spend" note="proxy log, test runs left out">
      <Row k={<b>In this range</b>} v={<><b>{usd(d.usd)}</b> · {d.calls} calls</>} />
      {d.models.length > 0 && <Row k={<b>By model, these days</b>} v="" />}
      {d.models.map((r: J) => (
        <Row key={r.model} k={modelName(r.model)}
          v={<><b>{usd(r.usd)}</b> · {Math.round(r.usd / d.all * 100)}% · {r.calls} calls · {tokn(r.cache_read)} cache read · {tokn(r.cache_write)} written · {tokn(r.output)} out</>} />
      ))}
      <Row k={<b>Cache rewrites after a 5 min gap, all time</b>} v={usd(d.gap)} />
      <DayTable label="LLM spend per day" head={['Calls', 'Cost', 'Cache writes']} rows={d.days.map((x: J) => [x.day, x.calls, usd(x.usd),
        x.cache_write_usd ? `${Math.round(x.cache_write_usd / Math.max(x.usd, 0.01) * 100)}%` : ''])} />
      <div data-new>
        <Bars title="Tokens per day" what="Tokens per day by type, every model" labels={d.tokens.map((x: J) => shortDay(x.day))} format={tokn} height={160}
          series={TOK.map(([k, n, c]) => ({ name: n, color: c, values: d.tokens.map((x: J) => x[k] || 0) }))} />
      </div>
    </Box>
  );
}

export const Pipeline = memo(function Pipeline({ st, lo, hi }: { st: J; lo: number; hi: number }) {
  const p = pipelineData(st.pipeline, lo, hi), m = st.memory;
  const o = p ? oldest(p.days) : [];
  return (
    <div className="st-cols">
      {!p ? <Box title="Pipeline queue" note="passes"><Empty>No pass recorded yet.</Empty></Box> : (
        <Box title="Pipeline queue" note="waits all time, passes in this range">
          {p.waits && (
            <>
              <Row k={<b>Queued to first run, all time</b>} v={p.waits.first} />
              <Row k={<b>Queued to PR, all time</b>} v={p.waits.pr} />
              <Row k={<b>Queued to merge, all time</b>} v={p.waits.merge} />
            </>
          )}
          <Row k={<b>Tickets retried, all time</b>} v={p.retried} />
          <DayTable label="Pipeline passes per day" head={['Passes', 'Work', 'Queue', 'In flight', 'Merged', 'Cost']} rows={p.days.map((d: J) => {
            const wk = Object.entries(d.woke ?? {}).sort((a: J, b: J) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`).join(', ');
            return [d.day, d.passes, wk ? <span title={`woke: ${wk}`}>{d.work}</span> : d.work, d.max_queued, d.inflight,
              `${d.merged || ''}${d.rejected ? ` (${d.rejected} rejected)` : ''}`, d.usd ? usd(d.usd) : ''];
          })} />
          <div data-new>
            <Bars title="Queue and in flight" what="Most tickets queued and in flight per day" labels={o.map((d: J) => shortDay(d.day))} format={(v) => String(Math.round(v))} height={160} grouped
              series={[{ name: 'Queued', color: 'chart-1', values: o.map((d: J) => d.max_queued || 0) }, { name: 'In flight', color: 'chart-3', values: o.map((d: J) => d.inflight || 0) }]} />
          </div>
        </Box>
      )}
      {m && <MemoryCard m={m} />}
    </div>
  );
});

function MemoryCard({ m }: { m: J }) {
  const saves = Object.entries(m.saves ?? {}), d = m.last_digest;
  return (
    <Box title="Team memory" note="30 days">
      <Row k={<b>Saves</b>} v={saves.length ? saves.map(([k, n]) => `${n} ${k.replace(/_/g, ' ')}`).join(' · ') : 'none'} />
      <Row k={<b>Learnings</b>} v={`${m.added} live at once · ${m.inbox} to the inbox · ${m.dropped} dropped as instructions`} />
      <Row k={<b>Last digest</b>} v={d ? `${String(d.at).slice(0, 10)} · ${d.result}${d.result === 'opened' ? ` · ${d.added} from the inbox, ${d.inbox} to look at` : ''}` : 'none yet'} />
    </Box>
  );
}

