// The Overview: what runs, what it costs, and how the teams do; two columns on a wide screen.
import { memo, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Boundary } from '../../app/parts';
import { useParts } from '../../app/store';
import type { ViewChunk } from '../../app/views';
import { Heatmap, Spark, type ChartColor } from '../../charts';
import { ago, jiraHref, modelName, plainMd, usd } from '../../format';
import { latest } from '../../live/api';
import { costPerMerged, ovFloor, pipeSnap } from '../../model';
import type { J } from '../../model/base';
import { sessHref, sessTabOf } from '../../model/sessions';
import { kpiChange, ovKpis, ovSpend, ovStats, ovTeams, statsBounds } from '../../model/stats';
import { teamAccess, teamLabel, teamName } from '../../model/teams';
import { format } from '../../router';
import type { Route } from '../../router/types';
import { dispatch, setRoute, store, useApp } from '../../store';
import type { Store } from '../../store/types';
import { EmptyBox, Kv, Meter, Tag, type Tone } from '../../ui';
import { cx } from '../../ui/tone';
import { OvChart, type Point, type Series } from './chart';
import {
  OV_METRICS, OV_RANGES, OV_SRC, RUN_KIND, SRC_NAME, WEEKDAYS, byTeam, capOf, headOf, median, metricOf, ovBudget, ovHours, ovLlm, ovWeek,
  overviewOf, prsWhy, quart, rangeName, rangeOf, rowMs, teamSpark, type Metric, type Range,
} from './model';
import { runBadge, statsNote } from '../shared/stats';
import './overview.css';

const SWATCH: Record<ChartColor, string> = { 'chart-1': 'bg-chart-1', 'chart-2': 'bg-chart-2', 'chart-3': 'bg-chart-3', 'chart-4': 'bg-chart-4', 'chart-5': 'bg-chart-5', 'chart-muted': 'bg-chart-muted' };
// One formatter each: toLocaleDateString with options builds a new one each call, about 25 µs a call.
const DAY_FMT = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }), TIME_FMT = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const shortDay = (t: number) => DAY_FMT.format(t);
const money = (v: number) => (v === 0 || Math.abs(v) >= 1 ? `$${Math.round(v)}` : usd(v));
const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

// The figures move with the clock: a new minute computes them again.
function useNow(ms = 60000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(id);
  }, [ms]);
  return now;
}

// Range and metric live in the hash; replace, so a click keeps the scroll and the focus.
function setQuery(q: Partial<Route['query']>) {
  const r = store.getState().route, next = { ...r, query: { ...r.query, ...q } };
  history.replaceState(null, '', format(next));
  setRoute(next);
}

// The slim /api/overview slice fills the cards until the full stats load (v1 loadOverview).
function useOverviewFeed() {
  const has = useApp((s) => !!s.feeds.stats?.data);
  useEffect(() => {
    if (has || store.getState().feeds.overview) return;
    void latest<J>('ov-slice', '/api/overview').then((g) => {
      const ov = g && 'data' in g ? overviewOf(g.data) : null;
      if (ov) dispatch({ event: 'feed', data: { name: 'overview', data: ov, age_seconds: 0, interval: 0, error: null, refreshing: false, fetched_at: Math.round(Date.now() / 1000) } });
    });
  }, [has]);
}

function Sec({ id, sm, className, children }: { id: string; sm?: boolean; className?: string; children: ReactNode }) {
  return <section id={id} className={cx('card', sm && 'sm', className)}>{children}</section>;
}
// A card head: the h2 is the plain title, so a heading list reads well; the count or link sits beside it.
const Hd = ({ t, children }: { t: ReactNode; children?: ReactNode }) => <div className="cardhd"><h2>{t}</h2>{children}</div>;
const Go = () => <span aria-hidden="true"> ›</span>;

function Main() {
  const route = useApp((s) => s.route);
  const range = rangeOf(route.query.range), metric = metricOf(route.query.metric), team = route.query.team ?? '';
  const now = useNow();
  useOverviewFeed();
  const stats = useApp((s) => s.feeds.stats), slim = useApp((s) => s.feeds.overview);
  // The stats-only store that the stats functions read, so a session delta computes nothing again; a team keeps its own rows.
  const fs = useMemo(() => ({ feeds: {
    stats: stats && { ...stats, data: byTeam(stats.data as J, team) }, overview: slim && { ...slim, data: byTeam(slim.data as J, team) },
  } }) as unknown as Store, [stats, slim, team]);
  // Old stats still show, with one notice at the top; a card says unknown only when there is no stats at all.
  const full = statsNote(stats, now), has = !!ovStats(fs), note = has ? '' : full;
  const p = { fs, range, note, now, team };
  return (
    <div className="ov">
      <Boundary><Head {...p} /></Boundary>

      <div className="ovgrid">
        <div className="ovcol">
          <Boundary><MainCard {...p} metric={metric} /></Boundary>
          <Boundary><Activity {...p} /></Boundary>
        </div>
        <div className="ovrail">
          <Boundary><Budget {...p} /></Boundary>
          <Boundary><Llm {...p} /></Boundary>
          <Boundary><Hours {...p} /></Boundary>
        </div>
      </div>
      <Boundary><Teams {...p} /></Boundary>
    </div>
  );
}

