// The Spend tab: five KPI tiles, runs and spend per day or week, and where the money went.
import { memo, useState } from 'react';
import type { ChartColor } from '../../charts';
import { modelName, usd } from '../../format';
import type { J } from '../../model/base';
import { convTitle, ownerName, sessHref } from '../../model/sessions';
import { teamLabel } from '../../model/teams';
import type { Store } from '../../store/types';

import { Bars, Scatter } from './lazy';
import { buckets, byModel, conv, group, maxOf, med, plural, sum } from './compute';
import { KIND, SF_SRC, setFilter } from './filter';
import { Box, isKey, JiraKey, Kpi, Row, Sub } from './parts';

const COLORS: ChartColor[] = ['chart-1', 'chart-2', 'chart-3', 'chart-4', 'chart-5'];
const SRCS = Object.keys(SF_SRC);
const dayKey = (t: number) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
export const bucketLabel = (t: number) => new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
export const axisUsd = (v: number) => (v >= 1 || v === 0 ? `$${Math.round(v)}` : usd(v));

export type TabProps = { s: Store; rows: J[]; lo: number; hi: number; now: number; unk: string; srcOn: boolean };

export function Spend({ s, rows, lo, hi, now, unk, srcOn }: TabProps) {
  if (!rows.length) return <div className="emptybox">Nothing matches these filters.</div>;
  // A stale or failed feed may lack the newest runs: a figure of one source says unknown, never a value or 0.
  const kv = (v: string | number) => (unk && srcOn ? 'unknown' : v);
  // A Slack conversation counts once: its resumes share conv. Passes and triage are pipeline overhead, not a ticket.
  const work = rows.filter((r) => r.src !== 'pass'), over = rows.filter((r) => r.src === 'pass');
  const spend = sum(rows), keys = new Set(work.map(conv)).size, compute = rows.reduce((x: number, r: J) => x + (r.compute_usd || 0), 0);
  const mainOnly = rows.filter((r) => r.src === 'pipeline' && r.main_only).length;
  const share = (v: number) => (unk ? 0 : Math.round(v / Math.max(spend, 0.01) * 100));
  const per = Object.entries(SF_SRC).map(([v, l]) => [v, l, rows.filter((r) => r.src === v)] as const).filter(([, , a]) => a.length);
  const convs = group(work, conv);
  const m = med(rows.map((r) => r.min));
  const keyCell = (g: { name: string }) => {
    if (isKey(g.name)) return <JiraKey s={s} k={g.name} />;
    // A session is named by its title for an admin (the title can hold a private team's request), else by its key.
    const x = s.viewer.admin && s.sessions.byKey[g.name];
    const h = sessHref(g.name);
    return x && h ? <a href={h} title={g.name}>{convTitle(s, x)}</a> : <span className="mono">{g.name}</span>;
  };
  // Who a Slack row is for: its session's owner. A routine run is nobody's, so it is left out of By person.
  const person = (r: J) => { if (r.src !== 'slack') return null; const x = s.sessions.byKey[r.key]; return x?.routine_run ? null : x ? ownerName(s, x) : r.who || 'name not recorded'; };
  const persons = group(rows, person).filter((g) => g.name).sort((a, b2) => b2.usd - a.usd);
  const teams = new Set(rows.filter((r) => r.profile).map((r) => r.profile)).size > 1;
  const models = byModel(rows);

  return (
    <>
      {unk && <p className="unknown" role="status">Figures by source unknown: {unk}</p>}
      <div className="kpis">
        <Kpi label="Runs" value={kv(rows.length)} sub={unk ? 'by source unknown' : per.map(([, l, a]) => `${a.length} ${l.toLowerCase()}`).join(' · ')} />
        <Kpi label="Tickets and conversations" value={kv(keys)}
          sub={work.length ? `up to ${maxOf(convs.filter((g) => g.rs[0].src !== 'pass').map((g) => g.rs.length), 0)} runs on one${over.length ? ' · passes and triage left out' : ''}` : ''} />
        <Kpi label="Spend" value={kv(usd(spend))}
          sub={`${mainOnly ? `${plural(mainOnly, 'pipeline run')} count the main agent only` : 'LLM, estimated from tokens'}${compute ? ` · +${usd(compute)} session compute` : ''}`} />
        <Kpi label="Per run" value={kv(usd(spend / rows.length))}
          sub={unk ? 'by source unknown' : per.map(([v, , a]) => `${({ answer: 'answers', pass: 'passes' } as Record<string, string>)[v] ?? v} ${usd(sum([...a]) / a.length)}`).join(' · ')} />
        <Kpi label="Median length" value={kv(m != null ? `${m} min` : '—')} sub="wall time of a run" />
      </div>
      <SpendCharts rows={rows} lo={lo} hi={hi} now={now} />
      <div className="three">
        <Box title="By source">
          {group(rows, 'src').sort((a, c) => c.usd - a.usd).map((g) => (
            <Row key={g.name} p={share(g.usd)} k={<b>{SF_SRC[g.name] ?? g.name}</b>} v={unk ? 'unknown' : <>{g.rs.length} · <b>{usd(g.usd)}</b></>} />
          ))}
          {teams && (
            <>
              <Sub title="By team" note="every source" />
              {group(rows, 'profile').filter((g) => g.name).sort((a, c) => c.usd - a.usd).map((g) => {
                const w = g.rs.filter((r) => r.src !== 'pass').length, ps = g.rs.length - w;
                return <Row key={g.name} p={share(g.usd)} k={<b>{teamLabel(s, g.name)}</b>} v={<>{plural(w, 'run')}{ps ? ` · ${ps} passes` : ''} · <b>{usd(g.usd)}</b></>} />;
              })}
            </>
          )}
        </Box>
        <Box title="Most expensive" note="in this view">
          {over.length > 0 && <Row p={share(sum(over))} k={<b>Pipeline overhead</b>} v={<>{over.length} passes and triage · <b>{usd(sum(over))}</b></>} />}
          {convs.filter((g) => g.rs[0].src !== 'pass').sort((a, c) => c.usd - a.usd).slice(0, 8).map((g) => (
            <Row key={g.name} p={share(g.usd)} k={keyCell(g)} v={<>{g.rs[0].src === 'slack' ? plural(g.rs.length, 'session') : plural(g.rs.length, 'run')} · <b>{usd(g.usd)}</b></>} />
          ))}
          {persons.length > 0 && (
            <>
              <Sub title="By person" note="Slack sessions" />
              {persons.map((g) => <Row key={g.name} p={share(g.usd)} k={<b>{g.name}</b>} v={<>{plural(new Set(g.rs.map(conv)).size, 'conversation')} · <b>{usd(g.usd)}</b></>} />)}
            </>
          )}
        </Box>
        <Box title="Spend by model" note="in this view">
          {models.list.length || models.main || models.none ? (
            <>
              {models.list.map((x) => <Row key={x.model} p={x.pct} k={<span className="mono">{modelName(x.model)}</span>} v={<b>{usd(x.usd)} · {x.pct}%</b>} />)}
              {models.main > 0 && <Row k={<span className="note">{plural(models.main, 'run')} here count all tokens at the main model</span>} v="" />}
              {models.none > 0 && <Row k={<span className="note">{models.none} {models.none === 1 ? 'run has' : 'runs have'} no model recorded</span>} v="" />}
            </>
          ) : <div className="empty">No model recorded for these rows.</div>}
          <Sub title="By kind" />
          {group(rows, 'kind').sort((a, c) => c.rs.length - a.rs.length).map((g) => (
            <Row key={g.name ?? '-'} na={!g.name} k={g.name ? KIND[g.name] ?? g.name : 'Not recorded'} v={`${g.rs.length} · avg ${usd(g.usd / g.rs.length)}`} />
          ))}
        </Box>
      </div>
      <RunScatter rows={rows} />
    </>
  );
}

