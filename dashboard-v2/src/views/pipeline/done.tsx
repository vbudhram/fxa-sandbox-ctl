// The Done tab (v1 doneHtml): tiles, the line, the merges per week, and the table, which sorts by column.
import { memo, useMemo, useState } from 'react';
import { BarList, StripPlot } from '../../charts';
import { days, jiraHref, prUrl, usd } from '../../format';
import type { J } from '../../model/base';
import { SNAP, jiraSite, laneTitle, pipe, teamRepo } from '../../model/pipeline';
import { useParts } from '../../app/store';
import type { Store } from '../../store/types';
import { Card, EmptyBox } from '../../ui';
import { doneRows, median, weekOf } from './data';
import { Ext, Tile } from './parts';

type Col = 'key' | 'title' | 'merged' | 'took' | 'by' | 'cost';
const COLS: [Col, string][] = [['key', 'Ticket'], ['title', 'Title'], ['merged', 'Merged'], ['took', 'Days to merge'], ['by', 'Merged by'], ['cost', 'Cost']];

// The tab reads the snapshot and the cost of each ticket only, so a stats row or an agents event does not repaint it.
const PARTS = (s: Store) => [pipe(s), (s.feeds.stats?.data as J)?.tickets];

export function Done() {
  const s = useParts(PARTS), snap = SNAP(s), tickets = (s.feeds.stats?.data as J)?.tickets;
  const [sort, setSort] = useState<{ col: Col; up: boolean }>({ col: 'merged', up: false });
  // Stable rows and charts: a sort click only moves the memo rows, and does not draw the charts again.
  const rows = useMemo(() => doneRows(snap), [snap]);
  const { ws, people, med } = useMemo(() => weeksOf(rows), [rows]);
  const prs = snap?.merged_prs, lbl = snap?.team?.pr_label, cap = snap?.limits?.merged_prs ?? prs?.length ?? 0;
  if (!snap) return <div id="s-done"><EmptyBox>Loading the pipeline…</EmptyBox></div>;
  if (prs == null) return <div id="s-done"><EmptyBox>Could not read merged PRs from GitHub.</EmptyBox></div>;
  if (!rows.length) return <div id="s-done"><EmptyBox>No merged ticket yet.</EmptyBox></div>;
  const wk = rows.filter((r) => (days(r.merged) ?? 99) < 7).length;
  const medText = med == null ? '—' : Math.round(med) === 0 ? 'under 1' : Math.round(med);
  const cost = (r: J): number | null => tickets?.[r.t.key]?.cost ?? null;
  const val: Record<Col, (r: J) => string | number> = {
    key: (r) => r.t.key, title: (r) => laneTitle(r.t.summary).text, merged: (r) => Date.parse(r.merged), took: (r) => (Number.isFinite(r.took) ? r.took : -1),
    by: (r) => r.by ?? '', cost: (r) => cost(r) ?? -1,
  };
  const f = val[sort.col], sorted = rows.slice().sort((a, b) => {
    const x = f(a), y = f(b), c = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y));
    return sort.up ? c : -c;
  });
  return (
    <div id="s-done">
      <div className="ptiles">
        <Tile label="Tickets merged" value={rows.length} sub={`from the last ${cap} merged PRs`} />
        <Tile label="Merged, 7 days" value={wk} sub={wk === 1 ? 'ticket' : 'tickets'} />
        <Tile label="Median days to merge" value={medText} sub="from the PR's creation" />
        <Tile label="Merged by" value={people.length} sub={`${people.length === 1 ? 'person' : 'people'} · ${people[0]![0]} merged ${people[0]![1]}`} />
      </div>
      <div className="pcols">
      <div className="bwrap">
      <h2 className="bsub">Merged tickets <span className="cnt">{rows.length}</span><span className="hint" id="dline">{rows.length} ticket{rows.length === 1 ? '' : 's'} from the last {cap} merged PRs{lbl ? ` labelled ${lbl}` : ''}, newest first.</span></h2>
      <div className="tscroll">
        <table className="dtab">
          <caption className="sr-only">Merged tickets</caption>
          <thead>
            <tr>
              {COLS.map(([c, name]) => (
                <th key={c} scope="col" aria-sort={sort.col === c ? (sort.up ? 'ascending' : 'descending') : undefined}>
                  <button type="button" className="linkbtn" onClick={() => setSort({ col: c, up: sort.col === c ? !sort.up : c !== 'merged' })}>{name}</button>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {sorted.map((r) => <Row key={r.t.key} r={r} s={s} c={cost(r)} costs={!!tickets} />)}
          </tbody>
        </table>
      </div>
      </div>
      <Charts ws={ws} people={people} medText={medText} />
      </div>
    </div>
  );
}

// Merges per local week, oldest first, with the days to merge of each ticket; the merges per person; the median.
function weeksOf(rows: J[]) {
  const weeks = new Map<number, { label: string; rows: J[] }>();
  rows.slice().reverse().forEach((r) => { const w = weekOf(r.merged), e = weeks.get(w.at) ?? { label: w.label, rows: [] }; e.rows.push(r); weeks.set(w.at, e); });
  const ws = [...weeks.values()], by = new Map<string, number>();
  rows.forEach((r) => by.set(r.by || 'unknown', (by.get(r.by || 'unknown') ?? 0) + 1));
  return { ws, people: [...by].sort((a, b) => b[1] - a[1]), med: median(rows.map((r) => r.took)) };
}

const Row = memo(function Row({ r, s, c, costs }: { r: J; s: Store; c: number | null; costs: boolean }) {
  const t = r.t, took = Math.round(r.took), d = r.ago;
  return (
    <tr>
      <td><Ext className="key" href={jiraHref(t.key, jiraSite(s, t.key))}>{t.key}</Ext>{t.pr != null && <> <Ext className="key" href={prUrl(t.pr, teamRepo(s, t.key))}>#{t.pr}</Ext></>}</td>
      <td>{laneTitle(t.summary).text}</td>
      <td title={new Date(Date.parse(r.merged)).toLocaleString()}>{d === 0 ? 'today' : `${d} day${d === 1 ? '' : 's'} ago`}</td>
      <td>{Number.isFinite(took) ? took : '—'}</td>
      <td>{r.by || '—'}</td>
      <td>{c == null ? (costs ? '—' : '?') : usd(c)}</td>
    </tr>
  );
});

const Charts = memo(function Charts({ ws, people, medText }: { ws: { label: string; rows: J[] }[]; people: [string, number][]; medText: string | number }) {
  return (
    <aside className="paside" aria-label="Done details">
      <Card flat sm>
        <h3 className="ph">Merges per week</h3>
        <BarList label="Merges per week" items={ws.map((w) => ({ name: `Week of ${w.label}`, value: w.rows.length }))} />
      </Card>
      <Card flat sm>
        <StripPlot title="Days to merge, per week" unit="days"
          summary={`Days to merge per week of the merge. The median of all is ${medText} days.`}
          groups={ws.map((w) => ({ label: w.label, median: median(w.rows.map((r) => r.took)) ?? undefined,
            points: w.rows.filter((r) => Number.isFinite(r.took)).map((r) => ({ value: Math.round(r.took * 10) / 10, label: r.t.key })) }))}
          table={{ head: ['Week of', 'Ticket', 'Days to merge'], rows: ws.flatMap((w) => w.rows.map((r) => [w.label, r.t.key, Math.round(r.took * 10) / 10])) }} />
      </Card>
      <Card flat sm>
        <h3 className="ph">Merged by</h3>
        <BarList label="Merged by" items={people.map(([name, value]) => ({ name, value }))} />
      </Card>
    </aside>
  );
});
