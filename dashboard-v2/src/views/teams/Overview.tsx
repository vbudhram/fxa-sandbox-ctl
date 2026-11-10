// A team's Overview: the banner, four tiles, Activity and the budget burn, Recent work, the Routines strip and Readiness.
import { memo, useMemo } from 'react';
import { Frame, NoData, useChartKeys, useWidth } from '../../charts/frame';
import { prUrl, usd } from '../../format';
import { ERRS, type J, LIVE_SESSION, SS, STATS, TEAM_ADMIN } from '../../model/base';
import { teamRepo } from '../../model/pipeline';
import { convTitle, isFix, ownerName, sessHeads, sessHref, sessRoutine, sessTabOf } from '../../model/sessions';
import { rtSum, teamErrs, teamUse } from '../../model/teams';
import { format, HOME } from '../../router';
import { setPref, store, useApp } from '../../store';
import type { Store } from '../../store/types';
import { Card, Meter, StatTile, Tag } from '../../ui';
import { cx } from '../../ui/tone';
import { budgetOf, plural, sinceAgo, teamBanner, teamBurn, teamDays, teamReadiness } from './lib';
import { TestCell } from './parts';
import { useTs } from './state';

const day = (ms: number) => new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
const rowT = (r: J) => r.t0 ?? (r.ms ?? Date.parse(r.at)) / 1000;

function Banner({ t }: { t: J }) {
  const admin = useApp((s) => s.viewer.admin), b = teamBanner(t, admin, useApp((s) => rtSum(s, t.profile)));
  if (!b) return null;
  return (
    <div className="tbanner" role="alert">
      <div>
        <b>{b.head}</b>{b.more > 0 && <span className="na"> and {b.more} more</span>}
        <div>{b.why}{!admin && b.act ? ' A team admin can fix this. Ask the operator.' : ''}</div>
      </div>
      {admin && b.act && <a className="btn" href={b.act[0]} onClick={b.act[2] ? () => useTs.setState({ tact: t.profile }) : undefined}>{b.act[1]}</a>}
    </div>
  );
}

// 30 bars, Slack cost on pipeline cost; a day with runs and no cost still shows its count.
// memo: an errors or a session delta repaints the tiles, not the 30-day pass over the stats rows.
const Activity = memo(function Activity({ p }: { p: string }) {
  const rows = useApp((s) => STATS(s)?.rows ?? null), [ref, width] = useWidth(300);
  const ds = teamDays(rows, p), k = useChartKeys(ds.length);
  if (!rows) return <><h3>Activity, 30 days</h3><p className="na">—</p></>;
  const total = ds.reduce((n, d) => n + d.n, 0), maxN = Math.max(1, ...ds.map((d) => d.n));
  const slack = ds.reduce((n, d) => n + d.slack, 0), pipe = ds.reduce((n, d) => n + d.pipe, 0);
  const byCost = slack + pipe > 0, top = byCost ? Math.max(...ds.map((d) => d.slack + d.pipe)) : maxN;
  const H = 64, w = width / ds.length, y = (v: number) => (v / top) * (H - 6);
  const word = (i: number) => { const d = ds[i]!; return `${day(d.day)}: ${plural(d.n, 'session or run', 'sessions and runs')}, Slack ${usd(d.slack)}, pipeline ${usd(d.pipe)}`; };
  return (
    <Frame title="Activity, 30 days" keys={k.keys} tip={k.active == null ? null : word(k.active)}
      summary={`${total} sessions and runs in 30 days, at most ${maxN} a day. Slack ${usd(slack)}, pipeline ${usd(pipe)}.`}
      table={{ head: ['Day', 'Sessions and runs', 'Slack', 'Pipeline'], rows: ds.map((d) => [day(d.day), d.n, usd(d.slack), usd(d.pipe)]) }}
      note={<span className="tchartl"><span>30 days ago</span><span>{total} sessions and runs{byCost ? ' · cost: pipeline under Slack' : ''}</span><span>today</span></span>}>
      <div ref={ref}>
        {!total ? <NoData>No sessions or runs in 30 days.</NoData> : (
          <svg width={width} height={H} className="block">
            {ds.map((d, i) => {
              const a = byCost ? y(d.slack) : y(d.n), b = byCost ? y(d.pipe) : 0, on = k.active === i;
              return (
                <g key={d.day} onMouseEnter={() => k.setActive(i)} onMouseLeave={() => k.setActive(null)}>
                  <rect x={i * w + 1} y={0} width={Math.max(1, w - 2)} height={H} className="fill-transparent" />
                  {b > 0 && <rect x={i * w + 1} y={H - 2 - b} width={Math.max(1, w - 2)} height={b} rx={1} className={cx('fill-chart-2', on && 'opacity-70')} />}
                  <rect x={i * w + 1} y={H - 2 - b - Math.max(d.n ? 1 : 0, a)} width={Math.max(1, w - 2)} height={Math.max(d.n ? 1 : 0, a)} rx={1} className={cx('fill-chart-1', on && 'opacity-70')} />
                </g>
              );
            })}
            <line x1={0} x2={width} y1={H - 1.5} y2={H - 1.5} className="stroke-line" />
          </svg>
        )}
      </div>
    </Frame>
  );
});

