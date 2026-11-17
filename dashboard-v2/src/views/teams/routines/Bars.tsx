// Bars over the runs of one routine, oldest first, with an optional limit line (cost against max_usd).
import { Frame, NoData, useChartKeys, useWidth } from '../../../charts/frame';
import type { Tone } from '../../../ui';
import { cx, SVG } from '../../../ui/tone';
import { plural } from '../../../format';

export type Bar = { label: string; value: number | null; tone: Tone; word: string };

const H = 64;

export function Bars({ title, unit, bars, limit, fmt }: { title: string; unit: string; bars: Bar[]; limit?: number; fmt: (n: number) => string }) {
  const [ref, width] = useWidth(320);
  const k = useChartKeys(bars.length);
  const vals = bars.map((b) => b.value ?? 0), max = Math.max(limit ?? 0, ...vals) || 1;
  const w = Math.max(2, Math.min(24, Math.floor(width / Math.max(1, bars.length)) - 2));
  const y = (v: number) => H - (v / max) * (H - 4);
  const say = (b: Bar) => `${b.label}: ${b.value == null ? `no ${unit}` : fmt(b.value)}, ${b.word}`;
  const known = bars.filter((b) => b.value != null), top = known.reduce<Bar | null>((a, b) => (!a || (b.value ?? 0) > (a.value ?? 0) ? b : a), null);
  const over = limit != null ? known.filter((b) => (b.value ?? 0) > limit).length : 0;
  const summary = known.length
    ? `${title}, ${plural(bars.length, 'run')}, oldest first. Highest: ${say(top!)}.${limit != null ? ` Limit ${fmt(limit)}; ${over} over it.` : ''}`
    : `${title}: no data yet.`;
  return (
    <Frame title={title} summary={summary} keys={k.keys} tip={k.active == null ? null : say(bars[k.active]!)}
      table={{ head: ['Run', unit, 'Result'], rows: bars.map((b) => [b.label, b.value == null ? '—' : fmt(b.value), b.word]) }}>
      <div ref={ref}>
        {!known.length ? <NoData /> : (
          <svg width={width} height={H} className="block">
            {bars.map((b, i) => b.value != null && (
              <rect key={i} x={i * (w + 2)} y={y(b.value)} width={w} height={H - y(b.value)} rx={1} onMouseEnter={() => k.setActive(i)}
                className={cx(SVG[b.tone], k.active === i && 'stroke-ink')}><title>{say(b)}</title></rect>
            ))}
            {limit != null && <line x1={0} x2={width} y1={y(limit)} y2={y(limit)} className="stroke-bad" strokeDasharray="4 3" />}
          </svg>
        )}
      </div>
    </Frame>
  );
}