type P = { fs: Store; range: Range; note: string; now: number; team: string };

function Head({ fs, range, note, team }: P) {
  const f = useApp(ovFloor) as J, list = useApp((s) => s.feeds.teams?.data);
  const st = ovStats(fs), hr = st?.llm?.hour_usd, h = headOf(f);
  const teams = (Array.isArray(list) ? list : []).filter((t: J) => t.profile && !t.load_error) as J[];
  return (
    <section id="ov-head">
      <Tag label={h.tag} tone={f.atWork ? 'info' : 'dim'} run live={!!f.atWork} />
      {h.who && <span className="ovwho">{h.who}{team ? ', every team' : ''}</span>}
      <span className="ovkpi">LLM, last hour <b>{note ? 'unknown' : !st ? 'loading' : typeof hr === 'number' ? usd(hr) : 'unknown'}</b></span>
      <div className="ovfilters">
        {teams.length > 1 && (
          <label className="ovteam"><span className="vh">Team</span>
            <select data-ovteam value={team} onChange={(e) => setQuery({ team: e.target.value || undefined })}>
              <option value="">All teams</option>
              {teams.map((t) => <option key={t.profile} value={t.profile}>{teamName(t)}</option>)}
            </select>
          </label>
        )}
        <div className="seg" role="group" aria-label="Range">
          {OV_RANGES.map(([k, l]) => <button key={k} type="button" data-ovrange={k} aria-pressed={range === k} onClick={() => setQuery({ range: k })}>{l}</button>)}
        </div>
      </div>
    </section>
  );
}

const pct = (v: number | null) => (v == null ? '—' : `${Math.round(v * 100)}%`);
const mins = (v: number | null) => (v == null ? '—' : `${Math.round(v)} min`);
const dayHref = (t: number, range: Range, now: number) => {
  // The router keeps no day: today and yesterday have their own range, another day opens the card's range.
  const d = Math.round((statsBounds('today', now)[0] - t) / 86400000);
  return format({ view: 'stats', tab: 'spend', sel: '', rid: '', query: { range: d === 0 ? 'today' : d === 1 ? 'yesterday' : range } });
};

// Each metric by day, oldest first, for the small trend line under its value; a day with no pipeline run has no rate or median.
const SPARK: Record<Metric, (d: J) => number | null> = {
  spend: (d) => d.usd, runs: (d) => Object.values(d.n as Record<string, number>).reduce((a, b) => a + b, 0), merged: (d) => d.merged,
  rate: (d) => (d.pipe ? (d.pr / d.pipe) * 100 : null), median: (d) => median(d.mins),
};
const SPARK_FMT: Record<Metric, (v: number) => string> = { spend: usd, runs: (v) => String(v), merged: (v) => String(v), rate: (v) => `${Math.round(v)}%`, median: (v) => `${Math.round(v)} min` };

