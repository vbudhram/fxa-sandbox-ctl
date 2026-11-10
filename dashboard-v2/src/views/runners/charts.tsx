// The Sandboxes charts: the runner timeline, the slot grid, the boot steps and the Recently completed scatter.
import { scaleLinear } from 'd3-scale';
import { memo, useEffect, useMemo, useState } from 'react';
import { ChartFrame, Gantt } from '../../charts';
import { Frame, NoData, timeLabel, useChartKeys, useWidth } from '../../charts/frame';
import { short, usd } from '../../format';
import type { J } from '../../model/base';
import { cx } from '../../ui/tone';
import { runBadge } from '../shared/stats';
import { type Tile, timelineRows, WINDOW } from './model';

// The now line moves once a second.
function useNow() {
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => clearInterval(t);
  }, []);
  return now;
}

type TlProps = { rows: J[]; admin: boolean; sel: string; onPick: (id: string) => void };
// A feed frame skips the repaint when the fields the timeline reads are the same; the clock still moves it.
const sameTl = (a: TlProps, b: TlProps) => a.admin === b.admin && a.sel === b.sel && a.onPick === b.onPick
  && JSON.stringify(timelineRows(a.rows, a.admin, 0)) === JSON.stringify(timelineRows(b.rows, b.admin, 0));

export const Timeline = memo(function Timeline({ rows, admin, sel, onPick }: TlProps) {
  const now = useNow();
  // A row that gives only an age starts at the time of the feed read, not at each tick.
  const tl = useMemo(() => timelineRows(rows, admin), [rows, admin]);
  // The live runs set the window; an older fix row starts at its left edge, and a cap past its right edge is in the table.
  const base = tl.some((r) => !r.fix) ? tl.filter((r) => !r.fix) : tl;
  const start = Math.max(now - WINDOW, Math.min(now - 60, ...base.map((r) => r.t0))), end = now + (now - start) / 4;
  const over = tl.filter((r) => r.cap != null && now > r.cap).length, fix = tl.filter((r) => r.fix).length, run = tl.length - fix;
  const summary = !tl.length ? 'Runner timeline: no sandbox runs now.'
    : `Runner timeline: ${run} sandbox${run === 1 ? '' : 'es'} run now${over ? `, ${over} over cap` : ''}${fix ? `, ${fix} need${fix === 1 ? 's' : ''} a fix` : ''}.`;
  return (
    <Gantt title="Runner timeline" summary={summary} start={start} end={end} now={now} selected={sel} onSelect={onPick}
      rows={tl.map((r) => ({ id: r.id, label: r.label, tone: r.fix ? 'bad' : undefined, cap: r.cap != null && r.cap <= end ? r.cap : undefined,
        bars: [{ start: r.t0, end: now, tone: r.fix ? 'bad' : undefined, label: r.cap != null && now > r.cap ? `${r.state}, over cap` : r.state }] }))}
      table={{ head: ['Sandbox', 'Started', 'Up for', 'Cap', 'Now'],
        rows: tl.map((r) => [r.label, timeLabel(r.t0, 0), short(Math.round(now - r.t0)), r.cap != null ? short(Math.round(r.cap - r.t0)) : '—', r.cap != null && now > r.cap ? `${r.state}, over cap` : r.state]) }} />
  );
}, sameTl);

