// The Recharts part of OvChart, in its own chunk: Recharts is about half of the Overview first view.
import { Area, Bar, CartesianGrid, ComposedChart, Line, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import type { Point, Series } from './chart';

export type PlotProps = {
  data: Point[];
  series: Series[];
  fmt: (v: number) => string;
  word: (v: unknown) => string;
  stacked?: boolean;
  height: number;
  refs: { y: number; label: string }[];
  yMax?: number;
  active: number | null;
  onPick?: (i: number) => void;
};

export default function Plot({ data, series, fmt, word, stacked, height, refs, yMax, active, onPick }: PlotProps) {
  return (
    <ResponsiveContainer width="100%" height={height} initialDimension={{ width: 400, height }}>
      <ComposedChart data={data} margin={{ top: 8, right: 8, bottom: 0, left: 0 }} accessibilityLayer={false}
        // Recharts 3 gives the index as text.
        onClick={(e) => { const i = Number(e?.activeTooltipIndex); if (onPick && e?.activeTooltipIndex != null && Number.isInteger(i)) onPick(i); }}
        className={onPick ? 'cursor-pointer' : undefined}>
        <CartesianGrid vertical={false} stroke="var(--line)" />
        <XAxis dataKey="lbl" tickLine={false} axisLine={false} minTickGap={24} />
        <YAxis tickLine={false} axisLine={false} width="auto" tickFormatter={(v: number) => fmt(v)} allowDecimals={false}
          domain={yMax != null ? [0, (max: number) => Math.min(max, yMax)] : [0, 'auto']} allowDataOverflow={yMax != null} />
        <Tooltip isAnimationActive={false} formatter={(v) => word(v)} cursor={{ fill: 'var(--hover)', stroke: 'var(--line2)' }}
          contentStyle={{ background: 'var(--panel)', border: '1px solid var(--line)', borderRadius: 'var(--r-md)', fontSize: 'var(--t-label)', color: 'var(--ink)' }} />
        {series.map((s) => {
          const c = `var(--${s.color})`;
          if (s.mark === 'bar') return <Bar key={s.key} dataKey={s.key} name={s.name} fill={c} stackId={stacked ? 'a' : undefined} isAnimationActive={false} radius={2} />;
          if (s.mark === 'line') return <Line key={s.key} dataKey={s.key} name={s.name} stroke={c} strokeWidth={2} strokeDasharray={s.dash ? '4 3' : undefined} dot={false} connectNulls isAnimationActive={false} />;
          if (s.mark === 'band') return <Area key={s.key} dataKey={s.key} name={s.name} stroke="none" fill={c} fillOpacity={0.18} connectNulls isAnimationActive={false} />;
          return <Area key={s.key} dataKey={s.key} name={s.name} stroke={c} fill={c} fillOpacity={0.35} stackId={stacked ? 'a' : undefined} type="linear" connectNulls={false} isAnimationActive={false} />;
        })}
        {refs.map((r) => <ReferenceLine key={r.label} y={r.y} stroke="var(--ink)" strokeDasharray="4 3" label={{ value: r.label, position: 'insideBottomRight', offset: 6, className: 'ovref' }} />)}
        {active != null && <ReferenceLine x={data[active]!.lbl} stroke="var(--link)" />}
      </ComposedChart>
    </ResponsiveContainer>
  );
}