function MainCard({ fs, range, note, now, metric, team }: P & { metric: Metric }) {
  const s = ovStats(fs), n = rangeName(range);
  const k = useMemo(() => (s ? ovKpis(fs, range, now) : null), [s, fs, range, now]);
  const sp = useMemo(() => (s ? ovSpend(fs, range) : null), [s, fs, range]);
  if (!s || !k || !sp) return <Sec id="ov-main"><Hd t={`Last ${n}`} /><EmptyBox>{note ? `Stats unknown: ${note}` : 'Loading the stats…'}</EmptyBox></Sec>;
  const why = prsWhy(s, now), m = metric;
  const tabs: Record<Metric, [string, { t: string; c: string }]> = {
    spend: [usd(k.spend.v), kpiChange(k.spend, 'pct', true)], runs: [k.runs.v.toLocaleString(), { ...kpiChange(k.runs, 'pct', false), c: '' }],
    merged: [why ? '—' : String(k.merged.v), why ? { t: '', c: '' } : kpiChange(k.merged, 'pct', false)], rate: [pct(k.rate.v), kpiChange(k.rate, 'pts', false)], median: [mins(k.med.v), kpiChange(k.med, 'min', true)],
  };
  let head: ReactNode, chart: ReactNode, leg: ReactNode = null;
  const go = (i: number) => { location.hash = dayHref(sp.days[i].t, range, now); };
  if (m === 'spend' || m === 'runs') {
    const isS = m === 'spend', tot = isS ? sp.total : k.runs.v, by = (d: J) => (isS ? d.by : d.n);
    const data: Point[] = sp.days.map((d: J) => ({ lbl: shortDay(d.t), ...Object.fromEntries(OV_SRC.map(([src]) => [src, by(d)[src] ?? 0])) }));
    // A source with no run in the range draws no area, only a stray outline: leave it out, as the cards do.
    const series: Series[] = OV_SRC.filter(([src]) => note || (sp.nby[src] ?? 0) > 0).map(([src, color]) => ({ key: src, name: SRC_NAME[src]!, color }));
    const f = isS ? usd : (v: number) => String(Math.round(v)), pk = sp.days.reduce((a: J, d: J) => { const v = isS ? d.usd : Object.values(d.n as Record<string, number>).reduce((x, y) => x + y, 0); return v > (a?.v ?? 0) ? { t: d.t, v } : a; }, null);
    chart = tot ? (
      <OvChart title={`${isS ? 'Spend' : 'Runs'} by day and source, last ${n}`} data={data} series={series} stacked fmt={isS ? money : f} height={200} onPick={go}
        summary={`${isS ? 'Spend' : 'Runs'} by day and source, last ${n}. Total ${isS ? usd(tot) : tot.toLocaleString()}.${pk ? ` Peak ${shortDay(pk.t)}, ${f(pk.v)}.` : ''}`}
        table={{ head: ['Day', ...series.map((x) => x.name), 'Total'], rows: data.map((d) => [d.lbl, ...series.map((x) => f(Number(d[x.key]))), f(series.reduce((a, x) => a + Number(d[x.key]), 0))]) }} />
    ) : <EmptyBox>{isS ? `$0.00 · no runs in the last ${n}` : `No run in the last ${n}.`}</EmptyBox>;
    head = <a className="ovopen" href={`#stats/spend?range=${range}`}><span className="go">Open in Stats<Go /></span></a>;
    // A stale or failed feed may lack a source's newest runs, so a source figure says unknown, never a value or 0.
    // The share says what part of the total a source is; the bar it replaced did not say it.
    const share = (src: string) => { const v = isS ? sp.by[src] ?? 0 : sp.nby[src] ?? 0; return tot ? `${Math.round((100 * v) / tot)}% of ${isS ? 'spend' : 'runs'}` : ''; };
    leg = (
      <ul className="ovkinds" aria-label={`${isS ? 'Spend' : 'Runs'} by source`}>
        {OV_SRC.filter(([src]) => note || (sp.nby[src] ?? 0) > 0).map(([src, col]) => {
          const body = (
            <>
              <span className="kn"><i className={SWATCH[col]} />{SRC_NAME[src]}</span>
              <b>{note ? 'unknown' : isS ? usd(sp.by[src] ?? 0) : (sp.nby[src] ?? 0).toLocaleString()}{!note && isS && <span className="hint"> · {(sp.nby[src] ?? 0).toLocaleString()} runs</span>}</b>
              {!note && <span className="hint">{share(src)}</span>}
            </>
          );
          return <li key={src}>{isS ? <a href={`#stats/spend?range=${range}&src=${src}${team ? `&team=${team}` : ''}`}>{body}</a> : <span>{body}</span>}</li>;
        })}
      </ul>
    );
  } else if (m === 'merged') {
    const data: Point[] = sp.days.map((d: J) => ({ lbl: shortDay(d.t), merged: d.merged })), tot = data.reduce((a, d) => a + Number(d.merged), 0);
    chart = why ? <EmptyBox>Merged PRs unknown: {why}</EmptyBox> : (
      <OvChart title={`PRs merged by day, last ${n}`} data={data} series={[{ key: 'merged', name: 'Merged PRs', color: 'chart-1', mark: 'bar' }]} fmt={(v) => String(Math.round(v))} onPick={go}
        summary={`PRs merged by day, last ${n}. Total ${tot}.`} table={{ head: ['Day', 'Merged PRs'], rows: data.map((d) => [d.lbl, Number(d.merged)]) }} />
    );
    const c = costPerMerged(statsBounds('7d', now)[0], Infinity, s.prs, s.rows);
    head = why ? null : (
      <>
        <a className="ovopen" href="#stats/prs?range=7d"><span className="lbl">Cost per merged PR, 7 days</span> <b className="big">{c.per != null ? usd(c.per) : '—'}</b> <span className="go">{c.per != null ? `${usd(c.spentIn)} all-in over ${c.mergedIn.length}` : 'no PR merged in 7 days'}<Go /></span></a>
      </>
    );
  } else {
    const isR = m === 'rate', dm = sp.days.map((d: J) => median(d.mins)).filter((v: number | null) => v != null) as number[];
    const val = (d: J) => (isR ? (d.pipe ? (d.pr / d.pipe) * 100 : null) : median(d.mins));
    const data: Point[] = sp.days.map((d: J) => ({ lbl: shortDay(d.t), v: val(d), ...(isR ? {} : { band: quart(d.mins) }) }));
    const f = isR ? (v: number) => `${Math.round(v)}%` : (v: number) => `${Math.round(v)} min`, name = isR ? 'Runs that made a PR' : 'Median run';
    const series: Series[] = [...(isR ? [] : [{ key: 'band', name: '25th to 75th percentile', color: 'chart-1' as const, mark: 'band' as const }]), { key: 'v', name, color: 'chart-1', mark: 'line' }];
    const title = isR ? `Share of pipeline runs that made a PR, by day, last ${n}` : `Median pipeline run, by day, last ${n}`;
    chart = !sp.days.some((d: J) => val(d) != null) ? <EmptyBox>No pipeline run in the last {n}.</EmptyBox> : (
      // One stuck run would scale the axis to itself, so the axis stops at 3 times the typical day; the tip keeps the true value.
      <OvChart title={title} data={data} series={series} fmt={f} yMax={isR || !dm.length ? undefined : 3 * median(dm)!} onPick={go}
        summary={`${title}. ${data.filter((d) => d.v != null).length} days with a run.`}
        table={{ head: ['Day', name, ...(isR ? [] : ['25th to 75th percentile'])], rows: data.map((d) => [d.lbl, d.v == null ? 'none' : f(Number(d.v)), ...(isR ? [] : [d.band ? (d.band as number[]).map(f).join(' to ') : 'none'])]) }} />
    );
    const had = data.filter((d) => d.v != null), lo = had.reduce<Point | null>((a, d) => (!a || Number(d.v) < Number(a.v) ? d : a), null), hi = had.reduce<Point | null>((a, d) => (!a || Number(d.v) > Number(a.v) ? d : a), null);
    head = <span className="sub">{isR ? `${k.rate.n} pipeline run${k.rate.n === 1 ? '' : 's'} in the last ${n}`
      : `Median ${mins(k.med.v)} per pipeline run${lo && hi && had.length > 1 ? ` · Fastest day ${lo.lbl}, ${f(Number(lo.v))} · Slowest day ${hi.lbl}, ${f(Number(hi.v))}` : ''}`}</span>;
    if (!isR) head = <>{head}<div className="ovleg"><span><i className="bg-chart-1" />Line: the median run of the day</span><span><i className="bg-chart-1 op" />Shaded: the middle half of the runs</span></div></>;
  }
  const pk = sp.peak, pkText = m === 'spend' && pk ? `Peak ${shortDay(pk.t)}: ${usd(pk.usd)}${why ? '' : `, ${pk.merged} PR${pk.merged === 1 ? '' : 's'} merged that day`}` : '';
  return (
    <Sec id="ov-main">
      <h2 className="vh">Last {n}{team ? `, ${teamLabel(store.getState(), team)}` : ''}</h2>
      <div className="mtabs" role="group" aria-label="Metric">
        {OV_METRICS.map(([key, lbl]) => {
          const [v, c] = tabs[key];
          return (
            <button key={key} type="button" className="mt" data-ovmetric={key} aria-pressed={m === key} onClick={() => setQuery({ metric: key })}>
              <span className="ml">{lbl}<span className="vh">: </span></span><span className="mv">{v}</span>
              {/* A trend under the value; hidden from a screen reader, since the button name is the metric and the chart below has the days. */}
              <span className="msp" aria-hidden="true">{!(key === 'merged' && why) && <Spark label={`${lbl} by day, last ${key === 'merged' ? '7 days' : n}`} values={(key === 'merged' ? sp.days.slice(-7) : sp.days).map(SPARK[key])} format={SPARK_FMT[key]} />}</span>
              <span className="mdelta">{c.t ? <><span className={`chg ${c.c}`.trim()}>{c.t}{c.c && ` ${c.c === 'good' ? 'better' : 'worse'}`}</span> vs the {key === 'merged' ? '7 days' : n} before</> : key === 'merged' && why ? why : v === '—' ? '' : `No full ${key === 'merged' ? '7 days' : n} before to compare`}</span>
            </button>
          );
        })}
      </div>
      {note && <div className="ovknote">{note}</div>}
      <div className="ovhead">{head}{pkText && <span className="sub">{usd(sp.perDay)} a day on average · {pkText}</span>}</div>
      {chart}{leg}
      {m === 'spend' && <p className="vh">Spend in the last {n}: {usd(sp.total)}, {OV_SRC.filter(([src]) => note || (sp.nby[src] ?? 0) > 0).map(([src]) => `${SRC_NAME[src]} ${note ? 'unknown' : usd(sp.by[src] ?? 0)}`).join(', ')}. {pkText}.</p>}
    </Sec>
  );
}

