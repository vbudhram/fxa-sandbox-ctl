// The PRs tab: opened, merged and closed PRs in the range, what each cost, and how long a merge took.
import { memo, useMemo } from 'react';
import { Sankey } from '../../charts';
import { usd } from '../../format';
import type { J } from '../../model/base';
import { teamRepo } from '../../model/pipeline';
import { Bars, Scatter } from './lazy';
import { buckets, dur, leadBins, maxOf, med, prsData, rate } from './compute';
import { Box, isKey, JiraKey, Kpi, PrLink, Row, Sub } from './parts';
import { axisUsd, bucketLabel, type TabProps } from './Spend';

const SRC: Record<string, string> = { pipeline: 'Pipeline', slack: 'Slack sessions' };

export function Prs({ s, rows, lo, hi, now, unk, srcOn, all, src, q }: TabProps & { all: J[]; src: string; q: string }) {
  const runs: J[] | undefined = (s.feeds.stats?.data as J)?.rows;
  const repo = teamRepo(s, '');
  // A session or team event does not change the PR figures, so it does not recount them.
  const d = useMemo(() => prsData(all, runs ?? [], lo, hi, src, q, repo, now), [all, runs, lo, hi, src, q, repo, now]);
  if (d.empty) return <div className="emptybox">{all.length ? 'No PR opened or merged in this range matches these filters.' : 'No PR list yet.'}</div>;
  const kv = (v: string | number) => (unk && srcOn ? 'unknown' : v);
  const b = buckets(rows, lo, hi, now), unit = b.byDay ? 'day' : 'week';
  const mergedBy = new Map<number, number>();
  for (const p of d.merged) { const t = b.bucketOf(Date.parse(p.merged)); mergedBy.set(t, (mergedBy.get(t) ?? 0) + 1); }
  const ticket = (p: J) => (p.src !== 'pipeline' || !isKey(p.key) ? null
    : p.jira ? (/^done$/i.test(p.jira.status ?? '') ? null : ` · ${p.jira.assignee || 'unassigned'}, ${p.jira.status || '?'}`)
      : <> · <span className="warnt">ticket not updated yet</span></>);
  const line = (p: J) => (
    <div key={`${p.key}-${p.n}`} title={p.title}>
      <Row k={<span><PrLink s={s} k={p.key} n={p.n} /> {isKey(p.key) ? <JiraKey s={s} k={p.key} /> : <span className="mono">{p.key}</span>}</span>}
        v={<>{p.state === 'MERGED' ? <>{dur(d.hrs(p))} · <span className="add">+{p.add}</span> <span className="del">−{p.del}</span>{ticket(p)}</>
          : p.state === 'OPEN' ? `open ${dur((now - Date.parse(p.created)) / 3600000)}` : 'closed'} · <b>{usd(d.cost(p))}</b></>} />
    </div>
  );
  const list = (l: J[], none: string) => (l.length ? l.slice(0, 10).map(line) : <div className="empty">{none}</div>);
  const hrs = d.merged.map(d.hrs);

  return (
    <>
      <div className="kpis">
        <Kpi label="Opened" value={kv(d.opened.length)} sub={Object.entries(SRC).map(([v, l]) => { const n = d.opened.filter((p) => p.src === v).length; return n ? `${n} ${l.toLowerCase()}` : ''; }).filter(Boolean).join(' · ')} />
        <Kpi label="Merged" value={kv(d.merged.length)} sub="merged in this range, whenever opened" />
        <Kpi label="Closed, not merged" value={kv(d.closed.length)} sub={`closed in this range · ${d.openIn.length} opened in it still open`} />
        <Kpi label="Time to merge" value={kv(d.merged.length ? dur(med(hrs)!) : '—')} sub={d.merged.length ? `median · slowest ${dur(maxOf(hrs))}` : ''} />
        <Kpi label="Cost per merged PR" value={kv(d.mergedIn.length ? usd(d.spentIn / d.mergedIn.length) : '—')}
          sub={`all spend in this range, ${usd(d.spentIn)}, over ${d.mergedIn.length} merged${d.merged.length ? ` · one PR's own runs: median ${usd(med(d.mergedCosts))}` : ''} · last 4 full weeks ${d.weeks.map((w) => (w == null ? '—' : usd(w))).join(' → ')}`} />
      </div>
      <div className="charts">
        <div className="st-chart" id="st-merged">
          <Bars title={`Merged per ${unit}`} what={`Merged PRs per ${unit}, by merge date, with the filters of the Merged tile`} labels={b.list.map((x) => bucketLabel(x.t))}
            format={(v) => String(Math.round(v))} series={[{ name: 'Merged PRs', color: 'chart-1', values: b.list.map((x) => mergedBy.get(x.t) ?? 0) }]}
            note={b.cut ? `Showing the last ${b.list.length} of ${b.total} weeks. By merge date.` : 'By merge date.'} />
        </div>
        <Box title="By source" note="PRs opened in this range">
          {d.bySrc.map((x) => (
            <Row key={x.src} k={<b>{SRC[x.src]}</b>}
              v={<>{x.opened} opened · {x.merged} merged ({rate(x.merged, x.closed)}) · median {x.median != null ? dur(x.median) : '—'} · <span className="add">+{x.add}</span> <span className="del">−{x.del}</span></>} />
          ))}
          <Sub title="Merged by" />
          {d.who.length ? d.who.map(([k, n]) => <Row key={k} k={<span className="mono">{k}</span>} v={<b>{n}</b>} />) : <div className="empty">None merged.</div>}
        </Box>
      </div>
      <div className="three">
        <Box title="Recently merged" note="time to merge · lines · cost">{list(d.recent, 'None merged.')}</Box>
        <Box title="Still open" note="oldest first, any age">{list(d.openAll, 'None open.')}</Box>
        <Box title="Costliest merged" note="every run on the PR">
          {list(d.costliest, 'None merged.')}
          {d.closed.length > 0 && <><Sub title="Closed, not merged" note="newest first" />{list(d.closed, '')}</>}
        </Box>
      </div>
      <PrsCharts d={d} />
    </>
  );
}

// The flow, lead time and size charts read only the PR figures, so a session or team event does not redraw them.
const PrsCharts = memo(function PrsCharts({ d }: { d: ReturnType<typeof prsData> }) {
  const flow = { merged: d.opened.filter((p) => p.state === 'MERGED').length, closed: d.opened.filter((p) => p.state === 'CLOSED').length, open: d.opened.filter((p) => p.state === 'OPEN').length };
  const sankeyRows = [['Merged', flow.merged], ['Closed, not merged', flow.closed], ['Still open', flow.open]] as const;
  const bins = leadBins(d.merged.map(d.hrs));
  return (
    <div className="charts" data-new>
      <div className="st-chart">
        <Sankey title="Where the PRs opened in this range went" summary={`${d.opened.length} PRs opened: ${flow.merged} merged, ${flow.closed} closed, ${flow.open} still open.`}
          table={{ head: ['Outcome', 'PRs'], rows: sankeyRows.map(([l, n]) => [l, n]) }}
          nodes={[{ id: 'opened', label: 'Opened' }, { id: 'merged', label: 'Merged' }, { id: 'closed', label: 'Closed' }, { id: 'open', label: 'Still open' }]}
          links={[{ source: 'opened', target: 'merged', value: flow.merged }, { source: 'opened', target: 'closed', value: flow.closed }, { source: 'opened', target: 'open', value: flow.open }]} />
      </div>
      <div className="st-chart">
        <Bars title="Time to merge" what="PRs merged in this range by time to merge" labels={bins.map((x) => x.label)} format={(v) => String(Math.round(v))}
          series={[{ name: 'Merged PRs', color: 'chart-3', values: bins.map((x) => x.n) }]} />
      </div>
      <div className="st-chart">
        <Scatter title="Cost against PR size" what="Cost of each merged PR against its lines changed"
          points={d.merged.map((p) => ({ x: (p.add || 0) + (p.del || 0), y: d.cost(p), label: `#${p.n} ${p.key}` }))}
          x={{ name: 'Lines changed', format: (v) => String(Math.round(v)) }} y={{ name: 'Cost', format: axisUsd }} />
      </div>
    </div>
  );
});