// This month's spend so far, the straight-line projection to the month end, and the cap.
const Burn = memo(function Burn({ t }: { t: J }) {
  const rows = useApp((s) => STATS(s)?.rows ?? null), [ref, width] = useWidth(300);
  const b = t.budget, d = teamBurn(rows, t.profile, b?.month_usd ?? 0), k = useChartKeys(d.cum.length);
  if (!b || !rows) return null;
  const cap = b.month_cap ?? 0, top = Math.max(cap, d.projected, ...d.cum, 0.01), H = 80;
  const x = (i: number) => (i / Math.max(1, d.ndays - 1)) * (width - 4) + 2, y = (v: number) => H - 2 - (v / top) * (H - 8);
  const line = d.cum.map((v, i) => `${x(i)},${y(v)}`).join(' ');
  const over = cap && d.projected > cap ? `, over the ${usd(cap)} cap` : '';
  const monthDay = (i: number) => { const n = new Date(); return day(new Date(n.getFullYear(), n.getMonth(), i + 1).getTime()); };
  return (
    <Frame title="Budget this month" keys={k.keys} tip={k.active == null ? null : `${monthDay(k.active)}: ${usd(d.cum[k.active])} spent so far`}
      summary={`Spent ${usd(b.month_usd)} this month${cap ? ` of ${usd(cap)}` : ''}. At this rate, ${usd(d.projected)} by the month end${over}.`}
      table={{ head: ['Day', 'Spent so far'], rows: d.cum.map((v, i) => [monthDay(i), usd(v)]) }}
      note={cap ? `The line at the top is the ${usd(cap)} cap; the dashes are the projection.` : 'No cap; the dashes are the projection.'}>
      <div ref={ref}>
        <svg width={width} height={H} className="block">
          {cap > 0 && <line x1={0} x2={width} y1={y(cap)} y2={y(cap)} className="stroke-bad" strokeDasharray="2 2" />}
          <polyline points={line} fill="none" className="stroke-chart-1" strokeWidth={2} />
          <line x1={x(d.today - 1)} y1={y(d.cum[d.today - 1] ?? 0)} x2={x(d.ndays - 1)} y2={y(d.projected)} className="stroke-chart-1" strokeDasharray="4 3" />
          {d.cum.map((v, i) => (
            <circle key={i} cx={x(i)} cy={y(v)} r={k.active === i ? 4 : 2} className="fill-chart-1" onMouseEnter={() => k.setActive(i)} onMouseLeave={() => k.setActive(null)} />
          ))}
        </svg>
      </div>
    </Frame>
  );
});