function Budget({ fs, note, now, team }: P) {
  const who = team ? `${teamLabel(store.getState(), team)} only` : 'Every team';
  const s = ovStats(fs), teams = useApp((x) => x.feeds.teams);
  const b = useMemo(() => (s ? ovBudget(s.rows ?? [], now) : null), [s, now]);
  const name = new Date(now).toLocaleDateString(undefined, { month: 'long' });
  if (!s || !b) return <Sec id="ov-budget" sm><Hd t={`${name} spend`} /><EmptyBox>{note ? `Spend unknown: ${note}` : 'Loading the stats…'}</EmptyBox></Sec>;
  const list = (Array.isArray(teams?.data) ? teams.data : []) as J[];
  const caps = teams?.error ? [] : list.filter((t) => t.budget?.month_cap > 0 && !t.budget_error);
  const tnote = !teams ? 'Loading the team budgets…' : teams.error ? `Team budgets unknown: the teams feed failed: ${teams.error}.` : !caps.length ? 'No team has a monthly budget cap.' : '';
  const data: Point[] = b.pts.map((p) => ({ lbl: shortDay(p.t), spent: p.spent, proj: p.proj }));
  return (
    <Sec id="ov-budget" sm>
      <Hd t={`${b.name} spend`}><span className="note mono">{note ? 'unknown' : usd(b.mtd)}</span></Hd>
      {note ? (
        <><div className="ovknote">{note}</div><div className="sub">{who}. The month-end figure is unknown until the stats load again.</div></>
      ) : (
        <>
          <div className="sub">{who}. Day {new Date(now).getDate()} of {b.days.length}. At this rate the month ends near <b>${Math.round(b.end).toLocaleString('en-US')}</b>.</div>
          <div className="ovleg"><span><i className="bg-chart-1" />Spent</span><span><i className="bg-chart-muted" />Projected</span></div>
          <OvChart title={`${b.name} spend of ${team ? teamLabel(store.getState(), team) : 'every team'}, so far and projected`} data={data} height={170} fmt={money}
            series={[{ key: 'spent', name: 'Spent', color: 'chart-1', mark: 'line' }, { key: 'proj', name: 'Projected', color: 'chart-muted', mark: 'line', dash: true }]}
            refs={caps.filter((t) => !team || t.profile === team).slice(0, 3).map((t) => ({ y: t.budget.month_cap, label: `${teamName(t)} cap` }))}
            summary={`${b.name} spend of ${team ? teamLabel(store.getState(), team) : 'every team'}: ${usd(b.mtd)} so far, near ${usd(b.end)} at the month end.`}
            table={{ head: ['Day', 'Spent', 'Projected'], rows: data.map((d) => [d.lbl, d.spent == null ? '' : usd(Number(d.spent)), d.proj == null ? '' : usd(Number(d.proj))]) }} />
        </>
      )}
      {caps.filter((t) => !team || t.profile === team).slice(0, 3).map((t) => {
        const c = capOf(t, b.el, b.days), bu = t.budget;
        return (
          <div className="capr" key={t.profile}>
            <div className="kv"><span>{teamName(t)}</span><b>{usd(bu.month_usd)} of {usd(bu.month_cap)}</b></div>
            <Meter pct={c.pct} tone={c.tone} label={`${teamName(t)}: ${Math.round(c.pct)}% of the cap`} />
            <div className="sub">{c.over ? <b className="badt">Over the cap.</b> : c.day != null ? <>At this rate it passes the cap on <b className="badt">{shortDay(c.day)}</b>.</> : `At this rate it ends near ${usd(c.end)}.`}</div>
          </div>
        );
      })}
      {caps.length > 3 && <a className="note" href="#teams">{caps.length - 3} more capped team{caps.length === 4 ? '' : 's'}<Go /></a>}
      {tnote && <div className="sub">{tnote}</div>}
    </Sec>
  );
}

