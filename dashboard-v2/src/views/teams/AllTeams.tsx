// All teams: the tiles, the drafts that wait for a step, and the table with sortable columns.
import { memo, useEffect, useState } from 'react';
import { Spark } from '../../charts';
import { ago, usd } from '../../format';
import { getJson } from '../../live/api';
import { type J, STATS } from '../../model/base';
import { teamName } from '../../model/teams';
import { useApp } from '../../store';
import { Card, StatTile, Tag } from '../../ui';
import { allTeams, budgetOf, plural, teamDaysBy, teamDraftOf, teamProblem, teamTestState } from './lib';
import { BudgetCell, ProblemCell, TestCell } from './parts';

type Col = { k: string; label: string; key: (t: J) => string | number };
const COLS: Col[] = [
  { k: 'team', label: 'Team', key: (t) => (t.load_error ? t.profile : teamName(t)).toLowerCase() },
  { k: 'status', label: 'Status', key: (t) => (t.load_error ? 'did not load' : teamDraftOf(t) ? t.access.status : 'active') },
  { k: 'cost', label: 'Cost this month', key: (t) => { const b = budgetOf(t); return 'spent' in b ? b.spent : -1; } },
  { k: 'activity', label: 'Activity, 30 days', key: () => 0 },
  { k: 'test', label: 'Last test', key: (t) => teamTestState(t) },
  { k: 'problem', label: 'Problems', key: (t) => teamProblem(t)?.text ?? '' },
];

function status(t: J): [string, 'ok' | 'warn' | 'bad' | undefined] {
  return t.load_error ? ['did not load', 'bad'] : teamDraftOf(t) ? [t.access.status, t.access.status === 'disabled' ? 'warn' : undefined] : ['active', 'ok'];
}

// memo: a stats frame repaints only the rows whose 30 days changed.
const Row = memo(function Row({ t, n, known }: { t: J; n: number[]; known: boolean }) {
  const [st, tone] = status(t), total = n.reduce((x, y) => x + y, 0);
  return (
    <tr>
      <td><a href={`#teams/${t.profile}`} className="tname">{t.load_error ? t.profile : teamName(t)}</a></td>
      <td>
        <Tag label={st} tone={tone} />
        {t.read_only && <> <Tag label="read-only" title="This team gets diffs only, never a PR" /></>}
        {t.access?.open === 'built-in' && <> <Tag label="built in" title="Built into the bot: the operator changes it in the repo" /></>}
      </td>
      <td className="tbud">{t.load_error ? '—' : <BudgetCell t={t} />}</td>
      <td className="tspark">{known && total ? <Spark label={`${t.load_error ? t.profile : teamName(t)}: ${plural(total, 'session or run', 'sessions and runs')} in 30 days`} values={n} /> : <span className="na">{known ? 'none' : '—'}</span>}</td>
      <td>{t.load_error ? '—' : <TestCell t={t} />}</td>
      <td>{t.load_error ? <Tag label="did not load" tone="bad" /> : <ProblemCell t={t} />}</td>
    </tr>
  );
}, (a, b) => a.t === b.t && a.known === b.known && a.n.join() === b.n.join());

export function AllTeams() {
  const a = useApp(allTeams), admin = useApp((s) => s.viewer.admin), rows = useApp((s) => STATS(s)?.rows ?? null);
  const err = useApp((s) => s.feeds.teams?.error ?? null), age = useApp((s) => s.feeds.teams?.ageSeconds ?? null);
  // The teams feed keeps the rows only, so the top-level issues come from one read of /api/teams.
  const [issues, setIssues] = useState<J[]>([]);
  useEffect(() => {
    void getJson<J>('/api/teams').then((g) => 'data' in g && Array.isArray(g.data.issues) && setIssues(g.data.issues));
  }, []);
  const [sort, setSort] = useState<{ k: string; dir: 1 | -1 } | null>(null);
  const col = COLS.find((c) => c.k === sort?.k);
  const ts = col && sort ? [...a.ts].sort((x, y) => (col.key(x) < col.key(y) ? -1 : col.key(x) > col.key(y) ? 1 : 0) * sort.dir) : a.ts;
  const days = teamDaysBy(rows);
  return (
    <div className="tpage">
      <div className="thead-row">
        <h2 className="th" id="team-h" tabIndex={-1}>All teams</h2>
        {admin && <a className="btn" href="#teams/new">New team</a>}
      </div>
      {err && <p className="unknown">last refresh failed: {err}; showing data from {age == null ? 'an earlier read' : ago(Math.round(age))}</p>}
      {issues.map((i, n) => <div key={n} className="alert warn"><span className="mono">{i.key}</span><span className="what">{i.text}</span></div>)}
      <div className="tkpis">
        <StatTile label="Teams" value={a.ok.length} sub={`${a.act.length} active${a.drafts.length ? ` · ${a.drafts.length} not set up` : ''}`} />
        <StatTile label="Cost this month" value={a.bt.length ? usd(a.spent) : '—'} sub={a.top ? `${teamName(a.top)} ${usd(a.top.budget.month_usd)}` : ''} />
        <StatTile label="Needs attention" value={a.needs} sub={a.needs ? 'see Problems below' : 'none'} tone={a.needs ? 'warn' : undefined} />
        <div title="active record teams only"><StatTile label="Tests" value={a.rec ? `${a.passed} of ${a.rec}` : '—'} sub="teams with a test that passed it" /></div>
      </div>
      {admin && a.drafts.map((t) => (
        <Card key={t.profile} href={`#teams/${t.profile}/settings`} className="tdraft">
          <span className="who">
            <span className="row"><span className="nm">{teamName(t)}</span><Tag label={t.access.status} tone={t.access.status === 'disabled' ? 'warn' : undefined} /></span>
            <span className="says">{t.access.status === 'disabled' ? 'Off. Test it to turn it on again.' : 'Next: test and activate it.'}</span>
          </span>
          <Tag label="1 step left" tone="warn" />
        </Card>
      ))}
      <Card>
        <h2>All teams<span className="n">{a.ts.length}</span></h2>
        <div className="tscroll">
          <table className="ttable" data-teams>
            <thead>
              <tr>
                {COLS.map((c) => {
                  const on = sort?.k === c.k;
                  return (
                    <th key={c.k} scope="col" aria-sort={on ? (sort.dir === 1 ? 'ascending' : 'descending') : undefined}>
                      {c.k === 'activity' ? c.label : (
                        <button type="button" className="sortbtn" onClick={() => setSort(on && sort.dir === 1 ? { k: c.k, dir: -1 } : on ? null : { k: c.k, dir: 1 })}>
                          {c.label}<span aria-hidden="true">{on ? (sort.dir === 1 ? ' ▲' : ' ▼') : ''}</span>
                        </button>
                      )}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {ts.map((t) => <Row key={t.profile} t={t} n={days(t.profile)} known={!!rows} />)}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}