// The 5 newest runs of the team; a routine run is named only for an admin.
const Recent = memo(function Recent({ p }: { p: string }) {
  const stats = useApp((s) => STATS(s)), ss = useApp(SS), admin = useApp((s) => TEAM_ADMIN(s).admin);
  // A session delta changes the names only: the newest 5 rows wait for a stats change.
  const rows = useMemo(() => ((stats?.rows ?? []) as J[]).filter((r) => (r.profile || 'fxa') === p).sort((a, b) => rowT(b) - rowT(a)).slice(0, 5), [stats, p]);
  if (!stats) return <p className="na">—</p>;
  const by = new Map(ss.map((x) => [x.key, x])), st = store.getState() as Store;
  if (!rows.length) return <p className="na">No sessions or runs in 30 days.</p>;
  return (
    <>
      {rows.map((r, i) => {
        const x = by.get(r.key), name = r.src === 'pass' ? 'Pipeline pass' : x ? (x.routine_run ? (admin || isFix(x) ? sessRoutine(st, x) : ownerName(st, x) || 'scheduled run') : convTitle(st, x)) : r.key;
        const h = sessHref(r.key), pu = r.pr ? prUrl(r.pr, teamRepo(st, '')) : '';
        return (
          <div key={i} className="titem">
            <span>{h ? <a className="lnk" href={h}>{name}</a> : name} {r.src !== 'pass' && <span className="na">· {r.src}</span>}</span>
            <span>{r.pr ? (pu ? <a className="lnk" href={pu} target="_blank" rel="noopener noreferrer">PR #{r.pr}</a> : `PR #${r.pr}`) : <span className="na">{sinceAgo(rowT(r))}</span>}</span>
          </div>
        );
      })}
    </>
  );
});

function Readiness({ t }: { t: J }) {
  const rows = teamReadiness(t), good = rows.filter((r) => r[1] === 'good').length, set = `#teams/${t.profile}/settings`;
  if (good === rows.length) return <Card className="tcard"><span className="trd"><b>Readiness</b> {good} of {good} good.</span> <a className="lnk" href={set}>Open Settings</a></Card>;
  return (
    <Card className="tcard">
      <h3>Readiness <span className="na">{good} of {rows.length} good</span></h3>
      {rows.map(([k, st, d]) => (
        <div key={k} className="titem">
          <span><b>{k}</b> <span className="na">{d}</span></span>
          <span><Tag label={st} tone={st === 'good' ? 'ok' : st === 'required' ? 'warn' : undefined} /> <a className="lnk" href={set} aria-label={`Edit ${k.toLowerCase()}`}>Edit</a></span>
        </div>
      ))}
    </Card>
  );
}

export function Overview({ t }: { t: J }) {
  const p = t.profile, use = useApp(teamUse), er = useApp(teamErrs), r = useApp((s) => rtSum(s, p)), admin = useApp((s) => s.viewer.admin);
  const sumErr = useApp((s) => s.teamsUi.summary.error), u = use?.[p];
  // Active now counts the team's live sessions from the session rows, so a delta moves it at once.
  const live = useApp((s) => (s.feeds.agents?.data ? SS(s).filter((x) => (x.profile || 'fxa') === p && LIVE_SESSION.includes(x.state ?? '')).length : null));
  const tab = useApp((s) => { const h = sessHeads(SS(s)).filter((x) => (x.profile || 'fxa') === p).sort((x, y) => (y.created ?? 0) - (x.created ?? 0))[0]; return h ? sessTabOf(h) : 'stopped'; });
  const errsKnown = useApp((s) => !!ERRS(s));
  const split = use ? <span className="block">Slack {usd(u?.slack_usd ?? 0)} · pipeline {usd(u?.pipe_usd ?? 0)}, 30 days</span> : null;
  const b = budgetOf(t);
  const cost = b.kind === 'error' ? <StatTile label="Cost this month" value="—" sub={<span className="unknown">budget unknown: the spend file cannot be read</span>} />
    : b.kind === 'none' ? <StatTile label="Cost, 30 days" value={use ? usd(u?.usd ?? 0) : '—'} sub={<>budget unknown on this host{split}</>} />
    : <StatTile label={`Cost this month${b.kind === 'cap' ? ', of budget' : ''}`} value={usd(b.spent)}
        sub={<>{b.kind === 'cap' ? <>of {usd(b.cap)}<Meter pct={b.pct} tone={b.tone} label={`${Math.round(b.pct)}% of the budget`} /></> : 'no cap'}{split}</>} />;
  const tested = (t.issues ?? []).find((i: J) => /^last passed at generation/.test(i.text));
  const statsTeam = () => setPref('statsFilter', { ...store.getState().prefs.statsFilter, team: p });
  return (
    <>
      <Banner t={t} />
      <div className="tkpis">
        {cost}
        <StatTile label="Active now" value={live ?? '—'} sub={<><a className="lnk" href={format({ ...HOME, view: 'sessions', tab, query: { team: p } })}>Its sessions</a> · <a className="lnk" href="#stats/spend" onClick={statsTeam}>Its spend in Stats</a></>} />
        <StatTile label="Open errors" value={errsKnown && er ? er[p] ?? 0 : '—'} sub={<a className="lnk" href="#errors">Open in Errors</a>} />
        {t.access?.record || t.test ? <StatTile label="Last profile test" value={<TestCell t={t} />} sub={tested ? tested.text : ''} />
          : <StatTile label="Last profile test" value="—" sub="no record to test" />}
      </div>
      <div className="tcols">
        <Card className="tcard"><Activity p={p} /></Card>
        <Card className="tcard"><h3>Recent work</h3><Recent p={p} /></Card>
      </div>
      {t.budget && <Card className="tcard"><Burn t={t} /></Card>}
      {r ? (
        <Card className="tcard">
          <h3>Routines <a href={`#teams/${p}/routines`} className="lnk">All {plural(r.routines ?? 0, 'routine')}</a></h3>
          <div className="tkpis three">
            <StatTile label={r.failed ? 'Failed last run' : 'Failed runs'} value={r.last_failed ? r.last_failed.name ?? '' : 'none'} tone={r.failed ? 'bad' : undefined}
              sub={r.last_failed ? `${sinceAgo(r.last_failed.at)} · ${r.last_failed.reason ?? ''}` : ''} />
            <StatTile label="Routines" value={r.routines ?? 0} sub={`${r.paused ?? 0} paused · ${r.live ?? 0} running`} />
            <StatTile label="Routine cost, 30 days" value={usd(r.cost_30d as number)} sub={plural((r.runs_30d as number) ?? 0, 'run')} />
          </div>
        </Card>
      ) : admin && sumErr ? <Card className="tcard"><p className="unknown">Routine status unknown: {sumErr}</p></Card> : null}
      <Readiness t={t} />
    </>
  );
}