const RUN_ICON: Record<string, [string, string]> = {
  pipeline: ['bg-chart-1/15 text-chart-1', 'M4 12l5 5L20 6'], slack: ['bg-chart-3/15 text-chart-3', 'M4 5h16v11H8l-4 4z'],
  answer: ['bg-chart-4/15 text-chart-4', 'M12 18v.5M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.7v1'], pass: ['bg-chart-2/15 text-chart-2', 'M12 4v16M4 12h16'],
  depfix: ['bg-chart-5/15 text-chart-5', 'M14 7l3-3 3 3-3 3M17 4v6M4 20l9-9'],
};

// A row that comes after the first paint slides in once. It reads only its own session, so a delta of another one skips it.
const RunRow = memo(function RunRow({ r, site, fresh }: { r: J; site: unknown; fresh: { current: boolean } }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (fresh.current && !reduced()) ref.current?.animate?.([{ transform: 'translateY(-6px)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 250 });
  }, [fresh]);
  const tab = useApp((s) => { const x = s.sessions.byKey[r.key]; return x ? sessTabOf(x) : null; });
  const [ic, d] = RUN_ICON[r.src] ?? ['bg-sunk text-faint', 'M12 12h.01'], kind = RUN_KIND[r.src] ?? r.src, t = rowMs(r);
  const when = new Date(t).setHours(0, 0, 0, 0) === new Date().setHours(0, 0, 0, 0) ? TIME_FMT.format(t) : DAY_FMT.format(t);
  // A session link goes to the tab the session is on now.
  const href = r.src === 'pipeline' ? jiraHref(r.key, site) : tab && sessHref(r.key) ? `#sessions/${tab}/${r.key}` : sessHref(r.key);
  const key = r.src === 'pass' || !r.key ? null : href ? <a className="key" href={href} {...(r.src === 'pipeline' ? { target: '_blank', rel: 'noreferrer' } : {})}>{r.key}</a> : <span className="key">{r.key}</span>;
  // A run with no title can carry its key as the title: do not show the key twice.
  const title = (r.title !== r.key && r.title) || (r.src === 'pass' ? 'Pipeline pass' : ''), b = runBadge(r);
  return (
    <div className="ovrun" data-run={r.key} ref={ref}>
      <time dateTime={r.at}>{when}</time>
      <span className={cx('ic', ic)} title={kind}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden="true"><path d={d} /></svg></span>
      <span className="t" title={[r.key, r.title].filter(Boolean).join(' ')}>{key} {plainMd(title)}</span>
      <span className="r"><Tag label={b.label} tone={b.tone} href={b.href || undefined} /><span>{[r.min != null ? `${r.min} min` : '', r.usd != null ? usd(r.usd) : ''].filter(Boolean).join(' · ')}</span></span>
      <span className="d">{r.team && <Tag label={r.team} />}{[title, b.label].some((x) => x.toLowerCase().includes(String(r.kind || kind).toLowerCase())) ? null : <span>{r.kind || kind}</span>}</span>
    </div>
  );
});

function Activity({ range, note, team }: P) {
  const [runs, setRuns] = useState<{ runs: J[] | null; err: string | null }>({ runs: null, err: null });
  const tick = useApp((s) => s.feeds.full?.fetchedAt ?? 0), site = useApp((s) => (pipeSnap(s) as J)?.team?.jira_site);
  const last = useRef(''), fresh = useRef(false);
  // A range change reads at once; a new snapshot reads again after 5 s, so a burst of frames gives one read.
  useEffect(() => {
    const d = { '7d': 7, '30d': 30, '90d': 90 }[range], at = `${range}:${team}`, wait = last.current === at ? 5000 : 0;
    const id = setTimeout(async () => {
      last.current = at;
      // The API has no team filter: one team reads more runs and keeps its own.
      const g = await latest<J>('ov-runs', `/api/runs/recent?limit=${team ? 100 : 30}&days=${d}`);
      if (!g) return;
      const j = 'data' in g ? g.data : null, err = !('data' in g) ? g.error : !j || !Array.isArray(j.runs) ? 'the answer has no runs' : j.error || null;
      setRuns(err ? { runs: null, err } : { runs: team ? j.runs.filter((r: J) => r.team === team).slice(0, 30) : j.runs, err: null });
    }, wait);
    return () => clearTimeout(id);
  }, [range, team, tick]);
  useEffect(() => { if (runs.runs) fresh.current = true; }, [runs.runs]);
  if (runs.err) return <Sec id="ov-runs" sm><Hd t="Activity" /><EmptyBox>Recent runs unavailable: {runs.err}. The next poll tries again.</EmptyBox></Sec>;
  if (!runs.runs) return <Sec id="ov-runs" sm><Hd t="Activity" /><EmptyBox>Loading the recent runs…</EmptyBox></Sec>;
  return (
    <Sec id="ov-runs" sm>
      <Hd t="Activity"><a className="note" href="#sessions">All sessions<Go /></a></Hd>
      {note && <div className="ovknote">{note}</div>}
      {runs.runs.length ? <div className="ovruns">{runs.runs.map((r) => <RunRow key={`${r.key}:${r.at}`} r={r} site={site} fresh={fresh} />)}</div> : <EmptyBox>No run in the last {rangeName(range)}.</EmptyBox>}
    </Sec>
  );
}

function Llm({ fs, note, now, team }: P) {
  const s = ovStats(fs);
  const l = useMemo(() => (s ? ovLlm(s.llm ?? {}, now) : null), [s, now]);
  if (!s || !l) return <Sec id="ov-llm" sm><Hd t="LLM spend" /><EmptyBox>{note ? `LLM spend unknown: ${note}` : 'Loading the stats…'}</EmptyBox></Sec>;
  const series: Series[] = l.perDay
    ? [...l.top3.map((m, i) => ({ key: `m${i}`, name: modelName(m), color: (['chart-1', 'chart-2', 'chart-3'] as const)[i]! })), { key: 'other', name: 'Other models', color: 'chart-muted' as const }]
    : [{ key: 'usd', name: 'LLM spend', color: 'chart-1' }];
  const data: Point[] = l.days.map((d) => ({ ...d, lbl: shortDay(Date.parse(`${d.day}T00:00`)) }));
  const tot = l.days.reduce((a, d) => a + Number(d.usd), 0);
  return (
    <Sec id="ov-llm" sm>
      <Hd t="LLM spend, 14 days"><span className="note mono">{note || (!data.length && typeof l.hr === 'number' && l.hr > 0) ? 'unknown' : usd(tot)}</span></Hd>
      {note && <div className="ovknote">{note}</div>}
      <div className="sub">By UTC date for the last 14 days, as the LLM proxy logs it.{team && ' Every team: the proxy does not log the team.'}</div>
      {data.length ? (
        <OvChart title="LLM spend by model and UTC day, last 14 days" data={data} series={series} stacked fmt={money} height={200}
          summary={`LLM spend by UTC day, last 14 days. Total ${usd(tot)}.`}
          table={{ head: ['UTC day', ...series.map((x) => x.name)], rows: data.map((d) => [String(d.day), ...series.map((x) => usd(Number(d[x.key] ?? 0)))]) }} />
      ) : <EmptyBox>{typeof l.hr === 'number' && l.hr > 0 ? `Daily LLM spend unknown: the proxy logged ${usd(l.hr)} in the last hour, but no day total yet.` : 'No LLM call in the last 14 UTC days.'}</EmptyBox>}
      {/* The swatch ties each model to its colour in the chart; top3 and top share one order. */}
      {l.top.slice(0, 3).map(([m, v], i) => <Kv key={m} label={<>{l.perDay && <i className={cx('ovsw', ['bg-chart-1', 'bg-chart-2', 'bg-chart-3'][i])} />}{modelName(m)}</>} value={usd(v)} />)}
      {l.rest > 0 && <Kv label={<>{l.perDay && <i className="ovsw bg-chart-muted" />}Other models</>} value={usd(l.rest)} />}
    </Sec>
  );
}

function Hours({ fs, note, now }: P) {
  const s = ovStats(fs);
  const h = useMemo(() => (s ? ovHours(s.rows ?? [], now) : null), [s, now]);
  const w = useMemo(() => (s ? ovWeek(s.rows ?? [], now) : null), [s, now]);
  if (!s || !h || !w) return <Sec id="ov-hours" sm><Hd t="Runs by hour, 24 h" /><EmptyBox>{note ? `Runs unknown: ${note}` : 'Loading the stats…'}</EmptyBox></Sec>;
  const cols = [...Array(24)].map((_, i) => String(i)), wk = w.flat().reduce((a, x) => a + x, 0);
  const cells = w.flatMap((r, i) => r.map((v, j) => ({ row: i, col: j, value: v, label: `${v} run${v === 1 ? '' : 's'}` })));
  const top = cells.reduce((a, c) => (c.value > a.value ? c : a), cells[0]!);
  const data: Point[] = h.b.map((x) => ({ lbl: x.lbl, n: x.n }));
  return (
    <Sec id="ov-hours" sm>
      <Hd t="Runs by hour, 24 h"><span className="note">{note ? 'unknown' : `${h.tot} run${h.tot === 1 ? '' : 's'}`}</span></Hd>
      {note && <div className="ovknote">{note}</div>}
      {h.tot ? (
        <>
          <OvChart title="Runs started per hour, last 24 hours" data={data} series={[{ key: 'n', name: 'Runs', color: 'chart-1', mark: 'bar' }]} fmt={(v) => String(Math.round(v))} height={150}
            summary={`Runs started per hour, last 24 hours. Total ${h.tot}. ${h.text}`} table={{ head: ['Hour', 'Runs'], rows: data.map((d) => [d.lbl, Number(d.n)]) }} />
          <div className="sub">{h.text}</div>
        </>
      ) : <EmptyBox>No run in the last 24 hours.</EmptyBox>}
      <Heatmap title="Runs by weekday and hour, last 4 weeks, local time" rows={WEEKDAYS} cols={cols} cells={cells}
        summary={wk ? `Runs by weekday and hour, last 4 weeks: ${wk} runs. Busiest: ${WEEKDAYS[top.row]} at ${top.col}:00, ${top.label}. Passes are not counted.` : 'Runs by weekday and hour, last 4 weeks: no run.'}
        table={{ head: ['Day', ...cols.map((c) => `${c}:00`)], rows: w.map((r, i) => [WEEKDAYS[i]!, ...r]) }} />
    </Sec>
  );
}

const ACCESS_TONE = (a: string): Tone => (a === 'everyone' || a === 'open' ? 'ok' : a === 'unknown' ? 'dim' : /user/.test(a) ? 'info' : 'bad');

// What ovTeams reads: a session or agents delta that moves no team's count still makes a new floor, so the rows skip their repaint.
const TEAM_PARTS = (s: Store) => [s.feeds.teams, ovFloor(s), ovStats(s)];
type RowP = { t: J; runs: number; prs: number; spend: number; on: number | null; st: boolean; anyCap: boolean; team: string; spark?: number[] };
const link = (t: J) => (/^[a-z][a-z0-9-]{1,30}$/.test(t.profile ?? '') ? <a href={`#teams/${t.profile}`}>{teamName(t)}</a> : teamName(t));

const TeamRow = memo(function TeamRow({ t, runs, prs, spend, on, st, anyCap, team, spark }: RowP) {
  const [a, title] = teamAccess(t), b = t.budget, cap = b?.month_cap;
  return (
    <tr data-team={t.profile} className={team ? (t.profile === team ? 'sel' : 'dimrow') : undefined} aria-current={t.profile === team || undefined}>
      <td>{link(t)} <Tag label={a} tone={ACCESS_TONE(a)} title={title} /></td>
      <td className="num">{on ?? '?'}</td>
      <td className="num">{st ? runs.toLocaleString() : '—'}</td>
      <td className="num">{st ? prs : '—'}</td>
      <td className="bud"><div className="budc">
        <b>{st ? usd(spend) : '—'}</b>
        <span className="hint">{t.budget_error ? 'budget unknown' : cap ? `${usd(b.month_usd)} of ${usd(cap)} this month` : anyCap ? 'no cap' : ''}</span>
        {cap ? <Meter pct={(100 * b.month_usd) / cap} tone={b.month_usd >= cap ? 'bad' : b.month_usd >= 0.9 * cap ? 'warn' : undefined} label={`${teamName(t)}: ${Math.round((100 * b.month_usd) / cap)}% of this month's cap`} /> : null}
        {st && spark && <span className="tspark"><Spark label={`${teamName(t)} spend per day, last 30 days: the top day ${usd(spark.reduce((a, b) => Math.max(a, b), 0))}`} values={spark} format={usd} /></span>}
      </div></td>
    </tr>
  );
});

function Teams({ range, note, now, team }: P) {
  const all = useParts(TEAM_PARTS), teams = all.feeds.teams, n = rangeName(range);
  const rows0 = useMemo(() => ovTeams(all, range), [all, range]);
  // The table shows every team, so it reads every team's rows, not the picked team's.
  const s = ovStats(all as Store), spark = useMemo(() => (s ? teamSpark(s.rows ?? [], now) : {}), [s, now]);
  if (!teams) return <Sec id="ov-teams"><Hd t={`Teams, last ${n}`} /><EmptyBox>Loading the teams…</EmptyBox></Sec>;
  // A failed or stale stats feed: the runs, PRs and spend say unknown, and the rows go by name.
  const st = !!s && !note, rows = st ? rows0 : [...rows0].sort((a, b) => teamName(a.t).localeCompare(teamName(b.t)));
  const failed = (Array.isArray(teams.data) ? teams.data : []).filter((t: J) => t.load_error) as J[];
  const tnote = !teams.error ? '' : rows.length ? `The teams feed failed: ${teams.error}. These rows are from ${ago(Math.round(teams.ageSeconds ?? 0))}.` : `Teams unknown: ${teams.error}.`;
  // "no cap" says something only when some team has a cap or a budget read failed.
  const anyCap = rows.some(({ t }: J) => t.budget?.month_cap > 0 || t.budget_error);
  return (
    <Sec id="ov-teams">
      <Hd t={`Teams, last ${n}`}><a className="note" href="#teams">All teams<Go /></a></Hd>
      {[note, tnote].filter(Boolean).map((t) => <div key={t} className="ovknote">{t}</div>)}
      {rows.length || failed.length ? (
        <div className="tscroll">
          <table className="ovtab">
            <thead><tr><th scope="col">Team</th><th scope="col" className="num">Now</th><th scope="col" className="num">Runs</th><th scope="col" className="num">PRs</th><th scope="col" className="num">Spend</th></tr></thead>
            <tbody>
              {rows.map(({ t, u, now: on }: J) => <TeamRow key={t.profile} t={t} runs={u.runs} prs={u.prs} spend={u.usd} on={on} st={st} anyCap={anyCap} team={team} spark={spark[t.profile]} />)}
              {failed.map((t) => (
                <tr key={t.profile} data-team-error={t.profile}>
                  <td>{teamName(t)} <Tag label="did not load" tone="bad" /></td>
                  <td colSpan={4} className="hint">{typeof t.load_error === 'string' ? t.load_error : 'The team record did not load.'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : teams.error ? null : <EmptyBox>No team.</EmptyBox>}
    </Sec>
  );
}

export default { Main } satisfies ViewChunk;
