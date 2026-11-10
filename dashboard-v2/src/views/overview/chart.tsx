// One Recharts chart in the shared frame: a stacked area, lines with a band, or bars, by day or hour.
import { createElement, useEffect, useState } from 'react';
import type { ChartColor, ChartTable } from '../../charts';
import { Frame, useChartKeys } from '../../charts/frame';
import type PlotFn from './plot';
import type { PlotProps } from './plot';

export type Series = { key: string; name: string; color: ChartColor; dash?: boolean; mark?: 'area' | 'line' | 'bar' | 'band' };
export type Point = Record<string, unknown> & { lbl: string };

type Props = {
  title: string;
  summary: string;
  table: ChartTable;
  data: Point[];
  series: Series[];
  fmt: (v: number) => string;
  stacked?: boolean;
  height?: number;
  refs?: { y: number; label: string }[];
  yMax?: number;
  onPick?: (i: number) => void;
};

const val = (v: unknown) => (Array.isArray(v) ? v.map(Number) : v == null ? null : Number(v));
const word = (v: number | number[] | null, fmt: (v: number) => string) => (v == null ? 'none' : Array.isArray(v) ? v.map(fmt).join(' to ') : fmt(v));

// Recharts loads beside the first paint, not before it: the frame, its summary and its table show at once, the plot when it is in.
let loaded: typeof PlotFn | null = null;
const ready = import('./plot').then((m) => (loaded = m.default));
function usePlot() {
  const [p, setP] = useState<boolean | Error>(() => !!loaded);
  useEffect(() => {
    if (!p) ready.then(() => setP(true), (e: unknown) => setP(e instanceof Error ? e : new Error(String(e))));
  }, [p]);
  // A failed chunk read shows in the card's error boundary, as an error of the view chunk did.
  if (p instanceof Error) throw p;
  return p;
}
const Plot = (p: PlotProps) => createElement(loaded!, p);

export function OvChart({ title, summary, table, data, series, fmt, stacked, height = 240, refs = [], yMax, onPick }: Props) {
  const has = usePlot();
  const k = useChartKeys(data.length, onPick);
  const tipOf = (i: number) => `${data[i]!.lbl}: ${series.map((s) => `${s.name} ${word(val(data[i]![s.key]), fmt)}`).join(' · ')}`;
  return (
    <Frame title={title} summary={summary} table={table} keys={k.keys} tip={k.active == null ? null : tipOf(k.active)}>
      <div className="ovchart">
        {has ? <Plot data={data} series={series} fmt={fmt} word={(v) => word(val(v), fmt)} stacked={stacked} height={height} refs={refs} yMax={yMax} active={k.active} onPick={onPick} />
          : <div style={{ height }} />}
      </div>
    </Frame>
  );
}
