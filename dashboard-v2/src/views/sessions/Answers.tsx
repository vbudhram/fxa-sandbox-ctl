// Answers: the quick answers of the Stats range as one table, each row opens to its cost (v1 renderAnswers).
import { memo, useCallback, useMemo, useState } from 'react';
import { usd } from '../../format';
import type { State } from '../../live/reducers';
import { type J, STATS } from '../../model/base';
import { answerRows, threadUrl } from '../../model/sessions';
import { Card, EmptyBox, StatTile, Tag, type Tone } from '../../ui';
import { answersIn } from './data';
import { type Col, Columns } from './charts';
import { Usage } from './Details';
import { useNow } from './hooks';

const TONE: Record<string, Tone> = { answered: 'ok', upgraded: 'info', failed: 'bad' };
// One formatter each for all rows: toLocaleString builds a new one each call.
const WHEN = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }), DAY = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric' });
const fmt = (f: Intl.DateTimeFormat, at: string) => { const d = new Date(at); return Number.isNaN(d.getTime()) ? 'Invalid Date' : f.format(d); };
const when = (at: string) => fmt(WHEN, at), day = (at: string) => fmt(DAY, at);
const BUCKETS: [number, string][] = [[10, 'under 10 s'], [30, '10-30 s'], [60, '30-60 s'], [120, '1-2 min'], [300, '2-5 min'], [Infinity, '5 min or more']];

export function Answers({ s }: { s: State }) {
  const now = useNow(60000);
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set());
  // A session delta or an agents feed keeps the rows, so the table rows and the charts skip their repaint.
  const all = answerRows(s), f = s.prefs.statsFilter;
  // eslint-disable-next-line react-hooks/exhaustive-deps -- answersIn reads only the answer rows and the Stats filter of s
  const rows = useMemo(() => answersIn(s, now * 1000), [all, f, now]);
  const flip = useCallback((k: string) => setOpen((o) => { const n = new Set(o); if (n.has(k)) n.delete(k); else n.add(k); return n; }), []);
  if (!STATS(s)) return <div id="s-sess"><EmptyBox>Loading the quick answers…</EmptyBox></div>;
  const n = (k: string) => rows.filter((r) => r.kind === k).length, up = n('upgraded');
  const secs = rows.map((r) => r.secs).filter((x): x is number => typeof x === 'number').sort((a, b) => a - b);
  const med = secs.length ? secs[Math.floor(secs.length / 2)]! : null, cost = rows.reduce((a, r) => a + (r.usd ?? 0), 0);
  return (
    <div id="s-sess">
      {rows.length > 0 && (
        <div className="anstiles">
          <StatTile label="Quick answers" value={rows.length} sub="in the Stats range" />
          <StatTile label="Upgraded to a session" value={up} sub={`${Math.round((up / rows.length) * 100)}% of the answers`} />
          <StatTile label="Median time to answer" value={med == null ? '—' : `${med} s`} sub={`of ${secs.length} timed answers`} />
          <StatTile label="Cost" value={usd(cost)} sub={`${usd(cost / rows.length)} for each answer`} />
        </div>
      )}
      <div className="anscols">
      <Card flat className="anscard">
      <h2 className="ansh">Quick answers <span className="cnt">{rows.length}</span></h2>
      <div className="anshead">{rows.length} quick answers in the Stats range: read-only, no sandbox. Upgraded ones continue as a session.</div>
      {rows.length ? (
        <>
          <div className="overflow-x-auto" tabIndex={0} role="region" aria-label="Quick answers">
            <table className="table figures dense answers">
              <thead><tr><th>When</th><th>Answer</th><th>Outcome</th><th>Time</th><th>Turns</th><th>Cost</th><th>Thread</th></tr></thead>
              <tbody>
                {rows.map((r: J) => <Row key={String(r.key)} r={r} u={threadUrl(s, r.thread)} flip={flip} s={open.has(String(r.key)) ? s : null} />)}
              </tbody>
            </table>
          </div>
        </>
      ) : <EmptyBox>No quick answer in this range.</EmptyBox>}
      </Card>
      {rows.length > 0 && <Charts rows={rows} />}
      </div>
    </div>
  );
}

// memo: s is set only on an open row, for its usage table, so a closed row repaints only when its row changes.
const Row = memo(function Row({ r, u, flip, s }: { r: J; u: string; flip: (k: string) => void; s: State | null }) {
  const k = String(r.key), on = !!s, name = r.q || k;
  return (
    <>
      <tr>
        <td>{when(r.at)}</td>
        <td className={r.q ? undefined : 'mono'}>
          <button type="button" className="linkbtn toggle" title={name} aria-expanded={on} aria-controls={`ans-${k}`} aria-label={`${on ? 'Hide' : 'Show'} the cost breakdown of ${name}`} onClick={() => flip(k)}>{name}</button>
          {r.q && <span className="key">{k}</span>}
        </td>
        <td><Tag label={String(r.kind ?? 'unknown')} tone={TONE[r.kind] ?? 'dim'} /></td>
        <td>{r.secs != null ? `${r.secs} s` : '—'}</td>
        <td>{r.turns ?? '—'}</td>
        <td>{usd(r.usd ?? null)}</td>
        <td>{u ? <a className="text-link" href={u} target="_blank" rel="noopener noreferrer">Slack ↗</a> : r.thread ? <span className="font-mono">{r.thread}</span> : '—'}</td>
      </tr>
      {s && <tr id={`ans-${k}`}><td colSpan={7}><Usage k={k} s={s} /></td></tr>}
    </>
  );
});

// The outcome of each day, and how long the answers took.
// memo: the rows keep their array until the answers or the range change.
const Charts = memo(function Charts({ rows }: { rows: J[] }) {
  const days = new Map<string, Col>(), kinds = ['answered', 'upgraded', 'failed'];
  for (const r of [...rows].reverse()) {
    const d = day(r.at), c = days.get(d) ?? { label: d, parts: kinds.map((k) => ({ tone: TONE[k]!, label: k, value: 0 })) };
    const p = c.parts.find((x) => x.label === r.kind);
    if (p) p.value++;
    days.set(d, c);
  }
  const by = [...days.values()], peak = by.reduce((a: Col | null, c) => (!a || c.parts.reduce((n, p) => n + p.value, 0) > a.parts.reduce((n, p) => n + p.value, 0) ? c : a), null);
  const timed = rows.filter((r) => typeof r.secs === 'number');
  const hist: Col[] = BUCKETS.map(([hi, label], i) => ({ label, parts: [{ tone: 'info', label: 'answers', value: timed.filter((r) => r.secs < hi && r.secs >= (BUCKETS[i - 1]?.[0] ?? 0)).length }] }));
  const n = (k: string) => rows.filter((r) => r.kind === k).length;
  return (
    <aside className="anscharts" aria-label="Answer charts">
      <Card flat sm>
        <Columns title="Outcome per day" cols={by}
          summary={`${rows.length} answers on ${by.length} days: ${n('answered')} answered, ${n('upgraded')} upgraded, ${n('failed')} failed. Most on ${peak?.label ?? 'no day'}.`} />
      </Card>
      <Card flat sm>
        <Columns title="Time to answer" cols={hist}
          summary={`${timed.length} timed answers. ${hist.map((c) => `${c.parts[0]!.value} ${c.label}`).join(', ')}.`} />
      </Card>
    </aside>
  );
});