// The charts read only the rows and the range, so a session or team change repaints the cards and not them.
const SpendCharts = memo(function SpendCharts({ rows, lo, hi, now }: { rows: J[]; lo: number; hi: number; now: number }) {
  const [stack, setStack] = useState<'src' | 'model'>('src');
  const b = buckets(rows, lo, hi, now), unit = b.byDay ? 'day' : 'week';
  const labels = b.list.map((x) => bucketLabel(x.t));
  const cut = b.cut ? `Showing the last ${b.list.length} of ${b.total} weeks.` : undefined;
  // The stack: one series per source, or the top five models and the rest.
  const topModels = byModel(rows).list.slice(0, 5).map((x) => x.model);
  const stackSeries = stack === 'src'
    ? SRCS.filter((k) => b.list.some((x) => x.src[k])).map((k, i) => ({ name: SF_SRC[k]!, color: COLORS[i % 5]!, values: b.list.map((x) => x.src[k] ?? 0) }))
    : [...topModels.map((k, i) => ({ name: modelName(k), color: COLORS[i]!, values: b.list.map((x) => x.model[k] ?? 0) })),
      { name: 'Other models', color: 'chart-muted' as const, values: b.list.map((x) => Object.entries(x.model).filter(([k]) => !topModels.includes(k)).reduce((n, [, v]) => n + v, 0)) }]
      .filter((x) => x.values.some(Boolean));
  // A click on a bucket narrows the range to that day or week.
  const drill = (i: number) => {
    const t = b.list[i]?.t;
    if (t == null) return;
    const end = new Date(t); if (!b.byDay) end.setDate(end.getDate() + 6);
    setFilter({ range: 'custom', from: dayKey(t), to: dayKey(end.getTime()) });
  };
  return (
    <div className="charts">
      <div className="st-chart" id="st-runs">
        <Bars title={`Runs per ${unit}`} what={`Runs per ${unit}`} labels={labels} format={(v) => String(Math.round(v))} note={cut}
          series={[{ name: 'Runs', color: 'chart-1', values: b.list.map((x) => x.runs) }]} onPick={drill} />
      </div>
      <div className="st-chart" id="st-spend">
        <div className="st-toggle" role="group" aria-label="Stack the spend by" data-new>
          <span>Stack by</span>
          <button type="button" aria-pressed={stack === 'src'} onClick={() => setStack('src')}>Source</button>
          <button type="button" aria-pressed={stack === 'model'} onClick={() => setStack('model')}>Model</button>
        </div>
        <Bars title={`Spend per ${unit}`} what={`Spend per ${unit}, by ${stack === 'src' ? 'source' : 'model'}`} labels={labels} format={axisUsd} series={stackSeries} onPick={drill}
          note={<>{cut ? `${cut} ` : ''}Click a bar to see that {unit} only.{stack === 'model' ? ' By model counts subagents where the proxy priced the run.' : ''}</>} />
      </div>
    </div>
  );
});

// One point per run: the costliest chart to draw, so it repaints only for new rows.
const RunScatter = memo(function RunScatter({ rows }: { rows: J[] }) {
  const scatter = rows.filter((r) => typeof r.min === 'number').map((r) => ({ x: r.min, y: (r.usd || 0) + (r.compute_usd || 0), label: String(r.key ?? '') }));
  return (
    <div className="charts" data-new>
      <div className="st-chart">
        <Scatter title="Cost against run length" what="Cost against run length, one point per run" points={scatter}
          x={{ name: 'Length', format: (v) => `${Math.round(v)} min` }} y={{ name: 'Cost', format: axisUsd }} />
      </div>
    </div>
  );
});