function Tiles({ title, tiles }: { title: string; tiles: Tile[] }) {
  return (
    <div>
      <h3>{title}</h3>
      <ul className="sbtiles" aria-label={title}>
        {tiles.map((t) => (
          <li key={t.id} className={cx('sbtile', t.word, t.gce && 'gce')} title={t.title}>
            <b>{t.name}</b><span>{t.word}{t.gce ? ' · GCE' : ''}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

type GridProps = { pool: Tile[] | null; sess: Tile[] | null; showPool: boolean; showSess: boolean };
export const SlotGrid = memo(function SlotGrid({ pool, sess, showPool, showSess }: GridProps) {
  return (
    <div className="sbgrid" id="sb-slots">
      {showPool && (pool ? <Tiles title="Pipeline slots" tiles={pool} /> : <p className="sbfree">Pipeline slots unknown: the agents feed is not current.</p>)}
      {showSess && (sess ? <Tiles title="Session slots" tiles={sess} /> : <p className="sbfree">Session slots unknown: the agents feed is not current.</p>)}
    </div>
  );
}, (a, b) => a.showPool === b.showPool && a.showSess === b.showSess && JSON.stringify([a.pool, a.sess]) === JSON.stringify([b.pool, b.sess]));

// The boot steps as a waterfall: each step starts where the one before it ends.
export function BootSteps({ steps }: { steps: { step: string; s: number | null }[] }) {
  const total = steps.reduce((n, x) => n + (x.s ?? 0), 0) || 1;
  const long = steps.reduce((a, x) => ((x.s ?? 0) > (a.s ?? 0) ? x : a), steps[0]!);
  const offs = steps.map((_, i) => steps.slice(0, i).reduce((n, x) => n + (x.s ?? 0), 0));
  return (
    <ChartFrame title="Boot steps" summary={`Boot steps: ${steps.length} steps in ${Math.round(total)} s; the longest is ${long.step}, ${long.s ?? '?'} s.`}
      table={{ head: ['Step', 'Seconds'], rows: steps.map((x) => [String(x.step), x.s ?? '—']) }}>
      <div className="sbsteps">
        {steps.map((x, i) => {
          const left = (offs[i]! / total) * 100, w = ((x.s ?? 0) / total) * 100;
          return (
            <div key={i}>
              <span className="nm">{x.step}</span>
              <span className="tr"><i style={{ left: `${left}%`, width: `${w}%` }} /></span>
              <b>{x.s != null ? `${x.s} s` : '—'}</b>
            </div>
          );
        })}
      </div>
    </ChartFrame>
  );
}

const SRC_COLOR: Record<string, string> = { pipeline: 'fill-chart-1', slack: 'fill-chart-3', routine: 'fill-chart-2', depfix: 'fill-chart-5' };
const SRC_WORD: Record<string, string> = { pipeline: 'pipeline', slack: 'Slack', routine: 'routine', depfix: 'dependency fix' };
const srcOf = (r: J) => (r.src === 'pipeline' ? 'pipeline' : r.src === 'depfix' ? 'depfix' : r.routine ? 'routine' : 'slack');
// Shape by outcome: a PR is a circle, a failure a triangle, no change a square, the rest a diamond.
const shape = (o: string, x: number, y: number, r: number) =>
  o === 'pr' ? `M${x - r},${y}a${r},${r} 0 1,0 ${2 * r},0a${r},${r} 0 1,0 ${-2 * r},0`
    : o === 'failed' ? `M${x},${y - r}L${x + r},${y + r}L${x - r},${y + r}Z`
      : o === 'no_pr' || o === 'done' ? `M${x - r},${y - r}h${2 * r}v${2 * r}h${-2 * r}Z` : `M${x},${y - r}L${x + r},${y}L${x},${y + r}L${x - r},${y}Z`;

// Recently completed: time against LLM cost, colour by source, shape by result.
export function DoneScatter({ rows, name }: { rows: J[]; name: (r: J) => string }) {
  const [ref, width] = useWidth();
  const pts = rows.filter((r) => Number.isFinite(Number(r.min)) && Number.isFinite(Number(r.usd)));
  const k = useChartKeys(pts.length);
  const H = 180, L = 52, B = 24, T = 8;
  const x = scaleLinear().domain([0, Math.max(1, ...pts.map((r) => Number(r.min)))]).nice().range([L, Math.max(L + 1, width - 12)]);
  const y = scaleLinear().domain([0, Math.max(0.01, ...pts.map((r) => Number(r.usd)))]).nice().range([H - B, T]);
  const say = (r: J) => `${name(r)}: ${Number(r.min)} min, ${usd(Number(r.usd))}, ${SRC_WORD[srcOf(r)]}, ${runBadge(r).label}`;
  const p = k.active == null ? null : pts[k.active]!;
  const srcs = [...new Set(pts.map(srcOf))];
  const top = pts.reduce<J>((a, r) => (!a || Number(r.usd) > Number(a.usd) ? r : a), null);
  const summary = pts.length ? `Time against LLM cost for ${pts.length} recent runs. The most costly: ${say(top)}.` : 'Time against LLM cost: no run with a time and a cost.';
  return (
    <Frame title="Time and cost" summary={summary} keys={k.keys} tip={p && say(p)}
      table={{ head: ['For', 'Source', 'Time, min', 'LLM cost', 'Result'], rows: pts.map((r) => [name(r), SRC_WORD[srcOf(r)]!, Number(r.min), usd(Number(r.usd)), runBadge(r).label]) }}
      note={pts.length ? <span className="sbd-legend">{srcs.map((s) => <span key={s}><svg width="10" height="10" aria-hidden><rect width="10" height="10" rx="2" className={SRC_COLOR[s]} /></svg> {SRC_WORD[s]}</span>)}<span>circle PR, square no change, triangle failed, diamond other</span></span> : undefined}>
      <div ref={ref}>
        {!pts.length ? <NoData>No run with a time and a cost.</NoData> : (
          <svg width={width} height={H} className="block">
            {y.ticks(4).map((t) => (
              <g key={t}>
                <line x1={L} x2={width - 12} y1={y(t)} y2={y(t)} className="stroke-line" />
                <text x={L - 4} y={y(t)} textAnchor="end" dominantBaseline="middle" className="fill-faint text-tiny">{usd(t)}</text>
              </g>
            ))}
            {x.ticks(Math.max(2, Math.floor((width - L) / 80))).map((t) => (
              <text key={t} x={x(t)} y={H - 6} textAnchor="middle" className="fill-faint text-tiny">{t} min</text>
            ))}
            {pts.map((r, i) => (
              <path key={i} d={shape(r.outcome, x(Number(r.min)), y(Number(r.usd)), k.active === i ? 6 : 4.5)} onMouseEnter={() => k.setActive(i)}
                className={k.active === i ? 'fill-ink' : SRC_COLOR[srcOf(r)]} fillOpacity={k.active === i ? 1 : 0.8}>
                <title>{say(r)}</title>
              </path>
            ))}
          </svg>
        )}
      </div>
    </Frame>
  );
}
